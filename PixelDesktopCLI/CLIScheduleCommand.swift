//
//  CLIScheduleCommand.swift
//  PixelDesktopCLI
//
//  Phase 3.4 (C4) — `pixel-desktop schedule run <job-id>`.
//
//  WHAT IT IS
//  The one command through which launchd makes a scheduled attempt. It is invoked with a job id it
//  did not choose, after launchd decided the time had come. It does not decide cadence, does not
//  retry, and does not reschedule: `ScheduledJobRunner` owns the order of operations, and this file
//  only composes the live stack the runner runs against.
//
//  WHY A MISSING DEVICE IS NOT AN ERROR HERE
//  `CLIDeviceSelection` throws when no device is attached, which is right for `observe` and `run`.
//  For a scheduled job it is not: the attempt still has to be recorded, so the runner is given a
//  `nil` serial and produces a `.failed` report with an audit record. A launchd job that exits
//  before writing anything is indistinguishable from one that never fired, which is the failure
//  mode C4-7 exists to prevent.
//
//  WHAT IT IS NOT
//  Not a scheduler, not a retry policy, not a place a caller can introduce a new action. The job —
//  including its action and cadence — comes from the store the app owns, by id.
//

import Foundation

// Compiled into both the `pixel-desktop` tool and the test bundle, from one file.
#if canImport(PixelDesktop) && !PIXELDESKTOP_CLI_TOOL
@testable import PixelDesktop
#endif

enum CLIScheduleCommand {

    /// One attempt at one stored job.
    ///
    /// - Returns: the published report. A refusal or failure is a *result*, not a thrown error:
    ///   the run happened and reported what happened, and the exit status rides on the report.
    /// - Throws: only when no attempt can begin — an unreadable store, or a job id the store does
    ///   not hold.
    static func run(
        jobID: UUID,
        transport: TransportProtocol,
        clock: Clock = SystemClock()
    ) async throws -> CLIScheduledRunReport {
        let store = ScheduledJobStore(fileURL: try ScheduledJobStore.applicationDefaultURL())
        let auditLog = DeviceAuditLog(fileURL: try DeviceAuditLog.applicationDefaultURL())
        let consent = ConsentRegistry(fileURL: try ConsentRegistry.applicationDefaultURL())

        // A corrupt store is reported, never repaired and never treated as empty: repairing it would
        // destroy the evidence, and an empty store would silently disable every job on the machine.
        if let corruption = store.corruption {
            throw PixelDesktopError.invalidInput(
                "the schedule store could not be read (\(corruption)); it was left on disk unchanged"
            )
        }

        guard store.job(id: jobID) != nil else {
            throw PixelDesktopError.invalidInput(
                "no job with id \(jobID.uuidString); it may have been removed since this agent was "
                    + "installed"
            )
        }

        // Resolved once, before the gates, so the runner sees the same device on every check.
        let serial = try? await CLIDeviceSelection.connectedSerial(transport: transport)

        let runner = ScheduledJobRunner(
            store: store,
            consent: consent,
            auditLog: auditLog,
            clock: clock,
            deviceSerial: { serial },
            executor: DeviceScheduledActionExecutor(
                transport: transport,
                consentGate: ConsentGate(registry: consent, auditLog: auditLog)
            ),
            eligibility: DeviceExecutionEligibility(
                transport: transport,
                contractModelRequired: true
            )
        )

        guard let report = await runner.run(jobID: jobID) else {
            throw PixelDesktopError.invalidInput(
                "no job with id \(jobID.uuidString); it was removed while the run was starting"
            )
        }

        return CLIScheduledRunReport(report)
    }
}
