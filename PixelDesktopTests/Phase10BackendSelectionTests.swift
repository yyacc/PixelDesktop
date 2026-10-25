//
//  Phase10BackendSelectionTests.swift
//  PixelDesktopTests
//
//  Backend selection for LOCAL-LLM-1.
//
//  ## Why these tests exist
//
//  `LOCAL-LLM-1` used to have exactly one way to compute tokens: the worker's in-process
//  llama.cpp with a Qwen artifact whose filename was a compile-time constant. A second backend now
//  exists (the on-device llama-server, which serves its own model), selected per job.
//
//  That change has one dangerous failure mode: a request that *means* the in-process backend must
//  not become a request for the server, and vice versa. So the wire form is pinned here —
//
//    1. the default backend leaves the encoded job byte-identical to before this field existed
//    2. a non-default backend is always stated on the wire, with the exact string the worker reads
//    3. decoding tolerates a missing key (older job) and refuses an unknown value
//    4. the value survives into the job document that is actually pushed to the device
//    5. the CLI accepts the id and rejects an unimplemented one by name
//
//  The raw strings are asserted as literals because they are a contract with Java code that has
//  no view of this module: `LlmWorkload.BACKEND_IN_PROCESS` and
//  `HttpInferenceBackend.BACKEND_ID`. Renaming either side without the other must break here.
//

import XCTest
@testable import PixelDesktop

final class Phase10BackendSelectionTests: XCTestCase {

    // MARK: - Fixtures

    private func request(
        backend: InferenceRequest.InferenceBackend = .inProcess
    ) -> InferenceRequest {
        InferenceRequest(
            jobId: "JOB-1",
            prompt: "Name the capital of France.",
            maxTokens: 32,
            temperature: 0.0,
            seed: 0,
            backend: backend
        )
    }

    private func encodedJSONString(_ request: InferenceRequest) throws -> String {
        String(data: try JSONEncoder().encode(request), encoding: .utf8) ?? ""
    }

    // MARK: - 1. The default costs nothing on the wire

    func testDefaultBackendIsInProcess() {
        XCTAssertEqual(request().backend, .inProcess)
    }

    /// The regression that matters most: every job document written before this field existed must
    /// still encode to the same bytes, so a worker that predates the field sees an identical job.
    func testDefaultBackendIsOmittedFromTheWire() throws {
        let json = try encodedJSONString(request())
        XCTAssertFalse(json.contains("backend"), "the default must not appear on the wire")
        XCTAssertFalse(json.contains("llama-jni"))
    }

    func testDefaultEncodedKeysAreUnchanged() throws {
        let data = try JSONEncoder().encode(request())
        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(
            Set(object.keys),
            ["job_id", "prompt", "max_tokens", "temperature", "seed"],
            "the wire shape for an in-process request must not have changed")
    }

    // MARK: - 2. A non-default backend is always stated

    func testServerBackendEncodesTheExactWorkerString() throws {
        let json = try encodedJSONString(request(backend: .onDeviceServer))
        XCTAssertTrue(json.contains("\"backend\":\"llama-server-http\""),
                      "the worker matches this literal; got: \(json)")
    }

    /// The two ids the worker knows, as literals. See `LlmWorkload.BACKEND_IN_PROCESS` and
    /// `HttpInferenceBackend.BACKEND_ID`.
    func testBackendRawValuesMatchTheWorker() {
        XCTAssertEqual(InferenceRequest.InferenceBackend.inProcess.rawValue, "llama-jni")
        XCTAssertEqual(InferenceRequest.InferenceBackend.onDeviceServer.rawValue,
                       "llama-server-http")
        XCTAssertEqual(InferenceRequest.InferenceBackend.allCases.count, 2,
                       "a third backend must be a deliberate addition, not a typo")
    }

    // MARK: - 3. Decoding: missing means default, unknown is refused

    /// A job document written by an older build has no `backend` key. It must decode to the
    /// in-process backend — the behaviour it always had — rather than failing or guessing.
    func testDecodingLegacyDocumentWithoutBackendYieldsInProcess() throws {
        let legacy = """
        {"job_id":"JOB-1","prompt":"hi","max_tokens":32,"temperature":0,"seed":0}
        """
        let decoded = try JSONDecoder().decode(
            InferenceRequest.self, from: Data(legacy.utf8))
        XCTAssertEqual(decoded.backend, .inProcess)
    }

    func testDecodingExplicitServerBackend() throws {
        let json = """
        {"job_id":"JOB-1","prompt":"hi","max_tokens":32,"temperature":0,"seed":0,\
        "backend":"llama-server-http"}
        """
        let decoded = try JSONDecoder().decode(
            InferenceRequest.self, from: Data(json.utf8))
        XCTAssertEqual(decoded.backend, .onDeviceServer)
    }

    /// An unrecognised backend must never fall back to the default: silently running a different
    /// model than the one asked for is worse than failing to decode.
    func testUnknownBackendStringIsRefused() {
        let json = """
        {"job_id":"JOB-1","prompt":"hi","max_tokens":32,"temperature":0,"seed":0,\
        "backend":"qwen-over-smoke-signals"}
        """
        XCTAssertThrowsError(
            try JSONDecoder().decode(InferenceRequest.self, from: Data(json.utf8)))
    }

    func testRoundTripPreservesBackend() throws {
        for backend in InferenceRequest.InferenceBackend.allCases {
            let original = request(backend: backend)
            let decoded = try JSONDecoder().decode(
                InferenceRequest.self, from: try JSONEncoder().encode(original))
            XCTAssertEqual(decoded.backend, backend)
            XCTAssertEqual(decoded, original)
        }
    }

    // MARK: - 4. The choice reaches the job document the device reads

    func testServerBackendSurvivesIntoTheEncodedJob() throws {
        let payload = try LlmJob(request: request(backend: .onDeviceServer)).encoded()
        XCTAssertTrue(payload.contains("\"backend\":\"llama-server-http\""),
                      "the field must be in job.json, not only in the request: \(payload)")
        XCTAssertTrue(payload.contains("\"workload\":\"LOCAL-LLM-1\""))
    }

    func testInProcessJobDocumentIsUnchanged() throws {
        let payload = try LlmJob(request: request()).encoded()
        XCTAssertFalse(payload.contains("backend"))
    }

    // MARK: - 5. Validation is not weakened by adding a backend

    /// Selecting the server backend must not become a way around the greedy-only rule: the
    /// server is asked with `temperature: 0.0` and the request refuses anything else.
    func testServerBackendStillRefusesNonGreedyRequest() {
        let nonGreedy = InferenceRequest(
            jobId: "JOB-1", prompt: "hi", maxTokens: 32, temperature: 0.7, seed: 0,
            backend: .onDeviceServer)
        XCTAssertThrowsError(try nonGreedy.validate())
    }

    func testServerBackendStillHonoursTokenCeiling() {
        let tooMany = InferenceRequest(
            jobId: "JOB-1", prompt: "hi",
            maxTokens: InferenceRequest.maximumTokensCeiling + 1,
            temperature: 0.0, seed: 0, backend: .onDeviceServer)
        XCTAssertThrowsError(try tooMany.validate())
    }

    // MARK: - 6. CLI boundary

    func testCLIAcceptsTheServerBackend() {
        let result = CLIInvocation.parse([
            "run", "--workload", "LOCAL-LLM-1", "--input-file", "/tmp/p.txt",
            "--backend", "llama-server-http", "--json",
        ])
        guard case .success(let invocation) = result else {
            return XCTFail("expected success, got \(result)")
        }
        XCTAssertEqual(invocation.backend, .onDeviceServer)
    }

    func testCLITreatsAnAbsentBackendAsTheDefault() {
        let result = CLIInvocation.parse([
            "run", "--workload", "LOCAL-LLM-1", "--input-file", "/tmp/p.txt", "--json",
        ])
        guard case .success(let invocation) = result else {
            return XCTFail("expected success, got \(result)")
        }
        XCTAssertNil(invocation.backend, "absent stays absent; main.swift applies the default")
    }

    /// Refused by name, with the valid ids listed: a caller who typed the wrong id must not be
    /// handed the default backend and told nothing.
    func testCLIRejectsAnUnknownBackendNamingTheAllowedValues() {
        let result = CLIInvocation.parse([
            "run", "--workload", "LOCAL-LLM-1", "--input-file", "/tmp/p.txt",
            "--backend", "gemma", "--json",
        ])
        guard case .failure(let error) = result else {
            return XCTFail("expected a usage error, got \(result)")
        }
        XCTAssertTrue(error.message.contains("llama-jni"), error.message)
        XCTAssertTrue(error.message.contains("llama-server-http"), error.message)
    }

    func testCLIRejectsBackendOnCommandsThatCannotUseIt() {
        for command in ["capability", "observe", "schedule"] {
            let arguments = command == "schedule"
                ? ["schedule", "run", UUID().uuidString, "--backend", "llama-server-http", "--json"]
                : [command, "--backend", "llama-server-http", "--json"]
            let result = CLIInvocation.parse(arguments)
            guard case .failure = result else {
                return XCTFail("\(command) must reject --backend, got \(result)")
            }
        }
    }

    func testUsageAdvertisesTheBackendFlag() {
        XCTAssertTrue(CLICommand.usage.contains("--backend"))
        XCTAssertTrue(CLICommand.usage.contains("llama-server-http"))
    }
}
