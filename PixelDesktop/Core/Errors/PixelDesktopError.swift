import Foundation

/// The typed error vocabulary of PixelDesktop.
///
/// ## Case status (Phase 7 Step 3)
///
/// Every case here is either **reachable** (production code throws it) or **reserved**
/// (declared, correct, and deliberately not yet produced). That distinction is recorded
/// per case below, because a declared-but-unreachable case and a reachable one look
/// identical to a reader and mean very different things.
///
/// Step 3 found three cases that no production code threw. Two were traced to a real
/// signal being mis-typed and are now **reachable**; one has no implementation and is
/// **reserved**. No case was deleted to satisfy a completeness gate — see
/// `engineering/phases/phase-07-step-3-refusal-path.md`.
enum PixelDesktopError: Error, Equatable, CustomStringConvertible {

    // MARK: - Device state

    /// No device is attached, or none is in the `device` state.
    /// **Reachable.** Thrown by `AppState` when no connected device can be selected.
    case deviceNotFound

    /// The device is attached but has not accepted the host's ADB key.
    ///
    /// **Reachable (Phase 7 Step 3).** Previously unreachable: `DeviceState.unauthorized`
    /// was parsed correctly by `ADBTransport` and then discarded by a `state == .device`
    /// predicate, so an unauthorized device surfaced as `.deviceNotFound`. The state is now
    /// distinguished, because this is the only error in the vocabulary that tells the user
    /// something they can act on.
    case deviceUnauthorized

    /// The device is attached but offline.
    /// **Reachable.** Thrown by `DeviceManager` and `DeviceEnricher`.
    case deviceOffline

    // MARK: - Transport

    /// An ADB command ran and exited non-zero.
    ///
    /// **Reachable.** Note this is *not* the timeout path — a timeout is its own case.
    case adbCommandFailed(command: String, exitCode: Int, stderr: String)

    /// The transport itself failed, as distinct from the command failing.
    /// **Reachable.** Thrown by `ADBTransport`.
    case adbTransportError(String)

    // MARK: - Input and execution

    /// The caller supplied something the operation cannot accept.
    /// **Reachable.** The most frequently thrown case.
    case invalidInput(String)

    /// An operation exceeded its deadline and was terminated.
    ///
    /// **Reachable (Phase 7 Step 3).** Previously unreachable: `ADBTransport` detected the
    /// timeout, terminated the process, and then *returned* it as a `TransportResult` with
    /// `exitCode: -1` and a stderr message — so it surfaced upward as `.adbCommandFailed`.
    /// The distinction was carried only in prose, and a launch failure used the same `-1`
    /// sentinel. The transport now throws this case directly, so the timeout is typed at
    /// the point it is detected rather than reconstructed from a string.
    case timeout(operation: String, duration: TimeInterval)

    /// An operation was cancelled by the caller.
    ///
    /// **Reserved — not implemented.** Nothing in PixelDesktop throws this case.
    ///
    /// This is deliberate, not an oversight. Cancellation in this system is
    /// **`am force-stop`, issued outside the streaming session**: `WorkerStreamingTests`
    /// §13 asserts that the streaming path must never cancel, and in particular must not
    /// kill a worker whose stream died. A worker that outlives its control channel is
    /// recoverable; one that was killed is not.
    ///
    /// The case is preserved because the classification below is correct for a cancellation
    /// signal whenever one is genuinely produced. It is **not** faked into existence to make
    /// a completeness gate pass. If a real execution path ever needs to cancel, this is the
    /// type it should throw.
    case cancelled

    // MARK: - Worker

    /// Independent verification of a worker's result failed.
    /// **Reachable.** Thrown by `DTCA1Job`, `WorkerComputeProof`, `WorkerOperationsProtocol`.
    case verificationFailed(reason: String)

    /// A worker-side failure with no further structure.
    ///
    /// **Reachable.** Retained for failures that genuinely carry no category — for example a
    /// malformed envelope that never yielded a `status` at all.
    ///
    /// Prefer `workerRefused` when the worker supplied a category.
    case workerError(String)

    /// The worker refused the job and reported a **structured category**.
    ///
    /// **Reachable (Phase 7 Step 3).** Previously the worker's `error_type` was interpolated
    /// into a `workerError` prose string, so `MODEL_MISSING` and `INVALID_INPUT` — different
    /// causes, different fixes, one retryable and one not — became indistinguishable to any
    /// caller that was not pattern-matching English.
    ///
    /// The category is the worker's own token, carried verbatim. The vocabulary is fixed on
    /// the Android side in `LlmWorkload.java`:
    ///
    ///     INVALID_INPUT · NATIVE_LIBRARY_MISSING · MODEL_MISSING
    ///     MODEL_LOAD_FAILED · INFERENCE_FAILED
    ///
    /// It is deliberately a `String` rather than a Swift enum mirroring those five values:
    /// the worker is the authority on what it can refuse, and a mirrored enum would silently
    /// drop any category a newer worker introduced.
    case workerRefused(category: String, message: String)

    /// The routing gate refused to submit this work, and the decision travels with the refusal.
    ///
    /// **Reachable (Phase 3.4).** Distinct from `workerRefused`: the worker never saw a job. The
    /// decision is carried whole — not flattened into prose — because the two reasons work is
    /// withheld call for opposite responses: a `.deferred` decision is worth retrying once the
    /// device has settled, a `.rejected` one is not worth retrying until something changes.
    case routingBlocked(RoutingDecision)

    /// An error that fits none of the above.
    /// **Reachable** as a last-resort fallback.
    case unknown(String)

    // MARK: - Presentation

    var description: String {
        switch self {
        case .deviceNotFound:
            return "No authorized Android device found"
        case .deviceUnauthorized:
            return "Device is unauthorized. Please accept the ADB authorization prompt on the device."
        case .deviceOffline:
            return "Device is offline"
        case .adbCommandFailed(let command, let exitCode, let stderr):
            return "ADB command failed: \(command) (exit code \(exitCode)): \(stderr)"
        case .adbTransportError(let message):
            return "ADB transport error: \(message)"
        case .invalidInput(let reason):
            return "Invalid input: \(reason)"
        case .timeout(let operation, let duration):
            return "Operation timed out: \(operation) after \(String(format: "%.1f", duration))s"
        case .cancelled:
            return "Operation was cancelled"
        case .verificationFailed(let reason):
            return "Verification failed: \(reason)"
        case .workerError(let message):
            return "Worker error: \(message)"
        case .workerRefused(let category, let message):
            return "Worker refused the job [\(category)]: \(message)"
        case .routingBlocked(let decision):
            let reasons = decision.reasonLines.joined(separator: "; ")
            return "\(decision.summary)\(reasons.isEmpty ? "" : " \(reasons)")"
        case .unknown(let message):
            return "Unknown error: \(message)"
        }
    }

    // MARK: - Retry contract

    /// Whether retrying the same operation could plausibly succeed.
    ///
    /// **This contract is declared and correct but has no production reader.** There is no
    /// retry loop in PixelDesktop, so nothing currently consults it — verified in Step 3 by
    /// searching for readers and finding only tests. It is retained because the classification
    /// is the intended contract for any future retry policy, and it is recorded as
    /// *advisory rather than enforced* so a reader does not assume it is applied.
    ///
    /// `workerRefused` is classified **non-recoverable** because every category the worker can
    /// currently report describes a condition that will not change on retry: a bad prompt, a
    /// missing native library, a missing or unloadable model, or a failed inference on that
    /// model. If a future category is genuinely transient, it must be classified explicitly
    /// rather than inherited from this default.
    var isRecoverable: Bool {
        switch self {
        case .deviceNotFound, .deviceUnauthorized, .deviceOffline:
            return true
        case .adbCommandFailed, .adbTransportError:
            return true
        case .timeout, .cancelled:
            return true
        case .invalidInput, .verificationFailed, .workerError, .workerRefused:
            return false
        case .routingBlocked(let decision):
            // The decision already knows: a deferral clears on its own, a rejection does not.
            return decision.isRetryable
        case .unknown:
            return false
        }
    }
}
