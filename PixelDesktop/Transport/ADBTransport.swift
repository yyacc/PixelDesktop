import Foundation

actor ADBTransport: TransportProtocol {
    private let adbPath: String
    private let defaultTimeout: TimeInterval

    /// How long a streaming session may go without the child exiting before it is torn down.
    ///
    /// This is **not** a job timeout — it is a *stall* detector. A live worker reports a heartbeat
    /// every 0.5 s, so silence of this length means the transport is gone, not that the job is long.
    /// E1 F5 proved a job may legitimately exceed 90 s, so the bound is on quiet, not duration.
    static let streamStallTimeout: TimeInterval = 120.0

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

    func push(deviceSerial: String, localPath: String, remotePath: String, timeout: TimeInterval) async throws -> TransportResult {
        try await execute(
            command: "-s",
            arguments: [deviceSerial, "push", localPath, remotePath],
            timeout: timeout
        )
    }

    func pull(deviceSerial: String, remotePath: String, localPath: String, timeout: TimeInterval) async throws -> TransportResult {
        try await execute(
            command: "-s",
            arguments: [deviceSerial, "pull", remotePath, localPath],
            timeout: timeout
        )
    }

    func install(deviceSerial: String, apkPath: String, replace: Bool, timeout: TimeInterval) async throws -> TransportResult {
        var arguments = [deviceSerial, "install"]
        if replace {
            arguments.append("-r")
        }
        arguments.append(apkPath)

        return try await execute(command: "-s", arguments: arguments, timeout: timeout)
    }

    func shell(deviceSerial: String, command: String, timeout: TimeInterval) async throws -> TransportResult {
        try await execute(
            command: "-s",
            arguments: [deviceSerial, "shell", command],
            timeout: timeout
        )
    }

    /// Runs a command in the device shell, delivering stdout incrementally.
    ///
    /// Reads stdout on a dedicated thread so lines are surfaced **as produced** rather than at
    /// exit. `readabilityHandler` is deliberately not used: it delivers arbitrary byte chunks, not
    /// lines, which would push line assembly onto every caller and make the "arrives incrementally"
    /// property harder to reason about.
    ///
    /// stdin is written and closed **before** reading begins. `cat > file` on the device blocks
    /// until EOF, so a script that reads stdin and then emits protocol lines only starts producing
    /// output once the write side is closed.
    ///
    /// - Note: There is intentionally **no timeout parameter**. E1 F5 showed a job can exceed 90 s,
    ///   so an arbitrary deadline here would be a fabricated failure. The caller owns termination,
    ///   and a transport that dies ends the stream by itself.
    func shellStreaming(
        deviceSerial: String,
        command: String,
        stdin: String?,
        onLine: @Sendable @escaping (String) -> Void,
        onStderrLine: @Sendable @escaping (String) -> Void
    ) async throws -> Int32 {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: adbPath)
        process.arguments = ["-s", deviceSerial, "shell", command]

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        let stdinPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe
        process.standardInput = stdinPipe

        do {
            try process.run()
        } catch {
            throw PixelDesktopError.adbTransportError(
                "Failed to launch ADB for streaming: \(error.localizedDescription)"
            )
        }

        // Write the payload, then close. Doing this before the read loop is what unblocks the
        // device-side `cat`.
        if let stdin, let data = stdin.data(using: .utf8) {
            do {
                try stdinPipe.fileHandleForWriting.write(contentsOf: data)
            } catch {
                // A failed write means the session died before the payload landed. Close and let
                // the read loop observe the exit rather than reporting a write error as the cause.
            }
        }
        try? stdinPipe.fileHandleForWriting.close()

        // Drain stderr concurrently. A device script can produce enough stderr to fill the pipe
        // buffer and deadlock the child if nobody reads it.
        //
        // The drain is bounded by the same stall timeout as stdout. Without a bound, a transport
        // that dies while `adb` keeps its stderr pipe open leaves this thread blocked in
        // `availableData` forever — a leaked thread per session, which is exactly the class of
        // defect already found twice in this path.
        let stderrHandle = stderrPipe.fileHandleForReading
        let stderrQueue = DispatchQueue(label: "pixeldesktop.adb.stderr")
        stderrQueue.asyncAfter(deadline: .now() + Self.streamStallTimeout + 5.0) {
            try? stderrHandle.close()
        }
        stderrQueue.async {
            var buffer = Data()
            while true {
                let chunk = stderrHandle.availableData
                if chunk.isEmpty { break }
                buffer.append(chunk)
                while let newline = buffer.firstIndex(of: 0x0A) {
                    let lineData = buffer[buffer.startIndex..<newline]
                    buffer.removeSubrange(buffer.startIndex...newline)
                    if let line = String(data: lineData, encoding: .utf8) {
                        onStderrLine(line)
                    }
                }
            }
            if !buffer.isEmpty, let line = String(data: buffer, encoding: .utf8) {
                onStderrLine(line)
            }
        }

        // Read stdout incrementally on a separate thread; the async context awaits its completion.
        //
        // The read must be **interruptible**, and the continuation must be resumed on **every**
        // path. Two distinct hangs were observed on the real device during implementation:
        //
        //  1. `availableData` can block forever when the transport dies mid-session — `adb` does
        //     not always tear its pipes down when the device disappears.
        //  2. The child can exit while the reader thread is still blocked in `availableData`. If
        //     the watchdog only acts when `process.isRunning`, nothing ever resumes the
        //     continuation and the caller waits forever.
        //
        // So the watchdog runs unconditionally: it reaps the child, closes the read end to unblock
        // the reader, and resumes. `StreamReadState` guarantees exactly one resume wins.
        let stdoutHandle = stdoutPipe.fileHandleForReading
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let state = StreamReadState()
            let queue = DispatchQueue(label: "pixeldesktop.adb.stdout")

            queue.async {
                var buffer = Data()
                while true {
                    let chunk = stdoutHandle.availableData
                    if chunk.isEmpty { break }
                    if state.isCancelled { break }
                    buffer.append(chunk)
                    while let newline = buffer.firstIndex(of: 0x0A) {
                        let lineData = buffer[buffer.startIndex..<newline]
                        buffer.removeSubrange(buffer.startIndex...newline)
                        // Drop a trailing CR so CRLF output cannot smuggle a stray character into
                        // the protocol parser.
                        var line = String(data: lineData, encoding: .utf8) ?? ""
                        if line.hasSuffix("\r") { line.removeLast() }
                        onLine(line)
                    }
                }
                if !state.isCancelled, !buffer.isEmpty {
                    var line = String(data: buffer, encoding: .utf8) ?? ""
                    if line.hasSuffix("\r") { line.removeLast() }
                    onLine(line)
                }
                state.finish(continuation)
            }

            // Watchdog: unconditional. A live worker reports a heartbeat every 0.5 s, so silence of
            // `streamStallTimeout` means the transport is gone — not that the job is long. This is
            // a stall detector, never a job-duration limit (E1 F5).
            let watchdog = DispatchQueue(label: "pixeldesktop.adb.watchdog")
            watchdog.asyncAfter(deadline: .now() + Self.streamStallTimeout) {
                guard !state.isFinished else { return }

                if process.isRunning {
                    process.terminate()
                    Thread.sleep(forTimeInterval: 0.5)
                    if process.isRunning {
                        kill(process.processIdentifier, SIGKILL)
                    }
                }
                // Closing the read end is what unblocks a reader stuck in `availableData`.
                try? stdoutHandle.close()
                state.cancel()
                state.finish(continuation)
            }
        }

        // Reap the child without blocking indefinitely.
        //
        // `waitUntilExit()` was the last unbounded wait in this path: when the transport dies, the
        // `adb` child can remain alive and blocked even after the read end is closed, so the
        // caller would never return. Observed on the real device — the wireless entry vanished
        // mid-session and the run sat for 15 minutes with the watchdog already fired. The child is
        // therefore polled with a deadline and killed if it does not exit.
        let reapDeadline = Date().addingTimeInterval(5.0)
        while process.isRunning, Date() < reapDeadline {
            Thread.sleep(forTimeInterval: 0.05)
        }

        if process.isRunning {
            process.terminate()
            Thread.sleep(forTimeInterval: 0.3)
            if process.isRunning {
                kill(process.processIdentifier, SIGKILL)
            }
            // The session ended without a clean exit. Reported as a failure exit so the caller
            // treats it as a lost session rather than a completed job.
            return -1
        }

        return process.terminationStatus
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
