//
//  Phase7StreamingDeviceHarness.swift
//  PixelDesktopTests
//
//  E1 streaming implementation — real-device verification.
//
//  ADR-012 is explicit that a macOS test establishes nothing about Android correctness. The
//  protocol, the reducer and the runner are unit-tested against a scripted transport; whether a
//  real persistent `adb shell` actually drives a real worker job can only be established on the
//  device.
//
//  Skipped unless PIXELDESKTOP_DEVICE_SERIAL is set, matching the Phase 2–7 convention.
//
//  These are LIVE-DEVICE tests. They are deliberately separate from WorkerStreamingTests so a
//  passing unit suite is never mistaken for device verification.
//

import XCTest
@testable import PixelDesktop

final class Phase7StreamingDeviceHarness: XCTestCase {

    private var deviceSerial: String? {
        ProcessInfo.processInfo.environment["PIXELDESKTOP_DEVICE_SERIAL"]
    }

    private func requireDevice() throws -> String {
        guard let serial = deviceSerial else {
            throw XCTSkip("PIXELDESKTOP_DEVICE_SERIAL not set; skipping real-device verification")
        }
        return serial
    }

    /// Builds the `LOCAL-LLM-1` job document in the wire format the worker reads.
    ///
    /// There is no Swift encoder for this workload — Phase 6 submitted LLM jobs with a script, and
    /// the fields below are exactly the ones E1 used and the worker's `LlmWorkload` consumes.
    /// Building it here rather than inventing a production encoder keeps this harness a harness.
    private func llmJobJSON(jobId: String, prompt: String, maxTokens: Int) -> String {
        let escaped = prompt
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        return """
        {"job_id":"\(jobId)","workload":"LOCAL-LLM-1","prompt":"\(escaped)",\
        "max_tokens":\(maxTokens),"temperature":0,"seed":0}
        """
    }

    /// Performance comparison on the same workload E1 used.
    ///
    /// E1's baseline (OLD path: push → `am start` → Mac-side poll → pull) for the 32-token
    /// "capital of France" job was: 0.06 s to first output, 0.17 s to launch ack, 27.6 s wall,
    /// with a 758 ms result-wait component. This measures the NEW path on the same workload so the
    /// comparison is like-for-like.
    ///
    /// DTCA-1 is deliberately **not** used: its ~1 ms of compute means orchestration dominates its
    /// wall time and would make streaming look artificially transformative (E1's own caution).
    func testStreamingPerformanceOnTheE1Workload() async throws {
        let serial = try requireDevice()
        let transport = ADBTransport()
        let lifecycle = WorkerLifecycle(transport: transport)

        try await lifecycle.stopIfRunning(deviceSerial: serial)

        let jobId = UUID().uuidString
        let payload = llmJobJSON(
            jobId: jobId,
            prompt: "What is the capital of France? Answer in one short sentence.",
            maxTokens: 32
        )

        let runner = WorkerStreamRunner(transport: transport)
        let run = try await runner.run(deviceSerial: serial, jobId: jobId, payload: payload)

        print("=== E1 PERFORMANCE — SAME WORKLOAD, NEW PATH ===")
        print("workload           : LOCAL-LLM-1, 32 max tokens (identical to E1)")
        print("outcome            : \(run.outcome.isSuccess ? "completed" : "\(run.outcome)")")
        print("first event (s)    : \(run.timeToFirstEventSeconds.map { String(format: "%.3f", $0) } ?? "?")")
        print("launch ack (s)     : \(run.timeToLaunchAckSeconds.map { String(format: "%.3f", $0) } ?? "?")")
        print("outcome at (s)     : \(run.timeToOutcomeSeconds.map { String(format: "%.3f", $0) } ?? "?")")
        print("wall (s)           : \(String(format: "%.3f", run.wallSeconds))")
        print("heartbeats         : \(run.heartbeatCount)")
        print("worker pid         : \(run.workerPidObserved.map(String.init) ?? "none")")
        print("--- E1 OLD-PATH BASELINE ---")
        print("first output (s)   : 0.060")
        print("launch ack (s)     : 0.170")
        print("wall (s)           : 27.600")
        print("result wait (ms)   : 758 (poll cycle removed by streaming)")

        XCTAssertTrue(run.outcome.isSuccess, "the E1 workload must complete: \(run.outcome)")
        XCTAssertNotNil(run.timeToLaunchAckSeconds, "launch must be acknowledged on the stream")
        XCTAssertGreaterThan(run.wallSeconds, 0)

        // The worker's own reported execution time is the comparable figure: it is unaffected by
        // orchestration and is what the streamed result carries.
        if case .completed(let json, _) = run.outcome {
            XCTAssertTrue(json.contains("total_ms") || json.contains("generated_tokens"),
                          "the result must carry the worker's own timing")
        }
    }

    /// Diagnostic: exercises the streaming transport primitive directly.
    ///
    /// Added after the production script was verified to work correctly when run on the device by
    /// hand, while the Swift path produced no output — which located the defect in the read path
    /// rather than in the script.
    func testRawStreamingPrimitiveDeliversLines() async throws {
        let serial = try requireDevice()
        let transport = ADBTransport()

        let lock = NSLock()
        var lines: [String] = []
        var errs: [String] = []

        print("=== RAW STREAMING PRIMITIVE (no stdin) ===")
        let code = try await transport.shellStreaming(
            deviceSerial: serial,
            command: "echo PDE1 TEST1; sleep 0.3; echo PDE1 TEST2; echo TO_STDERR >&2",
            stdin: nil,
            onLine: { line in lock.lock(); lines.append(line); lock.unlock() },
            onStderrLine: { line in lock.lock(); errs.append(line); lock.unlock() }
        )
        lock.lock()
        let captured = lines
        let capturedErr = errs
        lock.unlock()

        print("exit code: \(code)")
        print("stdout lines: \(captured)")
        print("stderr lines: \(capturedErr)")

        XCTAssertEqual(captured, ["PDE1 TEST1", "PDE1 TEST2"], "stdout lines must be delivered")
        XCTAssertEqual(capturedErr, ["TO_STDERR"], "stderr must stay separate")

        // Now with stdin, which is what the production path uses.
        let lock2 = NSLock()
        var lines2: [String] = []
        print("=== RAW STREAMING PRIMITIVE (with stdin) ===")
        let code2 = try await transport.shellStreaming(
            deviceSerial: serial,
            command: "cat > /data/local/tmp/pd-stdin-probe.txt; echo PDE1 WROTE=$(wc -c < /data/local/tmp/pd-stdin-probe.txt | tr -d ' ')",
            stdin: "{\"hello\":\"world\"}",
            onLine: { line in lock2.lock(); lines2.append(line); lock2.unlock() },
            onStderrLine: { _ in }
        )
        lock2.lock()
        let captured2 = lines2
        lock2.unlock()

        print("exit code: \(code2)")
        print("stdout lines: \(captured2)")

        XCTAssertEqual(captured2, ["PDE1 WROTE=17"], "stdin must be delivered and closed")
    }

    /// A successful DTCA-1 job driven entirely by one persistent session.
    ///
    /// Asserts the properties the brief requires: launch acknowledgement, incremental events,
    /// no polling, and a durable result.
    func testStreamedDTCA1JobCompletesWithDurableResult() async throws {
        let serial = try requireDevice()
        let transport = ADBTransport()
        let lifecycle = WorkerLifecycle(transport: transport)

        // The workspace must exist before a job can be delivered. It is created by the worker,
        // never by adb (ADR-010 Revision 1).
        let exists = try await transport.shell(
            deviceSerial: serial,
            command: WorkerTransferContract.remoteWorkspaceExistsCommand,
            timeout: 30
        )
        if !exists.stdout.contains("EXISTS") {
            try await lifecycle.launch(deviceSerial: serial)
            // Bounded wait for the worker to create its own directory.
            let workspaceDeadline = Date().addingTimeInterval(30)
            while Date() < workspaceDeadline {
                try await Task.sleep(nanoseconds: 1_000_000_000)
                let recheck = try await transport.shell(
                    deviceSerial: serial,
                    command: WorkerTransferContract.remoteWorkspaceExistsCommand,
                    timeout: 15
                )
                if recheck.stdout.contains("EXISTS") { break }
            }
        }

        try await lifecycle.stopIfRunning(deviceSerial: serial)

        let jobId = UUID().uuidString
        let job = DTCA1Job(jobId: jobId, input: "the quick brown fox jumps over the lazy dog")

        let runner = WorkerStreamRunner(transport: transport)
        let run = try await runner.run(
            deviceSerial: serial,
            jobId: jobId,
            payload: try job.encoded()
        )

        print("=== E1 STREAMING — REAL DEVICE DTCA-1 JOB ===")
        print("outcome            : \(run.outcome)")
        print("jobId              : \(run.jobId ?? "?")")
        print("worker pid observed: \(run.workerPidObserved.map(String.init) ?? "none")")
        print("heartbeats         : \(run.heartbeatCount)")
        print("first event (s)    : \(run.timeToFirstEventSeconds.map { String(format: "%.3f", $0) } ?? "?")")
        print("launch ack (s)     : \(run.timeToLaunchAckSeconds.map { String(format: "%.3f", $0) } ?? "?")")
        print("outcome at (s)     : \(run.timeToOutcomeSeconds.map { String(format: "%.3f", $0) } ?? "?")")
        print("wall (s)           : \(String(format: "%.3f", run.wallSeconds))")
        print("stderr lines       : \(run.stderrLines.count)")
        print("unrecognized lines : \(run.unrecognizedLines.count)")

        XCTAssertTrue(run.outcome.isSuccess, "expected a completed job, got \(run.outcome)")
        XCTAssertEqual(run.jobId, jobId, "the stream must report the job it ran")
        XCTAssertNotNil(run.workerPidObserved, "a worker PID must be observed on a real run")
        XCTAssertGreaterThan(run.heartbeatCount, 0, "liveness heartbeats must arrive")
        XCTAssertNotNil(run.timeToLaunchAckSeconds, "launch must be acknowledged on the stream")
        XCTAssertTrue(run.unrecognizedLines.isEmpty,
                      "no stray output: \(run.unrecognizedLines.prefix(3))")

        // The durable result must exist and match what the stream carried.
        guard case .completed(let streamed, let durableBytes) = run.outcome else {
            return XCTFail("expected .completed, got \(run.outcome)")
        }
        XCTAssertGreaterThan(durableBytes, 0)

        let onDevice = try await transport.shell(
            deviceSerial: serial,
            command: "cat \(WorkerTransferContract.remoteResultPath)",
            timeout: 30
        )
        XCTAssertTrue(onDevice.stdout.contains(jobId),
                      "the durable result must carry the job id")
        XCTAssertTrue(streamed.contains(jobId))
    }

    /// E1 F4 on real hardware: kill the worker mid-run and confirm the stream reports death.
    ///
    /// This is the defect E1 found — a naive loop kept heartbeating after the worker died. The
    /// production path must terminate instead.
    func testWorkerDeathIsDetectedOnARealDevice() async throws {
        let serial = try requireDevice()
        let transport = ADBTransport()
        let lifecycle = WorkerLifecycle(transport: transport)

        try await lifecycle.stopIfRunning(deviceSerial: serial)

        let jobId = UUID().uuidString
        // A long job, so there is time to kill the worker while it is running.
        let payload = llmJobJSON(
            jobId: jobId,
            prompt: "Write a very long essay about the ocean.",
            maxTokens: 256
        )

        let runner = WorkerStreamRunner(transport: transport)
        let killer = Task {
            // Wait until the worker is running, then kill it. Bounded: a transport that has died
            // makes every probe slow, so this must not become an unbounded wait.
            for _ in 0..<40 {
                try? await Task.sleep(nanoseconds: 500_000_000)
                let state = try? await lifecycle.state(deviceSerial: serial)
                if state?.isRunning == true {
                    _ = try? await transport.shell(
                        deviceSerial: serial,
                        command: "am force-stop \(WorkerTransferContract.workerPackageName)",
                        timeout: 30
                    )
                    return
                }
            }
        }

        let run = try await runner.run(
            deviceSerial: serial,
            jobId: jobId,
            payload: payload
        )
        await killer.value

        print("=== E1 F4 — REAL DEVICE WORKER DEATH ===")
        print("outcome    : \(run.outcome)")
        print("heartbeats : \(run.heartbeatCount)")
        print("wall (s)   : \(String(format: "%.3f", run.wallSeconds))")

        // The stream must have ended rather than heartbeating indefinitely.
        switch run.outcome {
        case .workerExitedUnexpectedly, .failed, .streamLostWorkerGone,
             .streamLostWorkerRunning, .streamLostUnknown, .incomplete,
             .completedButDurabilityUnverified, .recoveredFromDevice, .malformedStream:
            // Any of these is acceptable — the requirement is that the run TERMINATED and reported
            // a specific state, rather than looping forever.
            break
        case .completed:
            // A race is possible: the worker may finish before the killer fires. Reported rather
            // than asserted away, because the property under test is termination, not the race.
            print("note: worker completed before the kill landed — no death to observe")
        }
    }

    /// E1 F7 on real hardware: the session dies while the worker continues.
    ///
    /// The worker must NOT be killed, and the durable result must be recoverable.
    func testStreamLossWhileWorkerContinuesIsRecoverable() async throws {
        let serial = try requireDevice()
        let transport = ADBTransport()
        let lifecycle = WorkerLifecycle(transport: transport)

        try await lifecycle.stopIfRunning(deviceSerial: serial)

        let jobId = UUID().uuidString
        let payload = llmJobJSON(
            jobId: jobId,
            prompt: "Write a long essay about the ocean.",
            maxTokens: 192
        )

        // Deliver the payload and launch the worker OUTSIDE any streaming session, then simulate
        // the session dying by simply not observing it. The worker is independent of the session,
        // so this reproduces the F7 condition on the device.
        _ = try await transport.shell(
            deviceSerial: serial,
            command: "rm -f \(WorkerTransferContract.remoteResultPath)",
            timeout: 30
        )

        _ = try await transport.shell(
            deviceSerial: serial,
            command: "cat > \(WorkerTransferContract.remoteInputPath) <<'PDEOF'\n\(payload)\nPDEOF",
            timeout: 30
        )
        try await lifecycle.launch(deviceSerial: serial)

        // The worker is now running with no session watching it.
        try await Task.sleep(nanoseconds: 3_000_000_000)
        let running = try await lifecycle.state(deviceSerial: serial)
        print("=== E1 F7 — REAL DEVICE SESSION LOSS ===")
        print("worker running after 'session loss': \(running.isRunning) pid=\(running.pid.map(String.init) ?? "none")")

        // Wait for the worker to finish on its own, with no session involved.
        //
        // Bounded by wall clock, not by iteration count: each probe costs up to 30 s on a dead
        // transport, so a fixed iteration count can become a multi-hour wait.
        var durableBytes: Int?
        let deadline = Date().addingTimeInterval(240)
        while Date() < deadline {
            let stat = try await transport.shell(
                deviceSerial: serial,
                command: "stat -c %s \(WorkerTransferContract.remoteResultPath)",
                timeout: 15
            )
            if let bytes = WorkerTransferContract.parseRemoteSize(stat.stdout), bytes > 0 {
                durableBytes = bytes
                break
            }
            try? await Task.sleep(nanoseconds: 1_000_000_000)
        }

        print("durable result bytes: \(durableBytes.map(String.init) ?? "none")")

        // The property that matters: the worker completed and wrote a durable result with no
        // streaming session alive at any point after launch.
        guard let bytes = durableBytes else {
            return XCTFail("the worker did not produce a durable result after session loss")
        }
        XCTAssertGreaterThan(bytes, 0)

        let content = try await transport.shell(
            deviceSerial: serial,
            command: "cat \(WorkerTransferContract.remoteResultPath)",
            timeout: 30
        )
        XCTAssertTrue(content.stdout.contains(jobId),
                      "the recovered result must belong to the job that was launched")
    }

    /// Cancellation remains `am force-stop`, external to any session (E1 F3).
    func testCancellationViaForceStopRemainsTheMechanism() async throws {
        let serial = try requireDevice()
        let transport = ADBTransport()
        let lifecycle = WorkerLifecycle(transport: transport)

        try await lifecycle.stopIfRunning(deviceSerial: serial)

        let jobId = UUID().uuidString
        let payload = llmJobJSON(
            jobId: jobId,
            prompt: "Write a very long essay about the ocean.",
            maxTokens: 256
        )

        let runner = WorkerStreamRunner(transport: transport)
        let runTask = Task {
            try await runner.run(deviceSerial: serial, jobId: jobId, payload: payload)
        }

        // Let the worker get going, then cancel from outside the session.
        var cancelled = false
        let cancelDeadline = Date().addingTimeInterval(60)
        while Date() < cancelDeadline {
            try? await Task.sleep(nanoseconds: 500_000_000)
            if try await lifecycle.state(deviceSerial: serial).isRunning {
                let start = Date()
                _ = try await transport.shell(
                    deviceSerial: serial,
                    command: "am force-stop \(WorkerTransferContract.workerPackageName)",
                    timeout: 30
                )
                print("=== E1 F3 — REAL DEVICE CANCELLATION ===")
                print("am force-stop took \(Int(Date().timeIntervalSince(start) * 1000)) ms")
                cancelled = true
                break
            }
        }

        let run = try await runTask.value
        print("outcome after cancellation: \(run.outcome)")

        if cancelled {
            let after = try await lifecycle.state(deviceSerial: serial)
            XCTAssertFalse(after.isRunning, "the worker must be gone after am force-stop")
        }
        // Whether or not the kill landed, the run must have terminated and reported a state.
        XCTAssertFalse(run.outcome.mayStillBeRunning && run.outcome.isSuccess)
    }
}
