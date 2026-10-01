import Foundation

actor ADBTransport: TransportProtocol {
    private let adbPath: String
    private let defaultTimeout: TimeInterval

    init(adbPath: String = "/opt/homebrew/bin/adb", defaultTimeout: TimeInterval = 30.0) {
        self.adbPath = adbPath
        self.defaultTimeout = defaultTimeout
    }

    func execute(command: String, arguments: [String], timeout: TimeInterval) async throws -> TransportResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: adbPath)
        process.arguments = [command] + arguments

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        let effectiveTimeout = timeout > 0 ? timeout : defaultTimeout

        return try await withThrowingTaskGroup(of: TransportResult?.self) { group in
            group.addTask {
                do {
                    try process.run()
                } catch {
                    return TransportResult(
                        exitCode: -1,
                        stdout: "",
                        stderr: "Failed to launch ADB: \(error.localizedDescription)"
                    )
                }

                process.waitUntilExit()

                let stdoutData = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
                let stderrData = stderrPipe.fileHandleForReading.readDataToEndOfFile()

                let stdout = String(data: stdoutData, encoding: .utf8) ?? ""
                let stderr = String(data: stderrData, encoding: .utf8) ?? ""

                return TransportResult(
                    exitCode: process.terminationStatus,
                    stdout: stdout,
                    stderr: stderr
                )
            }

            group.addTask {
                try? await Task.sleep(nanoseconds: UInt64(effectiveTimeout * 1_000_000_000))
                if process.isRunning {
                    process.terminate()
                    return TransportResult(
                        exitCode: -1,
                        stdout: "",
                        stderr: "Command timed out after \(effectiveTimeout)s"
                    )
                }
                return nil
            }

            guard let result = try await group.next() else {
                group.cancelAll()
                throw PixelDesktopError.unknown("No result from ADB command")
            }

            group.cancelAll()

            guard let transportResult = result else {
                throw PixelDesktopError.unknown("No result from ADB command")
            }

            return transportResult
        }
    }

    func listDevices() async throws -> [AndroidDevice] {
        let result = try await execute(command: "devices", arguments: ["-l"], timeout: 10)

        guard result.isSuccess else {
            throw PixelDesktopError.adbCommandFailed(
                command: "devices -l",
                exitCode: Int(result.exitCode),
                stderr: result.stderr
            )
        }

        return parseDeviceList(result.stdout)
    }

    nonisolated func parseDeviceList(_ output: String) -> [AndroidDevice] {
        var devices: [AndroidDevice] = []
        let lines = output.components(separatedBy: .newlines)

        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty,
                  !trimmed.hasPrefix("List of devices"),
                  trimmed.contains("device") || trimmed.contains("unauthorized") || trimmed.contains("offline") else {
                continue
            }

            let parts = trimmed.components(separatedBy: .whitespaces).filter { !$0.isEmpty }
            guard parts.count >= 2 else { continue }

            let serial = parts[0]
            let stateString = parts[1]

            let state: DeviceState
            switch stateString {
            case "device": state = .device
            case "unauthorized": state = .unauthorized
            case "offline": state = .offline
            default: state = .unknown
            }

            // The `device:` token is the build codename (`lynx`), NOT the marketing name
            // and NOT the manufacturer. Both of those come from `getprop` during
            // enrichment; this call must not pretend to know them.
            var codename = ""

            for part in parts {
                if part.hasPrefix("device:") {
                    codename = String(part.dropFirst(7))
                }
            }

            let device = AndroidDevice(
                id: serial,
                serialNumber: serial,
                deviceCodename: codename,
                marketingName: "",
                manufacturer: "",
                androidVersion: "",
                apiLevel: 0,
                architecture: "",
                supportedABIs: [],
                state: state
            )

            devices.append(device)
        }

        return devices
    }

    // MARK: - Property retrieval

    func getprop(deviceSerial: String, key: String, timeout: TimeInterval) async throws -> String {
        let result = try await execute(
            command: "-s",
            arguments: [deviceSerial, "shell", "getprop", key],
            timeout: timeout
        )

        guard result.isSuccess else {
            throw PixelDesktopError.adbCommandFailed(
                command: "getprop \(key)",
                exitCode: Int(result.exitCode),
                stderr: result.stderr
            )
        }

        let value = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)

        guard !value.isEmpty else {
            throw PixelDesktopError.invalidInput(
                "Property '\(key)' is unset on device \(deviceSerial)"
            )
        }

        return value
    }

    func shell(deviceSerial: String, command: String, timeout: TimeInterval) async throws -> TransportResult {
        try await execute(
            command: "-s",
            arguments: [deviceSerial, "shell", command],
            timeout: timeout
        )
    }

    func getSystemProperties(deviceSerial: String, timeout: TimeInterval) async throws -> [String: String] {
        let result = try await execute(
            command: "-s",
            arguments: [deviceSerial, "shell", "getprop"],
            timeout: timeout
        )

        guard result.isSuccess else {
            throw PixelDesktopError.adbCommandFailed(
                command: "getprop",
                exitCode: Int(result.exitCode),
                stderr: result.stderr
            )
        }

        return Self.parseSystemProperties(result.stdout)
    }

    /// Parses the output of a bare `adb shell getprop`.
    ///
    /// Each line has the form `[key]: [value]`, e.g.
    /// `[ro.product.model]: [Pixel 7a]`. Values may contain `]`, spaces and commas,
    /// so the value is taken as everything after the first `]: [` rather than by
    /// splitting on brackets.
    ///
    /// Unset properties print as `[key]: []` and are omitted from the result, so
    /// callers can distinguish "absent" from "present but empty".
    nonisolated static func parseSystemProperties(_ output: String) -> [String: String] {
        var properties: [String: String] = [:]

        for line in output.components(separatedBy: .newlines) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix("["), let separator = trimmed.range(of: "]: [") else {
                continue
            }

            let key = String(trimmed[trimmed.index(after: trimmed.startIndex)..<separator.lowerBound])
            var value = String(trimmed[separator.upperBound...])

            // Drop the single trailing `]` that closes the value.
            if value.hasSuffix("]") {
                value.removeLast()
            }

            let trimmedValue = value.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !key.isEmpty, !trimmedValue.isEmpty else {
                continue
            }

            properties[key] = trimmedValue
        }

        return properties
    }
}
