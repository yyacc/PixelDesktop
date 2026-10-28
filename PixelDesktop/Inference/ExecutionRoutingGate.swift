//
//  ExecutionRoutingGate.swift
//  PixelDesktop
//
//  Phase 11 — one decision, made once, at the execution boundary.
//
//  WHAT THIS IS
//  A pure function over an observation. It answers a single question — *should this work be
//  submitted to the Pixel right now?* — and it answers it the same way for every caller: the
//  manual `run` command, the scheduler, and the UI that renders the decision.
//
//  WHY IT EXISTS
//  Phase 10 measured LOCAL-LLM-1 at 125 451 ms on the device against 4 541 ms for the identical
//  job once the server stopped oversubscribing its cores. Nothing in the product noticed: the
//  run was submitted, the result was returned, and a 27× regression was reported as a success.
//  Resource unsuitability is not an inference failure — it is a reason not to start.
//
//  THE THREE-WAY ANSWER
//  "Eligible" and "not eligible" are not enough. Work is refused for two very different reasons,
//  and conflating them makes a transient condition indistinguishable from a permanent one:
//
//    • `.deferred` — a condition that can clear on its own (device busy, hot, low memory, stale
//      metrics). Retry later; nothing needs to change.
//    • `.rejected` — a condition that will not clear without an intervening action (model absent,
//      worker not installed, backend unhealthy — the server must be started). Retrying is
//      pointless until that action happens.
//    • `.requiresOverride` — soft conditions only, and only for an interactive caller, who is
//      shown the measurements and may proceed deliberately (`.overridden`).
//
//  HARD vs SOFT
//  A hard check can never be overridden. It encodes either a safety constraint (thermal, memory,
//  storage — conditions that can destabilise the device) or a precondition whose absence makes
//  the run meaningless (no model, no worker, backend unhealthy). A soft check encodes a
//  performance expectation, which an operator may knowingly accept.
//
//  FAIL CLOSED
//  An unattended run may not proceed on an unestablished metric. A `.unknown` verdict is treated
//  exactly like a failure for hard checks, and for unattended work for soft checks too. The one
//  exception is deliberate: an *unperformed* check is recorded as `notEvaluated` rather than as
//  a failure, because "we did not look" is not evidence of unsuitability. That distinction is
//  published, not hidden.
//

import Foundation

// MARK: - Context

/// Why the work is being submitted.
///
/// This is the only input that differs between the two real boundaries, and it decides what an
/// ineligible verdict *means*: an unattended run is blocked outright, an interactive one is told
/// why and may override soft conditions.
enum ExecutionContext: String, Codable, Equatable, Sendable {
    /// A human asked for this run, now, and is waiting for the answer.
    case interactive

    /// A scheduler fired. Nobody is watching, so there is nobody to show a reason to and nobody
    /// to accept a risk: an ineligible verdict blocks.
    case unattended
}

/// What the submitted work needs from the device.
///
/// The distinction is not cosmetic: a telemetry read needs a reachable device and somewhere to
/// write, while an inference run additionally needs a model, the memory to hold it, the thermal
/// headroom to run it, and a backend that answers.
enum ExecutionRequirement: String, Codable, Equatable, Sendable {
    /// Reads and writes over ADB. No model is loaded and no tokens are generated.
    case deviceRead

    /// Loads a model and generates tokens.
    case inference
}

// MARK: - One evaluated condition

/// A single condition, with what was measured and what it was measured against.
///
/// Measurements travel with the verdict on purpose: a refusal that says only "ineligible" is not
/// actionable, and an operator cannot judge an override without the numbers.
struct RoutingCheck: Codable, Equatable, Sendable {

    /// Whether this condition may be overridden by an interactive caller.
    enum Severity: String, Codable, Equatable, Sendable {
        /// Never overridable: a safety constraint or a precondition.
        case hard
        /// Overridable by a human who has been shown the measurement.
        case soft
    }

    /// The three answers a condition can give. `.unknown` is not `.passed`: it means the
    /// condition was not established, and it is treated as blocking where the policy requires
    /// a positive answer.
    enum Verdict: String, Codable, Equatable, Sendable {
        case passed
        case failed
        /// Not established — a missing, stale or unreliable measurement.
        case unknown
    }

    /// Stable machine-readable id (`thermal-status`, `model-present`, …).
    let id: String
    /// One line an operator can read.
    let title: String
    let severity: Severity
    let verdict: Verdict
    /// What was actually measured, rendered for a human. Never a guess.
    let measured: String
    /// What it was compared against.
    let threshold: String
    /// Why this condition matters, in one sentence.
    let explanation: String
    /// Whether re-checking later could change this verdict. `false` means the condition cannot
    /// clear without an intervening action (`model-present`, `worker-installed`).
    let isTransient: Bool

    /// True when this condition should block: it failed, or it could not be established.
    var isBlocking: Bool { verdict != .passed }
}

// MARK: - Thresholds

/// The numbers a decision is measured against. Explicit, injectable, and never defaulted inside
/// the evaluator — the same discipline `Freshness.assess` applies to its window.
struct RoutingThresholds: Equatable, Sendable {

    /// How old the observation may be. Older than this and the metrics are not trusted.
    var maxObservationAge: TimeInterval

    /// Minimum `MemAvailable` before an inference run is considered safe to start.
    ///
    /// The model itself is 1.04 GiB; the headroom covers the KV cache for the declared context
    /// plus the copy ggml makes while loading. A run started below this is a candidate for the
    /// low-memory killer, which is a device-stability event, not a workload failure.
    var minimumAvailableMemoryBytes: Int

    /// Minimum `MemAvailable` before a run against the on-device `llama-server`.
    ///
    /// The server loaded its model when it started and holds it resident, so those bytes are
    /// already committed — charging them again would refuse every run on a device that is in fact
    /// serving. What a request still needs is headroom for the KV cache growth of the next
    /// generation plus the worker's own footprint, which is orders of magnitude smaller than a
    /// model load.
    var minimumAvailableMemoryBytesOnDeviceServer: Int

    /// Minimum free bytes on the volume holding the worker's exchange directory.
    var minimumFreeStorageBytes: Int

    /// Highest Android thermal status (`PowerManager.THERMAL_STATUS_*`) at which inference is
    /// allowed. 2 is MODERATE; SEVERE and above are refused.
    var maximumThermalStatus: Int

    /// Floor for the most recent measured generation throughput. Below this the device is
    /// demonstrably not in a state to run the workload at a usable rate.
    var minimumGenerationTokensPerSecond: Double

    /// How old a throughput measurement may be before it stops being evidence about *now*.
    var maxPerformanceAge: TimeInterval

    /// The defaults this build ships with. Derived from the model contract where a number is
    /// already published there, so the two cannot drift.
    static let `default` = RoutingThresholds(
        maxObservationAge: 180,
        minimumAvailableMemoryBytes: ModelContract.expectedByteCount + (512 * 1024 * 1024),
        minimumAvailableMemoryBytesOnDeviceServer: 256 * 1024 * 1024,
        minimumFreeStorageBytes: 256 * 1024 * 1024,
        maximumThermalStatus: 2,
        minimumGenerationTokensPerSecond: 0.5,
        maxPerformanceAge: 3600
    )
}

// MARK: - The decision

/// What the gate concluded, and everything it looked at to conclude it.
enum RoutingOutcome: String, Codable, Equatable, Sendable {
    /// Every evaluated condition passed.
    case eligible
    /// A transient condition blocks. Retry later; nothing needs to change.
    case deferred
    /// A condition that will not clear on its own blocks. Retrying is pointless until it does.
    case rejected
    /// Soft conditions failed and this caller is interactive, so it may proceed deliberately.
    case requiresOverride
    /// Soft conditions failed, the caller overrode them, and the run proceeded.
    case overridden
}

/// The result of one evaluation.
///
/// Carries its own explanation: every surface (CLI envelope, audit log, scheduler report, UI)
/// renders this type rather than reconstructing the reasoning.
struct RoutingDecision: Codable, Equatable, Sendable {

    let outcome: RoutingOutcome
    let requirement: ExecutionRequirement
    let context: ExecutionContext

    /// Every condition that was evaluated, passed or not, in a stable order.
    let checks: [RoutingCheck]

    /// Checks that were deliberately not performed. `"we did not look"` — distinct from failed.
    let notEvaluated: [String]

    /// The serial the observation came from, so a decision cannot be silently attributed to a
    /// different device.
    let deviceSerial: String?

    let evaluatedAt: Date

    /// True only when the work may proceed.
    var isPermitted: Bool { outcome == .eligible || outcome == .overridden }

    /// Whether waiting could change the answer. `false` for `.rejected`.
    var isRetryable: Bool { outcome == .deferred || outcome == .requiresOverride }

    /// Conditions that blocked, in evaluation order.
    var blockingChecks: [RoutingCheck] { checks.filter { $0.isBlocking } }

    /// One sentence for a log line or a UI row.
    var summary: String {
        switch outcome {
        case .eligible:
            return "Eligible: every evaluated condition passed."
        case .deferred:
            return "Deferred: \(blockingChecks.count) condition(s) block execution and may clear without intervention."
        case .rejected:
            return "Rejected: \(blockingChecks.count) condition(s) block execution and will not clear on their own."
        case .requiresOverride:
            return "Requires override: \(blockingChecks.count) soft condition(s) failed; an interactive run may proceed deliberately."
        case .overridden:
            return "Overridden: \(blockingChecks.count) soft condition(s) failed and were accepted by an interactive caller."
        }
    }

    /// The reason, one line per blocking condition, each carrying its measurement. This is what
    /// an operator is shown before deciding, and what the audit log records.
    var reasonLines: [String] {
        blockingChecks.map { check in
            "\(check.title): \(check.measured) (required: \(check.threshold)) — \(check.explanation)"
        }
    }

    /// Re-stamps a `.requiresOverride` decision as `.overridden` once an interactive caller has
    /// explicitly accepted it.
    ///
    /// Refuses to convert anything else. A hard failure can never be re-stamped, and neither can
    /// an unattended decision — the override is a human act, so the type will not record one that
    /// did not happen.
    func overridden(by context: ExecutionContext) -> RoutingDecision? {
        guard outcome == .requiresOverride, context == .interactive else { return nil }
        // Defense in depth. The evaluator only produces `.requiresOverride` when every blocking
        // check is soft, but `RoutingDecision` is `Codable` and travels in the CLI envelope, so a
        // value rebuilt from JSON could pair that outcome with a hard block. Hard means hard
        // however the value was obtained: refuse rather than trust the outcome field.
        guard blockingChecks.allSatisfy({ $0.severity != .hard }) else { return nil }
        return RoutingDecision(
            outcome: .overridden,
            requirement: requirement,
            context: self.context,
            checks: checks,
            notEvaluated: notEvaluated,
            deviceSerial: deviceSerial,
            evaluatedAt: evaluatedAt
        )
    }
}

// MARK: - The evaluator

/// Evaluates one observation against the policy. Pure, synchronous, and injectable-clock, so
/// every branch is testable without a device.
struct ExecutionRoutingEvaluator: Sendable {

    let thresholds: RoutingThresholds

    init(thresholds: RoutingThresholds = .default) {
        self.thresholds = thresholds
    }

    /// Evaluates the policy.
    ///
    /// - Parameters:
    ///   - observation: the device's dynamic state. Its own `observedAt` decides freshness.
    ///   - performance: the most recent measured throughput, if any. Absent is not a failure.
    ///   - backendHealth: the result of a backend liveness probe, or `nil` when no probe applies
    ///     (an in-process backend has no endpoint to probe). A present-and-false probe is a hard
    ///     block. When `contractModelRequired` is `false`, `nil` is a wiring error — the probe
    ///     should have run — and is reported as an unknown, blocking check rather than assumed
    ///     healthy.
    ///   - contractModelRequired: whether the selected backend reads the contract artifact for
    ///     its model. When `false` (the on-device server serves its own model), the
    ///     model-presence check is skipped and the skip is recorded in `notEvaluated`.
    ///   - requirement: what the work needs.
    ///   - context: who is asking.
    ///   - now: injectable clock.
    func evaluate(
        observation: PixelStateObservation,
        performance: PerformanceObservation? = nil,
        backendHealth: Bool? = nil,
        contractModelRequired: Bool = true,
        requirement: ExecutionRequirement,
        context: ExecutionContext,
        now: Date = Date()
    ) -> RoutingDecision {

        var checks: [RoutingCheck] = []
        var notEvaluated: [String] = []

        // Freshness gates everything: an observation older than the window is not evidence about
        // the present, and a decision drawn from it would be a claim we cannot support.
        let freshness = observation.freshness(now: now, maxAge: thresholds.maxObservationAge)
        checks.append(RoutingCheck(
            id: "observation-freshness",
            title: "Observation freshness",
            severity: context == .unattended ? .hard : .soft,
            verdict: freshness == .current ? .passed : .unknown,
            measured: Self.describeAge(observation.observedAt, now: now),
            threshold: "within \(Self.describe(seconds: thresholds.maxObservationAge))",
            explanation: "A decision drawn from stale measurements describes the past, not the present.",
            isTransient: true
        ))

        // Reachability. Everything below is meaningless if the device is not answering, and the
        // failure is transient: a cable is re-seated, a device wakes up.
        checks.append(Self.boolCheck(
            id: "device-reachable",
            title: "Device reachable",
            value: observation.deviceReachable,
            expected: true,
            severity: .hard,
            threshold: "reachable over ADB",
            explanation: "No work can be submitted to a device that is not answering.",
            isTransient: true
        ))

        // Storage: both requirements write to the exchange directory.
        checks.append(Self.intCheck(
            id: "free-storage",
            title: "Free storage",
            value: observation.freeStorageBytes,
            minimum: thresholds.minimumFreeStorageBytes,
            severity: .hard,
            explanation: "The exchange directory and result files are written to this volume; a full volume fails the run mid-flight.",
            isTransient: true
        ))

        if requirement == .inference {
            // The model must be present *at its contract size*. A truncated or foreign artifact
            // is not a transient condition.
            //
            // Only when the backend actually consults that artifact: the on-device server serves
            // its own model and never reads the contract file, so the check is skipped and the
            // skip is reported — never silently treated as a pass.
            if contractModelRequired {
                let presence = observation.modelPresent
                let matchesContract: Bool
                let measured: String
                if presence.source == .unknown {
                    matchesContract = false
                    measured = "not established"
                } else if case .present(let byteCount) = presence.value {
                    matchesContract = byteCount == ModelContract.expectedByteCount
                    measured = "\(byteCount) bytes"
                } else {
                    matchesContract = false
                    measured = "absent"
                }
                checks.append(RoutingCheck(
                    id: "model-present",
                    title: "Model present",
                    severity: .hard,
                    verdict: presence.source == .unknown ? .unknown : (matchesContract ? .passed : .failed),
                    measured: measured,
                    threshold: "\(ModelContract.expectedByteCount) bytes at the contract path",
                    explanation: "A run cannot be started for a model that is not on the device at the size the contract expects.",
                    isTransient: false
                ))
            } else {
                notEvaluated.append(
                    "model-present: not consulted — the llama-server-http backend serves its own model and never reads the contract artifact"
                )
            }

            // Memory. Read as MemAvailable, which is what predicts whether the allocation lands.
            //
            // Which allocation depends on the backend. The in-process path loads the model, so it
            // must find room for the model plus the copy ggml makes. The on-device server loaded
            // its model at startup: charging for a load that already happened would defer every
            // run against a device that is demonstrably serving, so that path is measured against
            // headroom instead. The floor that applied is stated in the check, never left implicit.
            let memoryMinimum = contractModelRequired
                ? thresholds.minimumAvailableMemoryBytes
                : thresholds.minimumAvailableMemoryBytesOnDeviceServer
            checks.append(Self.intCheck(
                id: "available-memory",
                title: "Available memory",
                value: observation.availableMemoryBytes,
                minimum: memoryMinimum,
                severity: .hard,
                explanation: contractModelRequired
                    ? "Starting an inference run that does not fit risks the low-memory killer, which is a device-stability event."
                    : "The on-device server already holds its model resident, so this run needs only headroom for KV growth and the worker's own footprint; below it the low-memory killer is a device-stability event.",
                isTransient: true
            ))

            // Thermal. Refused at SEVERE and above: the device's own governor has already told us
            // it is shedding load, and adding a sustained eight-core workload is the opposite of
            // what that signal asks for.
            checks.append(Self.thermalCheck(
                observation: observation,
                maximum: thresholds.maximumThermalStatus
            ))

            // Backend liveness. A failed health check is a hard block and can never be overridden.
            // For the on-device server this is the only positive evidence left once model-presence
            // is skipped, so a failed or unrun probe is permanent (`.rejected`): retrying without
            // an intervening action cannot clear it.
            if let healthy = backendHealth {
                checks.append(RoutingCheck(
                    id: "backend-health",
                    title: "Backend health",
                    severity: .hard,
                    verdict: healthy ? .passed : .failed,
                    measured: healthy ? "health probe returned 200" : "health probe failed",
                    threshold: "healthy",
                    explanation: "Submitting tokens to a backend that is not answering is a guaranteed failure with a long timeout.",
                    isTransient: false
                ))
            } else if contractModelRequired {
                notEvaluated.append("backend-health: no liveness probe applies to this backend")
            } else {
                // Fail closed: the on-device server backend must be probed. A skipped model check
                // with an unprobed backend is a wiring error, reported as unknown rather than as
                // an eligible decision.
                checks.append(RoutingCheck(
                    id: "backend-health",
                    title: "Backend health",
                    severity: .hard,
                    verdict: .unknown,
                    measured: "not probed — the on-device server backend requires a liveness probe",
                    threshold: "healthy",
                    explanation: "The on-device server serves its own model, so the liveness probe is the only evidence the run can proceed; it did not run.",
                    isTransient: false
                ))
            }

            // Throughput expectation — the only soft check, and the one that would have caught the
            // Phase 10 regression. Absent or stale evidence is not treated as a failure: a device
            // with no history is not a degraded device.
            if let performance {
                let age = now.timeIntervalSince(performance.observedAt)
                if age < 0 || age > thresholds.maxPerformanceAge {
                    notEvaluated.append("recent-throughput: the last measurement is not current evidence")
                } else if let tps = performance.generationTokensPerSecond {
                    checks.append(RoutingCheck(
                        id: "recent-throughput",
                        title: "Measured throughput",
                        severity: .soft,
                        verdict: tps >= thresholds.minimumGenerationTokensPerSecond ? .passed : .failed,
                        measured: String(format: "%.2f tokens/s", tps),
                        threshold: String(format: "%.2f tokens/s", thresholds.minimumGenerationTokensPerSecond),
                        explanation: "A rate this low means the device is not in a state to run this workload at a usable speed; it is accepted deliberately, never silently.",
                        isTransient: true
                    ))
                } else {
                    notEvaluated.append("recent-throughput: the last measurement carries no rate")
                }
            } else {
                notEvaluated.append("recent-throughput: no measurement available")
            }
        }

        return Self.decide(checks: checks, notEvaluated: notEvaluated,
                           requirement: requirement, context: context,
                           deviceSerial: observation.deviceSerial, at: now)
    }

    /// A decision for work that could not be observed at all.
    ///
    /// Fail closed: an unattended run must not proceed on a state nobody could read, and an
    /// interactive one is told exactly that rather than being handed a synthetic "eligible".
    static func unobservable(
        reason: String,
        requirement: ExecutionRequirement,
        context: ExecutionContext,
        deviceSerial: String?,
        at date: Date
    ) -> RoutingDecision {
        let check = RoutingCheck(
            id: "state-observation",
            title: "Device state",
            severity: .hard,
            verdict: .unknown,
            measured: reason,
            threshold: "an observation taken at submit time",
            explanation: "Eligibility cannot be established without a reading of the device.",
            isTransient: true
        )
        return decide(checks: [check], notEvaluated: [], requirement: requirement,
                      context: context, deviceSerial: deviceSerial, at: date)
    }

    /// Aggregates checks into one outcome.
    ///
    /// Permanent beats transient: if any blocking condition cannot clear on its own, the answer is
    /// a rejection, because waiting will not change it.
    private static func decide(
        checks: [RoutingCheck],
        notEvaluated: [String],
        requirement: ExecutionRequirement,
        context: ExecutionContext,
        deviceSerial: String?,
        at date: Date
    ) -> RoutingDecision {

        let blocking = checks.filter { $0.isBlocking }
        let outcome: RoutingOutcome

        if blocking.isEmpty {
            outcome = .eligible
        } else if blocking.contains(where: { $0.severity == .hard }) {
            // A permanent hard failure means retrying is pointless; otherwise the condition can clear.
            let anyPermanent = blocking.contains { $0.severity == .hard && !$0.isTransient }
            outcome = anyPermanent ? .rejected : .deferred
        } else if context == .unattended {
            // Unattended work gets no override, so a soft failure is still a block.
            outcome = .deferred
        } else {
            outcome = .requiresOverride
        }

        return RoutingDecision(
            outcome: outcome,
            requirement: requirement,
            context: context,
            checks: checks,
            notEvaluated: notEvaluated,
            deviceSerial: deviceSerial,
            evaluatedAt: date
        )
    }

    // MARK: - Check builders

    private static func boolCheck(
        id: String,
        title: String,
        value: CapabilityValue<Bool>,
        expected: Bool,
        severity: RoutingCheck.Severity,
        threshold: String,
        explanation: String,
        isTransient: Bool
    ) -> RoutingCheck {
        let established = value.source != .unknown
        return RoutingCheck(
            id: id,
            title: title,
            severity: severity,
            verdict: established ? (value.value == expected ? .passed : .failed) : .unknown,
            measured: established ? (value.value ? "yes" : "no") : "not established",
            threshold: threshold,
            explanation: explanation,
            isTransient: isTransient
        )
    }

    private static func intCheck(
        id: String,
        title: String,
        value: CapabilityValue<Int>,
        minimum: Int,
        severity: RoutingCheck.Severity,
        explanation: String,
        isTransient: Bool
    ) -> RoutingCheck {
        let established = value.source != .unknown
        return RoutingCheck(
            id: id,
            title: title,
            severity: severity,
            verdict: established ? (value.value >= minimum ? .passed : .failed) : .unknown,
            measured: established ? Self.describe(bytes: value.value) : "not established",
            threshold: "at least \(Self.describe(bytes: minimum))",
            explanation: explanation,
            isTransient: isTransient
        )
    }

    private static func thermalCheck(observation: PixelStateObservation, maximum: Int) -> RoutingCheck {
        let value = observation.thermalStatus
        let established = value.source != .unknown
        return RoutingCheck(
            id: "thermal-status",
            title: "Thermal status",
            severity: .hard,
            verdict: established ? (value.value <= maximum ? .passed : .failed) : .unknown,
            measured: established ? Self.describeThermal(value.value) : "not established",
            threshold: "at most \(Self.describeThermal(maximum))",
            explanation: "At SEVERE and above the platform is already shedding load; adding a sustained compute workload risks throttling or a shutdown.",
            isTransient: true
        )
    }

    // MARK: - Rendering

    private static func describe(bytes: Int) -> String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .binary
        formatter.allowedUnits = [.useMB, .useGB]
        return formatter.string(fromByteCount: Int64(bytes))
    }

    private static func describe(seconds: TimeInterval) -> String {
        if seconds < 60 { return "\(Int(seconds))s" }
        if seconds < 3600 { return "\(Int(seconds / 60))min" }
        return "\(Int(seconds / 3600))h"
    }

    private static func describeAge(_ observedAt: Date, now: Date) -> String {
        let age = now.timeIntervalSince(observedAt)
        if age < 0 { return "timestamped in the future" }
        return "\(describe(seconds: age)) old"
    }

    /// Android `PowerManager.THERMAL_STATUS_*` names.
    static func describeThermal(_ status: Int) -> String {
        switch status {
        case 0: return "NONE (0)"
        case 1: return "LIGHT (1)"
        case 2: return "MODERATE (2)"
        case 3: return "SEVERE (3)"
        case 4: return "CRITICAL (4)"
        case 5: return "EMERGENCY (5)"
        case 6: return "SHUTDOWN (6)"
        default: return "status \(status)"
        }
    }
}
