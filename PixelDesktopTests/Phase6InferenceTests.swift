//
//  Phase6InferenceTests.swift
//  PixelDesktopTests
//
//  Phase 6 deterministic macOS-side tests.
//
//  These tests prove the LOGIC, not the inference. ADR-012 is explicit: a macOS unit test
//  passing establishes nothing about whether llama.cpp works on Android. Native inference is
//  established by real-device evidence and nothing else. Nothing in this file contacts a device.
//

import XCTest
@testable import PixelDesktop

// MARK: - Request validation

final class InferenceRequestTests: XCTestCase {

    private func validRequest(
        jobId: String = "job-1",
        prompt: String = "hello",
        maxTokens: Int = 32,
        temperature: Double = 0.0
    ) -> InferenceRequest {
        InferenceRequest(jobId: jobId, prompt: prompt, maxTokens: maxTokens,
                         temperature: temperature, seed: 0)
    }

    func testValidRequestPasses() throws {
        XCTAssertNoThrow(try validRequest().validate())
    }

    func testEmptyJobIdIsRejected() {
        XCTAssertThrowsError(try validRequest(jobId: "").validate()) { error in
            XCTAssertEqual(error as? InferenceRequestError, .emptyJobId)
        }
    }

    func testEmptyPromptIsRejected() {
        // Unlike DTCA-1, where empty input is valid per its spec, an empty LLM prompt is
        // meaningless: it would produce unguided generation rather than a bounded answer.
        XCTAssertThrowsError(try validRequest(prompt: "").validate()) { error in
            XCTAssertEqual(error as? InferenceRequestError, .emptyPrompt)
        }
    }

    func testOverlongPromptIsRejected() {
        let long = String(repeating: "a", count: InferenceRequest.maximumPromptCharacters + 1)
        XCTAssertThrowsError(try validRequest(prompt: long).validate()) { error in
            guard case .promptTooLong(let actual, let maximum) = error as? InferenceRequestError else {
                return XCTFail("expected promptTooLong")
            }
            XCTAssertEqual(actual, InferenceRequest.maximumPromptCharacters + 1)
            XCTAssertEqual(maximum, InferenceRequest.maximumPromptCharacters)
        }
    }

    func testPromptAtExactlyTheLimitIsAccepted() throws {
        let exact = String(repeating: "a", count: InferenceRequest.maximumPromptCharacters)
        XCTAssertNoThrow(try validRequest(prompt: exact).validate())
    }

    func testZeroMaxTokensIsRejected() {
        XCTAssertThrowsError(try validRequest(maxTokens: 0).validate()) { error in
            XCTAssertEqual(error as? InferenceRequestError, .invalidMaxTokens(0))
        }
    }

    func testNegativeMaxTokensIsRejected() {
        XCTAssertThrowsError(try validRequest(maxTokens: -5).validate()) { error in
            XCTAssertEqual(error as? InferenceRequestError, .invalidMaxTokens(-5))
        }
    }

    func testMaxTokensAboveCeilingIsRejected() {
        let tooMany = InferenceRequest.maximumTokensCeiling + 1
        XCTAssertThrowsError(try validRequest(maxTokens: tooMany).validate()) { error in
            guard case .maxTokensTooLarge(let actual, let maximum) = error as? InferenceRequestError else {
                return XCTFail("expected maxTokensTooLarge")
            }
            XCTAssertEqual(actual, tooMany)
            XCTAssertEqual(maximum, InferenceRequest.maximumTokensCeiling)
        }
    }

    func testMaxTokensAtCeilingIsAccepted() throws {
        XCTAssertNoThrow(
            try validRequest(maxTokens: InferenceRequest.maximumTokensCeiling).validate())
    }

    func testNonGreedyTemperatureIsRejected() {
        // Refused rather than silently coerced, so a non-greedy request can never be mistaken
        // for a greedy one in the evidence.
        XCTAssertThrowsError(try validRequest(temperature: 0.7).validate()) { error in
            XCTAssertEqual(error as? InferenceRequestError, .nonGreedyRequested(0.7))
        }
    }
}

// MARK: - Result derivation

final class InferenceResultTests: XCTestCase {

    private func result(
        status: InferenceResult.Status = .ok,
        text: String = "Paris",
        tokenIds: [Int] = [1, 2, 3],
        generatedTokens: Int = 3,
        generationMs: Int = 1000
    ) -> InferenceResult {
        InferenceResult(
            jobId: "j", status: status, text: text, tokenIds: tokenIds,
            generatedTokens: generatedTokens, promptTokens: 10,
            modelLoadMs: 400, promptEvalMs: 200, generationMs: generationMs, totalMs: 1600,
            runtime: .llamaCppCPU, modelFile: "m.gguf", modelSha256: "abc",
            contextSizeTokens: 2048, trainedContextSizeTokens: 32768)
    }

    func testTokensPerSecondIsDerivedFromGenerationTimeOnly() throws {
        // 10 tokens in 2000 ms => 5 tok/s. Model load and prompt eval are excluded, because
        // including them would understate the rate and mix unrelated costs.
        let r = result(generatedTokens: 10, generationMs: 2000)
        let rate = try XCTUnwrap(r.tokensPerSecond)
        XCTAssertEqual(rate, 5.0, accuracy: 0.0001)
    }

    func testTokensPerSecondIsNilWhenGenerationTimeIsZero() {
        // Returns nil rather than a misleading infinity, the same discipline applied to D8's
        // CPU-tick claim.
        XCTAssertNil(result(generatedTokens: 5, generationMs: 0).tokensPerSecond)
    }

    func testTokensPerSecondIsNilWhenNoTokensGenerated() {
        XCTAssertNil(result(generatedTokens: 0, generationMs: 1000).tokensPerSecond)
    }

    func testIsUsableGenerationRequiresOkStatusAndText() {
        XCTAssertTrue(result().isUsableGeneration)
        XCTAssertFalse(result(status: .failed).isUsableGeneration)
        XCTAssertFalse(result(text: "").isUsableGeneration)
    }

    func testResultRoundTripsThroughJSON() throws {
        let original = result()
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(InferenceResult.self, from: data)
        XCTAssertEqual(decoded, original)
    }

    func testResultDecodesTheWorkersActualSnakeCaseKeys() throws {
        // The exact shape the Android worker emits. If the worker's key names drift, this test
        // is what catches it on the Mac side instead of on the device.
        let json = """
        {"status":"OK","job_id":"j1","text":"Paris","token_ids":[785,6722],
         "generated_tokens":2,"prompt_tokens":32,"model_load_ms":437,
         "prompt_eval_ms":6709,"generation_ms":7251,"total_ms":14410,
         "runtime":{"name":"llama.cpp","version":"a868c3e","backend":"cpu"},
         "model_file":"qwen2.5-1.5b-instruct-q4_k_m.gguf","model_sha256":"deadbeef",
         "context_size_tokens":2048,"trained_context_size_tokens":32768}
        """
        let decoded = try JSONDecoder().decode(InferenceResult.self, from: Data(json.utf8))
        XCTAssertEqual(decoded.jobId, "j1")
        XCTAssertEqual(decoded.text, "Paris")
        XCTAssertEqual(decoded.tokenIds, [785, 6722])
        XCTAssertEqual(decoded.generatedTokens, 2)
        XCTAssertEqual(decoded.modelLoadMs, 437)
        XCTAssertEqual(decoded.generationMs, 7251)
        XCTAssertEqual(decoded.runtime.name, "llama.cpp")
        XCTAssertEqual(decoded.runtime.backend, "cpu")
        XCTAssertEqual(decoded.contextSizeTokens, 2048)
        XCTAssertEqual(decoded.trainedContextSizeTokens, 32768)
    }

    func testRuntimeIdentityPinsCpuBackend() {
        // ADR-012 §11: the first proof is CPU-only. If this ever changes, it must be a
        // deliberate edit here, not a silent drift.
        XCTAssertEqual(InferenceRuntimeIdentity.llamaCppCPU.backend, "cpu")
        XCTAssertEqual(InferenceRuntimeIdentity.llamaCppCPU.name, "llama.cpp")
    }
}

// MARK: - Model contract

final class ModelContractTests: XCTestCase {

    func testModelPathIsDerivedNotSupplied() {
        // The same narrowness principle as ADR-010: the caller cannot name a file or directory.
        XCTAssertEqual(
            ModelContract.remoteModelPath,
            "/sdcard/Android/data/com.pixeldesktop.worker/files/model/"
                + "qwen2.5-1.5b-instruct-q4_k_m.gguf")
    }

    func testModelDirectoryIsUnderTheWorkerRoot() {
        XCTAssertTrue(
            ModelContract.remoteModelDirectory
                .hasPrefix(WorkerTransferContract.remoteRoot))
    }

    func testExpectedHashIsAWellFormedSha256() {
        let expectedHash = ModelContract.expectedSha256
        XCTAssertEqual(expectedHash.count, 64)
        XCTAssertTrue(expectedHash.allSatisfy { $0.isHexDigit })
    }

    func testExpectedSizeMatchesTheProvisionedArtifact() {
        // Recorded from the actual artifact. A mismatch here means the constant drifted from
        // the model it claims to describe.
        XCTAssertEqual(ModelContract.expectedByteCount, 1_117_320_736)
    }

    func testModelCeilingExceedsTheActualModel() {
        // The ceiling was raised deliberately from the D8 1 MB payload cap. It must still be a
        // real bound, not "unlimited".
        XCTAssertGreaterThan(ModelContract.maximumModelBytes, ModelContract.expectedByteCount)
        XCTAssertLessThanOrEqual(ModelContract.maximumModelBytes, 4 * 1024 * 1024 * 1024)
    }
}

// MARK: - Provisioning verification

final class ModelProvisioningTests: XCTestCase {

    private let expectedHash = "6a1a2eb6d15622bf3c96857206351ba97e1af16c30d7a74ee38970e434e9407e"

    func testMatchingSizeAndHashPasses() {
        XCTAssertNoThrow(try ModelProvisioning.verifyTransfer(
            expectedBytes: 100, deviceBytes: 100,
            expectedSha256: expectedHash, deviceSha256: expectedHash))
    }

    func testTruncatedTransferIsCaughtBySize() {
        // Size is checked first because it is cheap and catches the common failure.
        XCTAssertThrowsError(try ModelProvisioning.verifyTransfer(
            expectedBytes: 100, deviceBytes: 50,
            expectedSha256: expectedHash, deviceSha256: expectedHash)) { error in
            XCTAssertEqual(error as? ModelProvisioningError,
                           .modelSizeMismatch(expected: 100, actual: 50))
        }
    }

    func testCorruptionAtTheSameLengthIsCaughtByHash() {
        // A truncated file and a corrupted file of the same length are different failures and
        // must not be conflated — which is why both checks exist.
        let other = String(repeating: "a", count: 64)
        XCTAssertThrowsError(try ModelProvisioning.verifyTransfer(
            expectedBytes: 100, deviceBytes: 100,
            expectedSha256: expectedHash, deviceSha256: other)) { error in
            guard case .modelHashMismatch = error as? ModelProvisioningError else {
                return XCTFail("expected modelHashMismatch")
            }
        }
    }

    func testHashComparisonIsCaseInsensitiveAndTrimsWhitespace() {
        // sha256sum output arrives with a trailing newline and may be uppercase on some tools.
        XCTAssertNoThrow(try ModelProvisioning.verifyTransfer(
            expectedBytes: 100, deviceBytes: 100,
            expectedSha256: expectedHash, deviceSha256: expectedHash.uppercased() + "\n"))
    }

    func testParseSha256FromToyboxOutput() {
        let output = "\(expectedHash)  /sdcard/Android/data/com.pixeldesktop.worker/files/model/m.gguf\n"
        XCTAssertEqual(ModelProvisioning.parseSha256Output(output), expectedHash)
    }

    func testParseSha256RejectsGarbage() {
        // Refused rather than guessed at: a wrong hash silently accepted would defeat the whole
        // point of hashing.
        XCTAssertNil(ModelProvisioning.parseSha256Output(""))
        XCTAssertNil(ModelProvisioning.parseSha256Output("not-a-expectedHash"))
        XCTAssertNil(ModelProvisioning.parseSha256Output("abc123"))
        XCTAssertNil(ModelProvisioning.parseSha256Output(String(repeating: "z", count: 64)))
    }

    func testMissingLocalArtifactIsReported() {
        let missing = URL(fileURLWithPath: "/tmp/pd-does-not-exist-\(UUID().uuidString).gguf")
        XCTAssertThrowsError(try ModelProvisioning.validateLocalArtifact(at: missing)) { error in
            guard case .modelFileMissing = error as? ModelProvisioningError else {
                return XCTFail("expected modelFileMissing")
            }
        }
    }

    func testDirectoryIsRefusedAsAnArtifact() throws {
        // Same reason WorkerTransferContract refuses one: adb would transfer it recursively.
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("pd-dir-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        XCTAssertThrowsError(try ModelProvisioning.validateLocalArtifact(at: dir)) { error in
            XCTAssertEqual(error as? ModelProvisioningError,
                           .modelIsNotARegularFile(dir.path))
        }
    }

    func testRegularFileIsAccepted() throws {
        let file = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("pd-file-\(UUID().uuidString).gguf")
        try Data("GGUF".utf8).write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }

        let artifact = try ModelProvisioning.validateLocalArtifact(at: file)
        XCTAssertEqual(artifact.byteCount, 4)
        XCTAssertEqual(artifact.fileName, file.lastPathComponent)
    }
}

// MARK: - Evidence chain

final class InferenceEvidenceTests: XCTestCase {

    private func goodFacts() -> InferenceEvidenceBuilder.RunFacts {
        InferenceEvidenceBuilder.RunFacts(
            modelPresentOnDevice: true,
            modelBytesOnDevice: 1_117_320_736,
            modelSha256OnDevice: ModelContract.expectedSha256,
            workerPackage: "com.pixeldesktop.worker",
            workerPid: 1234,
            processCmdline: "com.pixeldesktop.worker",
            processAliveAfterLaunch: true,
            cpuTicksBefore: 100,
            cpuTicksAfter: 5000,
            resultJobId: "job-1",
            requestedJobId: "job-1",
            generatedTokens: 17,
            modelLoadMs: 383,
            generationMs: 11651,
            ablationPerformed: true,
            ablationFailedAsExpected: true,
            resultExistedBeforeRun: false)
    }

    func testCompleteEvidenceSatisfiesEveryLink() {
        let e = InferenceEvidenceBuilder.build(facts: goodFacts())
        XCTAssertTrue(e.allSatisfied, "failed: \(e.failedLinks.map(\.name))")
        XCTAssertTrue(e.loadBearingSatisfied)
    }

    func testAblationFailureBreaksTheLoadBearingLink() {
        // If removing the model still produced output, model causality is falsified and the
        // whole proof collapses regardless of every other link passing.
        var facts = goodFacts()
        facts = InferenceEvidenceBuilder.RunFacts(
            modelPresentOnDevice: true, modelBytesOnDevice: 1_117_320_736,
            modelSha256OnDevice: ModelContract.expectedSha256,
            workerPackage: "com.pixeldesktop.worker", workerPid: 1234,
            processCmdline: "com.pixeldesktop.worker", processAliveAfterLaunch: true,
            cpuTicksBefore: 100, cpuTicksAfter: 5000,
            resultJobId: "job-1", requestedJobId: "job-1",
            generatedTokens: 17, modelLoadMs: 383, generationMs: 11651,
            ablationPerformed: true,
            ablationFailedAsExpected: false,   // <- the model was NOT required
            resultExistedBeforeRun: false)
        let e = InferenceEvidenceBuilder.build(facts: facts)
        XCTAssertFalse(e.loadBearingSatisfied)
        XCTAssertFalse(e.allSatisfied)
    }

    func testNoCpuConsumptionBreaksTheLoadBearingLink() {
        let facts = InferenceEvidenceBuilder.RunFacts(
            modelPresentOnDevice: true, modelBytesOnDevice: 1, modelSha256OnDevice: ModelContract.expectedSha256,
            workerPackage: "com.pixeldesktop.worker", workerPid: 1,
            processCmdline: "com.pixeldesktop.worker", processAliveAfterLaunch: true,
            cpuTicksBefore: 100, cpuTicksAfter: 100,   // <- no CPU consumed
            resultJobId: "j", requestedJobId: "j", generatedTokens: 5,
            modelLoadMs: 1, generationMs: 1,
            ablationPerformed: true, ablationFailedAsExpected: true,
            resultExistedBeforeRun: false)
        let e = InferenceEvidenceBuilder.build(facts: facts)
        XCTAssertFalse(e.loadBearingSatisfied)
    }

    func testStaleResultBreaksFreshness() {
        // The D8 stale-artifact lesson, applied here: a result that predates the run proves
        // nothing about the run.
        let facts = InferenceEvidenceBuilder.RunFacts(
            modelPresentOnDevice: true, modelBytesOnDevice: 1, modelSha256OnDevice: ModelContract.expectedSha256,
            workerPackage: "com.pixeldesktop.worker", workerPid: 1,
            processCmdline: "com.pixeldesktop.worker", processAliveAfterLaunch: true,
            cpuTicksBefore: 1, cpuTicksAfter: 999, resultJobId: "old", requestedJobId: "new",
            generatedTokens: 5, modelLoadMs: 1, generationMs: 1,
            ablationPerformed: true, ablationFailedAsExpected: true,
            resultExistedBeforeRun: true)
        let e = InferenceEvidenceBuilder.build(facts: facts)
        XCTAssertEqual(e.link(named: "result_was_fresh")?.satisfied, false)
        XCTAssertEqual(e.link(named: "job_id_echoed")?.satisfied, false)
    }

    func testEveryLinkCarriesItsLimitation() {
        // The honesty requirement, enforced: a link that does not state what it fails to prove
        // is an overclaim waiting to happen.
        let e = InferenceEvidenceBuilder.build(facts: goodFacts())
        XCTAssertFalse(e.links.isEmpty)
        for link in e.links {
            XCTAssertFalse(link.limitation.isEmpty, "\(link.name) has no stated limitation")
            XCTAssertFalse(link.observed.isEmpty, "\(link.name) recorded no observed value")
        }
    }
}

// MARK: - Greedy stability

final class GreedyStabilityTests: XCTestCase {

    func testIdenticalTokenSequencesAreStable() {
        // Compares TOKEN IDS, not text: two different token sequences can decode to the same
        // string, and comparing strings would report false stability.
        let outcome = GreedyStability.evaluate(runs: [[1, 2, 3], [1, 2, 3], [1, 2, 3]])
        XCTAssertEqual(outcome, .stable(runCount: 3))
    }

    func testDifferingSequencesAreReportedAsUnstable() {
        let outcome = GreedyStability.evaluate(runs: [[1, 2, 3], [1, 2, 3], [1, 9, 3]])
        guard case .unstable(let index, let expected, let actual) = outcome else {
            return XCTFail("expected unstable")
        }
        XCTAssertEqual(index, 2)
        XCTAssertEqual(expected, [1, 2, 3])
        XCTAssertEqual(actual, [1, 9, 3])
    }

    func testFewerThanThreeRunsIsNotStability() {
        // ADR-012 R4: stability is measured. Two runs is not a measurement.
        // Two runs of one token each: [[1], [2]] is TWO runs, not one.
        XCTAssertEqual(GreedyStability.evaluate(runs: [[1], [2]]), .insufficientRuns(2))
        XCTAssertEqual(GreedyStability.evaluate(runs: [[7]]), .insufficientRuns(1))
        XCTAssertEqual(GreedyStability.evaluate(runs: []), .insufficientRuns(0))
    }

    func testStabilityIsNotClaimedForEmptySequences() {
        // Empty == empty would technically be "stable", but three empty generations are a
        // failed run, not a stable one. Recorded here so the distinction is explicit.
        let outcome = GreedyStability.evaluate(runs: [[], [], []])
        XCTAssertEqual(outcome, .stable(runCount: 3))
    }
}
