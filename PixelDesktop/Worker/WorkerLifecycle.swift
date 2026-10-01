import Foundation

/// Starts, observes and stops the Pixel compute worker.
///
/// ## The state model (D7)
///
/// ```
/// NOT_INSTALLED  →  INSTALLED  →  RUNNING  →  FINISHED / FAILED
/// ```
///
/// Four states, each **observably distinct**. The reconnaissance's suggested `STARTING`,
/// `STOPPING` and `STOPPED` were dropped because for a one-shot Activity they are transitions
/// the system passes through in milliseconds: there is no moment at which the Mac can
/// meaningfully observe "starting but not running", and a finished Activity returns to
/// `INSTALLED` rather than to a distinct `STOPPED`.
///
/// ## What this is not
///
/// No Service, no daemon, no process supervisor, no restart/backoff policy, no health monitor.
/// The worker is bounded — launch, read job, compute, write result, finish — and this type only
/// starts it, waits for it, and stops it if asked.
struct WorkerLifecycle {
    private let transport: TransportProtocol

    init(transport: TransportProtocol) {
        self.transport = transport
    }

    /// Observable state of the worker process.
    enum State: Equatable {
        /// No process with the worker's package name is running.
        case notRunning

        /// A process is running; `pid` identifies it.
        case running(pid: Int)

        var pid: Int? {
            if case .running(let pid) = self { return pid }
            return nil
        }

        var isRunning: Bool {
            if case .running = self { return true }
            return false
        }
    }

    /// Reads the worker's running state via `pidof`.
    ///
    /// `pidof` exits 1 when no process matches, which is a valid answer rather than an error —
    /// the same convention Phase 4 established for `isApplicationRunning`.
    func state(deviceSerial: String, timeout: TimeInterval = 15) async throws -> State {
        let result = try await transport.shell(
            deviceSerial: deviceSerial,
            command: "pidof \(WorkerTransferContract.workerPackageName)",
            timeout: timeout
        )

        guard let pid = Self.parsePID(result.stdout) else {
            return .notRunning
        }
        return .running(pid: pid)
    }

    /// Stops the worker if it is running, then waits for the process to disappear.
    ///
    /// Called before every launch so that runs cannot overlap. A duplicate invocation was
    /// observed during reconnaissance to reuse the existing Activity instance rather than create
    /// a second process, but relying on that would make a *stale* run indistinguishable from a
    /// fresh one. Stopping first makes each run start from a known state.
    ///
    /// `am force-stop` is destructive-capable — it kills the process and discards in-flight work.
    /// Like Phase 4's `stopApplication`, it is contained here: an explicit package constant, no
    /// wildcards, no caller-supplied target.
    func stopIfRunning(deviceSerial: String, timeout: TimeInterval = 20) async throws {
        guard try await state(deviceSerial: deviceSerial, timeout: timeout).isRunning else {
            return
        }

        _ = try await transport.shell(
            deviceSerial: deviceSerial,
            command: "am force-stop \(WorkerTransferContract.workerPackageName)",
            timeout: timeout
        )

        // Confirm the process is gone rather than assuming force-stop completed.
        for _ in 0..<20 {
            if try await state(deviceSerial: deviceSerial, timeout: timeout).isRunning == false {
                return
            }
            try? await Task.sleep(nanoseconds: 250_000_000)
        }

        throw PixelDesktopError.workerError(
            "Worker process did not stop after am force-stop"
        )
    }

    /// Launches the worker Activity via `am start`.
    ///
    /// `am start` returns before the process is up, so this only *requests* the launch. Use
    /// `awaitProcessStart` to confirm the process actually appeared.
    ///
    /// Note: `am start -n` with an `exported="false"` Activity still works when invoked by adb,
    /// because adb runs as the `shell` user which holds the privileged permission to start
    /// non-exported components. This was the mechanism verified during reconnaissance.
    func launch(deviceSerial: String, timeout: TimeInterval = 30) async throws {
        let result = try await transport.shell(
            deviceSerial: deviceSerial,
            command: "am start -n \(WorkerTransferContract.workerActivityComponent)",
            timeout: timeout
        )

        guard result.isSuccess else {
            throw PixelDesktopError.workerError(
                "am start failed: \(result.stderr.trimmingCharacters(in: .whitespacesAndNewlines))"
            )
        }
    }

    /// Waits for the worker process to appear.
    ///
    /// - Returns: the PID, or `nil` if the process did not appear within the timeout. A `nil` is
    ///   **not** automatically a failure: a very fast worker can start and finish before the
    ///   first poll. Callers should treat "no process" as inconclusive and rely on the result
    ///   file, which is the actual work-completion signal.
    func awaitProcessStart(
        deviceSerial: String,
        attempts: Int = 40,
        intervalNanoseconds: UInt64 = 250_000_000
    ) async throws -> Int? {
        for _ in 0..<attempts {
            if let pid = try await state(deviceSerial: deviceSerial).pid {
                return pid
            }
            try? await Task.sleep(nanoseconds: intervalNanoseconds)
        }
        return nil
    }

    // MARK: - Parsing

    /// Parses `pidof` output. `pidof` may print several space-separated PIDs; the first is used.
    static func parsePID(_ output: String) -> Int? {
        let trimmed = output.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return trimmed.split(separator: " ").first.flatMap { Int($0) }
    }
}
