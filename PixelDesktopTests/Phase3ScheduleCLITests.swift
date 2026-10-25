//
//  Phase3ScheduleCLITests.swift
//  PixelDesktopTests
//
//  Phase 3.4 (C4) — the published side of a scheduled attempt.
//
//  WHAT THESE ASSERT
//  Three properties, each of which has a way of silently breaking:
//
//  1. The parser accepts exactly one shape — `schedule run <uuid> --json` — and refuses everything
//     that would let a caller name a cadence, an action, or a second command.
//  2. The generated launch agent and the parser agree. The plist's `ProgramArguments` is handed
//     straight through `CLIInvocation.parse` here: an argument added to one side and not the other
//     makes every scheduled tick a usage error, and launchd would report that as a job that ran and
//     printed nothing useful. That failure is invisible in a unit test of either side alone.
//  3. The envelope carries `scheduled_run` with its snake_case keys, and does not invent an `error`
//     for a decision the scheduler made rather than an exception the run raised.
//

import XCTest
@testable import PixelDesktop

final class Phase3ScheduleCLITests: XCTestCase {

    // MARK: - Parser

    func testParseAcceptsScheduleRunWithAJobID() throws {
        let jobID = UUID(uuidString: "11111111-2222-3333-4444-555555555555")!

        let invocation = try CLIInvocation.parse(
            ["schedule", "run", jobID.uuidString, "--json"]
        ).get()

        XCTAssertEqual(invocation.command, .schedule)
        XCTAssertEqual(invocation.jobID, jobID)
        XCTAssertTrue(invocation.json)
        // The job is named, never described: a scheduled attempt carries no workload or input.
        XCTAssertNil(invocation.workload)
        XCTAssertNil(invocation.inputFile)
    }

    func testParseAcceptsALowercaseJobID() throws {
        let invocation = try CLIInvocation.parse(
            ["schedule", "run", "11111111-2222-3333-4444-555555555555", "--json"]
        ).get()

        XCTAssertEqual(
            invocation.jobID,
            UUID(uuidString: "11111111-2222-3333-4444-555555555555")
        )
    }

    func testParseRejectsScheduleWithoutTheRunVerb() {
        // Without `run` there is no stored attempt to make. Treating `schedule` as a command on its
        // own would mean the CLI deciding what to do, which is the boundary C4 exists to hold.
        for arguments in [
            ["schedule", "--json"],
            ["schedule", "execute", "11111111-2222-3333-4444-555555555555", "--json"],
        ] {
            let result = CLIInvocation.parse(arguments)
            guard case .failure = result else {
                return XCTFail("expected a usage error for \(arguments)")
            }
        }
    }

    func testParseRejectsANonUUIDJobID() {
        // A job is looked up by id. A name would be a description of work, and a description is
        // how a caller reintroduces the action the store is meant to own.
        let result = CLIInvocation.parse(["schedule", "run", "nightly-telemetry", "--json"])
        guard case .failure(let error) = result else {
            return XCTFail("expected a usage error for a non-UUID job id")
        }
        XCTAssertTrue(error.message.contains("not a job id"), error.message)
    }

    func testParseRejectsWorkloadOnAScheduledRun() {
        let result = CLIInvocation.parse([
            "schedule", "run", "11111111-2222-3333-4444-555555555555",
            "--workload", "DTCA-1", "--json",
        ])
        guard case .failure(let error) = result else {
            return XCTFail("expected a usage error for --workload on schedule")
        }
        XCTAssertTrue(error.message.contains("apply only to 'run'"), error.message)
    }

    func testParseRequiresJSONForAScheduledRun() {
        // launchd redirects stdout into the job's log. A human-formatted line there is a log no
        // consumer can parse, so the flag is required here exactly as it is for every command.
        let result = CLIInvocation.parse([
            "schedule", "run", "11111111-2222-3333-4444-555555555555",
        ])
        guard case .failure = result else {
            return XCTFail("expected a usage error without --json")
        }
    }

    func testSchedulerFlagStaysForbidden() {
        // The CLI makes an attempt; it does not become the clock. `--scheduler` is the flag that
        // would turn this process into one, so it is still rejected by name.
        let result = CLIInvocation.parse([
            "schedule", "run", "11111111-2222-3333-4444-555555555555", "--json", "--scheduler",
        ])
        guard case .failure(let error) = result else {
            return XCTFail("expected a usage error for --scheduler")
        }
        XCTAssertTrue(error.message.contains("not part of this interface"), error.message)
    }

    // MARK: - Plist ↔ parser agreement

    func testLaunchAgentArgumentsAreAcceptedByTheParser() throws {
        let jobID = UUID(uuidString: "11111111-2222-3333-4444-555555555555")!
        let job = ScheduledJob(
            id: jobID,
            name: "Nightly telemetry",
            cadence: .interval(seconds: 900),
            action: .telemetrySample,
            createdAt: Date(timeIntervalSince1970: 1_700_000_000)
        )

        let plist = LaunchAgent.plist(for: LaunchAgent.descriptor(
            for: job,
            cliPath: "/opt/pixel-desktop",
            logDirectory: "/tmp/pixeldesktop-test"
        ))

        let data = try XCTUnwrap(plist.data(using: .utf8))
        let root = try XCTUnwrap(
            PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
        )
        let arguments = try XCTUnwrap(root["ProgramArguments"] as? [String])

        // argv[0] is the executable; the CLI parses what follows it.
        let invocation = try CLIInvocation.parse(Array(arguments.dropFirst())).get()

        XCTAssertEqual(invocation.command, .schedule)
        XCTAssertEqual(invocation.jobID, jobID, "the plist must name the job it was made for")
        XCTAssertTrue(
            invocation.json,
            "launchd logs this process's stdout; without --json the log is not machine-readable"
        )
    }

    // MARK: - Envelope

    func testEnvelopePublishesTheScheduledRunUnderItsOwnKey() throws {
        let report = ScheduledRunReport(
            jobID: UUID(),
            jobName: "Nightly telemetry",
            action: .telemetrySample,
            outcome: .failed,
            detail: "no device serial is available",
            startedAt: Date(timeIntervalSince1970: 1_700_000_000),
            duration: 0.02,
            skippedTicks: 2,
            auditID: UUID()
        )

        let published = CLIScheduledRunReport(report)
        let envelope = CLIEnvelope(
            command: CLICommand.schedule.rawValue,
            ok: published.isSuccess,
            scheduledRun: published
        )

        let json = try CLIEnvelopeRenderer.render(envelope)
        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any]
        )

        // A failure is a result, not an exception: the report carries the reason, and `error`
        // stays empty rather than naming a PixelDesktopError the run never raised.
        XCTAssertEqual(object["ok"] as? Bool, false)
        XCTAssertTrue(object.keys.contains("error"))
        XCTAssertTrue(object["error"] is NSNull)

        let scheduled = try XCTUnwrap(object["scheduled_run"] as? [String: Any])
        XCTAssertEqual(scheduled["job_name"] as? String, "Nightly telemetry")
        XCTAssertEqual(scheduled["outcome"] as? String, "failed")
        XCTAssertEqual(scheduled["skipped_ticks"] as? Int, 2)
        XCTAssertEqual(scheduled["exit_status"] as? Int, 1)
        XCTAssertNotNil(scheduled["audit_id"])
        XCTAssertNotNil(scheduled["duration_seconds"])
        XCTAssertNotNil(scheduled["started_at"])
    }

    func testASkippedAttemptExitsSuccessfully() {
        let report = ScheduledRunReport(
            jobID: UUID(),
            jobName: "Nightly telemetry",
            action: .telemetrySample,
            outcome: .skipped,
            detail: "not due until later",
            startedAt: Date(),
            duration: 0.001,
            skippedTicks: 0,
            auditID: nil
        )

        let published = CLIScheduledRunReport(report)

        // Not-due is not an error: launchd fires on its own clock and the job decides whether the
        // tick applies. Exiting non-zero here would fill the log with failures for a healthy job.
        XCTAssertTrue(published.isSuccess)
        XCTAssertEqual(published.exitStatus, 0)
        XCTAssertNil(published.auditID, "nothing happened, so there is nothing to audit")
    }
}
