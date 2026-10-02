import Foundation

/// Runs one worker job through a single persistent `adb shell` session.
///
/// ## What this replaces, and what it does not
///
/// E1 (`790164d`) validated the architecture. This type implements it:
///
/// ```
/// OLD                                    NEW
/// adb push job.json                      job payload on stdin
/// am start                               am start
/// Mac-side poll for pid/result           streamed liveness + completion
/// adb pull result.json                   result read from the durable file
/// ```
///
/// Three things are deliberately **unchanged**, because E1 showed each one is load-bearing:
///
/// | Kept | Why |
/// |---|---|
/// | the durable `result.json` | F7: a killed session loses the stream, not the file |
/// | `am force-stop` cancellation | F3: cancellation is external to the session |
/// | `pidof` liveness | F4: the only way to tell "slow" from "dead" |
///
/// ## What the stream is, and is not
///
/// The stream is a **live observation channel**: launch acknowledgement, process liveness, and
/// completion. It is **not** a source of truth for the result, and it is **not** a cancellation
/// channel. The worker emits no progress of its own, so no progress is invented — `HEARTBEAT`
/// reports process liveness only.
///
/// ## Stream state and worker state are independent
///
/// The brief requires four situations to be distinguishable rather than collapsed into one
/// connection state. `WorkerStreamReducer` carries that distinction; this type's job is to supply
/// it with the observations it needs — in particular, after the stream ends, to ask the device
/// whether the worker is still running before deciding anything.
struct WorkerStreamRunner {
    private let transport: TransportProtocol
    private let lifecycle: WorkerLifecycle

    init(transport: TransportProtocol) {
        self.transport = transport
        self.lifecycle = WorkerLifecycle(transport: transport)
    }

    /// A completed streaming run: the outcome plus the live record of what the stream reported.
    struct Run: Sendable {
        let outcome: WorkerStreamOutcome
        let jobId: String?
        /// Whether the worker process was observed alive at any point.
        let workerPidObserved: Int?
        /// Number of liveness heartbeats received.
        let heartbeatCount: Int
        /// Time from session start to the first line received.
        let timeToFirstEventSeconds: Double?
        /// Time from session start to the launch acknowledgement.
        let timeToLaunchAckSeconds: Double?
        /// Time from session start to a terminal outcome.
        let timeToOutcomeSeconds: Double?
        /// Total wall time of the streaming session.
        let wallSeconds: Double
        /// stderr lines, kept separate from protocol events.
        let stderrLines: [String]
        /// Unstructured stdout lines — evidence that the script and parser disagree.
        let unrecognizedLines: [String]
        /// Whether the session ended without a protocol terminal event.
        let streamEndedUnexpectedly: Bool
    }

    /// Runs one job to completion over a persistent session.
    ///
    /// - Parameters:
    ///   - jobId: validated before interpolation into the device script.
    ///   - payload: the job document, delivered on stdin.
    ///   - onEvent: invoked for each parsed event, in arrival order, as it arrives.
    /// - Returns: the outcome and the live measurements.
    func run(
        deviceSerial: String,
        jobId: String,
        payload: String,
        onEvent: (@Sendable (WorkerEvent) -> Void)? = nil
    ) async throws -> Run {
        let script = try WorkerStreamScript.deviceScript(jobId: jobId)

        // The reducer is mutated from the read callback (a background thread) and read afterwards.
        // A lock keeps that well-defined without making the whole runner an actor, which would
        // force the callbacks to be async and lose their arrival ordering.
        let lock = NSLock()
        var reducer = WorkerStreamReducer()
        var stderrLines: [String] = []
        var firstEventAt: Double?
        var launchAckAt: Double?
        var outcomeAt: Double?
        var pidObserved: Int?
        var heartbeats = 0

        let start = Date()
        let elapsed = { Date().timeIntervalSince(start) }

        let exitCode: Int32
        do {
            exitCode = try await transport.shellStreaming(
                deviceSerial: deviceSerial,
                command: script,
                stdin: payload,
                onLine: { line in
                    lock.lock()
                    defer { lock.unlock() }

                    guard let event = WorkerEventParser.parse(line) else {
                        // Not a protocol line. While a result is being collected the payload is
                        // opaque JSON and belongs to the result; otherwise this is stray output
                        // and is recorded so a script/parser mismatch stays visible.
                        if reducer.isCollectingResult {
                            reducer.apply(.resultLine(line))
                        } else {
                            reducer.apply(.unrecognized(line))
                        }
                        return
                    }

                    if firstEventAt == nil { firstEventAt = elapsed() }
                    if case .launched = event, launchAckAt == nil { launchAckAt = elapsed() }
                    if case .heartbeat(_, let pid) = event {
                        heartbeats += 1
                        if let pid { pidObserved = pid }
                    }

                    reducer.apply(event)
                    if reducer.finalOutcome != nil, outcomeAt == nil { outcomeAt = elapsed() }
                    onEvent?(event)
                },
                onStderrLine: { line in
                    lock.lock()
                    defer { lock.unlock() }
                    stderrLines.append(line)
                }
            )
        } catch {
            // The session failed to start at all. Nothing was observed, so the worker state is
            // genuinely unknown rather than assumed dead.
            lock.lock()
            reducer.streamEnded(workerAlive: nil, workerPid: nil, reason: error.localizedDescription)
            lock.unlock()
            throw error
        }

        // The session is over. What the stream produced is now frozen; the only remaining question
        // is what the *device* says, which is independent of the stream.
        lock.lock()
        let hadOutcome = reducer.finalOutcome != nil
        let streamedOutcome = reducer.finalOutcome
        lock.unlock()

        var finalOutcome: WorkerStreamOutcome

        if let streamedOutcome {
            // The stream reached its own terminal state. It is not second-guessed here; the only
            // follow-up is the durability confirmation below, which is asked of the device because
            // the brief requires that stream completion is not treated as durability.
            finalOutcome = streamedOutcome
        } else {
            // The stream ended with no terminal event. This is the F7 case: the session is gone but
            // the worker is independent of it, so ask the device before concluding anything.
            let (alive, pid) = try await observeWorkerAfterStream(deviceSerial: deviceSerial)

            if let recovered = try await recoverDurableResult(deviceSerial: deviceSerial) {
                finalOutcome = .recoveredFromDevice(
                    resultJSON: recovered.json,
                    resultBytes: recovered.bytes
                )
            } else {
                lock.lock()
                reducer.streamEnded(
                    workerAlive: alive,
                    workerPid: pid,
                    reason: "stream ended with exit code \(exitCode)"
                )
                finalOutcome = reducer.finalOutcome ?? .incomplete(
                    reason: "stream ended with exit code \(exitCode) and no outcome was determined"
                )
                lock.unlock()
            }
        }

        // Durability confirmation for a streamed completion. The brief is explicit that stream
        // completion is not durability, so this is asked of the device rather than assumed.
        if case .completedButDurabilityUnverified = finalOutcome {
            let bytes = try await durableResultBytes(deviceSerial: deviceSerial)
            lock.lock()
            reducer.confirmDurability(durableBytes: bytes)
            finalOutcome = reducer.finalOutcome ?? finalOutcome
            lock.unlock()
        }

        lock.lock()
        let run = Run(
            outcome: finalOutcome,
            jobId: reducer.jobId ?? jobId,
            workerPidObserved: pidObserved,
            heartbeatCount: heartbeats,
            timeToFirstEventSeconds: firstEventAt,
            timeToLaunchAckSeconds: launchAckAt,
            timeToOutcomeSeconds: outcomeAt,
            wallSeconds: elapsed(),
            stderrLines: stderrLines,
            unrecognizedLines: reducer.unrecognizedLines,
            streamEndedUnexpectedly: !hadOutcome
        )
        lock.unlock()

        return run
    }

    // MARK: - Device-side observation after the stream ends

    /// Determines whether the worker is still running, after the stream ended.
    ///
    /// - Returns: `(alive, pid)`. `alive` is `nil` when the check itself failed — reported as
    ///   unknown rather than converted into "dead", per the brief's instruction not to invent
    ///   failure.
    private func observeWorkerAfterStream(
        deviceSerial: String
    ) async throws -> (Bool?, Int?) {
        do {
            let state = try await lifecycle.state(deviceSerial: deviceSerial)
            switch state {
            case .running(let pid): return (true, pid)
            case .notRunning: return (false, nil)
            }
        } catch {
            return (nil, nil)
        }
    }

    /// Reads the durable result if it exists on the device.
    ///
    /// This is the recovery path for E1 F7: the stream is gone, but the worker may have completed
    /// and written its result anyway.
    private func recoverDurableResult(
        deviceSerial: String
    ) async throws -> (json: String, bytes: Int)? {
        guard let bytes = try await durableResultBytes(deviceSerial: deviceSerial), bytes > 0 else {
            return nil
        }

        let read = try await transport.shell(
            deviceSerial: deviceSerial,
            command: "cat \(WorkerTransferContract.remoteResultPath)",
            timeout: 30
        )

        let content = read.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        guard read.isSuccess, !content.isEmpty else { return nil }

        return (content, bytes)
    }

    /// Reads the size of the durable result file, or `nil` when it does not exist.
    ///
    /// A `nil` here is meaningful: it is the difference between "no durable result" and "a durable
    /// result of unknown size".
    private func durableResultBytes(deviceSerial: String) async throws -> Int? {
        let stat = try await transport.shell(
            deviceSerial: deviceSerial,
            command: "stat -c %s \(WorkerTransferContract.remoteResultPath)",
            timeout: 30
        )
        return WorkerTransferContract.parseRemoteSize(stat.stdout)
    }
}
