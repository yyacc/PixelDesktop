//
//  CLIEnvelope.swift
//  PixelDesktopCLI
//
//  Phase 9 Step 1 — the read-only publication envelope.
//
//  WHAT THIS IS
//  A thin presentation layer over the EXISTING PixelDesktop types. It introduces no
//  capability logic of its own: every value it publishes is read from
//  `PixelCapabilityContract` or `PixelEvidenceReader` unchanged.
//
//  WHY AN ENVELOPE AT ALL
//  A consumer (Hermes) needs to distinguish five things a bare payload cannot express:
//  which interface shape it is reading, which command produced it, whether it succeeded,
//  when it was produced, and — on failure — a structured error rather than prose.
//
//  WHAT THIS IS NOT
//  Not a second capability implementation. Not a DTO hierarchy mirroring the contract.
//  The payload fields are the project's own Codable types, encoded as-is.
//

import Foundation

// Compiled into both the `pixel-desktop` tool (same module as the shared sources) and the test
// bundle (separate module), from one file.
#if canImport(PixelDesktop) && !PIXELDESKTOP_CLI_TOOL
@testable import PixelDesktop
#endif

/// The publication envelope for every `pixel-desktop` command.
///
/// `contract` and `observation` are deliberately separate fields rather than one merged
/// payload: Phase 7 Step 1/Step 2 established that static capability and observed state are
/// different channels with different lifetimes, and merging them here would undo that.
struct CLIEnvelope {

    /// The envelope's own shape version, independent of `PixelCapabilityContract.contractVersion`.
    ///
    /// The two can move independently: the contract may gain a field without the envelope
    /// changing, and the envelope may change (e.g. a new key) without the contract changing.
    /// A consumer must be able to detect either.
    static let currentInterfaceVersion = 1

    let interfaceVersion: Int
    let command: String
    let ok: Bool
    let producedAt: Date
    let contract: PixelCapabilityContract?
    let observation: PixelStateObservation?

    /// The structured result of one `run` invocation.
    ///
    /// Present only for the `run` command. Like `contract` and `observation`, the key is always
    /// emitted (`null` when it does not apply) so a consumer never has to guess whether a missing
    /// key means "not applicable" or "something went wrong".
    let result: CLIRunResult?

    /// The structured result of one `schedule run` invocation.
    ///
    /// Present only for the `schedule` command, and always emitted for it (`null` otherwise), for
    /// the same reason as `result`: a missing key and a null key must not look alike. The outcome
    /// here is the scheduler's own vocabulary — see `CLIScheduledRunReport` for why it is not
    /// mapped onto `PixelDesktopError`.
    let scheduledRun: CLIScheduledRunReport?

    /// Fields deliberately not read, with the reason.
    ///
    /// Present so an omission is *stated* rather than left for the consumer to infer from a
    /// missing key. An absent field with a recorded reason is honest; an absent field with no
    /// explanation is indistinguishable from a bug.
    let notRead: [CLINotRead]

    let error: CLIErrorPayload?

    init(
        command: String,
        ok: Bool,
        producedAt: Date = Date(),
        contract: PixelCapabilityContract? = nil,
        observation: PixelStateObservation? = nil,
        result: CLIRunResult? = nil,
        scheduledRun: CLIScheduledRunReport? = nil,
        notRead: [CLINotRead] = [],
        error: CLIErrorPayload? = nil
    ) {
        self.interfaceVersion = Self.currentInterfaceVersion
        self.command = command
        self.ok = ok
        self.producedAt = producedAt
        self.contract = contract
        self.observation = observation
        self.result = result
        self.scheduledRun = scheduledRun
        self.notRead = notRead
        self.error = error
    }
}

/// A field this command did not read, and why.
struct CLINotRead: Codable, Equatable {
    let field: String
    let reason: String
}

// MARK: - Encoding

extension CLIEnvelope: Encodable {

    enum CodingKeys: String, CodingKey {
        case interfaceVersion = "interface_version"
        case command
        case ok
        case producedAt = "produced_at"
        case contract
        case observation
        case result
        case scheduledRun = "scheduled_run"
        case notRead = "not_read"
        case error
    }

    /// Encoded by hand so that `contract`, `observation`, `result`, `error` and `not_read` are
    /// always **present** keys — `null` / `[]` when empty.
    ///
    /// Swift's synthesized conformance omits `nil` optionals entirely, which would make
    /// "no observation because this is the capability command" indistinguishable from
    /// "no observation because something went wrong". A consumer should never have to guess
    /// which of those it is looking at.
    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(interfaceVersion, forKey: .interfaceVersion)
        try container.encode(command, forKey: .command)
        try container.encode(ok, forKey: .ok)
        try container.encode(producedAt, forKey: .producedAt)
        try container.encode(contract, forKey: .contract)
        try container.encode(observation, forKey: .observation)
        try container.encode(result, forKey: .result)
        try container.encode(scheduledRun, forKey: .scheduledRun)
        try container.encode(notRead, forKey: .notRead)
        try container.encode(error, forKey: .error)
    }
}

// MARK: - Structured error

/// A failure, in the project's existing error taxonomy.
///
/// `type` is a stable machine token derived from `PixelDesktopError`. `category` carries the
/// Android worker's own `error_type` **verbatim** when the failure came from a worker — the
/// Phase 7 Step 3 finding was that flattening that token into prose destroys the distinction
/// between `MODEL_MISSING` and `INVALID_INPUT`, so it is preserved rather than re-mapped.
struct CLIErrorPayload: Encodable, Equatable {
    let type: String
    let message: String
    let isRecoverable: Bool
    let category: String?

    /// The routing decision, when the failure *is* a routing decision.
    ///
    /// Present only for `routing_blocked`, and carried whole rather than summarised: the reason
    /// lines, the measurements and the `deferred`/`rejected` distinction are the actionable part
    /// of the refusal, and a consumer that gets only prose cannot tell whether to retry.
    let routing: RoutingDecision?

    /// snake_case to match the rest of the envelope (`interface_version`, `produced_at`,
    /// `not_read`). The keys inside `contract` and `observation` are the shared types' own and
    /// are deliberately left alone.
    enum CodingKeys: String, CodingKey {
        case type
        case message
        case isRecoverable = "is_recoverable"
        case category
        case routing
    }

    init(_ error: PixelDesktopError) {
        self.type = Self.token(for: error)
        self.message = error.description
        self.isRecoverable = error.isRecoverable

        if case .workerRefused(let category, _) = error {
            self.category = category
        } else {
            self.category = nil
        }

        if case .routingBlocked(let decision) = error {
            self.routing = decision
        } else {
            self.routing = nil
        }
    }

    /// Maps the existing `PixelDesktopError` vocabulary onto stable snake_case tokens.
    ///
    /// Every case of the enum is handled. `workerRefused` reports as `worker_refused` with its
    /// category carried separately, so a consumer can branch on the category without parsing
    /// the message.
    static func token(for error: PixelDesktopError) -> String {
        switch error {
        case .deviceNotFound: return "device_not_found"
        case .deviceUnauthorized: return "device_unauthorized"
        case .deviceOffline: return "device_offline"
        case .adbCommandFailed: return "adb_command_failed"
        case .adbTransportError: return "adb_transport_error"
        case .invalidInput: return "invalid_input"
        case .timeout: return "timeout"
        case .cancelled: return "cancelled"
        case .verificationFailed: return "verification_failed"
        case .workerError: return "worker_error"
        case .workerRefused: return "worker_refused"
        // Distinct from `worker_refused`: nothing was asked of the worker. The gate stopped the
        // run before submission, and the decision travels alongside in `routing`.
        case .routingBlocked: return "routing_blocked"
        case .unknown: return "unknown"
        }
    }
}
