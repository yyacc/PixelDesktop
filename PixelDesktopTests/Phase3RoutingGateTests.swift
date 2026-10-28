//
//  Phase3RoutingGateTests.swift
//  PixelDesktopTests
//
//  Phase 3 (P3) — the routing gate, wired into both real execution boundaries.
//
//  ## What these tests prove
//
//  The gate was already written (`ExecutionRoutingGate.swift`, `ExecutionEligibility.swift`) but
//  nothing called it. These tests drive the *real* command and runner paths — `CLIRunCommand.run`
//  and `ScheduledJobRunner` — against a scripted eligibility fake and a scripted transport, so the
//  proof is about the boundary, not about a re-statement of the policy:
//
//   1. an eligible interactive run reaches `WorkerStreamRunner` (the worker is asked)
//   2. a hard-ineligible run is refused before the worker, as `.routingBlocked`
//   3. an unattended soft-ineligible attempt is blocked and never executed
//   4. a `.requiresOverride` verdict proceeds only when an interactive caller requested it
//   5. a `.rejected` verdict stays blocked even when an override was requested
//   6. an unestablished observation fails closed for unattended work
//   7. a backend-health failure prevents submission
//   8. a deferred scheduled attempt is never a success, does not advance `lastRunAt`, and stays due
//   9. routing decisions survive Codable and appear in the CLI payload/result
//  10. the stored-job wire format and the un-blocked run result shape are unchanged, additive only
//

import XCTest
@testable import PixelDesktop

// MARK: - The explicit test-only stub

/// Permits everything. For tests and for call sites that have already made the same decision.
///
/// Deliberately not the default anywhere in production code: both real boundaries require an
/// evaluator to be passed in, so an un-gated execution path cannot be created by omitting an
/// argument. It lives in the test target for exactly that reason — a grep for it in `PixelDesktop/`
/// or `PixelDesktopCLI/` must return nothing.
struct AlwaysEligibleEligibility: ExecutionEligibilityEvaluating {

    init() {}

    func decide(
        deviceSerial: String,
        requirement: ExecutionRequirement,
        context: ExecutionContext
    ) async -> RoutingDecision {
        // No fabricated measurements: the stub states that nothing was evaluated.
        RoutingDecision(
            outcome: .eligible,
            requirement: requirement,
            context: context,
            checks: [],
            notEvaluated: ["all: AlwaysEligibleEligibility makes no measurements"],
            deviceSerial: deviceSerial,
            evaluatedAt: Date()
        )
    }
}

// MARK: - A scripted eligibility source

/// Returns a decision per requirement, and records what was asked so a test can assert the boundary
/// asked the right question. Fails closed by default: a missing script is a block, never a pass.
actor ScriptedEligibility: ExecutionEligibilityEvaluating {

    struct Ask: Equatable {
        let deviceSerial: String
        let requirement: ExecutionRequirement
        let context: ExecutionContext
    }

    private var decisions: [String: RoutingDecision] = [:]
    private var recorded: [Ask] = []

    func set(_ decision: RoutingDecision, for requirement: ExecutionRequirement) {
        decisions[requirement.rawValue] = decision
    }

    func asks() -> [Ask] { recorded }

    func decide(
        deviceSerial: String,
        requirement: ExecutionRequirement,
        context: ExecutionContext
    ) async -> RoutingDecision {
        recorded.append(Ask(deviceSerial: deviceSerial, requirement: requirement, context: context))
        return decisions[requirement.rawValue] ?? RoutingDecision(
            outcome: .rejected,
            requirement: requirement,
            context: context,
            checks: [],
            notEvaluated: ["test: no decision scripted for \(requirement.rawValue)"],
            deviceSerial: deviceSerial,
            evaluatedAt: Date(timeIntervalSince1970: 1_700_000_000)
        )
    }
}

// MARK: - A slow reader that stamps its observation at its own start

/// Reproduces `PixelEvidenceReader`'s timing: it stamps `observedAt` at the *start* of the read,
/// then waits, so the timestamp precedes the read's completion by the read duration. This is what
/// made every real observation look "timestamped in the future" when the decision clock was
/// sampled before the read.
struct SlowStampingReader: PixelStateObserving {

    let sleepNanoseconds: UInt64

    func observeState(
        deviceSerial: String,
        timeout: TimeInterval
    ) async throws -> PixelStateObservation {
        let start = Date()
        try await Task.sleep(nanoseconds: sleepNanoseconds)
        return PixelStateObservation(
            observedAt: start,
            deviceSerial: deviceSerial,
            availableMemoryBytes: .deviceReported(0, at: start, limitation: "test stub"),
            freeStorageBytes: .deviceReported(8 * 1024 * 1024 * 1024, at: start, limitation: "test stub"),
            workerInstalled: .deviceReported(.installed(versionCode: 7), at: start, limitation: "test stub"),
            workerRunning: .deviceReported(false, at: start, limitation: "test stub"),
            modelPresent: .deviceReported(.absent, at: start, limitation: "test stub"),
            thermalStatus: .deviceReported(0, at: start, limitation: "test stub"),
            deviceReachable: .deviceReported(true, at: start, limitation: "test stub")
        )
    }
}

/// A fixed, healthy inference observation: every dynamic precondition is met, with only the
/// model presence varying. The model is reported absent so the routing-gate tests exercise the
/// model-presence decision without a real device.
struct HealthyInferenceReader: PixelStateObserving {

    func observeState(
        deviceSerial: String,
        timeout: TimeInterval
    ) async throws -> PixelStateObservation {
        let now = Date()
        return PixelStateObservation(
            observedAt: now,
            deviceSerial: deviceSerial,
            availableMemoryBytes: .deviceReported(8 * 1024 * 1024 * 1024, at: now, limitation: "test stub"),
            freeStorageBytes: .deviceReported(8 * 1024 * 1024 * 1024, at: now, limitation: "test stub"),
            workerInstalled: .deviceReported(.installed(versionCode: 7), at: now, limitation: "test stub"),
            workerRunning: .deviceReported(false, at: now, limitation: "test stub"),
            modelPresent: .deviceReported(.absent, at: now, limitation: "test stub"),
            thermalStatus: .deviceReported(0, at: now, limitation: "test stub"),
            deviceReachable: .deviceReported(true, at: now, limitation: "test stub")
        )
    }
}

// MARK: - Small fakes shared by the scheduled-path tests

final class ScriptedExecutor: ScheduledActionExecuting, @unchecked Sendable {
    private(set) var calls: [(action: ScheduledAction, serial: String)] = []
    var summary = "ok"

    func perform(action: ScheduledAction, deviceSerial: String, deadline: Date) async throws -> String {
        calls.append((action, deviceSerial))
        return summary
    }
}

final class FixedClock: Clock, @unchecked Sendable {
    var current: Date
    init(_ date: Date) { self.current = date }

    func now() -> Date { current }

    func sleep(until date: Date) async throws {
        // Only used by the bounded-execution race, which the scripted executor always wins.
        try await Task.sleep(nanoseconds: 10_000_000)
    }
}

// MARK: - Decision builders

private func routingDecision(
    _ outcome: RoutingOutcome,
    requirement: ExecutionRequirement = .deviceRead,
    context: ExecutionContext = .unattended,
    deviceSerial: String = "TEST-SERIAL",
    checks: [RoutingCheck] = []
) -> RoutingDecision {
    RoutingDecision(
        outcome: outcome,
        requirement: requirement,
        context: context,
        checks: checks,
        notEvaluated: [],
        deviceSerial: deviceSerial,
        evaluatedAt: Date(timeIntervalSince1970: 1_700_000_000)
    )
}

private func backendHealthFailureCheck() -> RoutingCheck {
    RoutingCheck(
        id: "backend-health",
        title: "Backend health",
        severity: .hard,
        verdict: .failed,
        measured: "health probe failed",
        threshold: "healthy",
        explanation: "Submitting tokens to a backend that is not answering is a guaranteed failure with a long timeout.",
        isTransient: true
    )
}

// MARK: - The suite

final class Phase3RoutingGateTests: XCTestCase {

    // MARK: Fixtures

    private static let dtca1ResultJSON = """
    {"status":"COMPLETED","job_id":"__JOB__","input_characters":11,"total_words":2,
     "unique_words":2,"top_words":[{"word":"hello","count":1},{"word":"world","count":1}],
     "classification":"GENERAL","confidence":0.5,"execution_timestamp_ms":1,
     "execution_duration_ms":2}
    """

    private static let dtca1StreamingLines: [String] = [
        "PDE1 START job_id=__JOB__",
        "PDE1 LAUNCHED",
        "PDE1 HEARTBEAT n=1 pid=1234",
        "PDE1 RESULT_BEGIN",
        dtca1ResultJSON,
        "PDE1 RESULT_END bytes=__BYTES__",
    ]

    private func temporaryInput(_ contents: String = "hello world") throws -> String {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("p3gate-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("input.txt")
        try contents.write(to: url, atomically: true, encoding: .utf8)
        return url.path
    }

    /// A transport that passes preflight and streams a completed DTCA-1 result.
    private func configuredDTCA1Transport(serial: String = "S") async -> RunTransport {
        let transport = RunTransport()
        await transport.setDevices([RunTransport.device(serial: serial, state: .device)])
        await transport.setShellPrefix(
            "dumpsys package", TransportResult(exitCode: 0, stdout: "versionCode=7", stderr: ""))
        await transport.setShellPrefix(
            "test -d", TransportResult(exitCode: 0, stdout: "EXISTS", stderr: ""))
        await transport.setStreamingLines(Self.dtca1StreamingLines)
        return transport
    }

    private func makeRunner(
        store: ScheduledJobStore,
        clock: Clock,
        executor: ScriptedExecutor,
        eligibility: ScriptedEligibility,
        auditLog: DeviceAuditLog = DeviceAuditLog(),
        serial: String? = "TEST-SERIAL"
    ) -> ScheduledJobRunner {
        ScheduledJobRunner(
            store: store,
            consent: ConsentRegistry(),
            auditLog: auditLog,
            clock: clock,
            deviceSerial: { serial },
            executor: executor,
            eligibility: eligibility
        )
    }

    private func makeStore(now: Date = Date(timeIntervalSince1970: 1_000_000)) -> ScheduledJobStore {
        ScheduledJobStore(fileURL: nil, now: { now })
    }

    // MARK: 1. Eligible interactive run reaches WorkerStreamRunner

    func testEligibleInteractiveRunReachesWorkerStreamRunner() async throws {
        let transport = await configuredDTCA1Transport()
        let eligibility = ScriptedEligibility()
        await eligibility.set(
            routingDecision(.eligible, requirement: .deviceRead, context: .interactive),
            for: .deviceRead
        )

        let path = try temporaryInput("hello world")
        let (result, error) = try await CLIRunCommand.run(
            workload: "DTCA-1", inputPath: path, transport: transport, eligibility: eligibility)

        XCTAssertNil(error, "an eligible run carries no error")
        XCTAssertEqual(result.outcome, "completed")
        XCTAssertEqual(result.routing?.outcome, .eligible, "the decision rides on the result")
        let sessions = await transport.streamingSessionCount
        XCTAssertEqual(sessions, 1, "the worker was asked")

        let asks = await eligibility.asks()
        XCTAssertEqual(asks.first?.requirement, .deviceRead)
        XCTAssertEqual(asks.first?.context, .interactive)
    }

    // MARK: 2. Hard-ineligible run never reaches the worker

    func testRejectedRunNeverReachesTheWorker() async throws {
        let transport = await configuredDTCA1Transport()
        let eligibility = ScriptedEligibility()
        let rejected = routingDecision(.rejected, requirement: .deviceRead, context: .interactive)
        await eligibility.set(rejected, for: .deviceRead)

        let path = try temporaryInput("hello")
        do {
            _ = try await CLIRunCommand.run(
                workload: "DTCA-1", inputPath: path, transport: transport, eligibility: eligibility)
            XCTFail("expected a routingBlocked refusal")
        } catch {
            guard case PixelDesktopError.routingBlocked(let decision) = error else {
                return XCTFail("expected routingBlocked, got \(error)")
            }
            XCTAssertEqual(decision.outcome, .rejected)
        }
        let sessions = await transport.streamingSessionCount
        XCTAssertEqual(sessions, 0, "nothing may reach the worker")
    }

    // MARK: 3. Soft-ineligible unattended execution is blocked, never executed

    func testUnattendedSoftIneligibleAttemptIsDeferredAndNeverExecuted() async throws {
        let now = Date(timeIntervalSince1970: 1_000_000)
        let store = makeStore(now: now)
        let job = try store.add(name: "Telemetry", cadence: .interval(seconds: 900), action: .telemetrySample)

        let executor = ScriptedExecutor()
        let audit = DeviceAuditLog()
        let eligibility = ScriptedEligibility()
        await eligibility.set(
            routingDecision(.deferred, requirement: .deviceRead, context: .unattended),
            for: .deviceRead
        )

        let runner = makeRunner(
            store: store, clock: FixedClock(now), executor: executor,
            eligibility: eligibility, auditLog: audit)

        let runResult = await runner.run(jobID: job.id)
        let report = try XCTUnwrap(runResult)
        XCTAssertEqual(report.outcome, .deferred)
        XCTAssertEqual(report.exitStatus, 1, "a deferred attempt did not happen, so it is not success")
        XCTAssertTrue(executor.calls.isEmpty, "a deferred attempt must issue zero device calls")
        XCTAssertEqual(audit.records.last?.outcome, .deferred)
    }

    // MARK: 4. Interactive override of a `.requiresOverride` verdict

    func testRequiresOverrideProceedsOnlyWhenRequested() async throws {
        let requiresOverride = routingDecision(
            .requiresOverride, requirement: .deviceRead, context: .interactive)

        // Without an explicit request the run is blocked.
        do {
            let transport = await configuredDTCA1Transport()
            let eligibility = ScriptedEligibility()
            await eligibility.set(requiresOverride, for: .deviceRead)
            let path = try temporaryInput("hello")
            _ = try await CLIRunCommand.run(
                workload: "DTCA-1", inputPath: path, transport: transport, eligibility: eligibility)
            XCTFail("expected a routingBlocked refusal without an override request")
        } catch {
            guard case PixelDesktopError.routingBlocked(let decision) = error else {
                return XCTFail("expected routingBlocked, got \(error)")
            }
            XCTAssertEqual(decision.outcome, .requiresOverride)
        }

        // With the request, the run proceeds and the recorded decision is the overridden one.
        let transport = await configuredDTCA1Transport()
        let eligibility = ScriptedEligibility()
        await eligibility.set(requiresOverride, for: .deviceRead)
        let path = try temporaryInput("hello")
        let (result, error) = try await CLIRunCommand.run(
            workload: "DTCA-1", inputPath: path, transport: transport,
            eligibility: eligibility, overrideRequested: true)

        XCTAssertNil(error)
        XCTAssertEqual(result.outcome, "completed")
        XCTAssertEqual(result.routing?.outcome, .overridden,
                       "the recorded decision must be the overridden one, not the original")
        let sessions = await transport.streamingSessionCount
        XCTAssertEqual(sessions, 1)
    }

    // MARK: 5. `.rejected` stays blocked even when an override is requested

    func testRejectedStaysBlockedEvenWhenOverrideRequested() async throws {
        let transport = await configuredDTCA1Transport()
        let eligibility = ScriptedEligibility()
        await eligibility.set(
            routingDecision(.rejected, requirement: .deviceRead, context: .interactive),
            for: .deviceRead
        )

        let path = try temporaryInput("hello")
        do {
            _ = try await CLIRunCommand.run(
                workload: "DTCA-1", inputPath: path, transport: transport,
                eligibility: eligibility, overrideRequested: true)
            XCTFail("a hard failure must never be overridden")
        } catch {
            guard case PixelDesktopError.routingBlocked(let decision) = error else {
                return XCTFail("expected routingBlocked, got \(error)")
            }
            XCTAssertEqual(decision.outcome, .rejected)
        }
        let sessions = await transport.streamingSessionCount
        XCTAssertEqual(sessions, 0)
    }

    // MARK: 6. `.unknown` / stale observations fail closed (unattended blocks)

    func testUnknownObservationFailsClosedForUnattendedRun() async throws {
        let now = Date(timeIntervalSince1970: 1_000_000)
        let store = makeStore(now: now)
        let job = try store.add(name: "Telemetry", cadence: .interval(seconds: 900), action: .telemetrySample)

        // The real evaluator's fail-closed verdict for an unreadable device: a single hard,
        // unknown check that an unattended caller may not pass.
        let unobservable = ExecutionRoutingEvaluator.unobservable(
            reason: "adb: no devices attached",
            requirement: .deviceRead,
            context: .unattended,
            deviceSerial: "TEST-SERIAL",
            at: now
        )
        XCTAssertEqual(unobservable.outcome, .deferred)
        XCTAssertTrue(unobservable.blockingChecks.contains { $0.verdict == .unknown })

        let executor = ScriptedExecutor()
        let audit = DeviceAuditLog()
        let eligibility = ScriptedEligibility()
        await eligibility.set(unobservable, for: .deviceRead)

        let runner = makeRunner(
            store: store, clock: FixedClock(now), executor: executor,
            eligibility: eligibility, auditLog: audit)

        let runResult = await runner.run(jobID: job.id)
        let report = try XCTUnwrap(runResult)
        XCTAssertEqual(report.outcome, .deferred)
        XCTAssertTrue(executor.calls.isEmpty, "an unestablished observation must block an unattended run")
        XCTAssertEqual(audit.records.last?.outcome, .deferred)
    }

    // MARK: 7. Backend-health failure prevents submission

    func testBackendHealthFailurePreventsSubmission() async throws {
        let transport = await configuredDTCA1Transport()
        let eligibility = ScriptedEligibility()
        // A failed backend probe is hard and transient, so the policy answers `.deferred` — which,
        // like a hard failure, is never overridable.
        let decision = routingDecision(
            .deferred,
            requirement: .inference,
            context: .interactive,
            checks: [backendHealthFailureCheck()]
        )
        await eligibility.set(decision, for: .inference)

        let path = try temporaryInput("hello")
        do {
            _ = try await CLIRunCommand.run(
                workload: "LOCAL-LLM-1", inputPath: path, transport: transport,
                eligibility: eligibility, overrideRequested: true)
            XCTFail("an unhealthy backend must prevent submission")
        } catch {
            guard case PixelDesktopError.routingBlocked(let blocked) = error else {
                return XCTFail("expected routingBlocked, got \(error)")
            }
            XCTAssertEqual(blocked.outcome, .deferred)
            XCTAssertTrue(blocked.reasonLines.contains { $0.contains("Backend health") },
                          "the refusal must name the failed check")
        }
        let sessions = await transport.streamingSessionCount
        XCTAssertEqual(sessions, 0)

        let asks = await eligibility.asks()
        XCTAssertEqual(asks.first?.requirement, .inference,
                       "an inference workload must be gated as inference, not device read")
    }

    // MARK: 8. A deferred scheduled attempt is never success, stays due

    func testDeferredScheduledJobStaysDueAndIsNeverSucceeded() async throws {
        let now = Date(timeIntervalSince1970: 1_000_000)
        let store = makeStore(now: now)
        let job = try store.add(name: "Telemetry", cadence: .interval(seconds: 900), action: .telemetrySample)

        let executor = ScriptedExecutor()
        let audit = DeviceAuditLog()
        let eligibility = ScriptedEligibility()
        await eligibility.set(
            routingDecision(.deferred, requirement: .deviceRead, context: .unattended),
            for: .deviceRead
        )

        let runner = makeRunner(
            store: store, clock: FixedClock(now), executor: executor,
            eligibility: eligibility, auditLog: audit)

        let runResult = await runner.run(jobID: job.id)
        let report = try XCTUnwrap(runResult)
        XCTAssertEqual(report.outcome, .deferred)
        XCTAssertNotEqual(report.outcome, .succeeded, "a blocked attempt must never appear succeeded")
        XCTAssertNil(store.job(id: job.id)?.lastRunAt, "lastRunAt must not advance on deferral")
        XCTAssertEqual(store.job(id: job.id)?.lastOutcome, .deferred)
        XCTAssertTrue(
            CadenceResolver.isDue(lastRun: nil, now: now, cadence: .interval(seconds: 900)),
            "the job must stay due and retry on the next tick")
        XCTAssertTrue(executor.calls.isEmpty)
    }

    // MARK: 9. Decisions survive Codable and appear in the CLI payload

    func testRoutingDecisionSurvivesCodableRoundTrip() throws {
        let check = RoutingCheck(
            id: "thermal-status",
            title: "Thermal status",
            severity: .soft,
            verdict: .failed,
            measured: "SEVERE (3)",
            threshold: "at most MODERATE (2)",
            explanation: "the device is hot",
            isTransient: true
        )
        let original = RoutingDecision(
            outcome: .requiresOverride,
            requirement: .inference,
            context: .interactive,
            checks: [check],
            notEvaluated: ["recent-throughput: no measurement available"],
            deviceSerial: "S",
            evaluatedAt: Date(timeIntervalSince1970: 1_700_000_000)
        )

        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(RoutingDecision.self, from: data)
        XCTAssertEqual(decoded, original)
    }

    func testBlockedRunRendersRoutingBlockedWithoutAResultObject() throws {
        let decision = routingDecision(
            .rejected, requirement: .deviceRead, context: .interactive,
            checks: [backendHealthFailureCheck()]
        )
        let payload = CLIErrorPayload(.routingBlocked(decision))
        XCTAssertEqual(payload.type, "routing_blocked")
        XCTAssertEqual(payload.routing, decision)

        let envelope = CLIEnvelope(command: "run", ok: false, error: payload)
        let json = try CLIEnvelopeRenderer.render(envelope)
        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])

        XCTAssertEqual(object["ok"] as? Bool, false)
        let error = try XCTUnwrap(object["error"] as? [String: Any])
        XCTAssertEqual(error["type"] as? String, "routing_blocked")
        XCTAssertNotNil(error["routing"], "the decision travels whole in the payload")
        XCTAssertTrue(object["result"] is NSNull, "a blocked run must not emit a result object")
    }

    // MARK: 10. Backward compatibility

    func testStoredJobWireFormatIsUnchangedAndStillDecodes() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("pd-gate-legacy-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }

        let store = ScheduledJobStore(fileURL: url, now: { Date(timeIntervalSince1970: 1_000_000) })
        let added = try store.add(name: "Telemetry", cadence: .interval(seconds: 900), action: .telemetrySample)

        // A fresh job has no outcome/run keys: the additive `.deferred` case changes nothing here.
        let written = try String(contentsOf: url, encoding: .utf8)
        XCTAssertFalse(written.contains("lastOutcome"), "a fresh job must not carry a lastOutcome key")

        let reopened = ScheduledJobStore(fileURL: url)
        XCTAssertNil(reopened.corruption)
        XCTAssertEqual(reopened.job(id: added.id)?.name, "Telemetry")
        XCTAssertNil(reopened.job(id: added.id)?.lastOutcome)
        XCTAssertNil(reopened.job(id: added.id)?.lastRunAt)
    }

    func testDeferredOutcomePersistsThroughTheStore() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("pd-gate-deferred-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }

        let store = ScheduledJobStore(fileURL: url, now: { Date(timeIntervalSince1970: 1_000_000) })
        let job = try store.add(name: "Telemetry", cadence: .interval(seconds: 900), action: .telemetrySample)
        try store.recordDeferral(id: job.id, at: Date(timeIntervalSince1970: 1_000_100), outcome: .deferred)

        let reopened = ScheduledJobStore(fileURL: url)
        XCTAssertEqual(reopened.job(id: job.id)?.lastOutcome, .deferred)
        XCTAssertNil(reopened.job(id: job.id)?.lastRunAt, "deferral must not advance lastRunAt")
    }

    func testUnblockedRunKeepsItsJSONShapeApartFromAdditiveRouting() async throws {
        let transport = await configuredDTCA1Transport()
        let eligibility = ScriptedEligibility()
        await eligibility.set(
            routingDecision(.eligible, requirement: .deviceRead, context: .interactive),
            for: .deviceRead
        )

        let path = try temporaryInput("hello world")
        let (result, _) = try await CLIRunCommand.run(
            workload: "DTCA-1", inputPath: path, transport: transport, eligibility: eligibility)

        let data = try JSONEncoder().encode(result)
        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: data) as? [String: Any])

        // The existing keys are intact…
        XCTAssertNotNil(object["workload"])
        XCTAssertNotNil(object["jobId"])
        XCTAssertNotNil(object["outcome"])
        XCTAssertNotNil(object["evidence"])
        // …and routing is the one additive, optional field.
        let routing = try XCTUnwrap(object["routing"] as? [String: Any])
        XCTAssertEqual(routing["outcome"] as? String, "eligible")
    }

    // MARK: 11. A slow-but-healthy reader yields a current, not future, observation

    func testSlowHealthyReaderYieldsCurrentObservationAndEligibleDecision() async throws {
        let eligibility = DeviceExecutionEligibility(
            transport: RunTransport(),
            contractModelRequired: true,
            reader: SlowStampingReader(sleepNanoseconds: 100_000_000)
        )

        let decision = await eligibility.decide(
            deviceSerial: "TEST-SERIAL",
            requirement: .deviceRead,
            context: .interactive
        )

        let freshness = try XCTUnwrap(decision.checks.first { $0.id == "observation-freshness" })
        XCTAssertEqual(
            freshness.verdict, .passed,
            "a slow but healthy read must be current, not a future timestamp")
        XCTAssertFalse(
            freshness.measured.contains("future"),
            "the observation age must never be reported as timestamped in the future")
        XCTAssertEqual(
            decision.outcome, .eligible,
            "a healthy interactive read with enough storage must be eligible")
    }

    // MARK: 12. Scoped model-presence for the on-device server backend
    //
    // When the selected backend is `llama-server-http`, the contract artifact is never read by
    // that path, so model-presence must not block the run. The skip is reported, the liveness
    // probe carries the weight, and an unprobed backend fails closed.

    func testOnDeviceServerHealthyProbeWithEmptyModelIsEligible() async throws {
        let transport = RunTransport()
        await transport.setShellPrefix(
            "printf 'GET /health",
            TransportResult(exitCode: 0, stdout: "HTTP/1.1 200 OK\r\n", stderr: "")
        )

        let eligibility = DeviceExecutionEligibility(
            transport: transport,
            backendPort: LlamaCppInferenceRuntime.onDeviceServerPort,
            contractModelRequired: false,
            reader: HealthyInferenceReader()
        )

        let decision = await eligibility.decide(
            deviceSerial: "TEST-SERIAL",
            requirement: .inference,
            context: .interactive
        )

        XCTAssertEqual(decision.outcome, .eligible)
        XCTAssertNil(
            decision.checks.first { $0.id == "model-present" },
            "model-present must not appear as a passed check for the on-device server backend")
        XCTAssertTrue(
            decision.notEvaluated.contains { $0.hasPrefix("model-present:") },
            "the skipped model check must be reported in notEvaluated, not silently dropped")
        let health = try XCTUnwrap(decision.checks.first { $0.id == "backend-health" })
        XCTAssertEqual(health.verdict, .passed)
    }

    func testOnDeviceServerFailedProbeWithEmptyModelIsRejected() async throws {
        let transport = RunTransport()
        await transport.setShellPrefix(
            "printf 'GET /health",
            TransportResult(exitCode: 0, stdout: "", stderr: "connection refused")
        )

        let eligibility = DeviceExecutionEligibility(
            transport: transport,
            backendPort: LlamaCppInferenceRuntime.onDeviceServerPort,
            contractModelRequired: false,
            reader: HealthyInferenceReader()
        )

        let decision = await eligibility.decide(
            deviceSerial: "TEST-SERIAL",
            requirement: .inference,
            context: .interactive
        )

        XCTAssertEqual(decision.outcome, .rejected)
        let health = try XCTUnwrap(decision.checks.first { $0.id == "backend-health" })
        XCTAssertEqual(health.verdict, .failed)
        XCTAssertTrue(
            decision.blockingChecks.contains { $0.id == "backend-health" },
            "a failed probe must be the blocking check")
    }

    func testOnDeviceServerWithNoProbeFailsClosed() async throws {
        // `backendPort: nil` with `contractModelRequired: false` is a wiring error: the caller
        // declared the on-device server but supplied no endpoint to probe, so the liveness probe
        // never ran. That must not read as eligible.
        let eligibility = DeviceExecutionEligibility(
            transport: RunTransport(),
            contractModelRequired: false,
            reader: HealthyInferenceReader()
        )

        let decision = await eligibility.decide(
            deviceSerial: "TEST-SERIAL",
            requirement: .inference,
            context: .interactive
        )

        XCTAssertNotEqual(decision.outcome, .eligible, "an unprobed on-device server must not be eligible")
        XCTAssertEqual(decision.outcome, .rejected)
        let health = try XCTUnwrap(decision.checks.first { $0.id == "backend-health" })
        XCTAssertEqual(health.verdict, .unknown, "the unrun probe must be reported as unknown, not as a pass")
    }

    func testInProcessBackendWithEmptyModelIsStillRejected() async throws {
        let eligibility = DeviceExecutionEligibility(
            transport: RunTransport(),
            contractModelRequired: true,
            reader: HealthyInferenceReader()
        )

        let decision = await eligibility.decide(
            deviceSerial: "TEST-SERIAL",
            requirement: .inference,
            context: .interactive
        )

        XCTAssertEqual(decision.outcome, .rejected)
        let model = try XCTUnwrap(decision.checks.first { $0.id == "model-present" })
        XCTAssertEqual(model.verdict, .failed)
        XCTAssertTrue(
            decision.blockingChecks.contains { $0.id == "model-present" },
            "the in-process backend must still block on an absent contract model")
        XCTAssertTrue(
            decision.notEvaluated.contains { $0.hasPrefix("backend-health:") },
            "the in-process backend has no endpoint, so backend-health is not evaluated")
    }

    // MARK: 15. A stale — but readable — observation fails closed by context

    /// An observation past the window is still a real reading: of the past. The gate must not treat
    /// it as evidence about now, and the two contexts must answer differently — unattended it
    /// blocks and stays retryable, interactive it needs an explicit act.
    ///
    /// The boundary is the policy's own `maxObservationAge`, exceeded by one second, so no new
    /// threshold is introduced here.
    private func staleButHealthyObservation(now: Date) -> PixelStateObservation {
        let observedAt = now.addingTimeInterval(-(RoutingThresholds.default.maxObservationAge + 1))
        return PixelStateObservation(
            observedAt: observedAt,
            deviceSerial: "TEST-SERIAL",
            availableMemoryBytes: .deviceReported(8 * 1024 * 1024 * 1024, at: observedAt, limitation: "test stub"),
            freeStorageBytes: .deviceReported(8 * 1024 * 1024 * 1024, at: observedAt, limitation: "test stub"),
            workerInstalled: .deviceReported(.installed(versionCode: 7), at: observedAt, limitation: "test stub"),
            workerRunning: .deviceReported(false, at: observedAt, limitation: "test stub"),
            modelPresent: .deviceReported(.absent, at: observedAt, limitation: "test stub"),
            thermalStatus: .deviceReported(0, at: observedAt, limitation: "test stub"),
            deviceReachable: .deviceReported(true, at: observedAt, limitation: "test stub")
        )
    }

    func testStaleObservationDefersAnUnattendedRun() throws {
        let now = Date(timeIntervalSince1970: 1_000_000)
        let decision = ExecutionRoutingEvaluator().evaluate(
            observation: staleButHealthyObservation(now: now),
            requirement: .deviceRead,
            context: .unattended,
            now: now
        )

        XCTAssertEqual(decision.outcome, .deferred,
                       "an unattended run must never proceed on a stale reading")
        XCTAssertFalse(decision.isPermitted)
        XCTAssertTrue(decision.isRetryable, "a stale reading can be re-read, so the attempt is retryable")
        XCTAssertEqual(decision.blockingChecks.map(\.id), ["observation-freshness"],
                       "every other condition was satisfied; freshness is the only failure")

        let freshness = try XCTUnwrap(decision.checks.first { $0.id == "observation-freshness" })
        XCTAssertEqual(freshness.verdict, .unknown, "not current is not a pass")
        XCTAssertEqual(freshness.severity, .hard, "unattended, staleness is not overridable")
        XCTAssertTrue(freshness.measured.contains("old"), "measured: \(freshness.measured)")
    }

    func testStaleObservationRequiresAnInteractiveOverride() throws {
        let now = Date(timeIntervalSince1970: 1_000_000)
        let decision = ExecutionRoutingEvaluator().evaluate(
            observation: staleButHealthyObservation(now: now),
            requirement: .deviceRead,
            context: .interactive,
            now: now
        )

        XCTAssertEqual(decision.outcome, .requiresOverride)
        XCTAssertFalse(decision.isPermitted, "an unaccepted soft failure is not permission")
        XCTAssertTrue(decision.blockingChecks.allSatisfy { $0.severity == .soft },
                      "an interactive caller may only be asked to accept soft conditions")
        XCTAssertNotNil(decision.overridden(by: .interactive))
        XCTAssertNil(decision.overridden(by: .unattended), "nobody is present to accept it")
    }

    // MARK: 6. A hard block is never overridable, whatever the outcome field says

    /// `.requiresOverride` is only produced when every blocking check is soft, but `RoutingDecision`
    /// is `Codable` and crosses the CLI boundary, so the guard must not trust the outcome alone.
    func testADecisionWithAHardBlockIsNeverOverridable() throws {
        let soft = RoutingCheck(
            id: "observation-freshness",
            title: "Observation freshness",
            severity: .soft,
            verdict: .unknown,
            measured: "old",
            threshold: "at most 120s",
            explanation: "A stale reading cannot be trusted.",
            isTransient: true
        )
        let hard = RoutingCheck(
            id: "thermal-status",
            title: "Thermal status",
            severity: .hard,
            verdict: .failed,
            measured: "severe",
            threshold: "at most moderate",
            explanation: "The device is too hot to run this.",
            isTransient: true
        )
        let now = Date(timeIntervalSince1970: 1_000_000)
        func decision(_ checks: [RoutingCheck], _ outcome: RoutingOutcome) -> RoutingDecision {
            RoutingDecision(
                outcome: outcome,
                requirement: .deviceRead,
                context: .interactive,
                checks: checks,
                notEvaluated: [],
                deviceSerial: "R58M0000000",
                evaluatedAt: now
            )
        }

        XCTAssertNil(decision([soft, hard], .requiresOverride).overridden(by: .interactive),
                     "a hard block must not be overridable just because the outcome says it may be")
        XCTAssertNil(decision([hard], .requiresOverride).overridden(by: .interactive))

        // The legitimate case is unaffected: all blocking checks soft, interactive caller.
        let overridden = try XCTUnwrap(decision([soft], .requiresOverride).overridden(by: .interactive))
        XCTAssertEqual(overridden.outcome, .overridden)
        XCTAssertEqual(overridden.context, .interactive, "the record keeps the context it was decided in")
        XCTAssertEqual(overridden.checks.map(\.id), ["observation-freshness"], "the evidence is carried over")

        // Outcomes that are never overridable stay that way.
        XCTAssertNil(decision([soft], .deferred).overridden(by: .interactive))
        XCTAssertNil(decision([soft], .rejected).overridden(by: .interactive))
        XCTAssertNil(decision([soft], .requiresOverride).overridden(by: .unattended))
    }
}

// MARK: - 16. The memory floor is backend-aware
//
// The in-process path loads the model, so it must find room for the model plus ggml's loading
// copy. The on-device server loaded its model when it started and holds it resident, so charging
// those bytes again would defer every run against a device that is demonstrably serving. Measured
// on a Pixel 7a holding Gemma 4 E2B (2.84 GB) resident: MemAvailable ~545 MB, which is below the
// in-process floor of 1.54 GB and above the headroom floor, so each backend must answer differently.

/// An inference observation whose available memory and model presence are the variables.
struct MemoryBoundInferenceReader: PixelStateObserving {
    let availableMemoryBytes: Int
    let modelPresent: PixelStateObservation.ModelPresence

    func observeState(
        deviceSerial: String,
        timeout: TimeInterval
    ) async throws -> PixelStateObservation {
        let now = Date()
        return PixelStateObservation(
            observedAt: now,
            deviceSerial: deviceSerial,
            availableMemoryBytes: .deviceReported(availableMemoryBytes, at: now, limitation: "test stub"),
            freeStorageBytes: .deviceReported(8 * 1024 * 1024 * 1024, at: now, limitation: "test stub"),
            workerInstalled: .deviceReported(.installed(versionCode: 7), at: now, limitation: "test stub"),
            workerRunning: .deviceReported(false, at: now, limitation: "test stub"),
            modelPresent: .deviceReported(modelPresent, at: now, limitation: "test stub"),
            thermalStatus: .deviceReported(0, at: now, limitation: "test stub"),
            deviceReachable: .deviceReported(true, at: now, limitation: "test stub")
        )
    }
}

final class Phase10MemoryFloorTests: XCTestCase {

    private func healthyProbeTransport() async -> RunTransport {
        let transport = RunTransport()
        await transport.setShellPrefix(
            "printf 'GET /health",
            TransportResult(exitCode: 0, stdout: "HTTP/1.1 200 OK\r\n", stderr: "")
        )
        return transport
    }

    /// Below the in-process floor, above headroom: the server backend runs.
    func testOnDeviceServerRunsOnHeadroomRatherThanTheModelSizedFloor() async throws {
        let eligibility = DeviceExecutionEligibility(
            transport: await healthyProbeTransport(),
            backendPort: LlamaCppInferenceRuntime.onDeviceServerPort,
            contractModelRequired: false,
            reader: MemoryBoundInferenceReader(
                availableMemoryBytes: 545_000_000,
                modelPresent: .absent
            )
        )

        let decision = await eligibility.decide(
            deviceSerial: "TEST-SERIAL",
            requirement: .inference,
            context: .interactive
        )

        XCTAssertEqual(decision.outcome, .eligible)
        let memory = try XCTUnwrap(decision.checks.first { $0.id == "available-memory" })
        XCTAssertEqual(memory.verdict, .passed)
        XCTAssertEqual(memory.threshold, "at least 256 MB",
                       "the server backend is measured against headroom, not a model load")
        XCTAssertFalse(
            memory.explanation.contains("does not fit"),
            "the explanation must describe headroom, not a model load: \(memory.explanation)")
    }

    /// The floor still exists, and it still blocks: headroom is not a licence to overcommit.
    func testOnDeviceServerBelowHeadroomIsDeferred() async throws {
        let eligibility = DeviceExecutionEligibility(
            transport: await healthyProbeTransport(),
            backendPort: LlamaCppInferenceRuntime.onDeviceServerPort,
            contractModelRequired: false,
            reader: MemoryBoundInferenceReader(
                availableMemoryBytes: 128_000_000,
                modelPresent: .absent
            )
        )

        let decision = await eligibility.decide(
            deviceSerial: "TEST-SERIAL",
            requirement: .inference,
            context: .interactive
        )

        XCTAssertEqual(decision.outcome, .deferred)
        XCTAssertTrue(
            decision.blockingChecks.contains { $0.id == "available-memory" },
            "a memory shortfall must block regardless of backend")
    }

    /// The in-process backend is unchanged: it loads the model, so it must find room for it.
    func testInProcessBackendStillNeedsTheModelSizedFloor() async throws {
        let eligibility = DeviceExecutionEligibility(
            transport: RunTransport(),
            contractModelRequired: true,
            reader: MemoryBoundInferenceReader(
                availableMemoryBytes: 545_000_000,
                modelPresent: .present(byteCount: ModelContract.expectedByteCount)
            )
        )

        let decision = await eligibility.decide(
            deviceSerial: "TEST-SERIAL",
            requirement: .inference,
            context: .interactive
        )

        XCTAssertEqual(decision.outcome, .deferred)
        let memory = try XCTUnwrap(decision.checks.first { $0.id == "available-memory" })
        XCTAssertEqual(memory.verdict, .failed,
                       "545 MB is not enough to load a 1.04 GiB model and its copy")
        XCTAssertTrue(memory.threshold.contains("GB"),
                      "the in-process floor is model-sized: \(memory.threshold)")
        XCTAssertTrue(
            decision.blockingChecks.contains { $0.id == "available-memory" },
            "the in-process path must keep blocking on the model-sized floor")
    }
}
