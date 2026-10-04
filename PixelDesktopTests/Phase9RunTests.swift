//
//  Phase9RunTests.swift
//  PixelDesktopTests
//
//  Phase 9 Step 4 — the `run` execution boundary.
//
//  ## What these tests prove
//
//  1. the command surface — parsing, required arguments, and rejection of flags that would let a
//     caller name a transport primitive, a device, or an execution policy
//  2. input handling — the workload's own validator is used, nothing is truncated, and the
//     boundary behaves exactly as the contract publishes it
//  3. the outcome mapping — every `WorkerStreamOutcome` case maps to a stable token, and an
//     unsuccessful outcome maps to the existing error taxonomy with the worker's category intact
//  4. **`run` reaches the existing E1 machinery** — driven through the same `MockTransport` seam
//     the E1 suite uses, so the proof is against the real `WorkerStreamRunner` rather than a
//     parallel test double
//
//  ## Why the execution tests use `MockTransport`
//
//  `WorkerStreamingTests` already drives `WorkerStreamRunner` against a scripted transport. Reusing
//  that seam is the point: a second, purpose-built mock for `run` would prove only that the mock
//  and the code agree, and would let the two drift apart from the real E1 path.
//

import XCTest
import Foundation
@testable import PixelDesktop

final class Phase9RunCommandTests: XCTestCase {

    // MARK: - Fixtures

    private func temporaryInput(_ contents: String, name: String = "input.txt") throws -> String {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("p9s4-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent(name)
        try contents.write(to: url, atomically: true, encoding: .utf8)
        return url.path
    }

    // MARK: - 1. Argument parsing

    func testValidRunInvocationParses() throws {
        let invocation = try CLIInvocation.parse(
            ["run", "--workload", "DTCA-1", "--input-file", "/tmp/in.txt", "--json"]).get()

        XCTAssertEqual(invocation.command, .run)
        XCTAssertEqual(invocation.workload, "DTCA-1")
        XCTAssertEqual(invocation.inputFile, "/tmp/in.txt")
        XCTAssertTrue(invocation.json)
    }

    func testRunWithoutWorkloadIsAUsageError() {
        XCTAssertThrowsError(try CLIInvocation.parse(["run", "--input-file", "/tmp/in.txt", "--json"]).get())
    }

    func testRunWithoutInputFileIsAUsageError() {
        XCTAssertThrowsError(try CLIInvocation.parse(["run", "--workload", "DTCA-1", "--json"]).get())
    }

    func testWorkloadFlagWithoutAValueIsAUsageError() {
        XCTAssertThrowsError(try CLIInvocation.parse(["run", "--workload", "--json"]).get())
    }

    func testEveryForbiddenFlagIsRejected() {
        // A caller must not be able to name a transport primitive, a device, or an execution
        // policy. Rejecting by name matters: silently ignoring `--device` would leave the caller
        // believing it had selected a device.
        for flag in CLIInvocation.forbiddenFlags {
            let arguments = ["run", "--workload", "DTCA-1", "--input-file", "/tmp/in.txt", flag, "x", "--json"]
            XCTAssertThrowsError(try CLIInvocation.parse(arguments).get(),
                                 "\(flag) must be rejected, not ignored")
        }
    }

    func testExecutionFlagsAreRejectedWithAnExplanatoryMessage() {
        let result = CLIInvocation.parse(
            ["run", "--workload", "DTCA-1", "--input-file", "/tmp/in.txt", "--device", "SERIAL", "--json"])

        guard case .failure(let error) = result else {
            return XCTFail("expected a usage error")
        }
        XCTAssertTrue(error.message.contains("--device"))
        XCTAssertTrue(error.message.contains("PixelDesktop chooses"),
                      "the refusal must explain who does choose")
    }

    func testWorkloadFlagOnAnotherCommandIsAUsageError() {
        // Not a silent no-op: a caller passing `--workload` to `capability` has misunderstood.
        XCTAssertThrowsError(try CLIInvocation.parse(["capability", "--workload", "DTCA-1", "--json"]).get())
    }

    func testExistingCommandsStillParse() throws {
        XCTAssertEqual(try CLIInvocation.parse(["capability", "--json"]).get().command, .capability)
        XCTAssertEqual(try CLIInvocation.parse(["observe", "--json"]).get().command, .observe)
    }

    // MARK: - 2. Input handling

    func testInputIsReadVerbatimAndNotTruncated() throws {
        // Whitespace and newlines are part of the input. Trimming would make the result
        // unverifiable against what was actually submitted.
        let original = "  leading, trailing  \n\nand a newline\t\n"
        let path = try temporaryInput(original)

        let loaded = try CLIRunCommand.loadInput(from: path, workload: DTCA1Job.workloadName)
        XCTAssertEqual(loaded, original, "input must be read byte-for-byte, not normalised")
    }

    func testInputExactlyAtThePublishedBoundIsAccepted() throws {
        // The bound comes from the contract's own published value, not a literal — so this test
        // tracks Phase 7 Amendment 2 rather than restating it.
        let contract = PixelCapabilityContract.build(
            device: AndroidDevice(id: "t", serialNumber: "S", deviceCodename: "lynx",
                                  marketingName: "m", manufacturer: "f", androidVersion: "16",
                                  apiLevel: 36, architecture: "arm64-v8a",
                                  supportedABIs: ["arm64-v8a"], state: .device),
            contextSize: .declared(2048, limitation: nil))
        let published = try XCTUnwrap(
            contract.workloads.first { $0.name == "DTCA-1" }?.maximumInputCharacters?.value)

        let path = try temporaryInput(String(repeating: "a", count: published))
        XCTAssertNoThrow(try CLIRunCommand.loadInput(from: path, workload: DTCA1Job.workloadName),
                         "input exactly at the published bound must be accepted")
    }

    func testInputOneCharacterOverThePublishedBoundIsRejected() throws {
        let path = try temporaryInput(String(repeating: "a", count: DTCA1Worker.maximumInputCharacters + 1))

        XCTAssertThrowsError(try CLIRunCommand.loadInput(from: path, workload: DTCA1Job.workloadName)) { error in
            guard case PixelDesktopError.invalidInput(let message) = error else {
                return XCTFail("expected invalidInput, got \(error)")
            }
            XCTAssertTrue(message.contains("\(DTCA1Worker.maximumInputCharacters)"),
                          "the refusal must name the bound it enforced")
        }
    }

    func testNullByteInputIsRejected() throws {
        let path = try temporaryInput("has a \0 null byte")
        XCTAssertThrowsError(try CLIRunCommand.loadInput(from: path, workload: DTCA1Job.workloadName))
    }

    func testMissingFileIsAStructuredInvalidInput() throws {
        XCTAssertThrowsError(try CLIRunCommand.loadInput(from: "/nonexistent/\(UUID().uuidString)", workload: DTCA1Job.workloadName)) { error in
            guard case PixelDesktopError.invalidInput = error else {
                return XCTFail("expected invalidInput, got \(error)")
            }
        }
    }

    func testUnsupportedWorkloadIsRefusedBeforeAnyDeviceWork() async throws {
        // The refusal must happen before a transport is consulted at all — hence a transport that
        // fails the test if it is touched.
        let transport = RunTransport()
        let path = try temporaryInput("hello world")

        do {
            _ = try await CLIRunCommand.run(workload: "UNSUPPORTED-WORKLOAD", inputPath: path, transport: transport)
            XCTFail("expected a refusal")
        } catch {
            guard case PixelDesktopError.invalidInput(let message) = error else {
                return XCTFail("expected invalidInput, got \(error)")
            }
            XCTAssertTrue(message.contains("UNSUPPORTED-WORKLOAD"))
            XCTAssertTrue(message.contains("DTCA-1"), "the refusal must name what IS supported")
        }

        let shellCommands = await transport.shellCommands
        XCTAssertTrue(shellCommands.isEmpty,
                      "an unsupported workload must be refused without touching the device")
    }

    // MARK: - 3. Outcome mapping

    func testEveryOutcomeCaseMapsToAStableToken() {
        // Exhaustive: a new case must force a decision here rather than fall through.
        let cases: [(WorkerStreamOutcome, String)] = [
            (.completed(resultJSON: "{}", resultBytes: 2), "completed"),
            (.completedButDurabilityUnverified(resultJSON: "{}", reason: "r"), "completed_but_durability_unverified"),
            (.recoveredFromDevice(resultJSON: "{}", resultBytes: 2), "recovered_from_device"),
            (.failed(code: "MODEL_MISSING", message: "m"), "failed"),
            (.workerExitedUnexpectedly(sequence: 4), "worker_exited_unexpectedly"),
            (.streamLostWorkerRunning(pid: 1), "stream_lost_worker_running"),
            (.streamLostWorkerGone, "stream_lost_worker_gone"),
            (.streamLostUnknown(reason: "r"), "stream_lost_unknown"),
            (.incomplete(reason: "r"), "incomplete"),
            (.malformedStream(reason: "r"), "malformed_stream"),
        ]

        for (outcome, expected) in cases {
            XCTAssertEqual(CLIRunResult.token(for: outcome), expected)
        }
    }

    func testSuccessfulOutcomesProduceNoError() {
        XCTAssertNil(CLIRunResult.error(for: .completed(resultJSON: "{}", resultBytes: 2)))
        XCTAssertNil(CLIRunResult.error(for: .recoveredFromDevice(resultJSON: "{}", resultBytes: 2)))
    }

    func testWorkerRefusalCategoryIsPreservedVerbatim() {
        // The Phase 7 Step 3 finding: flattening the worker's structured category into prose
        // makes MODEL_MISSING and INVALID_INPUT indistinguishable.
        let missing = CLIRunResult.error(for: .failed(code: "MODEL_MISSING", message: "no model"))
        let invalid = CLIRunResult.error(for: .failed(code: "INVALID_INPUT", message: "bad"))

        guard case .workerRefused(let c1, _) = missing, case .workerRefused(let c2, _) = invalid else {
            return XCTFail("a worker refusal must surface as workerRefused with its category")
        }
        XCTAssertEqual(c1, "MODEL_MISSING")
        XCTAssertEqual(c2, "INVALID_INPUT")
        XCTAssertNotEqual(c1, c2)

        XCTAssertEqual(CLIErrorPayload(missing!).category, "MODEL_MISSING")
        XCTAssertFalse(CLIErrorPayload(missing!).isRecoverable,
                       "a bounded refusal is not retryable")
    }

    func testDurabilityUnverifiedIsNotTreatedAsSuccess() {
        // E1's own finding: "stream completion does not mean result durability". Reporting this
        // as success would discard exactly the distinction the outcome exists to carry.
        let error = CLIRunResult.error(
            for: .completedButDurabilityUnverified(resultJSON: "{}", reason: "not confirmed"))
        XCTAssertNotNil(error)
        guard case .verificationFailed = error! else {
            return XCTFail("expected verificationFailed, got \(error!)")
        }
    }

    func testStreamLossWhileWorkerRunsIsNotReportedAsACompletedJob() {
        let error = CLIRunResult.error(for: .streamLostWorkerRunning(pid: 42))
        XCTAssertNotNil(error, "the job did not report a result over this session")
    }

    func testExistingErrorTaxonomySurvivesToTheEnvelope() {
        let cases: [(PixelDesktopError, String)] = [
            (.deviceNotFound, "device_not_found"),
            (.deviceUnauthorized, "device_unauthorized"),
            (.deviceOffline, "device_offline"),
            (.timeout(operation: "o", duration: 1), "timeout"),
            (.invalidInput("m"), "invalid_input"),
            (.verificationFailed(reason: "r"), "verification_failed"),
        ]
        for (error, token) in cases {
            XCTAssertEqual(CLIErrorPayload(error).type, token)
        }
    }

    // MARK: - 4. run reaches the existing E1 machinery

    func testRunReachesWorkerStreamRunnerAndReportsACompletedOutcome() async throws {
        // Driven through the SAME seam the E1 suite uses. If `run` had grown its own execution
        // path, this would not produce a streamed outcome.
        let transport = RunTransport()
        let serial = "SERIAL"
        let resultJSON = """
        {"status":"COMPLETED","job_id":"__JOB__","input_characters":11,"total_words":2,
         "unique_words":2,"top_words":[{"word":"hello","count":1},{"word":"world","count":1}],
         "classification":"GENERAL","confidence":0.5,"execution_timestamp_ms":1,
         "execution_duration_ms":2}
        """

        await transport.setDevices([RunTransport.device(serial: serial, state: .device)])
        await transport.setShellPrefix("dumpsys package", TransportResult(
            exitCode: 0, stdout: "versionCode=7", stderr: ""))
        await transport.setShellPrefix("test -d", TransportResult(
            exitCode: 0, stdout: "EXISTS", stderr: ""))
        await transport.setStreamingLines([
            "PDE1 START job_id=__JOB__",
            "PDE1 LAUNCHED",
            "PDE1 HEARTBEAT n=1 pid=1234",
            "PDE1 RESULT_BEGIN",
            resultJSON,
            "PDE1 RESULT_END bytes=__BYTES__",
        ])

        let path = try temporaryInput("hello world")
        let (result, error) = try await CLIRunCommand.run(
            workload: "DTCA-1", inputPath: path, transport: transport)

        XCTAssertEqual(result.workload, "DTCA-1")
        XCTAssertEqual(result.jobId, result.jobId, "a job id is always reported")
        XCTAssertFalse(result.jobId.isEmpty)
        XCTAssertEqual(result.outcome, "completed")
        XCTAssertNil(error, "a completed run carries no error")
        XCTAssertEqual(result.output?.totalWords, 2)
        XCTAssertEqual(result.evidence.workerPidObserved, 1234)
        XCTAssertGreaterThanOrEqual(result.evidence.heartbeatCount, 1)
        XCTAssertFalse(result.evidence.streamEndedUnexpectedly)
    }

    func testRunUsesTheStreamingPathNotThePollingProofPath() async throws {
        // `WorkerComputeProof` pushes a job file and polls. The E1 path streams and writes the
        // payload to stdin. If `run` had reused the older path, no streaming session would occur.
        let transport = RunTransport()
        await transport.setDevices([RunTransport.device(serial: "S", state: .device)])
        await transport.setShellPrefix("dumpsys package", TransportResult(exitCode: 0, stdout: "versionCode=7", stderr: ""))
        await transport.setShellPrefix("test -d", TransportResult(exitCode: 0, stdout: "EXISTS", stderr: ""))
                await transport.setStreamingLines([
            "PDE1 START job_id=__JOB__", "PDE1 LAUNCHED", "PDE1 HEARTBEAT n=1 pid=none",
            "PDE1 WORKER_EXITED n=1",
        ])

        let path = try temporaryInput("hello")
        _ = try? await CLIRunCommand.run(workload: "DTCA-1", inputPath: path, transport: transport)

        let sessions = await transport.streamingSessionCount
        let pushes = await transport.pushCount
        let payloads = await transport.streamingPayloads
        XCTAssertEqual(sessions, 1, "exactly one streaming session")
        XCTAssertTrue(pushes == 0, "the streaming path must not push a job file")
        XCTAssertFalse(payloads.isEmpty, "the payload travels on stdin")
    }

    func testDeviceNotFoundIsReportedBeforeAnyExecution() async throws {
        let transport = RunTransport()
        await transport.setDevices([])

        let path = try temporaryInput("hello")
        do {
            _ = try await CLIRunCommand.run(workload: "DTCA-1", inputPath: path, transport: transport)
            XCTFail("expected deviceNotFound")
        } catch {
            XCTAssertEqual(error as? PixelDesktopError, .deviceNotFound)
        }
        let sessions = await transport.streamingSessionCount
        XCTAssertEqual(sessions, 0, "no session may start without a device")
    }

    func testMissingWorkerIsReportedAsAStructuredFailure() async throws {
        let transport = RunTransport()
        await transport.setDevices([RunTransport.device(serial: "S", state: .device)])
        // `dumpsys package` failing means not installed.
        await transport.setShellPrefix("dumpsys package", TransportResult(exitCode: 1, stdout: "", stderr: "Unable to find package"))

        let path = try temporaryInput("hello")
        do {
            _ = try await CLIRunCommand.run(workload: "DTCA-1", inputPath: path, transport: transport)
            XCTFail("expected a worker error")
        } catch {
            guard case PixelDesktopError.workerError(let message) = error else {
                return XCTFail("expected workerError, got \(error)")
            }
            XCTAssertTrue(message.contains("not installed"))
        }
        let sessions = await transport.streamingSessionCount
        XCTAssertEqual(sessions, 0)
    }

    func testMissingWorkspaceIsNamedRatherThanLeftAsAStreamError() async throws {
        let transport = RunTransport()
        await transport.setDevices([RunTransport.device(serial: "S", state: .device)])
        await transport.setShellPrefix("dumpsys package", TransportResult(exitCode: 0, stdout: "versionCode=7", stderr: ""))
        await transport.setShellPrefix("test -d", TransportResult(exitCode: 0, stdout: "", stderr: ""))

        let path = try temporaryInput("hello")
        do {
            _ = try await CLIRunCommand.run(workload: "DTCA-1", inputPath: path, transport: transport)
            XCTFail("expected a worker error")
        } catch {
            guard case PixelDesktopError.workerError(let message) = error else {
                return XCTFail("expected workerError, got \(error)")
            }
            XCTAssertTrue(message.contains("exchange directory"),
                          "the cause must be named, not left as an opaque stream failure")
        }
    }

    func testAWorkerRefusalIsReturnedAsAResultNotThrown() async throws {
        // A refusal is a result the caller must be able to reason about. Throwing it would force
        // the caller to treat an understood, reported outcome as an exception.
        let transport = RunTransport()
        await transport.setDevices([RunTransport.device(serial: "S", state: .device)])
        await transport.setShellPrefix("dumpsys package", TransportResult(exitCode: 0, stdout: "versionCode=7", stderr: ""))
        await transport.setShellPrefix("test -d", TransportResult(exitCode: 0, stdout: "EXISTS", stderr: ""))
        
        let refusal = """
        {"status":"FAILED","job_id":"__JOB__","error_type":"MODEL_MISSING","error_message":"model absent"}
        """
        await transport.setStreamingLines([
            "PDE1 START job_id=__JOB__", "PDE1 LAUNCHED",
            "PDE1 RESULT_BEGIN", refusal, "PDE1 RESULT_END bytes=__BYTES__",
        ])

        let path = try temporaryInput("hello")
        let (result, error) = try await CLIRunCommand.run(
            workload: "DTCA-1", inputPath: path, transport: transport)

        XCTAssertEqual(result.outcome, "failed")
        XCTAssertNil(result.output, "a refusal carries no result payload")
        let failure = try XCTUnwrap(error)
        let payload = CLIErrorPayload(failure)
        XCTAssertEqual(payload.type, "worker_refused")
        XCTAssertEqual(payload.category, "MODEL_MISSING", "the worker's own token survives")
    }
}

// MARK: - A scripted transport for the run tests

/// Drives `WorkerStreamRunner` the way the E1 suite does, and records which primitives were used.
///
/// Deliberately not a new execution abstraction: it satisfies the existing `TransportProtocol` and
/// answers the same commands the real transport would, so the code under test is the real E1 path.
actor RunTransport: TransportProtocol {

    private var devices: [AndroidDevice] = []
    private var shellPrefixes: [(String, TransportResult)] = []
    private var streamingLines: [String] = []

    private(set) var shellCommands: [String] = []
    /// The size the stream reported for the durable result, answered back for `stat -c %s`.
    private var durableResultBytes: Int?
    private(set) var streamingSessionCount = 0
    private(set) var streamingPayloads: [String] = []
    private(set) var pushCount = 0

    static func device(serial: String, state: DeviceState) -> AndroidDevice {
        AndroidDevice(id: serial, serialNumber: serial, deviceCodename: "lynx",
                      marketingName: "Pixel", manufacturer: "Google", androidVersion: "16",
                      apiLevel: 36, architecture: "arm64-v8a", supportedABIs: ["arm64-v8a"], state: state)
    }

    func setDevices(_ value: [AndroidDevice]) { devices = value }
    func setShellPrefix(_ prefix: String, _ result: TransportResult) {
        shellPrefixes.append((prefix, result))
    }
    func setStreamingLines(_ lines: [String]) { streamingLines = lines }

    func listDevices() async throws -> [AndroidDevice] { devices }

    func shell(deviceSerial: String, command: String, timeout: TimeInterval) async throws -> TransportResult {
        shellCommands.append(command)

        // The durable-file size question is answered from what the stream actually carried,
        // rather than a fixed number, so the durability check is exercised for real.
        if command.hasPrefix("stat -c %s"), let bytes = durableResultBytes {
            return TransportResult(exitCode: 0, stdout: "\(bytes)", stderr: "")
        }

        for (prefix, result) in shellPrefixes where command.hasPrefix(prefix) {
            return result
        }
        return TransportResult(exitCode: 0, stdout: "", stderr: "")
    }

    func shellStreaming(
        deviceSerial: String,
        command: String,
        stdin: String?,
        onLine: @Sendable @escaping (String) -> Void,
        onStderrLine: @Sendable @escaping (String) -> Void,
        cancellation: CancellationHandle
    ) async throws -> Int32 {
        streamingSessionCount += 1
        if let stdin { streamingPayloads.append(stdin) }

        // The real device echoes back whatever job id it was given. The mock must do the same,
        // or the ownership check (`resultBelongsToJob`) correctly rejects the result as foreign —
        // which is what happened before this was added, and is the check working, not failing.
        //
        // The id is read from the job payload on stdin, which is exactly where the real worker
        // reads it from. Parsing it out of the shell script instead was the first attempt and it
        // picked up a trailing quote, because the script interpolates the id inside a quoted echo.
        let jobId = Self.jobId(fromPayload: stdin)
        let substituted = streamingLines.map { $0.replacingOccurrences(of: "__JOB__", with: jobId) }

        // The device writes a durable file and reports its size. Recording the size the stream
        // carried lets `stat -c %s` answer with the same number, which is what makes the
        // durability check pass on a genuinely durable result — and fail when it does not match.
        // The payload is whatever is not a protocol line — the same rule the reducer uses. An
        // earlier version matched any line containing `job_id`, which also matched the START
        // event and made the durable size wrong.
        let resultBytes = substituted
            .first { !$0.hasPrefix(WorkerEventParser.prefix) }?
            .utf8.count
        if let resultBytes { durableResultBytes = resultBytes }

        for line in substituted {
            onLine(line.replacingOccurrences(of: "__BYTES__", with: String(resultBytes ?? 0)))
        }
        return 0
    }

    /// Reads `job_id` from the job document, the way the worker does.
    private static func jobId(fromPayload payload: String?) -> String {
        guard let payload,
              let data = payload.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let jobId = object["job_id"] as? String else {
            return ""
        }
        return jobId
    }

    func execute(command: String, arguments: [String], timeout: TimeInterval) async throws -> TransportResult {
        TransportResult(exitCode: 0, stdout: "", stderr: "")
    }
    func getprop(deviceSerial: String, key: String, timeout: TimeInterval) async throws -> String { "" }
    func getSystemProperties(deviceSerial: String, timeout: TimeInterval) async throws -> [String: String] { [:] }
    func push(deviceSerial: String, localPath: String, remotePath: String, timeout: TimeInterval) async throws -> TransportResult {
        pushCount += 1
        return TransportResult(exitCode: 0, stdout: "", stderr: "")
    }
    func pull(deviceSerial: String, remotePath: String, localPath: String, timeout: TimeInterval) async throws -> TransportResult {
        TransportResult(exitCode: 0, stdout: "", stderr: "")
    }
    func install(deviceSerial: String, apkPath: String, replace: Bool, timeout: TimeInterval) async throws -> TransportResult {
        TransportResult(exitCode: 0, stdout: "", stderr: "")
    }
}
