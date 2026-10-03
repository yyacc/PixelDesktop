//
//  CLIRunResult.swift
//  PixelDesktopCLI
//
//  Phase 9 Step 4 — the structured result of one execution.
//
//  WHAT THIS IS
//  A presentation layer over `WorkerStreamOutcome` and `WorkerStreamRunner.Run`. It reuses the
//  authoritative types rather than restating them, and it does not decide anything: every field
//  is read from the E1 machinery's own output.
//
//  WHAT IT IS NOT
//  Not a second result vocabulary. The `outcome` token is a stable *name* for an existing
//  `WorkerStreamOutcome` case — the case's payload is preserved alongside it, not replaced.
//
//  WHY THE OUTCOME IS ALWAYS PUBLISHED, EVEN ON FAILURE
//  `ok` answers "did the workload complete"; `outcome` answers "what did the execution machinery
//  actually observe". Collapsing the second into the first would discard the distinction E1
//  exists to preserve — `.recoveredFromDevice` and `.completed` are both successes but were
//  learned differently, and `.streamLostWorkerRunning` is not the same fact as `.failed`.
//

import Foundation

// This file is compiled into two different modules: the `pixel-desktop` tool (where the shared
// PixelDesktop sources are in the *same* module, so no import is needed) and the test bundle
// (where they are a separate module). The conditional keeps both compiling from one source file
// rather than forking a test-only copy that could drift.
#if canImport(PixelDesktop)
// `@testable` rather than a plain import: the shared types are `internal`, so a plain import
// would find the module but not the types. In the tool target this branch is not compiled at all
// (the shared sources are in the same module there).
@testable import PixelDesktop
#endif

/// The result of one `run` invocation.
struct CLIRunResult: Encodable, Equatable {

    /// The workload that was requested, as published by the contract.
    let workload: String

    /// The job id used for this execution. Echoed by the worker and used for the ownership check.
    let jobId: String

    /// Stable token naming the `WorkerStreamOutcome` case that was observed.
    let outcome: String

    /// The decoded DTCA-1 result payload, present only when the worker reported DTCA-1's own
    /// success token (`"COMPLETED"`).
    ///
    /// Absent — not empty, not zeroed — when there is no result to report. A consumer must not
    /// read a missing payload as a result of any kind.
    let output: DTCA1Result?

    /// The decoded LOCAL-LLM-1 inference result, present only when the worker reported
    /// LOCAL-LLM-1's own success token (`"OK"`).
    ///
    /// This is the result-shape routing added in Phase 9 Step 6: the CLI boundary can decode
    /// and publish the `InferenceResult` shape (including `text`, `token_ids`,
    /// `generated_tokens`, and execution evidence) without executing LOCAL-LLM-1.
    let inferenceOutput: InferenceResult?

    /// What the execution machinery observed while running the job.
    let evidence: CLIRunEvidence

    init(
        workload: String,
        jobId: String,
        outcome: WorkerStreamOutcome,
        run: WorkerStreamRunner.Run,
        output: DTCA1Result?,
        inferenceOutput: InferenceResult? = nil,
        workerRefusal: PixelDesktopError? = nil
    ) {
        self.workload = workload
        self.jobId = jobId
        // A worker-reported refusal is a *job* outcome, not a stream outcome. The stream can
        // complete cleanly while the job fails, and reporting `completed` alongside `ok: false`
        // would tell a consumer two contradictory things. The refusal therefore names the
        // outcome, and the stream-level detail stays in `evidence`.
        self.outcome = workerRefusal == nil ? CLIRunResult.token(for: outcome) : "failed"
        self.output = output
        self.inferenceOutput = inferenceOutput
        self.evidence = CLIRunEvidence(run)
    }

    /// A stable, machine-readable name for each `WorkerStreamOutcome` case.
    ///
    /// Exhaustive over the enum: a new case must force a decision here rather than silently
    /// falling through to a generic token.
    static func token(for outcome: WorkerStreamOutcome) -> String {
        switch outcome {
        case .completed: return "completed"
        case .completedButDurabilityUnverified: return "completed_but_durability_unverified"
        case .recoveredFromDevice: return "recovered_from_device"
        case .failed: return "failed"
        case .workerExitedUnexpectedly: return "worker_exited_unexpectedly"
        case .streamLostWorkerRunning: return "stream_lost_worker_running"
        case .streamLostWorkerGone: return "stream_lost_worker_gone"
        case .streamLostUnknown: return "stream_lost_unknown"
        case .incomplete: return "incomplete"
        case .malformedStream: return "malformed_stream"
        }
    }

    /// The typed error an unsuccessful outcome represents, in the existing taxonomy.
    ///
    /// Returns `nil` for the two outcomes that are genuine successes. Nothing here invents a
    /// category: `.failed` already carries the worker's own `code`, and it is passed through as
    /// `workerRefused(category:)` so the token survives rather than being flattened into prose.
    ///
    /// `.completedButDurabilityUnverified` is **not** treated as success. The worker produced a
    /// result, but the durable file could not be confirmed — E1's own finding is that "stream
    /// completion does not mean result durability". Reporting it as success would discard exactly
    /// the distinction that outcome exists to carry.
    static func error(for outcome: WorkerStreamOutcome) -> PixelDesktopError? {
        switch outcome {
        case .completed, .recoveredFromDevice:
            return nil

        case .failed(let code, let message):
            // The worker reported a structured category. Preserve it verbatim.
            return code.isEmpty
                ? .workerError("Worker reported failure: \(message)")
                : .workerRefused(category: code, message: message)

        case .completedButDurabilityUnverified(_, let reason):
            return .verificationFailed(
                reason: "Worker produced a result but the durable file could not be confirmed: \(reason)")

        case .workerExitedUnexpectedly(let sequence):
            return .workerError("Worker process disappeared before producing a result (at heartbeat \(sequence))")

        case .streamLostWorkerRunning(let pid):
            // Not a failure of the work — the worker outlived its control channel. Reported as an
            // incomplete run rather than as a lost job, because the two need different responses.
            return .workerError(
                "Transport lost while the worker was still running (pid \(pid.map(String.init) ?? "unknown")); "
                + "the job did not report a result over this session")

        case .streamLostWorkerGone:
            return .workerError("Transport lost, the worker is gone, and no result was found")

        case .streamLostUnknown(let reason):
            return .workerError("Transport lost and the worker's state could not be determined: \(reason)")

        case .incomplete(let reason):
            return .workerError("Execution ended without reporting completion: \(reason)")

        case .malformedStream(let reason):
            return .verificationFailed(reason: "Stream was structurally invalid: \(reason)")
        }
    }
}

/// What the execution machinery observed. Read from `WorkerStreamRunner.Run`, not measured here.
struct CLIRunEvidence: Encodable, Equatable {

    /// The worker's PID, when it was observed alive.
    let workerPidObserved: Int?

    /// Liveness heartbeats received. Liveness only — the worker reports no progress of its own.
    let heartbeatCount: Int

    /// Seconds from session start to the first line received.
    let timeToFirstEventSeconds: Double?

    /// Seconds from session start to the launch acknowledgement.
    let timeToLaunchAckSeconds: Double?

    /// Seconds from session start to a terminal outcome.
    let timeToOutcomeSeconds: Double?

    /// Total wall time of the streaming session.
    let wallSeconds: Double

    /// Whether the session ended without a protocol terminal event.
    ///
    /// Published because it is the difference between "the stream told us" and "the device told
    /// us later" — a distinction E1 keeps and a consumer should not have to infer.
    let streamEndedUnexpectedly: Bool

    /// Count of stderr lines. Kept separate from protocol events, and counted rather than
    /// inlined so device diagnostics cannot be mistaken for protocol traffic.
    let stderrLineCount: Int

    /// Count of unstructured stdout lines — evidence that the script and parser disagree.
    let unrecognizedLineCount: Int

    init(_ run: WorkerStreamRunner.Run) {
        self.workerPidObserved = run.workerPidObserved
        self.heartbeatCount = run.heartbeatCount
        self.timeToFirstEventSeconds = run.timeToFirstEventSeconds
        self.timeToLaunchAckSeconds = run.timeToLaunchAckSeconds
        self.timeToOutcomeSeconds = run.timeToOutcomeSeconds
        self.wallSeconds = run.wallSeconds
        self.streamEndedUnexpectedly = run.streamEndedUnexpectedly
        self.stderrLineCount = run.stderrLines.count
        self.unrecognizedLineCount = run.unrecognizedLines.count
    }
}
