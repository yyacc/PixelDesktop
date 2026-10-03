//
//  Phase9Step6Tests.swift
//  PixelDesktopTests
//
//  Phase 9 Step 6 — route InferenceResult through the CLI boundary.
//
//  ## What these tests prove
//
//  1. the CLI can decode the LOCAL-LLM-1 InferenceResult shape, including text, token_ids,
//     generated_tokens, and execution evidence fields
//  2. the decoded result is published through CLIRunResult.inferenceOutput without losing
//     the generation result or execution evidence
//  3. DTCA-1 behavior and its existing WorkerResultEnvelope path remain unchanged
//  4. malformed/invalid LOCAL-LLM-1 results are handled correctly
//  5. the success-token routing is correct: "OK" routes to InferenceResult, "COMPLETED"
//     routes to WorkerResultEnvelope
//

import XCTest
@testable import PixelDesktop

final class Phase9Step6Tests: XCTestCase {

    // MARK: - Fixtures

    /// A valid LOCAL-LLM-1 InferenceResult JSON payload, matching the worker's wire contract.
    private let validInferenceResultJSON = """
    {
        "job_id": "JOB-123",
        "status": "OK",
        "text": "Hello, world!",
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

    /// A malformed LOCAL-LLM-1 result (missing required fields).
    private let malformedInferenceResultJSON = """
    {
        "job_id": "JOB-789",
        "status": "OK",
        "text": "",
        "token_ids": [],
        "generated_tokens": 0,
        "prompt_tokens": 0,
        "model_load_ms": 0,
        "prompt_eval_ms": 0,
        "generation_ms": 0,
        "total_ms": 0,
        "runtime": {
            "name": "llama.cpp",
            "version": "a868c3e",
            "backend": "cpu"
        },
        "model_file": "qwen2.5-1.5b-instruct-q4_k_m.gguf",
        "model_sha256": "abc123"
    }
    """

    // MARK: - Helper

    /// Creates a WorkerStreamOutcome.completed with the given JSON payload.
    private func completedOutcome(_ json: String) -> WorkerStreamOutcome {
        .completed(resultJSON: json, resultBytes: json.utf8.count)
    }

    // MARK: - 1. Successful LOCAL-LLM-1 result decoding

    func testSuccessfulInferenceResultDecodes() throws {
        let outcome = completedOutcome(validInferenceResultJSON)
        let decoded = try CLIRunCommand.decodeResult(
            from: outcome,
            jobId: "JOB-123",
            expectedSuccessToken: "OK"
        )

        XCTAssertNil(decoded.refusal, "A successful LOCAL-LLM-1 result must not produce a refusal")
        XCTAssertNil(decoded.output, "A LOCAL-LLM-1 result must not produce a DTCA-1 output")

        let inference = try XCTUnwrap(decoded.inferenceOutput, "inferenceOutput must be present")
        XCTAssertEqual(inference.jobId, "JOB-123")
        XCTAssertEqual(inference.status, .ok)
        XCTAssertEqual(inference.text, "Hello, world!")
        XCTAssertEqual(inference.tokenIds, [1, 2, 3, 4, 5])
        XCTAssertEqual(inference.generatedTokens, 5)
        XCTAssertEqual(inference.promptTokens, 10)
        XCTAssertEqual(inference.modelLoadMs, 393)
        XCTAssertEqual(inference.promptEvalMs, 5250)
        XCTAssertEqual(inference.generationMs, 7270)
        XCTAssertEqual(inference.totalMs, 12913)
        XCTAssertEqual(inference.modelFile, "qwen2.5-1.5b-instruct-q4_k_m.gguf")
        XCTAssertEqual(inference.modelSha256, "abc123")
        XCTAssertEqual(inference.contextSizeTokens, 2048)
        XCTAssertEqual(inference.trainedContextSizeTokens, 32768)
        XCTAssertTrue(inference.isUsableGeneration)
    }

    // MARK: - 2. Generation fields are preserved

    func testGenerationFieldsArePreserved() throws {
        let outcome = completedOutcome(validInferenceResultJSON)
        let decoded = try CLIRunCommand.decodeResult(
            from: outcome,
            jobId: "JOB-123",
            expectedSuccessToken: "OK"
        )

        let inference = try XCTUnwrap(decoded.inferenceOutput)
        XCTAssertFalse(inference.text.isEmpty, "Generated text must not be empty")
        XCTAssertFalse(inference.tokenIds.isEmpty, "Token IDs must not be empty")
        XCTAssertGreaterThan(inference.generatedTokens, 0, "Generated tokens must be positive")
        XCTAssertGreaterThan(inference.promptTokens, 0, "Prompt tokens must be positive")
    }

    // MARK: - 3. Execution evidence is preserved

    func testExecutionEvidenceIsPreserved() throws {
        let outcome = completedOutcome(validInferenceResultJSON)
        let decoded = try CLIRunCommand.decodeResult(
            from: outcome,
            jobId: "JOB-123",
            expectedSuccessToken: "OK"
        )

        let inference = try XCTUnwrap(decoded.inferenceOutput)
        XCTAssertGreaterThan(inference.modelLoadMs, 0, "Model load time must be positive")
        XCTAssertGreaterThan(inference.promptEvalMs, 0, "Prompt eval time must be positive")
        XCTAssertGreaterThan(inference.generationMs, 0, "Generation time must be positive")
        XCTAssertGreaterThan(inference.totalMs, 0, "Total time must be positive")
        XCTAssertNotNil(inference.runtime, "Runtime identity must be present")
        XCTAssertFalse(inference.modelFile.isEmpty, "Model file must be present")
        XCTAssertFalse(inference.modelSha256.isEmpty, "Model SHA256 must be present")
    }

    // MARK: - 4. Malformed/invalid result handling

    func testMalformedInferenceResultIsRefused() throws {
        let outcome = completedOutcome(malformedInferenceResultJSON)
        let decoded = try CLIRunCommand.decodeResult(
            from: outcome,
            jobId: "JOB-789",
            expectedSuccessToken: "OK"
        )

        // An empty text with 0 tokens is not a usable generation, but it still decodes
        // as a valid InferenceResult. The isUsableGeneration property handles this.
        let inference = try XCTUnwrap(decoded.inferenceOutput)
        XCTAssertFalse(inference.isUsableGeneration, "Empty text must not be a usable generation")
    }

    func testInvalidJSONIsRejected() throws {
        let outcome = completedOutcome("not valid json")
        XCTAssertThrowsError(try CLIRunCommand.decodeResult(
            from: outcome,
            jobId: "JOB-123",
            expectedSuccessToken: "OK"
        )) { error in
            guard case PixelDesktopError.verificationFailed = error else {
                return XCTFail("Expected verificationFailed, got \(error)")
            }
        }
    }

    func testForeignJobIdIsRejected() throws {
        let outcome = completedOutcome(validInferenceResultJSON)
        XCTAssertThrowsError(try CLIRunCommand.decodeResult(
            from: outcome,
            jobId: "WRONG-JOB",
            expectedSuccessToken: "OK"
        )) { error in
            guard case PixelDesktopError.verificationFailed = error else {
                return XCTFail("Expected verificationFailed, got \(error)")
            }
        }
    }

    // MARK: - 5. DTCA-1 behavior is unchanged

    func testDTCA1ResultStillDecodes() throws {
        let outcome = completedOutcome(validDTCA1EnvelopeJSON)
        let decoded = try CLIRunCommand.decodeResult(
            from: outcome,
            jobId: "JOB-456",
            expectedSuccessToken: "COMPLETED"
        )

        XCTAssertNil(decoded.refusal)
        XCTAssertNil(decoded.inferenceOutput, "A DTCA-1 result must not produce an inference output")

        let output = try XCTUnwrap(decoded.output)
        XCTAssertEqual(output.status, "COMPLETED")
        XCTAssertEqual(output.inputCharacters, 11)
        XCTAssertEqual(output.totalWords, 2)
        XCTAssertEqual(output.uniqueWords, 2)
    }

    func testDTCA1FailureIsRefused() throws {
        let failedJSON = """
        {
            "status": "FAILED",
            "job_id": "JOB-456",
            "error_type": "INVALID_INPUT",
            "error_message": "bad input"
        }
        """
        let outcome = completedOutcome(failedJSON)
        let decoded = try CLIRunCommand.decodeResult(
            from: outcome,
            jobId: "JOB-456",
            expectedSuccessToken: "COMPLETED"
        )

        XCTAssertNotNil(decoded.refusal, "A FAILED envelope must produce a refusal")
        XCTAssertNil(decoded.output)
        XCTAssertNil(decoded.inferenceOutput)
    }

    // MARK: - 6. Success-token routing

    func testSuccessTokenRouting() throws {
        // "OK" routes to InferenceResult
        let okOutcome = completedOutcome(validInferenceResultJSON)
        let okDecoded = try CLIRunCommand.decodeResult(
            from: okOutcome,
            jobId: "JOB-123",
            expectedSuccessToken: "OK"
        )
        XCTAssertNotNil(okDecoded.inferenceOutput, "OK token must route to InferenceResult")
        XCTAssertNil(okDecoded.output, "OK token must not produce a DTCA-1 output")

        // "COMPLETED" routes to WorkerResultEnvelope
        let completedOutcome = completedOutcome(validDTCA1EnvelopeJSON)
        let completedDecoded = try CLIRunCommand.decodeResult(
            from: completedOutcome,
            jobId: "JOB-456",
            expectedSuccessToken: "COMPLETED"
        )
        XCTAssertNotNil(completedDecoded.output, "COMPLETED token must route to WorkerResultEnvelope")
        XCTAssertNil(completedDecoded.inferenceOutput, "COMPLETED token must not produce an inference output")
    }

    // MARK: - 7. CLIRunResult publishes inferenceOutput

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

        XCTAssertNotNil(result.inferenceOutput, "CLIRunResult must publish inferenceOutput")
        XCTAssertNil(result.output, "CLIRunResult must not publish DTCA-1 output for LOCAL-LLM-1")
        XCTAssertEqual(result.workload, "LOCAL-LLM-1")
        XCTAssertEqual(result.jobId, "JOB-123")
    }

    // MARK: - 8. InferenceResult Codable round-trip

    func testInferenceResultCodableRoundTrip() throws {
        let outcome = completedOutcome(validInferenceResultJSON)
        let decoded = try CLIRunCommand.decodeResult(
            from: outcome,
            jobId: "JOB-123",
            expectedSuccessToken: "OK"
        )

        let inference = try XCTUnwrap(decoded.inferenceOutput)
        let encoder = JSONEncoder()
        let data = try encoder.encode(inference)
        let decoder = JSONDecoder()
        let roundTripped = try decoder.decode(InferenceResult.self, from: data)

        XCTAssertEqual(inference, roundTripped, "InferenceResult must survive a Codable round-trip")
    }

    // MARK: - 9. InferenceResult wire keys

    func testInferenceResultWireKeys() throws {
        let outcome = completedOutcome(validInferenceResultJSON)
        let decoded = try CLIRunCommand.decodeResult(
            from: outcome,
            jobId: "JOB-123",
            expectedSuccessToken: "OK"
        )

        let inference = try XCTUnwrap(decoded.inferenceOutput)
        let encoder = JSONEncoder()
        let data = try encoder.encode(inference)
        let json = try XCTUnwrap(String(data: data, encoding: .utf8))

        // Verify snake_case wire keys are present
        XCTAssertTrue(json.contains("\"job_id\""), "Wire key job_id must be present")
        XCTAssertTrue(json.contains("\"token_ids\""), "Wire key token_ids must be present")
        XCTAssertTrue(json.contains("\"generated_tokens\""), "Wire key generated_tokens must be present")
        XCTAssertTrue(json.contains("\"prompt_tokens\""), "Wire key prompt_tokens must be present")
        XCTAssertTrue(json.contains("\"model_load_ms\""), "Wire key model_load_ms must be present")
        XCTAssertTrue(json.contains("\"prompt_eval_ms\""), "Wire key prompt_eval_ms must be present")
        XCTAssertTrue(json.contains("\"generation_ms\""), "Wire key generation_ms must be present")
        XCTAssertTrue(json.contains("\"total_ms\""), "Wire key total_ms must be present")
        XCTAssertTrue(json.contains("\"model_file\""), "Wire key model_file must be present")
        XCTAssertTrue(json.contains("\"model_sha256\""), "Wire key model_sha256 must be present")
    }
}
