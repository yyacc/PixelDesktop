import Foundation

/// A mutable payload shared between two pipe-drain threads and the awaiting task.
///
/// Each pipe is drained by its own thread, so the two writes never contend with each other — but
/// the reader does read both after the drain group completes, which establishes the happens-before.
/// The lock is therefore about the Swift memory model rather than about racing writers.
///
/// This type exists only because Swift has no `DispatchGroup`-combined tuple return: the drain
/// results have to land somewhere the awaiting task can read them from.
private final class PipePayloads: @unchecked Sendable {
    private let lock = NSLock()
    private var _stdout = Data()
    private var _stderr = Data()

    func setStdout(_ data: Data) {
        lock.lock(); _stdout = data; lock.unlock()
    }

    func setStderr(_ data: Data) {
        lock.lock(); _stderr = data; lock.unlock()
    }

    var stdout: Data {
        lock.lock(); defer { lock.unlock() }; return _stdout
    }

    var stderr: Data {
        lock.lock(); defer { lock.unlock() }; return _stderr
    }
}

actor ADBTransport: TransportProtocol, ConnectionTransporting {
    private let adbPath: String
    private let defaultTimeout: TimeInterval

    /// How long a streaming session may go without the child exiting before it is torn down.
    ///
    /// This is **not** a job timeout — it is a *stall* detector. A live worker reports a heartbeat
    /// every 0.5 s, so silence of this length means the transport is gone, not that the job is long.
    /// E1 F5 proved a job may legitimately exceed 90 s, so the bound is on quiet, not duration.
    ///
    /// Instance-level rather than static so the watchdog's termination path can be exercised in
    /// bounded time by a regression test. A test that had to wait the production 120 s to observe
    /// the watchdog would be a test nobody runs.
    let streamStallTimeout: TimeInterval

    /// How long to wait for the child to exit before forcibly reaping it.
    ///
    /// Also instance-level for the same reason: it is a termination path, and termination paths
    /// must be testable.
    let childReapTimeout: TimeInterval

    init(
        adbPath: String = "/opt/homebrew/bin/adb",
        defaultTimeout: TimeInterval = 30.0,
        streamStallTimeout: TimeInterval = 120.0,
        childReapTimeout: TimeInterval = 5.0
    ) {
        self.adbPath = adbPath
        self.defaultTimeout = defaultTimeout
        self.streamStallTimeout = streamStallTimeout
        self.childReapTimeout = childReapTimeout
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

                // Drain BOTH pipes while the child is still running.
                //
                // Reading only after `waitUntilExit()` deadlocks. The child's `write` blocks once
                // it has filled the pipe's buffer (65,536 bytes on macOS — measured, not assumed),
                // so it never exits, so the wait never returns. The timeout task eventually kills
                // it and the output is truncated to exactly one buffer.
                //
                // Reachability, stated precisely (corrected after an earlier draft of this comment
                // overstated it): `execute()` is reached in production by `listDevices`,
                // `getprop`, `push`, `pull`, `install`, `shell`, and `getSystemProperties`. Of
                // those, the ones that can carry device-controlled volume are `shell` (whose
                // callers include `PixelEvidence`'s combined reads and `WorkerStreamRunner`'s
                // `cat result.json` during F7 recovery) and `getSystemProperties` (53,721 bytes
                // measured — 82% of the buffer).
                //
                // `getSystemProperties` is currently reached only through
                // `DeviceManager.enrichDevice`, which has no non-test caller yet, so that specific
                // chain is latent rather than active. The defect is nonetheless real and one
                // command away from firing: any read whose device-side output exceeds the buffer
                // deadlocks and truncates. Fixing it here, at the single shared chokepoint, is what
                // keeps that from being a per-caller concern.
                let payloads = PipePayloads()
                let drain = DispatchGroup()

                drain.enter()
                DispatchQueue.global(qos: .userInitiated).async {
                    payloads.setStdout(stdoutPipe.fileHandleForReading.readDataToEndOfFile())
                    drain.leave()
                }
                drain.enter()
                DispatchQueue.global(qos: .userInitiated).async {
                    payloads.setStderr(stderrPipe.fileHandleForReading.readDataToEndOfFile())
                    drain.leave()
                }

                process.waitUntilExit()

                // The child has exited, so its write ends are closed and both drains observe EOF
                // immediately. Bounded anyway: a grandchild that inherited a write end could hold
                // the pipe open, and an unbounded wait here would reintroduce the very hang this
                // removes. On that (unreachable in practice) timeout the stream is reported as far
                // as it was drained rather than blocking the caller.
                _ = drain.wait(timeout: .now() + 2.0)

                let stdout = String(data: payloads.stdout, encoding: .utf8) ?? ""
                let stderr = String(data: payloads.stderr, encoding: .utf8) ?? ""

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
                    // A timeout is a distinct condition from "the command ran and exited
                    // non-zero", and it used to be indistinguishable from a launch failure:
                    // both returned `exitCode: -1`, separated only by an English stderr string.
                    // Throw the typed case at the point the condition is detected instead, so no
                    // caller has to reconstruct it from prose. The `-1` sentinel is not used here.
                    throw PixelDesktopError.timeout(
                        operation: "adb \(command)",
                        duration: effectiveTimeout
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

    // MARK: - Wireless connect

    /// Establishes a wireless ADB connection via `adb connect <host>:<port>`.
    ///
    /// This is the re-dial primitive `ConnectionManager` uses when the remembered
    /// Wireless Debugging endpoint is offline (app restart, network change, device
    /// reconnect). It performs no pairing — pairing is a one-time, user-performed
    /// step on the device (`adb pair`), recorded when the paired device is first
    /// observed; connect only re-establishes a channel to a paired endpoint.
    ///
    /// Note the discipline of the shell-command prototype: it is a transport
    /// primitive reached only from `ConnectionManager`, never from the operations
    /// layer, and takes structured host/port arguments — never a caller-supplied
    /// command string.
    func connect(host: String, port: Int) async throws {
        let endpoint = "\(host):\(port)"
        let result = try await execute(
            command: "connect",
            arguments: [endpoint],
            timeout: 10
        )

        try Self.validateConnectResult(result, endpoint: endpoint)
    }

    /// Interprets `adb connect` output as success or failure.
    ///
    /// `adb connect` is a **liar about exit codes**: reaching an unreachable
    /// endpoint exits 0 and prints `cannot connect to ...` on stdout. Success is
    /// therefore judged on the output text (`connected to` with none of the
    /// documented failure phrasings), never on the exit status alone.
    nonisolated static func validateConnectResult(_ result: TransportResult, endpoint: String) throws {
        guard result.isSuccess else {
            throw PixelDesktopError.adbCommandFailed(
                command: "connect \(endpoint)",
                exitCode: Int(result.exitCode),
                stderr: result.stderr
            )
        }

        let output = "\(result.stdout) \(result.stderr)".lowercased()

        if output.contains("cannot connect")
            || output.contains("could not connect")
            || output.contains("unable to connect")
            || output.contains("failed")
            || output.contains("refused") {
            throw PixelDesktopError.adbTransportError(
                "adb could not connect to \(endpoint): \(result.stdout.trimmingCharacters(in: .whitespacesAndNewlines))"
            )
        }

        guard output.contains("connected") else {
            throw PixelDesktopError.adbTransportError(
                "Unexpected adb connect response for \(endpoint): \(result.stdout.trimmingCharacters(in: .whitespacesAndNewlines))"
            )
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
        onStderrLine: @Sendable @escaping (String) -> Void,
        cancellation: CancellationHandle
    ) async throws -> Int32 {
        // If cancellation already occurred before we started, do not launch a process.
        if cancellation.isCancelled || Task.isCancelled {
            throw PixelDesktopError.cancelled
        }

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
        stderrQueue.asyncAfter(deadline: .now() + streamStallTimeout + 5.0) {
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

            // Register the cancellation handler. If cancellation already occurred before this
            // registration, the handler is invoked immediately by setCancellationHandler.
            // The handler closes the stdout handle to unblock a reader stuck in availableData,
            // then resumes the continuation exactly once via StreamReadState.
            cancellation.setCancellationHandler { [weak stdoutHandle] in
                try? stdoutHandle?.close()
                state.cancel()
                state.finish(continuation)
            }

            queue.async {
                var buffer = Data()
                while true {
                    let chunk = stdoutHandle.availableData
                    if chunk.isEmpty { break }
                    if state.isCancelled || cancellation.isCancelled { break }
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
                if !state.isCancelled, !cancellation.isCancelled, !buffer.isEmpty {
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
            watchdog.asyncAfter(deadline: .now() + streamStallTimeout) {
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
        let reapDeadline = Date().addingTimeInterval(childReapTimeout)
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

    // MARK: - Binary-safe read

    /// Runs `adb -s <serial> exec-out <arguments...>` and returns stdout as raw bytes.
    ///
    /// ## Why this is not `execute`
    ///
    /// `execute` builds `String(data: stdout, encoding: .utf8) ?? ""`. For a PNG that decode
    /// fails and the payload becomes an **empty string** with exit code 0 — a silent data
    /// loss that looks like a successful but blank capture. The drain structure is otherwise
    /// identical, because the deadlock it avoids is a property of `Pipe` on macOS (a 65,536-byte
    /// buffer, measured), not of text versus bytes.
    ///
    /// ## Termination
    ///
    /// A timeout throws `PixelDesktopError.timeout` at the point it is detected, matching
    /// `execute`. A launch failure is returned as exit code `-1` with the reason in stderr,
    /// which is distinguishable from a device-side non-zero exit by the caller that cares.
    func execOut(
        deviceSerial: String,
        arguments: [String],
        timeout: TimeInterval
    ) async throws -> TransportBinaryResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: adbPath)
        process.arguments = ["-s", deviceSerial, "exec-out"] + arguments

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        let effectiveTimeout = timeout > 0 ? timeout : defaultTimeout

        return try await withThrowingTaskGroup(of: TransportBinaryResult?.self) { group in
            group.addTask {
                do {
                    try process.run()
                } catch {
                    return TransportBinaryResult(
                        exitCode: -1,
                        stdout: Data(),
                        stderr: "Failed to launch ADB: \(error.localizedDescription)"
                    )
                }

                // Drain both pipes while the child runs — see `execute` for why reading after
                // `waitUntilExit()` deadlocks at the pipe buffer size.
                let payloads = PipePayloads()
                let drain = DispatchGroup()

                drain.enter()
                DispatchQueue.global(qos: .userInitiated).async {
                    payloads.setStdout(stdoutPipe.fileHandleForReading.readDataToEndOfFile())
                    drain.leave()
                }
                drain.enter()
                DispatchQueue.global(qos: .userInitiated).async {
                    payloads.setStderr(stderrPipe.fileHandleForReading.readDataToEndOfFile())
                    drain.leave()
                }

                process.waitUntilExit()
                _ = drain.wait(timeout: .now() + 5.0)

                return TransportBinaryResult(
                    exitCode: process.terminationStatus,
                    stdout: payloads.stdout,
                    stderr: String(data: payloads.stderr, encoding: .utf8) ?? ""
                )
            }

            group.addTask {
                try? await Task.sleep(nanoseconds: UInt64(effectiveTimeout * 1_000_000_000))
                if process.isRunning {
                    process.terminate()
                    throw PixelDesktopError.timeout(
                        operation: "adb -s \(deviceSerial) exec-out \(arguments.joined(separator: " "))",
                        duration: effectiveTimeout
                    )
                }
                return nil
            }

            guard let first = try await group.next(), let result = first else {
                group.cancelAll()
                throw PixelDesktopError.unknown("No result from ADB exec-out")
            }

            group.cancelAll()
            return result
        }
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
