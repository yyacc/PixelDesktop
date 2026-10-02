import Foundation

/// The streaming job state machine.
///
/// Pure and deterministic: it consumes `WorkerEvent`s and produces a state and an outcome. It
/// performs **no I/O**, so every transition — including the two that E1 discovered — is testable
/// without a device.
///
/// ## The two transitions this exists to get right
///
/// **F4 — worker death must be an explicit transition.** E1 measured a heartbeat loop that saw
/// `pid=none` and kept heartbeating to the end of its window. Here, a run of missed liveness
/// checks *before a result exists* moves the state to `.streamAliveWorkerExited` and sets a
/// terminal outcome. The loop stops; it does not keep reporting a dead worker as alive.
///
/// **F7 — stream loss is not job failure.** When the stream ends, this type is told what the
/// orchestrator could observe (is the worker alive? does the result exist?) and reports the
/// corresponding outcome. A worker that is still running yields `.streamLostWorkerRunning`, whose
/// `mayStillBeRunning` is `true` — so the caller knows **not** to cancel it.
///
/// ## Why liveness misses need a grace window
///
/// A single `pid=none` is not proof of death: the process can be mid-exit after writing its
/// result, and the shell can observe it in that window. The reducer therefore requires a run of
/// consecutive misses **with no result present** before declaring the worker gone. A completed job
/// emits `RESULT_BEGIN` before that run can accumulate, so a successful job is never misreported
/// as a dead worker.
struct WorkerStreamReducer {

    /// How many consecutive missed liveness checks, with no result present, constitute death.
    ///
    /// Not a job timeout — a *liveness* grace window. It bounds how long a dead worker can be
    /// reported as alive, not how long a job may run. Job duration is deliberately unbounded.
    static let livenessMissGrace = 3

    // MARK: - Observable state

    private(set) var state: WorkerStreamState = .streamAliveWorkerNotYetVisible
    private(set) var jobId: String?
    private(set) var launched = false
    private(set) var resultBytes: Int?
    private(set) var lastHeartbeatSequence = 0

    /// Unstructured lines seen on the stream. Surfaced rather than discarded.
    private(set) var unrecognizedLines: [String] = []

    // MARK: - Private

    private var resultLines: [String] = []
    private var inResult = false
    private var consecutiveLivenessMisses = 0
    private var outcome: WorkerStreamOutcome?
    private var terminalFailure: WorkerStreamOutcome?

    init() {}

    /// The outcome, once the job has reached a terminal state.
    var finalOutcome: WorkerStreamOutcome? { outcome }

    /// Whether the reducer is currently collecting result payload lines.
    ///
    /// The result payload is **opaque**: it is JSON, not protocol traffic. Callers need this so a
    /// line that is not a protocol line can be routed into the result rather than discarded as
    /// unrecognized output.
    var isCollectingResult: Bool { inResult }

    /// The accumulated result payload, or `nil` if no result was streamed.
    var streamedResult: String? {
        guard resultBytes != nil, !resultLines.isEmpty else { return nil }
        return resultLines.joined(separator: "\n")
    }

    // MARK: - Event application

    /// Applies one parsed event.
    mutating func apply(_ event: WorkerEvent) {
        // A terminal outcome is final. Late lines from a dying stream are recorded as
        // unstructured rather than allowed to reopen a decided job.
        if outcome != nil {
            if case .resultLine = event { return }
            if case .unrecognized(let line) = event { unrecognizedLines.append(line) }
            return
        }

        switch event {
        case .started(let id):
            jobId = id

        case .jobWritten:
            break // Delivery confirmation; carries no state change beyond jobId being set.

        case .launched:
            launched = true
            state = .streamAliveWorkerNotYetVisible

        case .heartbeat(let sequence, let workerPid):
            lastHeartbeatSequence = sequence

            if let pid = workerPid {
                consecutiveLivenessMisses = 0
                state = .streamAliveWorkerAlive(pid: pid)
            } else {
                // A miss only counts as evidence of death once the worker has been launched and
                // no result has arrived. Before launch, and after a result, `none` is expected.
                guard launched, resultBytes == nil else { return }
                consecutiveLivenessMisses += 1
                if consecutiveLivenessMisses >= Self.livenessMissGrace {
                    state = .streamAliveWorkerExited
                    outcome = .workerExitedUnexpectedly(sequence: sequence)
                }
            }

        case .workerExited(let sequence):
            // The device script made the same determination independently. Trust it immediately.
            state = .streamAliveWorkerExited
            outcome = .workerExitedUnexpectedly(sequence: sequence)

        case .resultBegan:
            inResult = true
            resultLines = []

        case .resultLine(let line):
            guard inResult else {
                unrecognizedLines.append(line)
                return
            }
            // An empty line carries no payload. The script terminates `cat` output with a newline,
            // and `cat` of a file already ending in a newline produces one trailing empty line;
            // treating it as payload would corrupt the JSON with a stray blank.
            guard !line.isEmpty else { return }
            resultLines.append(line)

        case .resultEnded(let bytes):
            guard inResult else {
                // A result end without a begin is a structurally broken stream, not a success.
                outcome = .malformedStream(reason: "RESULT_END without RESULT_BEGIN")
                return
            }
            inResult = false
            resultBytes = bytes
            state = .streamAliveWorkerNotYetVisible
            outcome = .completedButDurabilityUnverified(
                resultJSON: resultLines.joined(separator: "\n"),
                reason: "durable result not yet confirmed on the device"
            )

        case .failure(let code, let message):
            terminalFailure = .failed(code: code, message: message)
            outcome = terminalFailure

        case .unrecognized(let line):
            unrecognizedLines.append(line)
        }
    }

    // MARK: - Durability

    /// Confirms that the durable result file exists on the device and matches the streamed bytes.
    ///
    /// This is the step that upgrades a streamed completion into a `.completed` outcome. The brief
    /// is explicit that *"stream completion does not mean result durability"*, so without this call
    /// a job that streamed a result but left no file stays `.completedButDurabilityUnverified`.
    ///
    /// - Parameter durableBytes: the device-reported size of `result.json`, or `nil` if absent.
    mutating func confirmDurability(durableBytes: Int?) {
        guard case .completedButDurabilityUnverified(let json, let reason)? = outcome else { return }

        guard let durableBytes else {
            outcome = .completedButDurabilityUnverified(
                resultJSON: json,
                reason: "result.json was not found on the device after completion"
            )
            return
        }

        // A zero-byte or truncated durable file is not a durable result.
        guard durableBytes > 0 else {
            outcome = .completedButDurabilityUnverified(
                resultJSON: json,
                reason: "result.json is empty on the device"
            )
            return
        }

        if let streamed = resultBytes, durableBytes < streamed {
            outcome = .completedButDurabilityUnverified(
                resultJSON: json,
                reason: "result.json is \(durableBytes) bytes but the stream carried \(streamed); "
                    + "the durable file looks truncated"
            )
            return
        }

        outcome = .completed(resultJSON: json, resultBytes: durableBytes)
        _ = reason
    }

    // MARK: - Stream termination

    /// Reports that the stream ended, with whatever the orchestrator could observe afterwards.
    ///
    /// - Parameters:
    ///   - workerAlive: whether the worker process was found running after the stream ended.
    ///     `nil` means the check could not be performed.
    ///   - workerPid: the PID, when one was found.
    ///   - reason: a human-readable note about why the stream ended, when known.
    mutating func streamEnded(workerAlive: Bool?, workerPid: Int?, reason: String) {
        // A decided outcome is not reopened by transport loss.
        if let existing = outcome {
            // The one thing transport loss can change: a streamed completion whose durable file
            // could not be confirmed stays unconfirmed, and now cannot be confirmed at all.
            if case .completedButDurabilityUnverified = existing {
                return
            }
            return
        }

        if inResult {
            outcome = .malformedStream(
                reason: "stream ended mid-result: \(reason)"
            )
            state = .streamLostWorkerUnknown
            return
        }

        switch workerAlive {
        case .some(true):
            state = .streamLostWorkerAlive(pid: workerPid)
            // NOT a failure. F7: the worker continues and may still write a durable result.
            outcome = .streamLostWorkerRunning(pid: workerPid)

        case .some(false):
            state = .streamLostWorkerGone
            outcome = .streamLostWorkerGone

        case .none:
            state = .streamLostWorkerUnknown
            // Reported rather than guessed, per the brief.
            outcome = .streamLostUnknown(reason: reason)
        }
    }
}
