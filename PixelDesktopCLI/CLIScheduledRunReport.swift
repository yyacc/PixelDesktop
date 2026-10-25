//
//  CLIScheduledRunReport.swift
//  PixelDesktopCLI
//
//  Phase 3.4 (C4) — the published result of one scheduled attempt.
//
//  WHAT IT IS
//  A presentation of `ScheduledRunReport`: the same values, renamed to the envelope's snake_case
//  convention. It computes nothing — `exit_status` is read from the report, not re-derived.
//
//  WHY THE OUTCOME IS NOT A `PixelDesktopError`
//  A scheduled run that fails did not raise a transport or inference error; it reached a decision
//  the scheduler owns (`succeeded` / `refused` / `failed` / `skipped`). Publishing that decision
//  under `error.type` would invent a `PixelDesktopError` case the run never raised, so the outcome
//  stays its own vocabulary and `error` stays empty for this command.
//

import Foundation

// Compiled into both the `pixel-desktop` tool and the test bundle, from one file.
#if canImport(PixelDesktop) && !PIXELDESKTOP_CLI_TOOL
@testable import PixelDesktop
#endif

struct CLIScheduledRunReport: Codable, Equatable {
    let jobID: UUID
    let jobName: String
    /// The stored action's stable token, e.g. `telemetrySample`.
    let action: String
    /// `succeeded` / `refused` / `failed` / `skipped` / `deferred`.
    let outcome: String
    /// A short, payload-free account of what happened or why nothing did.
    let detail: String
    let startedAt: Date
    let durationSeconds: Double
    /// How many cadence ticks were missed and coalesced into this one attempt.
    let skippedTicks: Int
    /// The audit record for this attempt, when one was written.
    let auditID: UUID?
    /// 0 for a completed or not-due attempt; 1 for a refusal or failure.
    let exitStatus: Int

    enum CodingKeys: String, CodingKey {
        case jobID = "job_id"
        case jobName = "job_name"
        case action
        case outcome
        case detail
        case startedAt = "started_at"
        case durationSeconds = "duration_seconds"
        case skippedTicks = "skipped_ticks"
        case auditID = "audit_id"
        case exitStatus = "exit_status"
    }

    init(_ report: ScheduledRunReport) {
        self.jobID = report.jobID
        self.jobName = report.jobName
        self.action = report.action.rawValue
        self.outcome = report.outcome.rawValue
        self.detail = report.detail
        self.startedAt = report.startedAt
        self.durationSeconds = report.duration
        self.skippedTicks = report.skippedTicks
        self.auditID = report.auditID
        self.exitStatus = Int(report.exitStatus)
    }

    /// A completed or skipped attempt is a success for the process; a refusal or failure is not.
    var isSuccess: Bool { exitStatus == 0 }
}
