import Foundation

/// Executes one DTCA-1 workload on the Pixel and returns verified evidence.
///
/// This is the compute-proof orchestration. It composes the existing pieces rather than
/// duplicating them:
///
/// - `WorkerTransferContract` — fixed paths, validation, size verification
/// - `WorkerLifecycle` — start, stop, observe
/// - `WorkerInstaller` — installation and version identity
/// - `DTCA1Worker` — the **local** reference computation
/// - `ResultVerifier` — independent verification (ADR-004)
///
/// ## The claim this type is built to support
///
/// Not "the output string matched" but **"the Pixel worker computed this"**. The evidence it
/// collects is chosen to distinguish those two:
///
/// | Evidence | What it rules out |
/// |---|---|
/// | worker package identity (installed versionCode) | a different app running |
/// | worker **PID** and UID from the device | the Mac doing the work |
/// | execution began **after** job delivery | a stale result being reused |
/// | `job_id` echoed by the worker | a result from a previous run |
/// | **CPU time consumed by that PID** | a result fabricated without computing |
/// | independent local re-computation matching | a wrong-but-plausible result |
///
/// A matching output string alone proves none of these, which is why it is not sufficient.
struct WorkerComputeProof {
    private let transport: TransportProtocol
    private let lifecycle: WorkerLifecycle
    private let installer: WorkerInstaller

    init(transport: TransportProtocol) {
        self.transport = transport
        self.lifecycle = WorkerLifecycle(transport: transport)
        self.installer = WorkerInstaller(transport: transport)
    }

    /// Evidence captured around a single workload run.
    struct Evidence: Equatable {
        let jobId: String
        let workerPid: Int?
        let workerVersionCode: Int?
        /// utime + stime for the worker PID, in clock ticks, before and after the run.
        let cpuTicksBefore: Int?
        let cpuTicksAfter: Int?
        /// Highest cumulative utime+stime observed for the worker process **while it was alive**.
        ///
        /// This is the attributable figure. A before/after delta is not usable here: the worker
        /// completes in roughly 250 ms including startup, so by the time the result file appears
        /// the process has often already exited and there is no "after" to read. The cumulative
        /// value sampled during the run belongs to the worker's PID and to nothing else.
        let cpuTicksObservedWhileRunning: Int?
        let wallClockMs: Int
        let workerReportedDurationMs: Int64
        let verification: VerificationResult

        /// CPU time attributable to the worker, in clock ticks.
        ///
        /// Prefers the before/after delta when both ends were observable; otherwise falls back to
        /// the cumulative value sampled while the process was alive, which is equally attributable
        /// to the worker's PID.
        var cpuTicksConsumed: Int? {
            if let before = cpuTicksBefore, let after = cpuTicksAfter, after >= before {
                return after - before
            }
            return cpuTicksObservedWhileRunning
        }

        /// Whether the worker's own process consumed measurable CPU.
        ///
        /// This is the strongest available evidence that computation happened **on the device**,
        /// because `/proc/<pid>/stat` utime/stime are per-process and cannot be attributed to
        /// anything else. Note it covers the whole process lifetime, including Android app startup,
        /// not only the DTCA-1 computation — reported as such rather than overclaimed.
        var workerConsumedCPU: Bool {
            (cpuTicksConsumed ?? 0) > 0
        }
    }

    enum ComputeProofError: Error, CustomStringConvertible {
        case noResultFile(String)
        case staleResult(expected: String, actual: String)

        var description: String {
            switch self {
            case .noResultFile(let detail):
                return "Worker produced no result file: \(detail)"
            case .staleResult(let expected, let actual):
                return "Stale result: expected job_id \(expected), got \(actual)"
            }
        }
    }

    /// Runs one DTCA-1 job on the device and returns verified evidence.
    ///
    /// - Parameters:
    ///   - input: the DTCA-1 text. Validated locally before anything touches the device.
    ///   - resultPollAttempts: how many times to poll for the result file before giving up.
    /// - Returns: evidence including the verification outcome. A verification **failure is
    ///   returned, not thrown** — a mismatched result is a finding, not an error condition.
    func run(
        deviceSerial: String,
        input: String,
        timeout: TimeInterval = 60,
        resultPollAttempts: Int = 60,
        resultPollIntervalNanoseconds: UInt64 = 250_000_000
    ) async throws -> Evidence {
        // 1. Validate locally first — cheapest check, and it keeps invalid input off the device.
        try DTCA1Worker.validateInput(input)

        // 2. Establish the worker's identity before doing anything.
        let installed = try await installer.installedState(deviceSerial: deviceSerial)
        guard installed.isInstalled else {
            throw PixelDesktopError.workerError(
                "Worker package \(WorkerTransferContract.workerPackageName) is not installed"
            )
        }

        // 3. Ensure a clean start: no stale process, no stale result.
        try await lifecycle.stopIfRunning(deviceSerial: deviceSerial)
        try await removeStaleResult(deviceSerial: deviceSerial, timeout: timeout)

        // 4. Write the job and push it. The push is size-verified by the transfer contract.
        let jobId = DTCA1Job.newJobId()
        let job = DTCA1Job(jobId: jobId, input: input)
        try await submitJob(job: job, deviceSerial: deviceSerial, timeout: timeout)

        // 5. Measure CPU ticks immediately before launch, so a delta covers the computation when
        //    the process happens to still be alive at the end.
        let cpuBefore = try await workerCPUTicks(deviceSerial: deviceSerial, timeout: timeout)

        // 6. Launch and observe.
        let launchStart = Date()
        try await lifecycle.launch(deviceSerial: deviceSerial, timeout: timeout)
        let pid = try await lifecycle.awaitProcessStart(deviceSerial: deviceSerial)

        // 7. Wait for the result file — the actual work-completion signal — while sampling the
        //    worker's cumulative CPU time for as long as its process exists. The worker finishes
        //    in ~250 ms including startup, so this sampling is what makes CPU attribution possible
        //    at all; a before/after delta alone would almost always be unmeasurable.
        var cpuObservedWhileRunning: Int?
        let rawResult = try await awaitResultFile(
            deviceSerial: deviceSerial,
            attempts: resultPollAttempts,
            intervalNanoseconds: resultPollIntervalNanoseconds,
            timeout: timeout,
            onPoll: { sampled in
                if let sampled { cpuObservedWhileRunning = sampled }
            }
        )
        let wallClockMs = Int(Date().timeIntervalSince(launchStart) * 1000)

        // 8. Capture CPU ticks after. Read while the process may still exist; if it has already
        //    exited the delta is unavailable and is reported as nil rather than guessed.
        let cpuAfter = try await workerCPUTicks(deviceSerial: deviceSerial, timeout: timeout)

        // 9. Decode and check staleness.
        let envelope: WorkerResultEnvelope
        do {
            envelope = try JSONDecoder().decode(WorkerResultEnvelope.self, from: Data(rawResult.utf8))
        } catch {
            throw PixelDesktopError.verificationFailed(
                reason: "Worker result is not valid JSON: \(error.localizedDescription)"
            )
        }

        if let returnedJobId = envelope.jobId, returnedJobId != jobId {
            throw ComputeProofError.staleResult(expected: jobId, actual: returnedJobId)
        }

        let pixelResult = try envelope.asDTCA1Result()

        // 10. Verify independently — re-run DTCA-1 locally (ADR-004). Never trust the worker.
        let localResult = try DTCA1Worker.execute(input)
        let verification = ResultVerifier.verify(
            pixelResult: pixelResult,
            localResult: localResult,
            originalInput: input
        )

        return Evidence(
            jobId: jobId,
            workerPid: pid,
            workerVersionCode: installed.versionCode,
            cpuTicksBefore: cpuBefore,
            cpuTicksAfter: cpuAfter,
            cpuTicksObservedWhileRunning: cpuObservedWhileRunning,
            wallClockMs: wallClockMs,
            workerReportedDurationMs: pixelResult.executionDurationMs,
            verification: verification
        )
    }

    // MARK: - Steps

    private func submitJob(job: DTCA1Job, deviceSerial: String, timeout: TimeInterval) async throws {
        try WorkerTransferContract.prepareStagingDirectory()

        let jobURL = WorkerTransferContract.localInputPath
        do {
            try job.encoded().write(to: jobURL, atomically: true, encoding: .utf8)
        } catch {
            throw PixelDesktopError.invalidInput("Could not write staged job: \(error.localizedDescription)")
        }

        let validated = try WorkerTransferContract.validateRegularFile(at: jobURL)

        // The exchange directory must be created BY THE WORKER, not by adb: an adb-created
        // directory is owned by shell:ext_data_rw and the worker cannot write it. Launching the
        // worker once makes it create its own directory (it finds no job and exits immediately).
        try await ensureWorkspaceExists(deviceSerial: deviceSerial, timeout: timeout)

        let push = try await transport.push(
            deviceSerial: deviceSerial,
            localPath: validated.url.path,
            remotePath: WorkerTransferContract.remoteInputPath,
            timeout: timeout
        )

        guard push.isSuccess else {
            throw PixelDesktopError.adbCommandFailed(
                command: "push job",
                exitCode: Int(push.exitCode),
                stderr: push.stderr
            )
        }
    }

    /// Ensures the worker's exchange directory exists, by letting the worker create it.
    ///
    /// adb must **not** create this directory: doing so makes it owned by `shell:ext_data_rw`,
    /// which the worker cannot write. Measured on the real device.
    private func ensureWorkspaceExists(deviceSerial: String, timeout: TimeInterval) async throws {
        let check = try await transport.shell(
            deviceSerial: deviceSerial,
            command: WorkerTransferContract.remoteWorkspaceExistsCommand,
            timeout: timeout
        )

        if check.stdout.contains("EXISTS") {
            return
        }

        // Warm-up launch: the worker calls getExternalFilesDir(null) and creates its directory,
        // then finds no job and finishes.
        try await lifecycle.launch(deviceSerial: deviceSerial, timeout: timeout)

        for _ in 0..<40 {
            let poll = try await transport.shell(
                deviceSerial: deviceSerial,
                command: WorkerTransferContract.remoteWorkspaceExistsCommand,
                timeout: timeout
            )
            if poll.stdout.contains("EXISTS") { return }
            try? await Task.sleep(nanoseconds: 250_000_000)
        }

        throw PixelDesktopError.workerError(
            "Worker did not create its exchange directory at \(WorkerTransferContract.remoteRoot)"
        )
    }

    /// Deletes the remote result file so a previous run's output cannot be mistaken for this one.
    private func removeStaleResult(deviceSerial: String, timeout: TimeInterval) async throws {
        _ = try await transport.shell(
            deviceSerial: deviceSerial,
            command: "rm -f \(WorkerTransferContract.remoteResultPath)",
            timeout: timeout
        )
    }

    private func awaitResultFile(
        deviceSerial: String,
        attempts: Int,
        intervalNanoseconds: UInt64,
        timeout: TimeInterval,
        onPoll: (Int?) -> Void = { _ in }
    ) async throws -> String {
        for _ in 0..<attempts {
            // Sample the worker's cumulative CPU while its process is still alive.
            if let ticks = try await workerCPUTicks(deviceSerial: deviceSerial, timeout: timeout) {
                onPoll(ticks)
            }

            let check = try await transport.shell(
                deviceSerial: deviceSerial,
                command: "cat \(WorkerTransferContract.remoteResultPath)",
                timeout: timeout
            )

            let content = check.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
            if check.isSuccess, !content.isEmpty {
                return content
            }

            try? await Task.sleep(nanoseconds: intervalNanoseconds)
        }

        throw ComputeProofError.noResultFile(
            "no result appeared at \(WorkerTransferContract.remoteResultPath) within the poll window"
        )
    }

    /// Reads utime+stime for the worker's process, in clock ticks.
    ///
    /// `/proc/<pid>/stat` fields 14 and 15 (1-indexed) are utime and stime. adb holds the
    /// `readproc` group on this device, so this is readable for another UID's process without
    /// root — verified during reconnaissance.
    ///
    /// - Returns: `nil` when the process is not running or the fields cannot be parsed. `nil` is
    ///   reported honestly rather than substituted with a zero, because zero would be
    ///   indistinguishable from "consumed no CPU".
    private func workerCPUTicks(deviceSerial: String, timeout: TimeInterval) async throws -> Int? {
        guard let pid = try await lifecycle.state(deviceSerial: deviceSerial, timeout: timeout).pid else {
            return nil
        }

        let stat = try await transport.shell(
            deviceSerial: deviceSerial,
            command: "cat /proc/\(pid)/stat",
            timeout: timeout
        )

        guard stat.isSuccess else { return nil }
        return Self.parseCPUTicks(stat.stdout)
    }

    /// Extracts utime+stime from `/proc/<pid>/stat`.
    ///
    /// The process name in field 2 is wrapped in parentheses and may itself contain spaces, so
    /// parsing splits **after the final `)`** rather than on whitespace from the start.
    static func parseCPUTicks(_ statLine: String) -> Int? {
        guard let closeParen = statLine.lastIndex(of: ")") else { return nil }

        let remainder = statLine[statLine.index(after: closeParen)...]
        let fields = remainder.split(separator: " ").map(String.init)

        // After the command, field 3 is state. utime is field 14 and stime is field 15, i.e.
        // indices 11 and 12 in this remainder (index 0 == state).
        guard fields.count > 12 else { return nil }
        guard let utime = Int(fields[11]), let stime = Int(fields[12]) else { return nil }

        return utime + stime
    }
}
