import Foundation

/// The structured event protocol carried on a persistent `adb shell` stream.
///
/// ## Why a line protocol and not a framework
///
/// E1 (`790164d`) established that a single persistent `adb shell` can drive a complete worker
/// job: deliver the payload, launch the worker, report liveness, and carry the result. This file
/// defines the *smallest* structured protocol that supports that, and nothing more.
///
/// It is **not** an RPC framework. There is no framing layer, no handshake, no session
/// negotiation, no multiplexing, and no message bus. It is a prefix, a token, and `key=value`
/// pairs — chosen because the only thing parsing it is a `while` loop in the device script and a
/// `switch` on the Mac.
///
/// ## The events are about the *job*, not about the *model*
///
/// `HEARTBEAT` reports **process liveness**, and deliberately does not claim to be inference
/// progress. The worker emits no progress of any kind (verified: it writes to logcat, never to
/// stdout), so any "generation progress" event would be invented. The distinction is enforced by
/// naming and by documentation rather than left to a reader's assumption.
enum WorkerEvent: Equatable, Sendable {

    /// The device script began. Carries the `job_id` so a result can be matched to this stream.
    case started(jobId: String)

    /// The job payload was written on the device. Confirms stdin delivery completed.
    case jobWritten(bytes: Int)

    /// `am start` was issued and accepted. **Not** proof the process is up.
    case launched

    /// Liveness tick. `workerPid` is `nil` when no process matched.
    ///
    /// This is **process liveness, not model-generation progress**.
    case heartbeat(sequence: Int, workerPid: Int?)

    /// The worker process disappeared while the result had not yet appeared.
    ///
    /// This is the E1 F4 case: without this transition a naive loop keeps heartbeating forever
    /// after the worker has died.
    case workerExited(sequence: Int)

    /// The worker produced a result and the script is about to emit it.
    case resultBegan

    /// One line of the result payload. Emitted between `resultBegan` and `resultEnded`.
    case resultLine(String)

    /// The result payload ended. `bytes` is what the device reported for the file.
    case resultEnded(bytes: Int)

    /// A bounded, machine-readable failure reported by the script itself.
    ///
    /// This is for failures the *stream* can detect (a missing workspace, a failed write). Worker
    /// failures are reported in the result file, not here, because the worker always writes a
    /// `FAILED` result rather than crashing.
    case failure(code: String, message: String)

    /// A line on the stream that is not a protocol event.
    ///
    /// Kept as a distinct case rather than dropped: unstructured output is a signal that the
    /// device script and this parser disagree, and silently discarding it would hide that.
    case unrecognized(String)
}

/// Parses `PDE1` protocol lines.
///
/// Pure and total: every input maps to an event or to `nil`. No I/O, no state, so the whole
/// protocol is testable without a device.
enum WorkerEventParser {

    /// The line prefix. Chosen to be unlikely to collide with anything a shell or the worker
    /// prints, so stray output is distinguishable from protocol traffic.
    static let prefix = "PDE1"

    /// Parses one line into an event.
    ///
    /// - Returns: `nil` for blank lines and for lines that are not protocol lines.
    static func parse(_ line: String) -> WorkerEvent? {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        let parts = trimmed.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
        guard let first = parts.first, first == prefix, parts.count >= 2 else { return nil }

        let token = parts[1]
        let fields = parseFields(Array(parts.dropFirst(2)))

        switch token {
        case "START":
            return .started(jobId: fields["job_id"] ?? "")

        case "JOB_WRITTEN":
            return .jobWritten(bytes: fields["bytes"].flatMap(Int.init) ?? 0)

        case "LAUNCHED":
            return .launched

        case "HEARTBEAT":
            let sequence = fields["n"].flatMap(Int.init) ?? 0
            let pidText = fields["pid"]
            let pid = (pidText == nil || pidText == "none") ? nil : pidText.flatMap(Int.init)
            return .heartbeat(sequence: sequence, workerPid: pid)

        case "WORKER_EXITED":
            return .workerExited(sequence: fields["n"].flatMap(Int.init) ?? 0)

        case "RESULT_BEGIN":
            return .resultBegan

        case "RESULT_END":
            return .resultEnded(bytes: fields["bytes"].flatMap(Int.init) ?? 0)

        case "ERROR":
            return .failure(
                code: fields["code"] ?? "UNKNOWN",
                message: fields["message"] ?? ""
            )

        default:
            return .unrecognized(trimmed)
        }
    }

    /// Splits `key=value` tokens.
    ///
    /// A value may contain spaces, so a token is only treated as a field when its key is a bare
    /// identifier; anything else is appended to the previous value. That keeps
    /// `message=some text here` intact instead of truncating it at the first space.
    static func parseFields(_ tokens: [String]) -> [String: String] {
        var fields: [String: String] = [:]
        var currentKey: String?

        for token in tokens {
            guard let equals = token.firstIndex(of: "=") else {
                if let key = currentKey {
                    fields[key] = (fields[key] ?? "") + " " + token
                }
                continue
            }

            let key = String(token[token.startIndex..<equals])
            let value = String(token[token.index(after: equals)...])

            // A bare identifier key starts a new field; anything else continues the previous one.
            if isIdentifier(key) {
                fields[key] = value
                currentKey = key
            } else if let current = currentKey {
                fields[current] = (fields[current] ?? "") + " " + token
            }
        }

        return fields
    }

    private static func isIdentifier(_ text: String) -> Bool {
        guard !text.isEmpty else { return false }
        return text.allSatisfy { $0.isLetter || $0.isNumber || $0 == "_" }
    }
}

/// The live state of a streaming job.
///
/// The brief requires that stream state and worker state are **not collapsed into one connection
/// state**. These are separate axes, and the whole point of this enum is to keep them separate:
/// the stream can be alive while the worker is dead (F4), and the stream can be gone while the
/// worker is alive (F7).
enum WorkerStreamState: Equatable, Sendable {
    /// Stream connected, worker process present.
    case streamAliveWorkerAlive(pid: Int)

    /// Stream connected, no worker process yet. Normal between `LAUNCHED` and the process
    /// appearing.
    case streamAliveWorkerNotYetVisible

    /// Stream connected, worker process disappeared before producing a result. **F4.**
    case streamAliveWorkerExited

    /// Stream gone, worker still running. **F7** — the job is *not* failed.
    case streamLostWorkerAlive(pid: Int?)

    /// Stream gone, worker gone, result may or may not be on the device.
    case streamLostWorkerGone

    /// Stream gone and the worker's state could not be determined.
    case streamLostWorkerUnknown

    var description: String {
        switch self {
        case .streamAliveWorkerAlive(let pid): return "stream alive / worker alive (pid \(pid))"
        case .streamAliveWorkerNotYetVisible: return "stream alive / worker not yet visible"
        case .streamAliveWorkerExited: return "stream alive / worker exited"
        case .streamLostWorkerAlive(let pid): return "stream lost / worker alive" + (pid.map { " (pid \($0))" } ?? "")
        case .streamLostWorkerGone: return "stream lost / worker gone"
        case .streamLostWorkerUnknown: return "stream lost / worker state unknown"
        }
    }
}

/// The final outcome of a streaming job.
///
/// Deliberately more granular than success/failure. In particular `.streamLost*` outcomes are
/// **not** failures: E1 F7 proved a stream can die while the worker completes successfully, so
/// reporting transport loss as job failure would be a false negative.
enum WorkerStreamOutcome: Equatable, Sendable {

    /// The worker produced a result and the durable file was verified on the device.
    case completed(resultJSON: String, resultBytes: Int)

    /// The worker produced a result on the stream, but the durable file could not be confirmed.
    ///
    /// Kept distinct from `.completed` because the brief requires that *"stream completion does
    /// not mean result durability"*. This outcome says exactly that.
    case completedButDurabilityUnverified(resultJSON: String, reason: String)

    /// The worker produced a result that was **recovered from the device** after the stream ended.
    ///
    /// Distinct from `.completed` because the stream did not carry the result: it was read from the
    /// durable file after transport loss. This is the E1 F7 recovery path, and naming it separately
    /// keeps "the stream told us" and "the device told us later" from being conflated.
    case recoveredFromDevice(resultJSON: String, resultBytes: Int)

    /// The worker wrote a `FAILED` result. A reported failure, not a missing one.
    case failed(code: String, message: String)

    /// The worker process disappeared before producing a result. **F4.**
    case workerExitedUnexpectedly(sequence: Int)

    /// The stream ended while the worker was still running. **F7** — the worker was *not* killed.
    case streamLostWorkerRunning(pid: Int?)

    /// The stream ended, the worker is gone, and no result was found.
    case streamLostWorkerGone

    /// The stream ended and the worker's state could not be determined. Reported rather than
    /// guessed, per the brief's instruction not to invent failure.
    case streamLostUnknown(reason: String)

    /// The stream ended without ever reporting completion.
    case incomplete(reason: String)

    /// The stream was structurally invalid (e.g. a result that never ended).
    case malformedStream(reason: String)

    var isSuccess: Bool {
        switch self {
        case .completed, .recoveredFromDevice: return true
        default: return false
        }
    }

    /// Whether the job reached a state where the worker may still be running.
    ///
    /// Callers use this to decide that a **cancellation must not be issued** — killing a worker
    /// because its stream died would discard valid in-flight work (F7).
    var mayStillBeRunning: Bool {
        switch self {
        case .streamLostWorkerRunning, .streamLostUnknown, .incomplete:
            return true
        default:
            return false
        }
    }

    var description: String {
        switch self {
        case .completed(_, let bytes): return "completed (result \(bytes) bytes, durable)"
        case .completedButDurabilityUnverified(_, let reason):
            return "completed on stream, durability unverified: \(reason)"
        case .recoveredFromDevice(_, let bytes):
            return "recovered from device after stream loss (result \(bytes) bytes)"
        case .failed(let code, let message): return "worker reported \(code): \(message)"
        case .workerExitedUnexpectedly(let seq): return "worker exited unexpectedly at heartbeat \(seq)"
        case .streamLostWorkerRunning(let pid):
            return "stream lost while worker still running" + (pid.map { " (pid \($0))" } ?? "")
        case .streamLostWorkerGone: return "stream lost and worker is gone"
        case .streamLostUnknown(let reason): return "stream lost, worker state unknown: \(reason)"
        case .incomplete(let reason): return "stream ended without completion: \(reason)"
        case .malformedStream(let reason): return "malformed stream: \(reason)"
        }
    }
}
