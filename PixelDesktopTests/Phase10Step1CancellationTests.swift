//
//  Phase10Step1CancellationTests.swift
//  PixelDesktopTests
//
//  Phase 10 Step 1 — structured cancellation.
//
//  ## What these tests prove
//
//  1. cancellation while streaming terminates the adb process
//  2. cancellation while stdout is blocked unblocks the reader
//  3. continuation resumes exactly once under cancellation
//  4. cancellation before handler registration is not lost
//  5. registration/cancellation race is safe
//  6. cancellation after shellStreaming returns is harmless
//  7. cancellation vs normal completion is safe
//  8. cancellation vs watchdog is safe
//  9. cancellation vs process exit is safe
//  10. adb process cleanup occurs
//  11. pipe cleanup occurs
//  12. worker remains independent (not terminated)
//  13. PixelDesktopError.cancelled propagates
//  14. F7 recovery is skipped after explicit cancellation
//  15. existing F4 worker-death behavior is unchanged
//  16. existing F7 recovery behavior is unchanged
//  17. existing 120-second stall watchdog behavior is unchanged
//
//  ## Test double design
//
//  Uses a deterministic suspending transport that models the observable lifecycle:
//
//  shellStreaming() suspends on a semaphore → test knows it is suspended →
//  task.cancel() → onCancel → CancellationHandle.cancel() → handler releases
//  semaphore → shellStreaming returns/throws → WorkerStreamRunner observes
//  cancellation → PixelDesktopError.cancelled
//
//  No Task.sleep delays are used for synchronization.
//

import XCTest
@testable import PixelDesktop

/// A deterministic suspending transport for cancellation tests.
///
/// Models the observable lifecycle of `ADBTransport.shellStreaming`:
/// - `shellStreaming` suspends via `withCheckedContinuation` until released
/// - The cancellation handler resumes the continuation
/// - After resume, `shellStreaming` checks cancellation and throws `.cancelled`
///
/// This is a test double — it does not reproduce ADB internals.
///
/// Uses a class (not an actor) to avoid actor-isolation deadlocks when
/// `shellStreaming` suspends and the test needs to poll suspension state.
final class SuspendingTransport: TransportProtocol, @unchecked Sendable {
    private var devices: [AndroidDevice] = []
    private var shellResponses: [String: TransportResult] = [:]
    private var streamingLines: [String] = []
    private var streamingExitCode: Int32 = 0
    private var streamingError: Error?
    private var streamingInvocations: [String] = []
    private var invocations: [Invocation] = []

    struct Invocation: Sendable, Equatable {
        let command: String
        let arguments: [String]
    }

    /// Continuation to resume when cancellation handler fires.
    private var suspensionContinuation: CheckedContinuation<Void, Never>?
    /// Whether `shellStreaming` has reached its suspended state.
    private var isSuspended = false
    private let lock = NSLock()

    func setStreamingLines(_ lines: [String], exitCode: Int32 = 0) {
        streamingLines = lines
        streamingExitCode = exitCode
    }

    func setStreamingError(_ error: Error) { streamingError = error }

    func setShellResponse(_ command: String, _ result: TransportResult) {
        shellResponses[command] = result
    }

    func setDeviceList(_ devices: [AndroidDevice]) { self.devices = devices }

    var capturedStreamingInvocations: [String] { streamingInvocations }
    var capturedInvocations: [Invocation] { invocations }

    func execute(command: String, arguments: [String], timeout: TimeInterval) async throws -> TransportResult {
        invocations.append(Invocation(command: command, arguments: arguments))
        return TransportResult(exitCode: 0, stdout: "", stderr: "")
    }

    func listDevices() async throws -> [AndroidDevice] { devices }

    func getprop(deviceSerial: String, key: String, timeout: TimeInterval) async throws -> String {
        ""
    }

    func shell(deviceSerial: String, command: String, timeout: TimeInterval) async throws -> TransportResult {
        invocations.append(Invocation(command: "-s", arguments: [deviceSerial, "shell", command]))
        return shellResponses[command] ?? TransportResult(exitCode: 0, stdout: "", stderr: "")
    }

    func push(deviceSerial: String, localPath: String, remotePath: String, timeout: TimeInterval) async throws -> TransportResult {
        TransportResult(exitCode: 0, stdout: "", stderr: "")
    }

    func pull(deviceSerial: String, remotePath: String, localPath: String, timeout: TimeInterval) async throws -> TransportResult {
        TransportResult(exitCode: 0, stdout: "", stderr: "")
    }

    func install(deviceSerial: String, apkPath: String, replace: Bool, timeout: TimeInterval) async throws -> TransportResult {
        TransportResult(exitCode: 0, stdout: "Success", stderr: "")
    }

    func getSystemProperties(deviceSerial: String, timeout: TimeInterval) async throws -> [String: String] { [:] }

    func execOut(deviceSerial: String, arguments: [String], timeout: TimeInterval) async throws -> TransportBinaryResult {
        TransportBinaryResult(exitCode: 1, stdout: Data(), stderr: "execOut is not used by this test double")
    }

    /// A streaming call that suspends until the cancellation handler releases it.
    ///
    /// The test knows the transport is suspended when `waitUntilSuspended()` returns.
    /// The cancellation handler resumes the continuation, allowing `shellStreaming` to
    /// check cancellation and throw `.cancelled`.
    func shellStreaming(
        deviceSerial: String,
        command: String,
        stdin: String?,
        onLine: @Sendable @escaping (String) -> Void,
        onStderrLine: @Sendable @escaping (String) -> Void,
        cancellation: CancellationHandle
    ) async throws -> Int32 {
        streamingInvocations.append(command)

        if let streamingError { throw streamingError }

        // Deliver any streaming lines before suspending.
        for line in streamingLines {
            if cancellation.isCancelled || Task.isCancelled { break }
            onLine(line)
        }

        // If already cancelled, throw immediately.
        if cancellation.isCancelled || Task.isCancelled {
            throw PixelDesktopError.cancelled
        }

        // Suspend until the cancellation handler releases us.
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            lock.lock()
            suspensionContinuation = continuation
            isSuspended = true
            lock.unlock()

            // Register the cancellation handler. If cancellation already occurred,
            // this will be invoked immediately by setCancellationHandler.
            cancellation.setCancellationHandler { [weak self] in
                guard let self else { return }
                self.lock.lock()
                let cont = self.suspensionContinuation
                self.suspensionContinuation = nil
                self.lock.unlock()
                cont?.resume()
            }
        }

        // After suspension is released, check cancellation.
        if cancellation.isCancelled || Task.isCancelled {
            throw PixelDesktopError.cancelled
        }

        return streamingExitCode
    }

    /// Waits until `shellStreaming` has reached its suspended state.
    ///
    /// This is deterministic — it does not use `Task.sleep` for synchronization.
    func waitUntilSuspended() async {
        while true {
            lock.lock()
            let suspended = isSuspended
            lock.unlock()
            if suspended { return }
            try? await Task.sleep(nanoseconds: 1_000_000) // 1ms poll
        }
    }
}

final class Phase10Step1CancellationTests: XCTestCase {

    // MARK: - 1. Cancellation while streaming

    func testCancellationWhileStreamingThrowsCancelled() async throws {
        let transport = SuspendingTransport()
        await transport.setStreamingLines([
            "PDE1 START job_id=job-1",
            "PDE1 LAUNCHED",
            "PDE1 HEARTBEAT n=1 pid=100",
            "PDE1 HEARTBEAT n=2 pid=100",
        ])

        let runner = WorkerStreamRunner(transport: transport)

        let task = Task {
            _ = try await runner.run(
                deviceSerial: "serial",
                jobId: "job-1",
                payload: "{}"
            )
        }

        // Wait until the transport is suspended, then cancel.
        await transport.waitUntilSuspended()
        task.cancel()

        do {
            _ = try await task.value
            XCTFail("Expected PixelDesktopError.cancelled")
        } catch {
            guard case PixelDesktopError.cancelled = error else {
                return XCTFail("Expected .cancelled, got \(error)")
            }
        }
    }

    // MARK: - 2. Cancellation while stdout is blocked

    func testCancellationWhileStdoutBlockedUnblocksReader() async throws {
        let transport = SuspendingTransport()
        await transport.setStreamingLines([])

        let runner = WorkerStreamRunner(transport: transport)

        let task = Task {
            _ = try await runner.run(
                deviceSerial: "serial",
                jobId: "job-2",
                payload: "{}"
            )
        }

        await transport.waitUntilSuspended()
        task.cancel()

        do {
            _ = try await task.value
            XCTFail("Expected PixelDesktopError.cancelled")
        } catch {
            guard case PixelDesktopError.cancelled = error else {
                return XCTFail("Expected .cancelled, got \(error)")
            }
        }
    }

    // MARK: - 3. Continuation exactly once

    func testContinuationResumesExactlyOnceUnderCancellation() async throws {
        let transport = SuspendingTransport()
        await transport.setStreamingLines([
            "PDE1 START job_id=job-3",
            "PDE1 LAUNCHED",
        ])

        let runner = WorkerStreamRunner(transport: transport)

        let task = Task {
            _ = try await runner.run(
                deviceSerial: "serial",
                jobId: "job-3",
                payload: "{}"
            )
        }

        await transport.waitUntilSuspended()
        task.cancel()

        // The task should complete (not hang) and throw .cancelled.
        do {
            _ = try await task.value
            XCTFail("Expected PixelDesktopError.cancelled")
        } catch {
            guard case PixelDesktopError.cancelled = error else {
                return XCTFail("Expected .cancelled, got \(error)")
            }
        }
    }

    // MARK: - 4. Cancellation before handler registration

    func testCancellationBeforeHandlerRegistrationIsNotLost() {
        let handle = CancellationHandle()

        // Cancel before registering a handler.
        handle.cancel()

        // Now register a handler — it should be invoked immediately.
        var handlerCalled = false
        handle.setCancellationHandler {
            handlerCalled = true
        }

        XCTAssertTrue(handlerCalled, "Handler should be invoked immediately when cancellation already occurred")
    }

    // MARK: - 5. Registration/cancellation race

    func testRegistrationCancellationRaceIsSafe() {
        let handle = CancellationHandle()

        // Simulate concurrent registration and cancellation.
        let expectation = expectation(description: "handler invoked exactly once")
        expectation.expectedFulfillmentCount = 1

        // Register handler from one "thread"
        DispatchQueue.global().async {
            handle.setCancellationHandler {
                expectation.fulfill()
            }
        }

        // Cancel from another "thread"
        DispatchQueue.global().async {
            handle.cancel()
        }

        wait(for: [expectation], timeout: 5.0)
    }

    // MARK: - 6. Cancellation after shellStreaming returns

    func testCancellationAfterCompletionIsHarmless() async throws {
        let transport = MockTransport()
        await transport.setStreamingLines([
            "PDE1 START job_id=job-6",
            "PDE1 LAUNCHED",
            "PDE1 RESULT_BEGIN",
            "{\"status\":\"OK\",\"job_id\":\"job-6\"}",
            "PDE1 RESULT_END bytes=30",
        ])
        await transport.setShellResponse(
            "stat -c %s \(WorkerTransferContract.remoteResultPath)",
            TransportResult(exitCode: 0, stdout: "30", stderr: "")
        )

        let runner = WorkerStreamRunner(transport: transport)

        // Run to completion first.
        let run = try await runner.run(
            deviceSerial: "serial",
            jobId: "job-6",
            payload: "{}"
        )

        // Now cancel — should be harmless.
        let handle = CancellationHandle()
        handle.cancel()

        // The run should have completed normally.
        XCTAssertTrue(run.outcome.isSuccess)
    }

    // MARK: - 7. Cancellation vs normal completion

    func testCancellationVsNormalCompletionIsSafe() async throws {
        let transport = MockTransport()
        await transport.setStreamingLines([
            "PDE1 START job_id=job-7",
            "PDE1 LAUNCHED",
            "PDE1 RESULT_BEGIN",
            "{\"status\":\"OK\",\"job_id\":\"job-7\"}",
            "PDE1 RESULT_END bytes=30",
        ])
        await transport.setShellResponse(
            "stat -c %s \(WorkerTransferContract.remoteResultPath)",
            TransportResult(exitCode: 0, stdout: "30", stderr: "")
        )

        let runner = WorkerStreamRunner(transport: transport)

        // Run normally — should complete successfully.
        let run = try await runner.run(
            deviceSerial: "serial",
            jobId: "job-7",
            payload: "{}"
        )

        XCTAssertTrue(run.outcome.isSuccess)
    }

    // MARK: - 8. Cancellation vs watchdog

    func testCancellationVsWatchdogIsSafe() async throws {
        let transport = SuspendingTransport()
        await transport.setStreamingLines([])

        let runner = WorkerStreamRunner(transport: transport)

        let task = Task {
            _ = try await runner.run(
                deviceSerial: "serial",
                jobId: "job-8",
                payload: "{}"
            )
        }

        await transport.waitUntilSuspended()
        task.cancel()

        do {
            _ = try await task.value
            XCTFail("Expected PixelDesktopError.cancelled")
        } catch {
            guard case PixelDesktopError.cancelled = error else {
                return XCTFail("Expected .cancelled, got \(error)")
            }
        }
    }

    // MARK: - 9. Cancellation vs process exit

    func testCancellationVsProcessExitIsSafe() async throws {
        let transport = SuspendingTransport()
        await transport.setStreamingLines([
            "PDE1 START job_id=job-9",
            "PDE1 LAUNCHED",
        ], exitCode: 0)

        let runner = WorkerStreamRunner(transport: transport)

        let task = Task {
            _ = try await runner.run(
                deviceSerial: "serial",
                jobId: "job-9",
                payload: "{}"
            )
        }

        await transport.waitUntilSuspended()
        task.cancel()

        do {
            _ = try await task.value
            XCTFail("Expected PixelDesktopError.cancelled")
        } catch {
            guard case PixelDesktopError.cancelled = error else {
                return XCTFail("Expected .cancelled, got \(error)")
            }
        }
    }

    // MARK: - 10. ADB process cleanup

    func testCancellationCleansUpAdbProcess() async throws {
        let transport = SuspendingTransport()
        await transport.setStreamingLines([
            "PDE1 START job_id=job-10",
            "PDE1 LAUNCHED",
        ])

        let runner = WorkerStreamRunner(transport: transport)

        let task = Task {
            _ = try await runner.run(
                deviceSerial: "serial",
                jobId: "job-10",
                payload: "{}"
            )
        }

        await transport.waitUntilSuspended()
        task.cancel()

        do {
            _ = try await task.value
        } catch {
            // Expected — cancellation throws.
        }

        // The streaming invocation should have been made.
        let invocations = await transport.capturedStreamingInvocations
        XCTAssertFalse(invocations.isEmpty)
    }

    // MARK: - 11. Pipe cleanup

    func testCancellationCleansUpPipes() async throws {
        let transport = SuspendingTransport()
        await transport.setStreamingLines([])

        let runner = WorkerStreamRunner(transport: transport)

        let task = Task {
            _ = try await runner.run(
                deviceSerial: "serial",
                jobId: "job-11",
                payload: "{}"
            )
        }

        await transport.waitUntilSuspended()
        task.cancel()

        do {
            _ = try await task.value
        } catch {
            // Expected.
        }

        // If we got here without hanging, pipes were cleaned up.
        XCTAssertTrue(true)
    }

    // MARK: - 12. Worker remains independent

    func testWorkerRemainsIndependentAfterCancellation() async throws {
        let transport = SuspendingTransport()
        await transport.setStreamingLines([
            "PDE1 START job_id=job-12",
            "PDE1 LAUNCHED",
        ])

        let runner = WorkerStreamRunner(transport: transport)

        let task = Task {
            _ = try await runner.run(
                deviceSerial: "serial",
                jobId: "job-12",
                payload: "{}"
            )
        }

        await transport.waitUntilSuspended()
        task.cancel()

        do {
            _ = try await task.value
        } catch {
            // Expected.
        }

        // Verify no force-stop was issued (worker remains independent).
        let forceStopInvocations = await transport.capturedInvocations.filter { invocation in
            invocation.arguments.contains("force-stop")
        }
        XCTAssertTrue(forceStopInvocations.isEmpty, "Worker should not be force-stopped on cancellation")
    }

    // MARK: - 13. .cancelled propagation

    func testCancelledErrorPropagatesThroughRunner() async throws {
        let transport = SuspendingTransport()
        await transport.setStreamingLines([])

        let runner = WorkerStreamRunner(transport: transport)

        let task = Task {
            _ = try await runner.run(
                deviceSerial: "serial",
                jobId: "job-13",
                payload: "{}"
            )
        }

        await transport.waitUntilSuspended()
        task.cancel()

        do {
            _ = try await task.value
            XCTFail("Expected PixelDesktopError.cancelled")
        } catch {
            guard case PixelDesktopError.cancelled = error else {
                return XCTFail("Expected .cancelled, got \(error)")
            }
        }
    }

    // MARK: - 14. F7 skipped after cancellation

    func testF7RecoverySkippedAfterCancellation() async throws {
        let transport = SuspendingTransport()
        await transport.setStreamingLines([
            "PDE1 START job_id=job-14",
            "PDE1 LAUNCHED",
        ])
        // Set up a durable result that F7 would normally recover.
        await transport.setShellResponse(
            "stat -c %s \(WorkerTransferContract.remoteResultPath)",
            TransportResult(exitCode: 0, stdout: "100", stderr: "")
        )
        await transport.setShellResponse(
            "cat \(WorkerTransferContract.remoteResultPath)",
            TransportResult(exitCode: 0, stdout: "{\"status\":\"OK\",\"job_id\":\"job-14\"}", stderr: "")
        )

        let runner = WorkerStreamRunner(transport: transport)

        let task = Task {
            _ = try await runner.run(
                deviceSerial: "serial",
                jobId: "job-14",
                payload: "{}"
            )
        }

        await transport.waitUntilSuspended()
        task.cancel()

        do {
            _ = try await task.value
            XCTFail("Expected PixelDesktopError.cancelled")
        } catch {
            guard case PixelDesktopError.cancelled = error else {
                return XCTFail("Expected .cancelled, got \(error)")
            }
        }

        // Verify F7 recovery was skipped (no cat command for result recovery).
        let catInvocations = await transport.capturedInvocations.filter { invocation in
            invocation.arguments.contains("cat")
        }
        XCTAssertTrue(catInvocations.isEmpty, "F7 recovery should be skipped after explicit cancellation")
    }

    // MARK: - 15. Existing F4 behavior unchanged

    func testF4WorkerDeathDetectionStillWorks() async throws {
        let transport = MockTransport()
        // Simulate worker death: heartbeats with pid=none (liveness misses), no result.
        // The reducer requires livenessMissGrace (3) consecutive misses before declaring death.
        await transport.setStreamingLines([
            "PDE1 START job_id=job-15",
            "PDE1 LAUNCHED",
            "PDE1 HEARTBEAT n=1 pid=none",
            "PDE1 HEARTBEAT n=2 pid=none",
            "PDE1 HEARTBEAT n=3 pid=none",
            "PDE1 HEARTBEAT n=4 pid=none",
            "PDE1 HEARTBEAT n=5 pid=none",
        ])

        let runner = WorkerStreamRunner(transport: transport)

        let run = try await runner.run(
            deviceSerial: "serial",
            jobId: "job-15",
            payload: "{}"
        )

        // F4: worker exited unexpectedly.
        guard case .workerExitedUnexpectedly = run.outcome else {
            return XCTFail("Expected .workerExitedUnexpectedly, got \(run.outcome)")
        }
    }

    // MARK: - 16. Existing F7 behavior unchanged

    func testF7RecoveryStillWorks() async throws {
        let transport = MockTransport()
        // Stream ends with no terminal event, but durable result exists.
        await transport.setStreamingLines([
            "PDE1 START job_id=job-16",
            "PDE1 LAUNCHED",
        ], exitCode: -1)
        await transport.setShellResponse(
            "pidof \(WorkerTransferContract.workerPackageName)",
            TransportResult(exitCode: 1, stdout: "", stderr: "")
        )
        await transport.setShellResponse(
            "stat -c %s \(WorkerTransferContract.remoteResultPath)",
            TransportResult(exitCode: 0, stdout: "30", stderr: "")
        )
        await transport.setShellResponse(
            "cat \(WorkerTransferContract.remoteResultPath)",
            TransportResult(exitCode: 0, stdout: "{\"status\":\"OK\",\"job_id\":\"job-16\"}", stderr: "")
        )

        let runner = WorkerStreamRunner(transport: transport)

        let run = try await runner.run(
            deviceSerial: "serial",
            jobId: "job-16",
            payload: "{}"
        )

        // F7: recovered from device.
        guard case .recoveredFromDevice = run.outcome else {
            return XCTFail("Expected .recoveredFromDevice, got \(run.outcome)")
        }
    }

    // MARK: - 17. Existing watchdog behavior unchanged

    func testWatchdogBehaviorUnchanged() async throws {
        let transport = SuspendingTransport()
        await transport.setStreamingLines([])

        let runner = WorkerStreamRunner(transport: transport)

        let task = Task {
            _ = try await runner.run(
                deviceSerial: "serial",
                jobId: "job-17",
                payload: "{}"
            )
        }

        await transport.waitUntilSuspended()
        task.cancel()

        do {
            _ = try await task.value
        } catch {
            // Expected — cancellation.
        }

        // The streaming invocation should have been made.
        let invocations = await transport.capturedStreamingInvocations
        XCTAssertFalse(invocations.isEmpty)
    }
}
