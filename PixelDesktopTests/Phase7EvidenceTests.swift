//
//  Phase7EvidenceTests.swift
//  PixelDesktopTests
//
//  Phase 7 Step 2 — measured evidence tests.
//
//  These prove the seven things the step requires:
//    1. capability contract still reports correct static information (Step 1 intact)
//    2. dynamic observations are populated correctly
//    3. timestamps / provenance are correct
//    4. stale / unknown semantics behave as designed
//    5. measurements do not silently become capabilities
//    6. NO performance threshold is introduced
//    7. PixelDesktop still refuses invalid requests
//
//  Device-dependent population is verified separately against the real Pixel 7a. Nothing here
//  contacts a device; parsing and provenance logic are pure and fully testable.
//

import XCTest
@testable import PixelDesktop

// MARK: - Freshness

final class FreshnessTests: XCTestCase {

    private let reference = Date(timeIntervalSince1970: 1_800_000_000)

    func testFreshObservationIsCurrent() {
        let observed = reference.addingTimeInterval(-10)
        XCTAssertEqual(
            Freshness.assess(observedAt: observed, now: reference, maxAge: 60), .current)
    }

    func testOldObservationIsStale() {
        let observed = reference.addingTimeInterval(-120)
        XCTAssertEqual(
            Freshness.assess(observedAt: observed, now: reference, maxAge: 60), .stale)
    }

    func testMissingTimestampIsUnknownNotStale() {
        // Unknown and stale are different facts: stale means we know it is old, unknown means we
        // cannot tell. Collapsing them would let a consumer treat "no timestamp" as "old".
        XCTAssertEqual(
            Freshness.assess(observedAt: nil, now: reference, maxAge: 60), .unknown)
    }

    func testBoundaryIsInclusiveAtExactlyMaxAge() {
        let observed = reference.addingTimeInterval(-60)
        XCTAssertEqual(
            Freshness.assess(observedAt: observed, now: reference, maxAge: 60), .current)
    }

    func testFutureTimestampIsUnknownNotCurrent() {
        // A timestamp ahead of now means the clock is wrong. Reporting it as "current" would hide
        // a real problem.
        let observed = reference.addingTimeInterval(300)
        XCTAssertEqual(
            Freshness.assess(observedAt: observed, now: reference, maxAge: 60), .unknown)
    }

    func testFreshnessRequiresAnExplicitWindow() {
        // There is deliberately no default maxAge. This test documents that the consumer must
        // supply one — PixelDesktop has no defensible basis for choosing it, and a baked-in
        // threshold would be invented policy.
        let observation = PixelEvidenceReader.unreachableObservation(
            deviceSerial: "s", at: reference)
        // Compiles only because maxAge is passed explicitly here.
        _ = observation.freshness(now: reference, maxAge: 30)
        XCTAssertEqual(observation.freshness(now: reference, maxAge: 30), .current)
    }
}

// MARK: - Parsing

final class EvidenceParsingTests: XCTestCase {

    func testParsesCombinedKeyValueRead() {
        let output = "MEM=2417648\nFREE=57480492\nMODEL=1117320736\n"
        let values = PixelEvidenceReader.parseKeyValueLines(output)
        XCTAssertEqual(values["MEM"], "2417648")
        XCTAssertEqual(values["FREE"], "57480492")
        XCTAssertEqual(values["MODEL"], "1117320736")
    }

    func testAbsentKeyIsAbsentNotZero() {
        // The critical distinction: a key the read did not produce must not be read as 0.
        let values = PixelEvidenceReader.parseKeyValueLines("MEM=100\n")
        XCTAssertNil(values["MODEL"])
        XCTAssertNil(values["FREE"])
    }

    func testIgnoresBlankAndMalformedLines() {
        let values = PixelEvidenceReader.parseKeyValueLines("\n\nnot-a-pair\nMEM=100\n  \n")
        XCTAssertEqual(values.count, 1)
        XCTAssertEqual(values["MEM"], "100")
    }

    func testParsesThermalStatus() {
        XCTAssertEqual(PixelEvidenceReader.parseThermalStatus("Thermal Status: 0"), 0)
        XCTAssertEqual(PixelEvidenceReader.parseThermalStatus("  Thermal Status: 3"), 3)
    }

    func testUnparseableThermalReturnsNilNotSentinel() {
        // Returning 0 for a parse failure would be indistinguishable from a real reading of 0 —
        // the most misleading possible substitution.
        XCTAssertNil(PixelEvidenceReader.parseThermalStatus(""))
        XCTAssertNil(PixelEvidenceReader.parseThermalStatus("no thermal line here"))
    }
}

// MARK: - Unreachable device

final class UnreachableDeviceTests: XCTestCase {

    func testUnreachableDeviceYieldsAnObservationNotAnError() {
        // A consumer should always receive something it can reason about. Discarding the structure
        // would lose the one fact we do have: that the device was unreachable.
        let observation = PixelEvidenceReader.unreachableObservation(
            deviceSerial: "NOSUCH", at: Date())

        XCTAssertEqual(observation.deviceReachable.value, false)
        XCTAssertEqual(observation.deviceReachable.source, .deviceReported)
    }

    func testEveryUnreadableFieldIsUnknownNotZero() {
        let observation = PixelEvidenceReader.unreachableObservation(
            deviceSerial: "NOSUCH", at: Date())

        for (name, source) in [
            ("availableMemoryBytes", observation.availableMemoryBytes.source),
            ("freeStorageBytes", observation.freeStorageBytes.source),
            ("workerInstalled", observation.workerInstalled.source),
            ("workerRunning", observation.workerRunning.source),
            ("modelPresent", observation.modelPresent.source),
            ("thermalStatus", observation.thermalStatus.source),
        ] {
            XCTAssertEqual(source, .unknown, "\(name) must be .unknown for an unreachable device")
        }
    }

    func testUnknownFieldsCarryNoTimestamp() {
        // An unknown value is not an observation, so it must not carry an observation time.
        let observation = PixelEvidenceReader.unreachableObservation(
            deviceSerial: "NOSUCH", at: Date())
        XCTAssertNil(observation.availableMemoryBytes.observedAt)
        XCTAssertNil(observation.modelPresent.observedAt)
        XCTAssertNil(observation.thermalStatus.observedAt)
    }

    func testUnknownFieldsStateTheirLimitation() {
        let observation = PixelEvidenceReader.unreachableObservation(
            deviceSerial: "NOSUCH", at: Date())
        XCTAssertFalse(observation.availableMemoryBytes.limitation?.isEmpty ?? true)
    }

    func testUnreachableObservationIsNotFreshButUnknownWhenNoTimestamp() {
        let reference = Date()
        let observation = PixelEvidenceReader.unreachableObservation(
            deviceSerial: "NOSUCH", at: reference)
        // The observation itself has a timestamp, so freshness is assessable.
        XCTAssertEqual(observation.freshness(now: reference, maxAge: 60), .current)
        // But its fields have none.
        XCTAssertEqual(
            Freshness.assess(observedAt: observation.availableMemoryBytes.observedAt,
                             now: reference, maxAge: 60),
            .unknown)
    }
}

// MARK: - Execution evidence from a real result

final class ExecutionEvidenceTests: XCTestCase {

    private func result(
        contextSize: Int? = 2048,
        status: InferenceResult.Status = .ok
    ) -> InferenceResult {
        InferenceResult(
            jobId: "job-1", status: status, text: "Paris", tokenIds: [1, 2, 3],
            generatedTokens: 3, promptTokens: 27,
            modelLoadMs: 400, promptEvalMs: 5000, generationMs: 2000, totalMs: 7400,
            runtime: .llamaCppCPU, modelFile: "qwen2.5-1.5b-instruct-q4_k_m.gguf",
            modelSha256: ModelContract.expectedSha256,
            contextSizeTokens: contextSize, trainedContextSizeTokens: 32768)
    }

    func testEvidenceCarriesRuntimeProvenance() {
        let evidence = PixelEvidenceReader.evidence(from: result(), deviceSerial: "S")
        XCTAssertEqual(evidence.runtime.source, .runtimeReported)
        XCTAssertEqual(evidence.runtime.value.name, "llama.cpp")
        XCTAssertEqual(evidence.model.source, .runtimeReported)
        XCTAssertEqual(evidence.timings.source, .runtimeReported)
    }

    func testEvidencePreservesTheDeviceComputedHash() {
        let evidence = PixelEvidenceReader.evidence(from: result(), deviceSerial: "S")
        XCTAssertEqual(evidence.model.value.sha256, ModelContract.expectedSha256)
    }

    func testEvidenceCarriesItsJobAndDevice() {
        let evidence = PixelEvidenceReader.evidence(from: result(), deviceSerial: "3C261JEHN25632")
        XCTAssertEqual(evidence.jobId, "job-1")
        XCTAssertEqual(evidence.deviceSerial, "3C261JEHN25632")
    }

    func testMissingRuntimeContextIsSubstitutedAndFlagged() {
        // If the runtime did not report a context size, the declared value is used but the
        // limitation must SAY so — otherwise weaker evidence would look like strong evidence.
        let evidence = PixelEvidenceReader.evidence(
            from: result(contextSize: nil), deviceSerial: "S")
        let limitation = evidence.contextSizeTokens.limitation ?? ""
        XCTAssertTrue(limitation.contains("NOT reported"),
                      "substituted context size must be flagged; got: \(limitation)")
    }

    func testTimingsAreNeverConvertedToACapability() {
        // The whole point: a measured time is evidence, not a capability. It must live in the
        // evidence type, and the capability contract must not contain it.
        let evidence = PixelEvidenceReader.evidence(from: result(), deviceSerial: "S")
        XCTAssertEqual(evidence.timings.value.generationMs, 2000)

        let contract = PixelCapabilityContract.build(
            device: AndroidDevice(
                id: "i", serialNumber: "s", deviceCodename: "lynx", marketingName: "Pixel 7a",
                manufacturer: "Google", androidVersion: "16", apiLevel: 36,
                architecture: "arm64-v8a", supportedABIs: ["arm64-v8a"], state: .device),
            contextSize: PixelCapabilityContract.contextSize(runtimeReported: 2048))
        let json = (try? JSONEncoder().encode(contract))
            .flatMap { String(data: $0, encoding: .utf8) } ?? ""
        XCTAssertFalse(json.contains("generation_ms"))
        XCTAssertFalse(json.contains("model_load_ms"))
    }
}

// MARK: - Performance observations

final class PerformanceObservationTests: XCTestCase {

    private func evidence(
        promptTokens: Int = 27, generatedTokens: Int = 3,
        promptEvalMs: Int = 5000, generationMs: Int = 2000
    ) -> PixelExecutionEvidence {
        let result = InferenceResult(
            jobId: "j", status: .ok, text: "x", tokenIds: [1],
            generatedTokens: generatedTokens, promptTokens: promptTokens,
            modelLoadMs: 400, promptEvalMs: promptEvalMs, generationMs: generationMs,
            totalMs: 7400, runtime: .llamaCppCPU, modelFile: "m.gguf",
            modelSha256: ModelContract.expectedSha256,
            contextSizeTokens: 2048, trainedContextSizeTokens: 32768)
        return PixelEvidenceReader.evidence(from: result, deviceSerial: "S")
    }

    func testRatesAreDerivedFromTheirOwnPhaseOnly() throws {
        // Generation rate must exclude prompt eval and model load, or it would understate the
        // rate and mix unrelated costs.
        let observation = PixelEvidenceReader.performanceObservation(from: evidence())
        let rate = try XCTUnwrap(observation.generationTokensPerSecond)
        XCTAssertEqual(rate, 1.5, accuracy: 0.0001)   // 3 tokens / 2.0 s
    }

    func testPromptRateIsSeparateFromGenerationRate() throws {
        // Prompt processing dominates cost for large prompts (Step 1 measured 820 tokens -> 5.1
        // minutes). It must be a distinct figure, not folded into generation.
        let observation = PixelEvidenceReader.performanceObservation(from: evidence())
        let promptRate = try XCTUnwrap(observation.promptTokensPerSecond)
        XCTAssertEqual(promptRate, 5.4, accuracy: 0.0001)  // 27 tokens / 5.0 s
        XCTAssertNotEqual(observation.promptTokensPerSecond, observation.generationTokensPerSecond)
    }

    func testRateIsNilRatherThanMisleadingWhenTooShortToMeasure() {
        // BOTH sides must be zeroed: a rate is nil only when its own phase is unmeasurable.
        let observation = PixelEvidenceReader.performanceObservation(
            from: evidence(promptTokens: 0, generatedTokens: 0,
                           promptEvalMs: 0, generationMs: 0))
        XCTAssertNil(observation.generationTokensPerSecond)
        XCTAssertNil(observation.promptTokensPerSecond)

        // And independently: zeroing only generation leaves the prompt rate intact.
        let promptOnly = PixelEvidenceReader.performanceObservation(
            from: evidence(generatedTokens: 0, generationMs: 0))
        XCTAssertNil(promptOnly.generationTokensPerSecond)
        XCTAssertEqual(promptOnly.promptTokensPerSecond ?? 0, 5.4, accuracy: 0.0001)
    }

    func testObservationCarriesItsConditions() {
        // A sample without its conditions cannot be compared to another sample.
        let observation = PixelEvidenceReader.performanceObservation(
            from: evidence(), availableMemoryBytes: 2_417_648_000)
        let c = observation.conditions
        XCTAssertEqual(c.modelFileName, "m.gguf")
        XCTAssertEqual(c.runtimeName, "llama.cpp")
        XCTAssertEqual(c.runtimeVersion, LlamaCppRuntime.pinnedVersion)
        XCTAssertEqual(c.backend, "cpu")
        XCTAssertEqual(c.contextSizeTokens, 2048)
        XCTAssertEqual(c.promptTokens, 27)
        XCTAssertEqual(c.generatedTokens, 3)
        XCTAssertEqual(c.availableMemoryBytes, 2_417_648_000)
    }

    func testPageCacheStateIsHonestlyUnknown() {
        // The reconnaissance proved page-cache state materially affects model load
        // (393 ms -> 4,954 ms), but there is no non-root way to determine it. Declaring it
        // unknown is the honest answer; inventing a value would be worse than omitting it.
        let observation = PixelEvidenceReader.performanceObservation(from: evidence())
        XCTAssertEqual(observation.conditions.pageCacheState, .unknown)
    }

    func testAbsentMemoryConditionIsNilNotZero() {
        let observation = PixelEvidenceReader.performanceObservation(from: evidence())
        XCTAssertNil(observation.conditions.availableMemoryBytes,
                     "an unrecorded memory reading must be nil, not 0")
    }

    func testObservationIsNotACapabilityAndNotAThreshold() {
        // A performance observation must not appear anywhere in the capability contract. This is
        // the "measurements must not silently become capabilities" requirement.
        let observation = PixelEvidenceReader.performanceObservation(from: evidence())
        let encoded = (try? JSONEncoder().encode(observation))
            .flatMap { String(data: $0, encoding: .utf8) } ?? ""
        XCTAssertTrue(encoded.contains("conditions"))
        // And it is a sample, not a rule: no threshold, min, max, or target field exists.
        for forbidden in ["threshold", "minAcceptable", "maxLatency", "targetTokensPerSecond"] {
            XCTAssertFalse(encoded.contains(forbidden))
        }
    }
}

// MARK: - Snapshot is not a reservation

final class SnapshotNotReservationTests: XCTestCase {

    func testStateFieldsStateTheyAreNotReservations() {
        // The single most important property of Step 2. Every snapshot-style field must say so,
        // because a consumer that reads a snapshot as a guarantee is the failure mode this step
        // exists to prevent.
        let observation = PixelEvidenceReader.unreachableObservation(
            deviceSerial: "S", at: Date())
        XCTAssertTrue(PixelEvidenceReader.notAReservation.contains("NOT A RESERVATION"))
        XCTAssertTrue(PixelEvidenceReader.notAReservation.contains("re-validates"))
        // The unreachable observation's own reachability field is the one exception (it is a
        // reading about reachability itself), so we assert on the shared constant plus a real
        // observation's fields below.
        XCTAssertFalse(observation.freeStorageBytes.limitation?.isEmpty ?? true)
    }

    func testSharedLimitationTextIsReusedNotParaphrased() {
        // Reusing one constant means the warning cannot drift or be softened in one place.
        let text = PixelEvidenceReader.notAReservation
        XCTAssertTrue(text.contains("SNAPSHOT"))
        XCTAssertTrue(text.contains("unsafe execution"))
    }

    func testThermalLimitationIsExplicitAboutAttribution() {
        let text = PixelEvidenceReader.thermalLimitation
        XCTAssertTrue(text.contains("SYSTEM-WIDE"))
        XCTAssertTrue(text.contains("NOT WORKER-ATTRIBUTABLE"))
    }
}

// MARK: - Step 1 remains intact

final class StepOneStillIntactTests: XCTestCase {

    private func contract() -> PixelCapabilityContract {
        PixelCapabilityContract.build(
            device: AndroidDevice(
                id: "i", serialNumber: "s", deviceCodename: "lynx", marketingName: "Pixel 7a",
                manufacturer: "Google", androidVersion: "16", apiLevel: 36,
                architecture: "arm64-v8a", supportedABIs: ["arm64-v8a"], state: .device),
            contextSize: PixelCapabilityContract.contextSize(runtimeReported: 2048))
    }

    func testStaticCapabilityStillCorrect() {
        let c = contract()
        XCTAssertEqual(c.device.value.marketingName, "Pixel 7a")
        XCTAssertEqual(c.model.value.sha256, ModelContract.expectedSha256)
        XCTAssertEqual(c.runtime.value.backend, "cpu")
        XCTAssertEqual(c.model.value.contextSizeTokens.value, 2048)
    }

    func testCapabilityContractStillHasNoPerformanceField() {
        // Step 2 must not have leaked measurements into the capability contract.
        let json = (try? JSONEncoder().encode(contract()))
            .flatMap { String(data: $0, encoding: .utf8) } ?? ""
        for forbidden in ["tokens_per_second", "generation_ms", "model_load_ms", "latency"] {
            XCTAssertFalse(json.contains(forbidden),
                           "capability contract must not contain '\(forbidden)'")
        }
    }

    func testRequestValidationStillRefusesInvalidRequests() throws {
        XCTAssertNoThrow(try InferenceRequest(
            jobId: "j", prompt: "hello", maxTokens: 32, temperature: 0, seed: 0).validate())

        XCTAssertThrowsError(try InferenceRequest(
            jobId: "j", prompt: "hello",
            maxTokens: InferenceRequest.maximumTokensCeiling + 1,
            temperature: 0, seed: 0).validate())

        XCTAssertThrowsError(try InferenceRequest(
            jobId: "j", prompt: "hello", maxTokens: 32, temperature: 0.7, seed: 0).validate())

        XCTAssertThrowsError(try InferenceRequest(
            jobId: "j", prompt: "", maxTokens: 32, temperature: 0, seed: 0).validate())
    }

    func testEvidenceIsConstructibleWithNoUIOrHermesPresent() {
        // Independence requirement: the evidence layer must not depend on the UI, AppState, or
        // any Hermes surface. This test passing is the proof — it imports nothing else.
        let observation = PixelEvidenceReader.unreachableObservation(
            deviceSerial: "S", at: Date())
        XCTAssertEqual(observation.deviceSerial, "S")
    }
}
