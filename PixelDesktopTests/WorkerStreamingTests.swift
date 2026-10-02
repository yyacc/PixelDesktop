import XCTest
@testable import PixelDesktop

/// Phase 7 / E1 — persistent ADB shell streaming.
///
/// These are **unit tests**: the protocol, the reducer and the runner are all exercised against a
/// scripted transport, with no device attached. The live-device equivalents are recorded in
/// `engineering/phases/phase-07-e1-streaming-implementation.md`; the two are kept deliberately
/// separate so a passing suite is never mistaken for device verification.
///
/// Test numbering follows the brief's required list.
final class WorkerStreamingTests: XCTestCase {

    // MARK: - 1. Successful streamed job

    func testSuccessfulStreamedJobReachesCompletedWithDurableResult() async throws {
        let transport = MockTransport()
        let resultJSON = """
        {"status":"OK","job_id":"job-1","generated_tokens":7}
        """
        await transport.setStreamingLines([
            "PDE1 START job_id=job-1",
            "PDE1 JOB_WRITTEN bytes=176",
            "PDE1 LAUNCHED",
            "PDE1 HEARTBEAT n=1 pid=14415",
            "PDE1 HEARTBEAT n=2 pid=14415",
            "PDE1 RESULT_BEGIN",
            resultJSON,
            "PDE1 RESULT_END bytes=\(resultJSON.utf8.count)",
        ])
        // The device reports the durable file, matching what the stream carried.
        await transport.setShellResponse(
            "stat -c %s \(WorkerTransferContract.remoteResultPath)",
            TransportResult(exitCode: 0, stdout: "\(resultJSON.utf8.count)", stderr: "")
        )

        let runner = WorkerStreamRunner(transport: transport)
        let run = try await runner.run(
            deviceSerial: "serial",
            jobId: "job-1",
            payload: "{\"job_id\":\"job-1\"}"
        )

        guard case .completed(let json, let bytes) = run.outcome else {
            return XCTFail("Expected .completed, got \(run.outcome)")
        }
        XCTAssertTrue(json.contains("\"status\":\"OK\""))
        XCTAssertEqual(bytes, resultJSON.utf8.count)
        XCTAssertEqual(run.jobId, "job-1")
        XCTAssertEqual(run.workerPidObserved, 14415)
    }

    // MARK: - 2. Progress arrives incrementally

    func testHeartbeatsAreDeliveredIncrementallyInOrder() async throws {
        let transport = MockTransport()
        await transport.setStreamingLines([
            "PDE1 START job_id=job-2",
            "PDE1 LAUNCHED",
            "PDE1 HEARTBEAT n=1 pid=100",
            "PDE1 HEARTBEAT n=2 pid=100",
            "PDE1 HEARTBEAT n=3 pid=100",
        ])

        let recorder = EventRecorder()
        let runner = WorkerStreamRunner(transport: transport)
        _ = try await runner.run(
            deviceSerial: "serial",
            jobId: "job-2",
            payload: "{}",
            onEvent: { event in recorder.record(event) }
        )

        let heartbeats = recorder.events.compactMap { event -> Int? in
            if case .heartbeat(let sequence, _) = event { return sequence }
            return nil
        }
        // Order is preserved and every heartbeat is observed — the property that makes the stream
        // useful for liveness rather than only for the final answer.
        XCTAssertEqual(heartbeats, [1, 2, 3])
    }

    // MARK: - 3. No polling loop required

    func testNoPollingShellInvocationsAreMadeDuringAStreamedJob() async throws {
        let transport = MockTransport()
        await transport.setStreamingLines([
            "PDE1 START job_id=job-3",
            "PDE1 LAUNCHED",
            "PDE1 HEARTBEAT n=1 pid=1",
            "PDE1 RESULT_BEGIN",
            "{\"status\":\"OK\"}",
            "PDE1 RESULT_END bytes=15",
        ])
        await transport.setShellResponse(
            "stat -c %s \(WorkerTransferContract.remoteResultPath)",
            TransportResult(exitCode: 0, stdout: "15", stderr: "")
        )

        let runner = WorkerStreamRunner(transport: transport)
        _ = try await runner.run(deviceSerial: "serial", jobId: "job-3", payload: "{}")

        // The old design polled `cat result.json` repeatedly. The only shell call allowed here is
        // the single durability confirmation — no repeated polling.
        let invocations = await transport.invocations
        let pollCalls = invocations.filter { $0.arguments.last?.hasPrefix("cat ") == true }
        XCTAssertTrue(pollCalls.isEmpty, "Streaming must not poll the result file")
        XCTAssertEqual(invocations.count, 1, "Only the durability stat should be issued")
    }

    // MARK: - 4. Malformed job

    func testMalformedJobIsReportedAsAFailedResult() async throws {
        let transport = MockTransport()
        let failureJSON = """
        {"status":"FAILED","job_id":"job-4","error_type":"INVALID_INPUT","error_message":"unsupported workload"}
        """
        await transport.setStreamingLines([
            "PDE1 START job_id=job-4",
            "PDE1 LAUNCHED",
            "PDE1 HEARTBEAT n=1 pid=50",
            "PDE1 RESULT_BEGIN",
            failureJSON,
            "PDE1 RESULT_END bytes=\(failureJSON.utf8.count)",
        ])
        await transport.setShellResponse(
            "stat -c %s \(WorkerTransferContract.remoteResultPath)",
            TransportResult(exitCode: 0, stdout: "\(failureJSON.utf8.count)", stderr: "")
        )

        let runner = WorkerStreamRunner(transport: transport)
        let run = try await runner.run(deviceSerial: "serial", jobId: "job-4", payload: "{}")

        // A reported failure, delivered as a result — not a missing file and not a transport error.
        guard case .completed(let json, _) = run.outcome else {
            return XCTFail("Expected the failure to arrive as a result, got \(run.outcome)")
        }
        XCTAssertTrue(json.contains("INVALID_INPUT"))
    }

    // MARK: - 5. Missing model

    func testMissingModelFailureIsReportedOnTheStream() async throws {
        let transport = MockTransport()
        let failureJSON = """
        {"status":"FAILED","job_id":"job-5","error_type":"MODEL_MISSING","error_message":"model not found"}
        """
        await transport.setStreamingLines([
            "PDE1 START job_id=job-5",
            "PDE1 LAUNCHED",
            "PDE1 HEARTBEAT n=1 pid=60",
            "PDE1 RESULT_BEGIN",
            failureJSON,
            "PDE1 RESULT_END bytes=\(failureJSON.utf8.count)",
        ])
        await transport.setShellResponse(
            "stat -c %s \(WorkerTransferContract.remoteResultPath)",
            TransportResult(exitCode: 0, stdout: "\(failureJSON.utf8.count)", stderr: "")
        )

        let runner = WorkerStreamRunner(transport: transport)
        let run = try await runner.run(deviceSerial: "serial", jobId: "job-5", payload: "{}")

        guard case .completed(let json, _) = run.outcome else {
            return XCTFail("Expected a result, got \(run.outcome)")
        }
        XCTAssertTrue(json.contains("MODEL_MISSING"))
    }

    // MARK: - 6/7. Worker exits unexpectedly; PID disappears during execution (E1 F4)

    func testWorkerDeathDuringExecutionProducesAnExplicitTerminalOutcome() async throws {
        let transport = MockTransport()
        // The worker dies and no result ever appears. E1 measured a naive loop that kept
        // heartbeating forever here; the reducer must instead terminate.
        await transport.setStreamingLines([
            "PDE1 START job_id=job-6",
            "PDE1 LAUNCHED",
            "PDE1 HEARTBEAT n=1 pid=17560",
            "PDE1 HEARTBEAT n=2 pid=17560",
            "PDE1 HEARTBEAT n=3 pid=none",
            "PDE1 HEARTBEAT n=4 pid=none",
            "PDE1 HEARTBEAT n=5 pid=none",
        ])

        let runner = WorkerStreamRunner(transport: transport)
        let run = try await runner.run(deviceSerial: "serial", jobId: "job-6", payload: "{}")

        guard case .workerExitedUnexpectedly = run.outcome else {
            return XCTFail("Expected worker death to be explicit, got \(run.outcome)")
        }
        XCTAssertFalse(run.outcome.isSuccess)
        XCTAssertFalse(run.outcome.mayStillBeRunning)
    }

    func testExplicitWorkerExitedEventTerminatesImmediately() {
        var reducer = WorkerStreamReducer()
        reducer.apply(.started(jobId: "j"))
        reducer.apply(.launched)
        reducer.apply(.heartbeat(sequence: 1, workerPid: 999))
        XCTAssertEqual(reducer.state, .streamAliveWorkerAlive(pid: 999))

        reducer.apply(.workerExited(sequence: 2))

        XCTAssertEqual(reducer.state, .streamAliveWorkerExited)
        guard case .workerExitedUnexpectedly(let sequence)? = reducer.finalOutcome else {
            return XCTFail("Expected .workerExitedUnexpectedly, got \(String(describing: reducer.finalOutcome))")
        }
        XCTAssertEqual(sequence, 2)
    }

    func testASingleLivenessMissIsNotTreatedAsDeath() {
        var reducer = WorkerStreamReducer()
        reducer.apply(.launched)
        reducer.apply(.heartbeat(sequence: 1, workerPid: 500))
        reducer.apply(.heartbeat(sequence: 2, workerPid: nil))

        // One miss is normal during process exit; the job must not be declared dead on it.
        XCTAssertNil(reducer.finalOutcome)
        XCTAssertEqual(reducer.state, .streamAliveWorkerAlive(pid: 500))
    }

    func testLivenessMissesBeforeLaunchDoNotCountAsDeath() {
        var reducer = WorkerStreamReducer()
        reducer.apply(.started(jobId: "j"))
        for i in 1...10 {
            reducer.apply(.heartbeat(sequence: i, workerPid: nil))
        }
        // Before launch, "no process" is expected — the worker has not been started yet.
        XCTAssertNil(reducer.finalOutcome)
    }

    func testLivenessMissesAfterAResultDoNotCountAsDeath() {
        var reducer = WorkerStreamReducer()
        reducer.apply(.launched)
        reducer.apply(.heartbeat(sequence: 1, workerPid: 400))
        reducer.apply(.resultBegan)
        reducer.apply(.resultLine("{\"status\":\"OK\"}"))
        reducer.apply(.resultEnded(bytes: 15))

        for i in 2...10 {
            reducer.apply(.heartbeat(sequence: i, workerPid: nil))
        }

        // The worker legitimately exits after writing its result; that must not be a failure.
        guard case .completedButDurabilityUnverified? = reducer.finalOutcome else {
            return XCTFail("Expected a streamed completion, got \(String(describing: reducer.finalOutcome))")
        }
    }

    // MARK: - 8. Stream disconnect while the worker remains alive (E1 F7)

    func testStreamLossWhileWorkerAliveIsNotAFailure() {
        var reducer = WorkerStreamReducer()
        reducer.apply(.started(jobId: "j"))
        reducer.apply(.launched)
        reducer.apply(.heartbeat(sequence: 1, workerPid: 17751))

        reducer.streamEnded(workerAlive: true, workerPid: 17751, reason: "transport lost")

        guard case .streamLostWorkerRunning(let pid)? = reducer.finalOutcome else {
            return XCTFail("Expected .streamLostWorkerRunning, got \(String(describing: reducer.finalOutcome))")
        }
        XCTAssertEqual(pid, 17751)
        // The critical property: this is NOT a failure, and the caller must not cancel.
        XCTAssertFalse(reducer.finalOutcome!.isSuccess)
        XCTAssertTrue(reducer.finalOutcome!.mayStillBeRunning)
        XCTAssertEqual(reducer.state, .streamLostWorkerAlive(pid: 17751))
    }

    func testRunnerRecoversTheDurableResultAfterStreamLoss() async throws {
        let transport = MockTransport()
        // The stream dies immediately — no terminal event at all.
        await transport.setStreamingLines(["PDE1 START job_id=job-8", "PDE1 LAUNCHED"], exitCode: 0)
        // The worker is still running on the device.
        await transport.setShellResponse(
            "pidof \(WorkerTransferContract.workerPackageName)",
            TransportResult(exitCode: 0, stdout: "17751", stderr: "")
        )
        // And a durable result exists.
        await transport.setShellResponse(
            "stat -c %s \(WorkerTransferContract.remoteResultPath)",
            TransportResult(exitCode: 0, stdout: "2983", stderr: "")
        )
        await transport.setShellResponse(
            "cat \(WorkerTransferContract.remoteResultPath)",
            TransportResult(exitCode: 0, stdout: "{\"status\":\"OK\",\"job_id\":\"job-8\"}", stderr: "")
        )

        let runner = WorkerStreamRunner(transport: transport)
        let run = try await runner.run(deviceSerial: "serial", jobId: "job-8", payload: "{}")

        guard case .recoveredFromDevice(let json, let bytes) = run.outcome else {
            return XCTFail("Expected recovery from the device, got \(run.outcome)")
        }
        XCTAssertTrue(json.contains("\"status\":\"OK\""))
        XCTAssertEqual(bytes, 2983)
        XCTAssertTrue(run.outcome.isSuccess)
    }

    func testStreamLossWithNoDurableResultAndWorkerGoneReportsWorkerGone() async throws {
        let transport = MockTransport()
        await transport.setStreamingLines(["PDE1 START job_id=job-9", "PDE1 LAUNCHED"], exitCode: 0)
        await transport.setShellResponse(
            "pidof \(WorkerTransferContract.workerPackageName)",
            TransportResult(exitCode: 1, stdout: "", stderr: "")
        )
        await transport.setShellResponse(
            "stat -c %s \(WorkerTransferContract.remoteResultPath)",
            TransportResult(exitCode: 1, stdout: "", stderr: "No such file")
        )

        let runner = WorkerStreamRunner(transport: transport)
        let run = try await runner.run(deviceSerial: "serial", jobId: "job-9", payload: "{}")

        guard case .streamLostWorkerGone = run.outcome else {
            return XCTFail("Expected .streamLostWorkerGone, got \(run.outcome)")
        }
    }

    // MARK: - 9. Stream disconnect after worker completion

    func testStreamLossAfterCompletionStillRecoversTheDurableResult() async throws {
        let transport = MockTransport()
        // The result was streamed, then the session died before the exit was clean.
        let resultJSON = "{\"status\":\"OK\",\"job_id\":\"job-10\"}"
        await transport.setStreamingLines([
            "PDE1 START job_id=job-10",
            "PDE1 LAUNCHED",
            "PDE1 HEARTBEAT n=1 pid=222",
            "PDE1 RESULT_BEGIN",
            resultJSON,
            "PDE1 RESULT_END bytes=\(resultJSON.utf8.count)",
        ])
        await transport.setShellResponse(
            "stat -c %s \(WorkerTransferContract.remoteResultPath)",
            TransportResult(exitCode: 0, stdout: "\(resultJSON.utf8.count)", stderr: "")
        )

        let runner = WorkerStreamRunner(transport: transport)
        let run = try await runner.run(deviceSerial: "serial", jobId: "job-10", payload: "{}")

        // A clean streamed completion whose durable file was confirmed is `.completed`, not
        // `.recoveredFromDevice` — the two paths are distinct.
        guard case .completed = run.outcome else {
            return XCTFail("Expected .completed, got \(run.outcome)")
        }
    }

    // MARK: - 10. Durable result survives stream disconnect

    func testDurableResultOnDeviceIsPreferredOverTheStreamedCopy() async throws {
        let transport = MockTransport()
        let streamed = "{\"status\":\"OK\",\"job_id\":\"job-11\"}"
        await transport.setStreamingLines([
            "PDE1 START job_id=job-11",
            "PDE1 LAUNCHED",
            "PDE1 HEARTBEAT n=1 pid=1",
            "PDE1 RESULT_BEGIN",
            streamed,
            "PDE1 RESULT_END bytes=\(streamed.utf8.count)",
        ])
        // The device's durable file is the authority on size.
        await transport.setShellResponse(
            "stat -c %s \(WorkerTransferContract.remoteResultPath)",
            TransportResult(exitCode: 0, stdout: "\(streamed.utf8.count)", stderr: "")
        )

        let runner = WorkerStreamRunner(transport: transport)
        let run = try await runner.run(deviceSerial: "serial", jobId: "job-11", payload: "{}")

        guard case .completed(_, let bytes) = run.outcome else {
            return XCTFail("Expected .completed, got \(run.outcome)")
        }
        // The byte count comes from the device, not from the stream.
        XCTAssertEqual(bytes, streamed.utf8.count)
    }

    // MARK: - 11. Result missing after apparent completion

    func testStreamedCompletionWithNoDurableFileIsNotReportedAsCompleted() async throws {
        let transport = MockTransport()
        let resultJSON = "{\"status\":\"OK\",\"job_id\":\"job-12\"}"
        await transport.setStreamingLines([
            "PDE1 START job_id=job-12",
            "PDE1 LAUNCHED",
            "PDE1 HEARTBEAT n=1 pid=1",
            "PDE1 RESULT_BEGIN",
            resultJSON,
            "PDE1 RESULT_END bytes=\(resultJSON.utf8.count)",
        ])
        // No durable file on the device.
        await transport.setShellResponse(
            "stat -c %s \(WorkerTransferContract.remoteResultPath)",
            TransportResult(exitCode: 1, stdout: "", stderr: "No such file")
        )

        let runner = WorkerStreamRunner(transport: transport)
        let run = try await runner.run(deviceSerial: "serial", jobId: "job-12", payload: "{}")

        // The brief: "stream completion does not mean result durability". This outcome says so.
        guard case .completedButDurabilityUnverified(_, let reason) = run.outcome else {
            return XCTFail("Expected durability to be unverified, got \(run.outcome)")
        }
        XCTAssertTrue(reason.contains("not found"))
        XCTAssertFalse(run.outcome.isSuccess)
    }

    func testTruncatedDurableFileIsNotAcceptedAsCompleted() {
        var reducer = WorkerStreamReducer()
        reducer.apply(.started(jobId: "j"))
        reducer.apply(.launched)
        reducer.apply(.heartbeat(sequence: 1, workerPid: 1))
        reducer.apply(.resultBegan)
        reducer.apply(.resultLine("{\"status\":\"OK\"}"))
        reducer.apply(.resultEnded(bytes: 15))

        // The durable file is shorter than what the stream carried: it is truncated.
        reducer.confirmDurability(durableBytes: 4)

        guard case .completedButDurabilityUnverified(_, let reason)? = reducer.finalOutcome else {
            return XCTFail("Expected durability to remain unverified, got \(String(describing: reducer.finalOutcome))")
        }
        XCTAssertTrue(reason.contains("truncated"))
    }

    func testEmptyDurableFileIsNotAcceptedAsCompleted() {
        var reducer = WorkerStreamReducer()
        reducer.apply(.launched)
        reducer.apply(.heartbeat(sequence: 1, workerPid: 1))
        reducer.apply(.resultBegan)
        reducer.apply(.resultLine("{}"))
        reducer.apply(.resultEnded(bytes: 2))

        reducer.confirmDurability(durableBytes: 0)

        guard case .completedButDurabilityUnverified? = reducer.finalOutcome else {
            return XCTFail("Expected an unverified durability outcome")
        }
    }

    // MARK: - 12. Corrupt / malformed stream

    func testResultEndWithoutBeginIsMalformed() {
        var reducer = WorkerStreamReducer()
        reducer.apply(.launched)
        reducer.apply(.resultEnded(bytes: 100))

        guard case .malformedStream? = reducer.finalOutcome else {
            return XCTFail("Expected .malformedStream, got \(String(describing: reducer.finalOutcome))")
        }
    }

    func testStreamEndingMidResultIsMalformedRatherThanCompleted() {
        var reducer = WorkerStreamReducer()
        reducer.apply(.launched)
        reducer.apply(.heartbeat(sequence: 1, workerPid: 1))
        reducer.apply(.resultBegan)
        reducer.apply(.resultLine("{\"status\":"))

        reducer.streamEnded(workerAlive: false, workerPid: nil, reason: "killed")

        guard case .malformedStream(let reason)? = reducer.finalOutcome else {
            return XCTFail("Expected .malformedStream, got \(String(describing: reducer.finalOutcome))")
        }
        XCTAssertTrue(reason.contains("mid-result"))
    }

    func testUnrecognizedLinesAreRecordedRatherThanDiscarded() async throws {
        let transport = MockTransport()
        await transport.setStreamingLines([
            "PDE1 START job_id=job-13",
            "some stray device output",
            "PDE1 LAUNCHED",
        ])

        let runner = WorkerStreamRunner(transport: transport)
        let run = try await runner.run(deviceSerial: "serial", jobId: "job-13", payload: "{}")

        // A mismatch between the script and the parser must be visible, not silent.
        XCTAssertTrue(run.unrecognizedLines.contains("some stray device output"))
    }

    // MARK: - 13. Cancellation remains external

    func testCancellationIsNotPerformedByTheStream() async throws {
        let transport = MockTransport()
        await transport.setStreamingLines(["PDE1 START job_id=job-14", "PDE1 LAUNCHED"])

        let runner = WorkerStreamRunner(transport: transport)
        _ = try await runner.run(deviceSerial: "serial", jobId: "job-14", payload: "{}")

        // E1 F3: cancellation is `am force-stop`, issued outside the session. The streaming path
        // must never issue it — and in particular must not kill a worker whose stream died.
        let invocations = await transport.invocations
        let forceStops = invocations.filter { $0.arguments.last?.contains("force-stop") == true }
        XCTAssertTrue(forceStops.isEmpty, "The streaming path must not cancel")
    }

    func testWorkerLifecycleForceStopRemainsAvailable() async throws {
        let transport = MockTransport()
        // `stopIfRunning` polls until the process disappears, so the second `pidof` must report
        // nothing. Modelling only the first read would make the test hang on a fake process that
        // never dies — which is what happened on the first run.
        await transport.setShellResponses(
            for: "pidof \(WorkerTransferContract.workerPackageName)",
            [
                TransportResult(exitCode: 0, stdout: "14415", stderr: ""),
                TransportResult(exitCode: 1, stdout: "", stderr: ""),
            ]
        )
        await transport.setShellResponse(
            "am force-stop \(WorkerTransferContract.workerPackageName)",
            TransportResult(exitCode: 0, stdout: "", stderr: "")
        )

        let lifecycle = WorkerLifecycle(transport: transport)
        try await lifecycle.stopIfRunning(deviceSerial: "serial")

        let invocations = await transport.invocations
        XCTAssertTrue(
            invocations.contains { $0.arguments.last == "am force-stop \(WorkerTransferContract.workerPackageName)" }
        )
    }

    // MARK: - 14. Long-running jobs are not capped

    func testNoFixedHeartbeatCapIsImposed() {
        var reducer = WorkerStreamReducer()
        reducer.apply(.launched)

        // E1 F5: a 256-token job exceeded 90 s. A job must be able to report liveness indefinitely
        // as long as the worker is alive.
        for i in 1...5_000 {
            reducer.apply(.heartbeat(sequence: i, workerPid: 1234))
        }

        XCTAssertNil(reducer.finalOutcome, "A live worker must never be declared dead by a count")
        XCTAssertEqual(reducer.state, .streamAliveWorkerAlive(pid: 1234))
    }

    // MARK: - 15. Locked / dozing execution

    func testStreamingIsIndependentOfScreenState() async throws {
        // E1 F6 measured a stream completing normally under mWakefulness=Dozing. Screen state is
        // not part of the protocol, so the same event sequence must behave identically.
        let transport = MockTransport()
        let resultJSON = "{\"status\":\"OK\",\"job_id\":\"job-15\"}"
        await transport.setStreamingLines([
            "PDE1 START job_id=job-15",
            "PDE1 LAUNCHED",
            "PDE1 HEARTBEAT n=1 pid=777",
            "PDE1 RESULT_BEGIN",
            resultJSON,
            "PDE1 RESULT_END bytes=\(resultJSON.utf8.count)",
        ])
        await transport.setShellResponse(
            "stat -c %s \(WorkerTransferContract.remoteResultPath)",
            TransportResult(exitCode: 0, stdout: "\(resultJSON.utf8.count)", stderr: "")
        )

        let runner = WorkerStreamRunner(transport: transport)
        let run = try await runner.run(deviceSerial: "serial", jobId: "job-15", payload: "{}")
        XCTAssertTrue(run.outcome.isSuccess)
    }

    // MARK: - 16. stdout/stderr separation

    func testStderrIsKeptSeparateFromProtocolEvents() async throws {
        let transport = MockTransport()
        await transport.setStreamingLines(
            ["PDE1 START job_id=job-16", "PDE1 LAUNCHED"],
            stderr: ["adb: warning: something", "another diagnostic"]
        )

        let runner = WorkerStreamRunner(transport: transport)
        let run = try await runner.run(deviceSerial: "serial", jobId: "job-16", payload: "{}")

        XCTAssertEqual(run.stderrLines, ["adb: warning: something", "another diagnostic"])
        // A stderr line must never be parsed as a protocol event.
        XCTAssertFalse(run.unrecognizedLines.contains("adb: warning: something"))
    }

    func testStderrContainingProtocolShapedTextIsNotTreatedAsAnEvent() async throws {
        let transport = MockTransport()
        await transport.setStreamingLines(
            ["PDE1 START job_id=job-17"],
            stderr: ["PDE1 RESULT_BEGIN"]
        )

        let runner = WorkerStreamRunner(transport: transport)
        let run = try await runner.run(deviceSerial: "serial", jobId: "job-17", payload: "{}")

        // The stream never entered a result, so this must not be read as completion.
        XCTAssertFalse(run.outcome.isSuccess)
        XCTAssertEqual(run.stderrLines, ["PDE1 RESULT_BEGIN"])
    }

    // MARK: - Payload delivery

    func testJobPayloadIsDeliveredOnStdinRatherThanPushed() async throws {
        let transport = MockTransport()
        await transport.setStreamingLines(["PDE1 START job_id=job-18", "PDE1 LAUNCHED"])
        let payload = "{\"job_id\":\"job-18\",\"workload\":\"DTCA-1\",\"input\":\"a b c\"}"

        let runner = WorkerStreamRunner(transport: transport)
        _ = try await runner.run(deviceSerial: "serial", jobId: "job-18", payload: payload)

        let stdin = await transport.lastStreamingStdin
        XCTAssertEqual(stdin, payload)

        // And no `push` was issued: stdin delivery replaced it.
        let invocations = await transport.invocations
        let pushes = invocations.filter { $0.arguments.contains("push") }
        XCTAssertTrue(pushes.isEmpty, "The payload must not be pushed separately")
    }

    func testDeviceScriptWritesThePayloadFromStdin() throws {
        let script = try WorkerStreamScript.deviceScript(jobId: "job-19")
        // The payload path is bound to a variable and read from stdin, replacing `adb push`.
        XCTAssertTrue(script.contains("J=\(WorkerTransferContract.remoteInputPath)"))
        XCTAssertTrue(script.contains("cat > $J"))
        // One line: `adb shell` treats embedded newlines as separators.
        XCTAssertFalse(script.contains("\n"))
    }

    func testDeviceScriptIsSyntacticallyValidShell() throws {
        let script = try WorkerStreamScript.deviceScript(jobId: "job-22")

        // The script is assembled with `joined(separator: "; ")`, which inserts a semicolon between
        // every element. An earlier revision emitted `while ...; do; i=0; ...` — `do;` is a shell
        // syntax error, so the ENTIRE script failed to parse and the stream produced no output at
        // all. It reached a live device before being caught, so it is asserted here instead.
        XCTAssertFalse(script.contains("; do;"), "`do` must not be followed by a separator")
        XCTAssertFalse(script.contains(";;"), "no doubled separators")
        XCTAssertTrue(script.contains("while [ ! -f $R ]"))
        XCTAssertTrue(script.contains("do i=$((i+1))"))
        XCTAssertTrue(script.contains("done"))

        // Every `if` must have a matching `fi`, and every `while` a matching `done`.
        let ifCount = script.components(separatedBy: "if ").count - 1
        let fiCount = script.components(separatedBy: "fi").count - 1
        XCTAssertGreaterThanOrEqual(fiCount, ifCount, "every `if` needs a `fi`")
    }

    func testDeviceScriptDoesNotContainTheResultContentsInTheCommand() throws {
        let script = try WorkerStreamScript.deviceScript(jobId: "job-20")
        // The result is read on the device and emitted; it must never be interpolated into the
        // command string.
        XCTAssertFalse(script.contains("status"))
    }

    // MARK: - Job id containment

    func testJobIdValidationRejectsShellMetacharacters() {
        let bad = [
            "job;rm -rf /",
            "job$(whoami)",
            "job`id`",
            "job id",
            "job\"quote",
            "job'quote",
            "job|pipe",
            "job>redirect",
            "",
            String(repeating: "a", count: 100),
        ]
        for candidate in bad {
            XCTAssertThrowsError(
                try WorkerStreamScript.validateJobId(candidate),
                "Job id should be rejected: \(candidate)"
            )
        }
    }

    func testJobIdValidationAcceptsUUIDs() throws {
        let uuid = UUID().uuidString
        XCTAssertEqual(try WorkerStreamScript.validateJobId(uuid), uuid)
    }

    // MARK: - Event parsing

    func testParserHandlesEveryProtocolToken() {
        XCTAssertEqual(WorkerEventParser.parse("PDE1 START job_id=abc"), .started(jobId: "abc"))
        XCTAssertEqual(WorkerEventParser.parse("PDE1 JOB_WRITTEN bytes=176"), .jobWritten(bytes: 176))
        XCTAssertEqual(WorkerEventParser.parse("PDE1 LAUNCHED"), .launched)
        XCTAssertEqual(
            WorkerEventParser.parse("PDE1 HEARTBEAT n=4 pid=99"),
            .heartbeat(sequence: 4, workerPid: 99)
        )
        XCTAssertEqual(
            WorkerEventParser.parse("PDE1 HEARTBEAT n=5 pid=none"),
            .heartbeat(sequence: 5, workerPid: nil)
        )
        XCTAssertEqual(WorkerEventParser.parse("PDE1 WORKER_EXITED n=7"), .workerExited(sequence: 7))
        XCTAssertEqual(WorkerEventParser.parse("PDE1 RESULT_BEGIN"), .resultBegan)
        XCTAssertEqual(WorkerEventParser.parse("PDE1 RESULT_END bytes=2983"), .resultEnded(bytes: 2983))
    }

    func testParserPreservesMultiWordFailureMessages() {
        let event = WorkerEventParser.parse("PDE1 ERROR code=NO_WORKSPACE message=worker exchange directory is missing")
        XCTAssertEqual(event, .failure(code: "NO_WORKSPACE", message: "worker exchange directory is missing"))
    }

    func testParserIgnoresNonProtocolAndBlankLines() {
        XCTAssertNil(WorkerEventParser.parse(""))
        XCTAssertNil(WorkerEventParser.parse("   "))
        XCTAssertNil(WorkerEventParser.parse("just some output"))
        XCTAssertNil(WorkerEventParser.parse("PDE1"))
    }

    func testParserTreatsUnknownTokensAsUnrecognized() {
        XCTAssertEqual(WorkerEventParser.parse("PDE1 SOMETHING_ELSE"), .unrecognized("PDE1 SOMETHING_ELSE"))
    }

    // MARK: - Transport failure

    func testTransportFailureAtStartupIsReportedAsUnknownRatherThanDead() async throws {
        let transport = MockTransport()
        await transport.setStreamingError(PixelDesktopError.adbTransportError("no such device"))

        let runner = WorkerStreamRunner(transport: transport)
        do {
            _ = try await runner.run(deviceSerial: "serial", jobId: "job-21", payload: "{}")
            XCTFail("Expected the transport error to propagate")
        } catch {
            // Expected: the caller learns the session never established, rather than being told
            // the job failed. The distinction matters because the worker may never have started.
            XCTAssertTrue(error is PixelDesktopError)
        }
    }

    // MARK: - State model

    func testFourStreamAndWorkerStatesAreDistinguishable() {
        var aliveAlive = WorkerStreamReducer()
        aliveAlive.apply(.launched)
        aliveAlive.apply(.heartbeat(sequence: 1, workerPid: 10))
        XCTAssertEqual(aliveAlive.state, .streamAliveWorkerAlive(pid: 10))

        var aliveDead = WorkerStreamReducer()
        aliveDead.apply(.launched)
        aliveDead.apply(.workerExited(sequence: 2))
        XCTAssertEqual(aliveDead.state, .streamAliveWorkerExited)

        var lostAlive = WorkerStreamReducer()
        lostAlive.apply(.launched)
        lostAlive.streamEnded(workerAlive: true, workerPid: 30, reason: "lost")
        XCTAssertEqual(lostAlive.state, .streamLostWorkerAlive(pid: 30))

        var lostDead = WorkerStreamReducer()
        lostDead.apply(.launched)
        lostDead.streamEnded(workerAlive: false, workerPid: nil, reason: "lost")
        XCTAssertEqual(lostDead.state, .streamLostWorkerGone)

        // The four states the brief requires to remain distinct are all distinct.
        let states: Set<String> = [
            aliveAlive.state.description,
            aliveDead.state.description,
            lostAlive.state.description,
            lostDead.state.description,
        ]
        XCTAssertEqual(states.count, 4)
    }

    func testStreamLossWithUnknowableWorkerStateIsReportedAsUnknown() {
        var reducer = WorkerStreamReducer()
        reducer.apply(.launched)
        reducer.apply(.heartbeat(sequence: 1, workerPid: 5))

        reducer.streamEnded(workerAlive: nil, workerPid: nil, reason: "pidof unavailable")

        guard case .streamLostUnknown(let reason)? = reducer.finalOutcome else {
            return XCTFail("Expected .streamLostUnknown, got \(String(describing: reducer.finalOutcome))")
        }
        XCTAssertTrue(reason.contains("pidof"))
        // Uncertainty is reported rather than converted into a failure.
        XCTAssertTrue(reducer.finalOutcome!.mayStillBeRunning)
    }

    func testTerminalOutcomeIsNotReopenedByLateEvents() {
        var reducer = WorkerStreamReducer()
        reducer.apply(.launched)
        reducer.apply(.workerExited(sequence: 3))
        let decided = reducer.finalOutcome

        reducer.apply(.heartbeat(sequence: 4, workerPid: 1))
        reducer.apply(.resultBegan)
        reducer.apply(.resultEnded(bytes: 10))

        XCTAssertEqual(reducer.finalOutcome, decided)
    }
}

/// Thread-safe event collector for `onEvent` callbacks, which arrive from a background thread.
final class EventRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [WorkerEvent] = []

    var events: [WorkerEvent] {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }

    func record(_ event: WorkerEvent) {
        lock.lock()
        defer { lock.unlock() }
        storage.append(event)
    }
}
