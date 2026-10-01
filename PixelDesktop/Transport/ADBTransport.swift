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

        return try await withTaskGroup(of: TransportResult?.self) { group in
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

            let result = await group.nextResult()
            group.cancelAll()

            guard let transportResult = result ?? nil else {
                throw PixelDesktopError.unknown("No result from ADB command")
            }

            return transportResult
        }
    }

    func listDevices() async throws -> [PixelDevice] {
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

    private func parseDeviceList(_ output: String) -> [PixelDevice] {
        var devices: [PixelDevice] = []
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

            var model = ""
            var manufacturer = ""

            for (index, part) in parts.enumerated() {
                if part.hasPrefix("model:") {
                    model = String(part.dropFirst(6))
                } else if part.hasPrefix("device:") {
                    manufacturer = String(part.dropFirst(7))
                }
            }

            let device = PixelDevice(
                id: serial,
                serialNumber: serial,
                model: model,
                manufacturer: manufacturer,
                androidVersion: "",
                apiLevel: 0,
                architecture: "",
                state: state
            )

            devices.append(device)
        }

        return devices
    }
}
