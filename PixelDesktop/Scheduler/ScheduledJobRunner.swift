//
//  ScheduledJobRunner.swift
//  PixelDesktop
//
//  Phase 3.4 (C4) — one tick, executed.
//
//  WHAT IT IS
//  The order of operations for a single scheduled run, and nothing else:
//
//    1. load the job            (unknown / disabled -> skip, zero device work)
//    2. is it due?              (an early or duplicate tick -> skip, zero device work)
//    3. consent                 (no active grant -> refused, zero device work)
//    4. audit begin             (.pending, written *before* the command)
//    5. execute once, bounded   (no retries: a headless retry is how a blip becomes a traffic problem)
//    6. audit resolve + record  (outcome and a short detail, never payloads)
//
//  The executor is injected, so the ordering above is testable against a mock that counts device
//  calls instead of a phone.
//
//  WHAT IT IS NOT
//  Not a scheduler — it does not know when to run. Not a retry policy. Not a place where a
//  destructive action can appear, because `ScheduledAction` does not carry one.
//

import Foundation

struct ScheduledRunReport: Equatable, Sendable {
    let jobID: UUID
    let jobName: String
    let action: ScheduledAction
    let outcome: ScheduledRunOutcome
    let detail: String
    let startedAt: Date
    let duration: TimeInterval
    let skippedTicks: Int
    let auditID: UUID?

    /// The CLI's exit status for this report: a refusal and a failure are failures; a skip is not.
    var exitStatus: Int32 {
        switch outcome {
        case .succeeded, .skipped: return 0
        case .refused, .failed, .deferred: return 1
        }
    }
}

protocol ScheduledActionExecuting: Sendable {
    /// Performs one action and returns a short, payload-free summary for the audit trail.
    func perform(
        action: ScheduledAction,
        deviceSerial: String,
        deadline: Date
    ) async throws -> String
}

final class ScheduledJobRunner: Sendable {
    private let store: ScheduledJobStore
    private let consent: ConsentRegistry
    private let auditLog: DeviceAuditLog
    private let clock: Clock
    private let deviceSerial: @Sendable () -> String?
    private let executor: ScheduledActionExecuting
    private let eligibility: any ExecutionEligibilityEvaluating
    private let timeout: TimeInterval

    init(
        store: ScheduledJobStore,
        consent: ConsentRegistry,
        auditLog: DeviceAuditLog,
        clock: Clock = SystemClock(),
        deviceSerial: @escaping @Sendable () -> String?,
        executor: ScheduledActionExecuting,
        eligibility: any ExecutionEligibilityEvaluating,
        timeout: TimeInterval = 60
    ) {
        self.store = store
        self.consent = consent
        self.auditLog = auditLog
        self.clock = clock
        self.deviceSerial = deviceSerial
        self.executor = executor
        self.eligibility = eligibility
        self.timeout = timeout
    }

    /// Runs one job. Never throws: every failure is a report, because a launchd job that dies
    /// silently is indistinguishable from one that never fired. Returns `nil` only when the store
    /// holds no job with this id — the one case a caller must render as a usage error, not a run.
    func run(jobID: UUID) async -> ScheduledRunReport? {
        let startedAt = clock.now()

        guard let job = store.job(id: jobID) else { return nil }

        guard job.enabled else {
            let reason = job.disabledReason.map { "Job is disabled: \($0)." } ?? "Job is disabled."
            return report(
                job: job,
                outcome: .skipped,
                detail: reason,
                at: startedAt,
                skipped: 0
            )
        }

        let skipped = CadenceResolver.missedTicks(
            lastRun: job.lastRunAt,
            now: startedAt,
            cadence: job.cadence
        )

        guard CadenceResolver.isDue(lastRun: job.lastRunAt, now: startedAt, cadence: job.cadence) else {
            return report(
                job: job,
                outcome: .skipped,
                detail: "Not due yet; the previous run already satisfied this interval.",
                at: startedAt,
                skipped: skipped
            )
        }

        // Consent is re-checked every run, never remembered in the job record.
        if let dataClass = job.action.requiredConsent {
            do {
                _ = try consent.permit(for: dataClass)
            } catch {
                let detail = ScheduledJobError.consentDenied(dataClass).description
                let auditID = auditLog.append(
                    operation: .scheduledTaskRun,
                    target: job.name,
                    outcome: .refused,
                    detail: detail,
                    at: startedAt
                )
                return report(
                    job: job,
                    outcome: .refused,
                    detail: detail,
                    at: startedAt,
                    skipped: skipped,
                    auditID: auditID
                )
            }
        }

        guard let serial = deviceSerial(), !serial.isEmpty else {
            let detail = ScheduledJobError.noDevice.description
            let auditID = auditLog.append(
                operation: .scheduledTaskRun,
                target: job.name,
                outcome: .failed,
                detail: detail,
                at: startedAt
            )
            try? store.recordRun(id: job.id, at: startedAt, outcome: .failed)
            return report(
                job: job,
                outcome: .failed,
                detail: detail,
                at: startedAt,
                skipped: skipped,
                auditID: auditID
            )
        }

        // The routing gate: before any device execution and before the audit record is resolved as
        // executed. Unattended, so an ineligible verdict always blocks — there is nobody to accept
        // an override, and a transient condition cannot be waved through.
        let decision = await eligibility.decide(
            deviceSerial: serial,
            requirement: .deviceRead,
            context: .unattended
        )

        guard decision.isPermitted else {
            let detail = Self.routingDetail(decision)
            if decision.outcome == .deferred {
                // Deferral: do not touch the device, record the outcome, but do not advance
                // `lastRunAt` — the job stays due and retries on the next tick.
                let auditID = auditLog.append(
                    operation: .scheduledTaskRun,
                    target: job.name,
                    outcome: .deferred,
                    detail: detail,
                    at: startedAt
                )
                try? store.recordDeferral(id: job.id, at: startedAt, outcome: .deferred)
                return report(
                    job: job,
                    outcome: .deferred,
                    detail: detail,
                    at: startedAt,
                    skipped: skipped,
                    auditID: auditID
                )
            }

            // `.rejected` (and a `.requiresOverride`/`.overridden` the evaluator cannot produce for
            // an unattended caller) is a refusal: recorded as a run, and never as a success.
            let auditID = auditLog.append(
                operation: .scheduledTaskRun,
                target: job.name,
                outcome: .refused,
                detail: detail,
                at: startedAt
            )
            try? store.recordRun(id: job.id, at: startedAt, outcome: .refused)
            return report(
                job: job,
                outcome: .refused,
                detail: detail,
                at: startedAt,
                skipped: skipped,
                auditID: auditID
            )
        }

        // Append before execute: a crash mid-command leaves a `.pending` record, which is proof the
        // attempt happened. An append-after-success log cannot provide that.
        let auditID = auditLog.begin(
            operation: .scheduledTaskRun,
            target: job.name,
            detail: "\(job.action.rawValue) · \(job.cadence.displayName)",
            at: startedAt
        )

        let deadline = startedAt.addingTimeInterval(timeout)
        var outcome: ScheduledRunOutcome = .failed
        var detail = ""

        do {
            let summary = try await bounded(
                action: job.action,
                serial: serial,
                deadline: deadline,
                startedAt: startedAt
            )
            outcome = .succeeded
            detail = summary
        } catch let error as ScheduledJobError {
            outcome = .failed
            detail = error.description
        } catch {
            outcome = .failed
            detail = String(describing: error)
        }

        let finishedAt = clock.now()
        auditLog.resolve(
            auditID,
            outcome: outcome == .succeeded ? .executed : .failed,
            detail: detail
        )
        try? store.recordRun(id: job.id, at: startedAt, outcome: outcome)

        return report(
            job: job,
            outcome: outcome,
            detail: detail,
            at: startedAt,
            skipped: skipped,
            auditID: auditID,
            duration: finishedAt.timeIntervalSince(startedAt)
        )
    }

    // MARK: Bounded execution

    /// Races the action against the deadline. The loser is cancelled, so a hung device call cannot
    /// turn into a hang: the run reports `.deadlineExceeded` instead.
    private func bounded(
        action: ScheduledAction,
        serial: String,
        deadline: Date,
        startedAt: Date
    ) async throws -> String {
        let executor = self.executor
        let clock = self.clock

        return try await withThrowingTaskGroup(of: String.self) { group in
            group.addTask {
                try await executor.perform(action: action, deviceSerial: serial, deadline: deadline)
            }
            group.addTask {
                try await clock.sleep(until: deadline)
                throw ScheduledJobError.deadlineExceeded(
                    seconds: Int(deadline.timeIntervalSince(startedAt))
                )
            }
            defer { group.cancelAll() }
            guard let first = try await group.next() else {
                throw ScheduledJobError.deadlineExceeded(
                    seconds: Int(deadline.timeIntervalSince(startedAt))
                )
            }
            return first
        }
    }

    // MARK: Reporting

    /// Renders a routing verdict for the report and audit detail: the summary plus one reason line
    /// per blocking condition, each carrying its measurement.
    private static func routingDetail(_ decision: RoutingDecision) -> String {
        ([decision.summary] + decision.reasonLines).joined(separator: " ")
    }

    private func report(
        job: ScheduledJob,
        outcome: ScheduledRunOutcome,
        detail: String,
        at date: Date,
        skipped: Int,
        auditID: UUID? = nil,
        duration: TimeInterval = 0
    ) -> ScheduledRunReport {
        ScheduledRunReport(
            jobID: job.id,
            jobName: job.name,
            action: job.action,
            outcome: outcome,
            detail: detail,
            startedAt: date,
            duration: duration,
            skippedTicks: skipped,
            auditID: auditID
        )
    }
}
