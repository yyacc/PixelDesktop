//
//  Phase7Amendment3PathTests.swift
//  PixelDesktopTests
//
//  Phase 7 Amendment 3 — workload-owned success semantics + the LLM request wire contract.
//
//  ## What this amendment corrects
//
//  Two defects, both of which made the boundary *accidentally* correct for exactly one workload.
//
//  1. **Success was hardcoded.** `WorkerResultEnvelope.isCompleted` compared against the literal
//     `"COMPLETED"` — DTCA-1's token. LOCAL-LLM-1's worker writes `"OK"`. So a successful
//     inference would have been reported as a **refusal**. The code was right only because DTCA-1
//     was the only workload the CLI accepted.
//
//  2. **The LLM request wire keys were implicit.** `InferenceRequest` had no `CodingKeys`, so the
//     synthesized encoding emitted `jobId` / `maxTokens` while the Android worker reads `job_id` /
//     `max_tokens`. A missing `max_tokens` is not an error on the device — the worker silently
//     falls back to its own default of 32 — so the Mac would have received a different request
//     than the one it validated, with nothing to indicate it.
//
//  ## What is deliberately NOT symmetric
//
//  Success is workload-owned; **failure is not**. Every workload's failure is written by the shared
//  `WorkerActivity` as `"FAILED"` with `error_type` / `error_message`. Modelling failure per
//  workload would invent a distinction the worker does not make, so it stays generic and these
//  tests assert that asymmetry rather than assuming it.
//
//  ## How these tests are shaped
//
//  Derivation tests assert the published token **equals its owner constant** rather than a literal,
//  so a change to either worker's vocabulary fails here instead of letting the contract drift out
//  of agreement with the worker that produces the token.
//

import XCTest
@testable import PixelDesktop

final class Phase7Amendment3Tests: XCTestCase {

    private func pixel7a() -> AndroidDevice {
        AndroidDevice(
            id: "test-id", serialNumber: "SERIAL", deviceCodename: "lynx",
            marketingName: "Pixel 7a", manufacturer: "Google",
            androidVersion: "16", apiLevel: 36, architecture: "arm64-v8a",
            supportedABIs: ["arm64-v8a"], state: .device
        )
    }

    private func contract() -> PixelCapabilityContract {
        PixelCapabilityContract.build(
            device: pixel7a(),
            contextSize: PixelCapabilityContract.contextSize(runtimeReported: nil)
        )
    }

    private func workload(_ name: String) throws -> PixelCapabilityContract.Workload {
        try XCTUnwrap(contract().workloads.first { $0.name == name })
    }

    /// A minimal successful DTCA-1 envelope, as the worker would write it.
    private func dtca1Envelope(status: String) -> WorkerResultEnvelope {
        WorkerResultEnvelope(
            status: status,
            jobId: "JOB",
            errorType: nil,
            errorMessage: nil,
            inputCharacters: 11,
            totalWords: 2,
            uniqueWords: 2,
            topWords: [WordCount(word: "hello", count: 1)],
            classification: "NATURAL_LANGUAGE",
            confidence: 0.5,
            executionTimestampMs: 1,
            executionDurationMs: 2
        )
    }

    /// A failed envelope, as the shared `WorkerActivity` writes it for any workload.
    private func failedEnvelope(errorType: String?) -> WorkerResultEnvelope {
        WorkerResultEnvelope(
            status: WorkerResultEnvelope.failureStatusToken,
            jobId: "JOB",
            errorType: errorType,
            errorMessage: "boom",
            inputCharacters: nil, totalWords: nil, uniqueWords: nil, topWords: nil,
            classification: nil, confidence: nil,
            executionTimestampMs: nil, executionDurationMs: nil
        )
    }

    // MARK: - 1. Contract version

    func testContractVersionIsThreeAfterTheAmendment() {
        // The contract's own rule: bumped when a field is added. A consumer reading success
        // semantics must be able to detect a version-2 contract, where no workload publishes a
        // success token and the only correct assumption is DTCA-1's.
        XCTAssertEqual(PixelCapabilityContract.currentVersion, 3)
        XCTAssertEqual(contract().contractVersion, 3)
    }

    // MARK: - 2. DTCA-1 publishes its own success token

    func testDTCA1WorkloadPublishesItsOwnSuccessToken() throws {
        let dtca1 = try workload("DTCA-1")

        XCTAssertEqual(dtca1.successResultToken.value, DTCA1Job.successResultToken)
        XCTAssertEqual(dtca1.successResultToken.value, "COMPLETED")
        XCTAssertEqual(dtca1.successResultToken.source, .declared)
        XCTAssertNil(dtca1.successResultToken.observedAt,
                     "a build constant was never observed; a timestamp would claim otherwise")
        XCTAssertNotNil(dtca1.successResultToken.limitation,
                        "a published token must state what it does not cover")
    }

    // MARK: - 3. LOCAL-LLM-1 publishes its own success token

    func testLocalLLM1WorkloadPublishesItsOwnSuccessToken() throws {
        let llm = try workload("LOCAL-LLM-1")

        XCTAssertEqual(llm.successResultToken.value, InferenceResult.successResultToken)
        XCTAssertEqual(llm.successResultToken.value, "OK")
        XCTAssertEqual(llm.successResultToken.source, .declared)
        XCTAssertNotNil(llm.successResultToken.limitation)
    }

    func testTheTwoWorkloadsDoNotShareASuccessToken() throws {
        // The whole point of the amendment: these differ, so no single hardcoded comparison can
        // be correct for both.
        let dtca1 = try workload("DTCA-1")
        let llm = try workload("LOCAL-LLM-1")

        XCTAssertNotEqual(dtca1.successResultToken.value, llm.successResultToken.value)
    }

    func testSuccessTokensAreDerivedFromTheirOwnWorkerConstants() throws {
        // Derivation, not restatement: if either worker's vocabulary changes, this fails rather
        // than letting the contract drift out of agreement with the worker.
        XCTAssertEqual(try workload("DTCA-1").successResultToken.value,
                       DTCA1Job.successResultToken)
        XCTAssertEqual(try workload("LOCAL-LLM-1").successResultToken.value,
                       InferenceResult.successResultToken)
    }

    func testPublishedSuccessTokenLimitationDeniesFailureScope() throws {
        // The asymmetry must be stated, not merely implied: a consumer must not read this field
        // as describing failure.
        for name in ["DTCA-1", "LOCAL-LLM-1"] {
            let limitation = try XCTUnwrap(try workload(name).successResultToken.limitation)
            XCTAssertTrue(limitation.lowercased().contains("success"),
                          "\(name): the limitation must scope the field to success")
            XCTAssertTrue(limitation.lowercased().contains("failure"),
                          "\(name): the limitation must deny failure scope")
        }
    }

    // MARK: - 4. Generic result boundary — workload-agnostic

    func testEnvelopeRecognisesTheTokenItsCallerSupplies() {
        // The same envelope type, two different workloads, two different tokens. Neither is
        // privileged: the boundary only compares.
        let completedEnvelope = dtca1Envelope(status: "COMPLETED")
        let okEnvelope = dtca1Envelope(status: "OK")

        XCTAssertTrue(completedEnvelope.isCompleted(expectedSuccessToken: DTCA1Job.successResultToken))
        XCTAssertTrue(okEnvelope.isCompleted(expectedSuccessToken: InferenceResult.successResultToken))
    }

    func testCompletedIsNotUniversallySuccessful() {
        // "COMPLETED" is DTCA-1's vocabulary. Under LOCAL-LLM-1's expected token it is not success.
        let envelope = dtca1Envelope(status: "COMPLETED")

        XCTAssertFalse(envelope.isCompleted(expectedSuccessToken: InferenceResult.successResultToken))
    }

    func testOkIsNotUniversallySuccessful() {
        let envelope = dtca1Envelope(status: "OK")

        XCTAssertFalse(envelope.isCompleted(expectedSuccessToken: DTCA1Job.successResultToken))
    }

    func testWrongTokenIsRejectedRatherThanTreatedAsSuccess() {
        let envelope = dtca1Envelope(status: "SOMETHING_ELSE")

        XCTAssertFalse(envelope.isCompleted(expectedSuccessToken: DTCA1Job.successResultToken))
        XCTAssertThrowsError(
            try envelope.asDTCA1Result(expectedSuccessToken: DTCA1Job.successResultToken)
        )
    }

    // MARK: - 5. Failure remains generic

    func testFailureTokenIsWorkerWideAndNotWorkloadOwned() throws {
        // Failure is written once by WorkerActivity for every workload. It must NOT be published
        // per workload — that would invent a distinction the worker does not make.
        XCTAssertEqual(WorkerResultEnvelope.failureStatusToken, "FAILED")

        for name in ["DTCA-1", "LOCAL-LLM-1"] {
            let w = try workload(name)
            XCTAssertNotEqual(w.successResultToken.value, WorkerResultEnvelope.failureStatusToken,
                              "\(name): the failure token must not be the success token")
        }
    }

    func testFailedResultIsNotSuccessUnderEitherWorkload() {
        let failed = failedEnvelope(errorType: "INVALID_INPUT")

        XCTAssertFalse(failed.isCompleted(expectedSuccessToken: DTCA1Job.successResultToken))
        XCTAssertFalse(failed.isCompleted(expectedSuccessToken: InferenceResult.successResultToken))
    }

    func testFailurePreservesItsStructuredCategory() {
        // Refusal semantics must survive the amendment: the worker's own category is not flattened
        // into prose, so a caller can tell MODEL_MISSING from INVALID_INPUT.
        let failed = failedEnvelope(errorType: "MODEL_MISSING")

        XCTAssertEqual(failed.refusal, .workerRefused(category: "MODEL_MISSING", message: "boom"))
    }

    func testFailureWithoutACategoryDoesNotFabricateOne() {
        let failed = failedEnvelope(errorType: nil)

        if case .workerError = failed.refusal {
            // correct: no structured category was supplied, so none is invented
        } else {
            XCTFail("an absent error_type must not be coerced into a category")
        }
    }

    // MARK: - 6. ResultVerifier stays generic

    func testResultVerifierAcceptsTheCallersExpectedToken() throws {
        let input = "Hello world"
        let pixel = try DTCA1Worker.execute(input)
        let local = try DTCA1Worker.execute(input)

        let verification = ResultVerifier.verify(
            pixelResult: pixel, localResult: local, originalInput: input,
            expectedSuccessToken: DTCA1Job.successResultToken)

        XCTAssertTrue(verification.isVerified)
    }

    func testResultVerifierRejectsAResultWhoseStatusIsNotTheExpectedToken() throws {
        let input = "Hello world"
        let base = try DTCA1Worker.execute(input)
        let local = try DTCA1Worker.execute(input)

        let tampered = DTCA1Result(
            status: "FAILED", inputCharacters: base.inputCharacters,
            totalWords: base.totalWords, uniqueWords: base.uniqueWords,
            topWords: base.topWords, classification: base.classification,
            confidence: base.confidence, executionTimestampMs: base.executionTimestampMs,
            executionDurationMs: base.executionDurationMs)

        let verification = ResultVerifier.verify(
            pixelResult: tampered, localResult: local, originalInput: input,
            expectedSuccessToken: DTCA1Job.successResultToken)

        XCTAssertFalse(verification.isVerified)
        XCTAssertTrue(verification.mismatches.contains { $0.contains("Status is not") })
    }

    func testResultVerifierComparesAgainstTheSuppliedTokenNotALiteral() throws {
        // Supply a token the result does not carry: the status check must fail on the *supplied*
        // token, proving the verifier holds no built-in vocabulary.
        let input = "Hello world"
        let pixel = try DTCA1Worker.execute(input)
        let local = try DTCA1Worker.execute(input)

        let verification = ResultVerifier.verify(
            pixelResult: pixel, localResult: local, originalInput: input,
            expectedSuccessToken: "NOT_DTCA1S_TOKEN")

        XCTAssertFalse(verification.isVerified)
        XCTAssertTrue(verification.mismatches.contains { $0.contains("NOT_DTCA1S_TOKEN") },
                      "the mismatch must name the token the caller supplied")
    }

    // MARK: - 7. LLM request wire contract

    func testInferenceRequestEmitsSnakeCaseWireKeys() throws {
        let request = InferenceRequest(
            jobId: "JOB-1", prompt: "hello", maxTokens: 64, temperature: 0, seed: 7)

        let data = try JSONEncoder().encode(request)
        let json = try XCTUnwrap(
            JSONSerialization.jsonObject(with: data) as? [String: Any])

        XCTAssertEqual(json["job_id"] as? String, "JOB-1")
        XCTAssertEqual(json["max_tokens"] as? Int, 64)
        XCTAssertEqual(json["prompt"] as? String, "hello")
        XCTAssertEqual(json["temperature"] as? Double, 0)
        XCTAssertEqual(json["seed"] as? Int, 7)
    }

    func testInferenceRequestDoesNotEmitCamelCaseKeys() throws {
        // The defect this amendment fixes: a synthesized encoding emits `maxTokens`, the worker
        // reads `max_tokens`, and the mismatch is SILENT — the worker defaults to 32 tokens and
        // reports no complaint.
        let request = InferenceRequest(
            jobId: "JOB-1", prompt: "hello", maxTokens: 64, temperature: 0, seed: 7)

        let data = try JSONEncoder().encode(request)
        let json = try XCTUnwrap(
            JSONSerialization.jsonObject(with: data) as? [String: Any])

        XCTAssertNil(json["maxTokens"], "camelCase must not reach the wire")
        XCTAssertNil(json["jobId"], "camelCase must not reach the wire")
    }

    func testInferenceRequestRoundTripsThroughTheWireForm() throws {
        let request = InferenceRequest(
            jobId: "JOB-1", prompt: "hello", maxTokens: 64, temperature: 0, seed: 7)

        let decoded = try JSONDecoder().decode(
            InferenceRequest.self, from: try JSONEncoder().encode(request))

        XCTAssertEqual(decoded, request)
    }

    func testInferenceRequestDecodesTheWorkersActualWireForm() throws {
        // Exactly the key set `LlmWorkload.execute` reads.
        let wire = #"{"job_id":"JOB-1","prompt":"hello","max_tokens":64,"temperature":0,"seed":7}"#

        let decoded = try JSONDecoder().decode(InferenceRequest.self, from: Data(wire.utf8))

        XCTAssertEqual(decoded.jobId, "JOB-1")
        XCTAssertEqual(decoded.maxTokens, 64)
        XCTAssertEqual(decoded.temperature, 0)
    }
}
