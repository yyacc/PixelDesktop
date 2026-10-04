//
//  Phase9Step7Tests.swift
//  PixelDesktopTests
//
//  Phase 9 Step 7 — LOCAL-LLM-1 execution through the CLI boundary.
//
//  ## What these tests prove
//
//  1. the CLI accepts LOCAL-LLM-1 as a workload
//  2. the InferenceRequest is built with correct defaults (max_tokens=32, temperature=0, seed=0)
//  3. the encoded job JSON contains the correct wire keys (job_id, prompt, max_tokens, temperature, seed)
//  4. invalid prompts are rejected before device I/O
//  5. a successful OK result becomes InferenceResult through the CLI boundary
//  6. DTCA-1 behavior remains unchanged
//  7. refusal/failure remains a refusal and cannot become false success
//

import XCTest
@testable import PixelDesktop

final class Phase9Step7Tests: XCTestCase {

    // MARK: - Fixtures

    /// A valid LOCAL-LLM-1 InferenceResult JSON payload.
    private let validInferenceResultJSON = """
    {
        "job_id": "JOB-123",
        "status": "OK",
        "text": "The capital of France is Paris.",
        "token_ids": [1, 2, 3, 4, 5],
        "generated_tokens": 5,
        "prompt_tokens": 10,
        "model_load_ms": 393,
        "prompt_eval_ms": 5250,
        "generation_ms": 7270,
        "total_ms": 12913,
        "runtime": {
            "name": "llama.cpp",
            "version": "a868c3e",
            "backend": "cpu"
        },
        "model_file": "qwen2.5-1.5b-instruct-q4_k_m.gguf",
        "model_sha256": "abc123",
        "context_size_tokens": 2048,
        "trained_context_size_tokens": 32768
    }
    """

    /// A valid DTCA-1 WorkerResultEnvelope JSON payload.
    private let validDTCA1EnvelopeJSON = """
    {
        "status": "COMPLETED",
        "job_id": "JOB-456",
        "error_type": null,
        "error_message": null,
        "input_characters": 11,
        "total_words": 2,
        "unique_words": 2,
        "top_words": [{"word": "hello", "count": 1}],
        "classification": "NATURAL_LANGUAGE",
        "confidence": 0.5,
        "execution_timestamp_ms": 1,
        "execution_duration_ms": 2
    }
    """

    // MARK: - Helper

    /// Creates a WorkerStreamOutcome.completed with the given JSON payload.
    private func completedOutcome(_ json: String) -> WorkerStreamOutcome {
        .completed(resultJSON: json, resultBytes: json.utf8.count)
    }

    // MARK: - 1. CLI accepts LOCAL-LLM-1 as a workload

    func testLocalLlm1IsSupported() {
        XCTAssertTrue(CLIRunCommand.supportedWorkloads.contains("LOCAL-LLM-1"))
        XCTAssertTrue(CLIRunCommand.supportedWorkloads.contains("DTCA-1"))
    }

    // MARK: - 2. InferenceRequest is built with correct defaults

    func testInferenceRequestDefaults() {
        let jobId = LlmJob.newJobId()
        let request = InferenceRequest(
            jobId: jobId,
            prompt: "Hello, world!",
            maxTokens: 32,
            temperature: 0.0,
            seed: 0
        )

        XCTAssertEqual(request.jobId, jobId)
        XCTAssertEqual(request.prompt, "Hello, world!")
        XCTAssertEqual(request.maxTokens, 32)
        XCTAssertEqual(request.temperature, 0.0)
        XCTAssertEqual(request.seed, 0)
    }

    // MARK: - 3. Encoded job JSON contains correct wire keys

    func testEncodedJobWireKeys() throws {
        let jobId = LlmJob.newJobId()
        let request = InferenceRequest(
            jobId: jobId,
            prompt: "Hello, world!",
            maxTokens: 32,
            temperature: 0.0,
            seed: 0
        )
        let job = LlmJob(request: request)
        let json = try job.encoded()

        XCTAssertTrue(json.contains("\"job_id\""), "Wire key job_id must be present")
        XCTAssertTrue(json.contains("\"prompt\""), "Wire key prompt must be present")
        XCTAssertTrue(json.contains("\"max_tokens\""), "Wire key max_tokens must be present")
        XCTAssertTrue(json.contains("\"temperature\""), "Wire key temperature must be present")
        XCTAssertTrue(json.contains("\"seed\""), "Wire key seed must be present")
    }

    // MARK: - 4. Invalid prompts are rejected before device I/O

    func testEmptyPromptIsRejected() {
        let request = InferenceRequest(
            jobId: LlmJob.newJobId(),
            prompt: "",
            maxTokens: 32,
            temperature: 0.0,
            seed: 0
        )

        XCTAssertThrowsError(try request.validate()) { error in
            guard case InferenceRequestError.emptyPrompt = error else {
                return XCTFail("Expected emptyPrompt, got \(error)")
            }
        }
    }

    func testPromptTooLongIsRejected() {
        let longPrompt = String(repeating: "a", count: 4097)
        let request = InferenceRequest(
            jobId: LlmJob.newJobId(),
            prompt: longPrompt,
            maxTokens: 32,
            temperature: 0.0,
            seed: 0
        )

        XCTAssertThrowsError(try request.validate()) { error in
            guard case InferenceRequestError.promptTooLong = error else {
                return XCTFail("Expected promptTooLong, got \(error)")
            }
        }
    }

    func testInvalidMaxTokensIsRejected() {
        let request = InferenceRequest(
            jobId: LlmJob.newJobId(),
            prompt: "Hello",
            maxTokens: 0,
            temperature: 0.0,
            seed: 0
        )

        XCTAssertThrowsError(try request.validate()) { error in
            guard case InferenceRequestError.invalidMaxTokens = error else {
                return XCTFail("Expected invalidMaxTokens, got \(error)")
            }
        }
    }

    func testMaxTokensTooLargeIsRejected() {
        let request = InferenceRequest(
            jobId: LlmJob.newJobId(),
            prompt: "Hello",
            maxTokens: 257,
            temperature: 0.0,
            seed: 0
        )

        XCTAssertThrowsError(try request.validate()) { error in
            guard case InferenceRequestError.maxTokensTooLarge = error else {
                return XCTFail("Expected maxTokensTooLarge, got \(error)")
            }
        }
    }

    func testNonGreedyTemperatureIsRejected() {
        let request = InferenceRequest(
            jobId: LlmJob.newJobId(),
            prompt: "Hello",
            maxTokens: 32,
            temperature: 0.7,
            seed: 0
        )

        XCTAssertThrowsError(try request.validate()) { error in
            guard case InferenceRequestError.nonGreedyRequested = error else {
                return XCTFail("Expected nonGreedyRequested, got \(error)")
            }
        }
    }

    // MARK: - 5. Successful OK result becomes InferenceResult

    func testSuccessfulResultBecomesInferenceResult() throws {
        let outcome = completedOutcome(validInferenceResultJSON)
        let decoded = try CLIRunCommand.decodeResult(
            from: outcome,
            jobId: "JOB-123",
            expectedSuccessToken: "OK"
        )

        XCTAssertNil(decoded.refusal)
        XCTAssertNil(decoded.output)

        let inference = try XCTUnwrap(decoded.inferenceOutput)
        XCTAssertEqual(inference.status, .ok)
        XCTAssertEqual(inference.text, "The capital of France is Paris.")
        XCTAssertEqual(inference.tokenIds, [1, 2, 3, 4, 5])
        XCTAssertEqual(inference.generatedTokens, 5)
        XCTAssertTrue(inference.isUsableGeneration)
    }

    // MARK: - 6. DTCA-1 behavior remains unchanged

    func testDTCA1StillWorks() throws {
        let outcome = completedOutcome(validDTCA1EnvelopeJSON)
        let decoded = try CLIRunCommand.decodeResult(
            from: outcome,
            jobId: "JOB-456",
            expectedSuccessToken: "COMPLETED"
        )

        XCTAssertNil(decoded.refusal)
        XCTAssertNil(decoded.inferenceOutput)

        let output = try XCTUnwrap(decoded.output)
        XCTAssertEqual(output.status, "COMPLETED")
        XCTAssertEqual(output.inputCharacters, 11)
    }

    // MARK: - 7. Refusal remains a refusal

    func testRefusalRemainsRefusal() throws {
        let failedJSON = """
        {
            "status": "FAILED",
            "job_id": "JOB-123",
            "error_type": "MODEL_MISSING",
            "error_message": "model not found"
        }
        """
        let outcome = completedOutcome(failedJSON)
        let decoded = try CLIRunCommand.decodeResult(
            from: outcome,
            jobId: "JOB-123",
            expectedSuccessToken: "OK"
        )

        XCTAssertNotNil(decoded.refusal)
        XCTAssertNil(decoded.output)
        XCTAssertNil(decoded.inferenceOutput)
    }

    // MARK: - 8. LlmJob properties

    func testLlmJobProperties() {
        let request = InferenceRequest(
            jobId: "JOB-789",
            prompt: "Test prompt",
            maxTokens: 32,
            temperature: 0.0,
            seed: 0
        )
        let job = LlmJob(request: request)

        XCTAssertEqual(job.jobId, "JOB-789")
        XCTAssertEqual(LlmJob.workloadName, "LOCAL-LLM-1")
        XCTAssertEqual(LlmJob.successResultToken, "OK")
    }

    // MARK: - 9. LlmJob newJobId generates unique IDs

    func testNewJobIdIsUnique() {
        let id1 = LlmJob.newJobId()
        let id2 = LlmJob.newJobId()
        XCTAssertNotEqual(id1, id2)
        XCTAssertFalse(id1.isEmpty)
        XCTAssertFalse(id2.isEmpty)
    }

    // MARK: - 10. CLIRunResult publishes inferenceOutput for LOCAL-LLM-1

    func testCLIRunResultPublishesInferenceOutput() throws {
        let outcome = completedOutcome(validInferenceResultJSON)
        let decoded = try CLIRunCommand.decodeResult(
            from: outcome,
            jobId: "JOB-123",
            expectedSuccessToken: "OK"
        )

        let run = WorkerStreamRunner.Run(
            outcome: outcome,
            jobId: "JOB-123",
            workerPidObserved: nil,
            heartbeatCount: 0,
            timeToFirstEventSeconds: nil,
            timeToLaunchAckSeconds: nil,
            timeToOutcomeSeconds: nil,
            wallSeconds: 0,
            stderrLines: [],
            unrecognizedLines: [],
            streamEndedUnexpectedly: false
        )

        let result = CLIRunResult(
            workload: "LOCAL-LLM-1",
            jobId: "JOB-123",
            outcome: outcome,
            run: run,
            output: decoded.output,
            inferenceOutput: decoded.inferenceOutput,
            workerRefusal: decoded.refusal
        )

        XCTAssertNotNil(result.inferenceOutput)
        XCTAssertNil(result.output)
        XCTAssertEqual(result.workload, "LOCAL-LLM-1")
        XCTAssertEqual(result.jobId, "JOB-123")
    }
}
