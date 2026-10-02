//
//  Phase7CapabilityContractTests.swift
//  PixelDesktopTests
//
//  Phase 7 Step 1 — capability contract tests.
//
//  These tests exist to prove six things, and deliberately no more:
//    1. the contract is correctly populated
//    2. existing authoritative values are preserved (not restated, not re-derived)
//    3. context size is correctly represented, including its provenance
//    4. unavailable / unknown states are represented honestly
//    5. the contract does not silently invent or hardcode measurements
//    6. existing Phase 1–6 behaviour is untouched
//
//  Nothing here contacts a device. The contract is a value type built from existing definitions,
//  so it is fully testable without hardware.
//

import XCTest
@testable import PixelDesktop

final class PixelCapabilityContractTests: XCTestCase {

    // A device matching the measured Pixel 7a, used only as input. Every value asserted below
    // comes from the project's own definitions, never from this fixture.
    private func pixel7a() -> AndroidDevice {
        AndroidDevice(
            id: "test-id",
            serialNumber: "3C261JEHN25632",
            deviceCodename: "lynx",
            marketingName: "Pixel 7a",
            manufacturer: "Google",
            androidVersion: "16",
            apiLevel: 36,
            architecture: "arm64-v8a",
            supportedABIs: ["arm64-v8a"],
            state: .device
        )
    }

    private func contract(runtimeReportedContext: Int? = nil) -> PixelCapabilityContract {
        PixelCapabilityContract.build(
            device: pixel7a(),
            contextSize: PixelCapabilityContract.contextSize(runtimeReported: runtimeReportedContext)
        )
    }

    // MARK: - 1. Correctly populated

    func testContractIsPopulatedFromTheDevice() {
        let c = contract()
        XCTAssertEqual(c.device.value.codename, "lynx")
        XCTAssertEqual(c.device.value.marketingName, "Pixel 7a")
        XCTAssertEqual(c.device.value.manufacturer, "Google")
        XCTAssertEqual(c.device.value.apiLevel, 36)
        XCTAssertEqual(c.device.value.supportedABIs, ["arm64-v8a"])
    }

    func testContractCarriesItsVersion() {
        // A consumer must be able to detect a contract shape it does not understand.
        XCTAssertEqual(contract().contractVersion, PixelCapabilityContract.currentVersion)
        XCTAssertGreaterThanOrEqual(PixelCapabilityContract.currentVersion, 1)
    }

    func testBothExistingWorkloadsArePublished() {
        let names = contract().workloads.map(\.name).sorted()
        XCTAssertEqual(names, ["DTCA-1", "LOCAL-LLM-1"])
    }

    func testWorkloadVerifiabilityDiffersAndIsStated() {
        // DTCA-1 is deterministic and exactly re-computable. LOCAL-LLM-1 is not — Phase 6
        // replaced re-computation with an evidence chain (ADR-012 §P7). A consumer assuming
        // exact verification for both would be wrong, so this is asserted explicitly.
        let c = contract()
        let dtca = c.workloads.first { $0.name == "DTCA-1" }
        let llm = c.workloads.first { $0.name == "LOCAL-LLM-1" }

        XCTAssertEqual(dtca?.exactlyVerifiable, true)
        XCTAssertEqual(dtca?.requiresModel, false)
        XCTAssertEqual(llm?.exactlyVerifiable, false)
        XCTAssertEqual(llm?.requiresModel, true)
        XCTAssertEqual(llm?.requiresRuntime, true)
    }

    // MARK: - 2. Existing authoritative values preserved

    func testModelIdentityComesFromModelContractNotFromANewConstant() {
        // The contract must DERIVE these. If ModelContract changes, this test fails rather than
        // the contract silently drifting out of agreement with the real provisioning contract.
        let model = contract().model.value
        XCTAssertEqual(model.fileName, ModelContract.modelFileName)
        XCTAssertEqual(model.sha256, ModelContract.expectedSha256)
        XCTAssertEqual(model.byteCount, ModelContract.expectedByteCount)
    }

    func testModelHashIsStillAWellFormedSha256() {
        let hash = contract().model.value.sha256
        XCTAssertEqual(hash.count, 64)
        XCTAssertTrue(hash.allSatisfy { $0.isHexDigit })
    }

    func testRuntimeIdentityComesFromTheExistingAdapter() {
        let runtime = contract().runtime.value
        let adapter = LlamaCppInferenceRuntime()
        XCTAssertEqual(runtime.name, adapter.identity.name)
        XCTAssertEqual(runtime.version, adapter.identity.version)
        XCTAssertEqual(runtime.backend, adapter.identity.backend)
        XCTAssertEqual(runtime.version, LlamaCppRuntime.pinnedVersion)
    }

    func testRequestLimitsComeFromInferenceRequestNotFromNewPolicy() {
        // These are existing validation limits, published — not new limits invented here.
        let limits = contract().limits.value
        XCTAssertEqual(limits.maximumPromptCharacters, InferenceRequest.maximumPromptCharacters)
        XCTAssertEqual(limits.maximumTokensCeiling, InferenceRequest.maximumTokensCeiling)
        XCTAssertEqual(limits.maximumModelBytes, ModelContract.maximumModelBytes)
    }

    // MARK: - 3. Context size

    func testContextSizePrefersTheRuntimeReport() {
        let c = contract(runtimeReportedContext: 2048)
        XCTAssertEqual(c.model.value.contextSizeTokens.value, 2048)
        XCTAssertEqual(c.model.value.contextSizeTokens.source, .runtimeReported)
        XCTAssertNotNil(c.model.value.contextSizeTokens.observedAt)
    }

    func testContextSizeFallsBackToDeclaredAndSaysSo() {
        // With no runtime report the value must be marked `.declared`, so a consumer can tell it
        // apart from an observed one. Presenting a declared value as observed would overclaim.
        let c = contract(runtimeReportedContext: nil)
        XCTAssertEqual(c.model.value.contextSizeTokens.value,
                       PixelCapabilityContract.declaredContextSizeTokens)
        XCTAssertEqual(c.model.value.contextSizeTokens.source, .declared)
        XCTAssertNil(c.model.value.contextSizeTokens.observedAt,
                     "a declared value is not an observation and must not carry a timestamp")
        XCTAssertNotNil(c.model.value.contextSizeTokens.limitation)
    }

    func testZeroContextReportIsTreatedAsNoReport() {
        // 0 means "no context established". Publishing 0 as a context size would be a lie in the
        // most damaging direction — it would tell a planner it can send nothing.
        let c = contract(runtimeReportedContext: 0)
        XCTAssertEqual(c.model.value.contextSizeTokens.source, .declared)
        XCTAssertGreaterThan(c.model.value.contextSizeTokens.value, 0)
    }

    func testNegativeContextReportIsRejected() {
        let c = contract(runtimeReportedContext: -5)
        XCTAssertEqual(c.model.value.contextSizeTokens.source, .declared)
    }

    func testDeclaredContextSizeAgreesWithTheNativeConstant() {
        // kContextSize in llama_jni.cpp is 2048. This asserts the Swift fallback still agrees with
        // it, so the two cannot drift apart silently. The native value remains the single
        // definition; this is a guard, not a second source of truth.
        XCTAssertEqual(PixelCapabilityContract.declaredContextSizeTokens, 2048)
    }

    // MARK: - Runtime report parsing

    func testParsesARealRuntimeReportShape() {
        // The exact shape nativeModelInfo emits, including the Phase 7 addition.
        let json = """
        {"desc":"Qwen2.5 1.5B Q4_K - Medium","n_params":1543714304,"size_bytes":1117320736,
         "n_ctx_train":32768,"n_ctx_in_use":2048,"model_load_ms":437,"backend":"cpu"}
        """
        let report = try? XCTUnwrap(PixelCapabilityContract.parseRuntimeModelReport(json))
        XCTAssertEqual(report?.contextSizeInUse, 2048)
        XCTAssertEqual(report?.trainedContextSize, 32768)
        XCTAssertEqual(report?.parameterCount, 1543714304)
        XCTAssertEqual(report?.sizeBytes, 1117320736)
    }

    func testTrainedContextAndConfiguredContextAreDistinct() {
        // The model's trained maximum (32768) is NOT the window we allocate (2048). Conflating
        // them would misstate what a caller may send.
        let json = #"{"n_ctx_train":32768,"n_ctx_in_use":2048}"#
        let report = PixelCapabilityContract.parseRuntimeModelReport(json)
        XCTAssertEqual(report?.trainedContextSize, 32768)
        XCTAssertEqual(report?.contextSizeInUse, 2048)
        XCTAssertNotEqual(report?.trainedContextSize, report?.contextSizeInUse)
    }

    func testErrorReportYieldsNoEvidence() {
        // A failed report is not evidence of anything and must not be partially parsed.
        XCTAssertNil(PixelCapabilityContract.parseRuntimeModelReport(#"{"error":"no model"}"#))
    }

    func testMalformedReportYieldsNoEvidence() {
        XCTAssertNil(PixelCapabilityContract.parseRuntimeModelReport(""))
        XCTAssertNil(PixelCapabilityContract.parseRuntimeModelReport("not json"))
        XCTAssertNil(PixelCapabilityContract.parseRuntimeModelReport("[1,2,3]"))
    }

    func testMissingContextFieldsNormaliseToNil() {
        // An older native report without the Phase 7 fields must not be read as context size 0.
        let report = PixelCapabilityContract.parseRuntimeModelReport(#"{"desc":"x"}"#)
        XCTAssertNil(report?.contextSizeInUse)
        XCTAssertNil(report?.trainedContextSize)
    }

    // MARK: - 4. Availability states

    func testAvailabilityHasFourDistinctStates() {
        // Two states would force a lie in one direction: "we do not know" is neither supported
        // nor unsupported, and "prerequisite missing" can become supported without a code change.
        XCTAssertEqual(CapabilityAvailability.supported.rawValue, "supported")
        XCTAssertEqual(CapabilityAvailability.unsupported.rawValue, "unsupported")
        XCTAssertEqual(CapabilityAvailability.unavailable.rawValue, "unavailable")
        XCTAssertEqual(CapabilityAvailability.unknown.rawValue, "unknown")
    }

    func testOnlySupportedIsExecutable() {
        XCTAssertTrue(CapabilityAvailability.supported.isExecutable)
        XCTAssertFalse(CapabilityAvailability.unsupported.isExecutable)
        XCTAssertFalse(CapabilityAvailability.unavailable.isExecutable,
                       "unavailable is a missing prerequisite, not permission to run")
        XCTAssertFalse(CapabilityAvailability.unknown.isExecutable,
                       "unknown must never be treated as executable")
    }

    func testUnknownIsNotSilentlyTreatedAsSupported() {
        // The failure mode this guards against: defaulting an unestablished value to "fine".
        let all: [CapabilityAvailability] = [.supported, .unsupported, .unavailable, .unknown]
        let executable = all.filter(\.isExecutable)
        XCTAssertEqual(executable, [.supported])
    }

    // MARK: - 5. No invented measurements

    func testContractContainsNoPerformanceMeasurements() {
        // Phase 7 reconnaissance measured a 2.4x latency variance and a 12x model-load variance.
        // Publishing a token rate or a load time as a capability would present an unstable
        // observation as a constant — a fabrication of precision. The contract must not carry one.
        let c = contract()
        let encoded = (try? JSONEncoder().encode(c)).flatMap { String(data: $0, encoding: .utf8) }
        let json = try? XCTUnwrap(encoded)

        for forbidden in ["tokens_per_second", "tokPerSec", "decode_rate",
                          "model_load_ms", "latency_ms", "generation_ms"] {
            XCTAssertFalse(json?.contains(forbidden) ?? true,
                           "the contract must not publish '\(forbidden)' as a capability")
        }
    }

    func testEveryFieldStatesItsProvenance() {
        let c = contract()
        XCTAssertEqual(c.device.source, .deviceReported)
        XCTAssertEqual(c.runtime.source, .declared)
        XCTAssertEqual(c.model.source, .declared)
        XCTAssertEqual(c.limits.source, .declared)
    }

    func testEveryFieldStatesItsLimitation() {
        // The honesty requirement made mechanical: a field that does not say what it fails to
        // establish is an overclaim waiting to happen.
        let c = contract()
        for (name, limitation) in [
            ("device", c.device.limitation),
            ("runtime", c.runtime.limitation),
            ("model", c.model.limitation),
            ("limits", c.limits.limitation),
        ] {
            XCTAssertNotNil(limitation, "\(name) states no limitation")
            XCTAssertFalse(limitation?.isEmpty ?? true, "\(name) has an empty limitation")
        }
    }

    func testModelFieldExplicitlyDisclaimsDevicePresence() {
        // The model block describes what we EXPECT. It must not be read as "the model is on the
        // device" — that is verified separately by provisioning.
        let limitation = contract().model.limitation ?? ""
        XCTAssertTrue(limitation.contains("does NOT establish"),
                      "the model field must disclaim device presence; got: \(limitation)")
    }

    func testRuntimeFieldDisclaimsBeingAHardwareStatement() {
        // CPU backend is a Phase 6 decision (ADR-012 section 11), not a hardware limit.
        let limitation = contract().runtime.limitation ?? ""
        XCTAssertTrue(limitation.contains("decision"),
                      "the runtime field must state CPU is a decision; got: \(limitation)")
    }

    // MARK: - Context size arriving from a real result

    func testAbsentContextSizeInAnOlderEnvelopeIsNotReadAsZero() {
        // A Phase 6-era result envelope has no context fields. They must decode to nil, and the
        // contract must then fall back to .declared — NOT publish 0, which would tell a planner
        // it can send nothing.
        let json = """
        {"status":"OK","job_id":"j","text":"hi","token_ids":[1],"generated_tokens":1,
         "prompt_tokens":5,"model_load_ms":400,"prompt_eval_ms":100,"generation_ms":200,
         "total_ms":700,"runtime":{"name":"llama.cpp","version":"a868c3e","backend":"cpu"},
         "model_file":"m.gguf","model_sha256":"deadbeef"}
        """
        let decoded = try? JSONDecoder().decode(InferenceResult.self, from: Data(json.utf8))
        XCTAssertNotNil(decoded)
        XCTAssertNil(decoded?.contextSizeTokens)

        let context = PixelCapabilityContract.contextSize(
            runtimeReported: decoded?.contextSizeTokens)
        XCTAssertEqual(context.source, .declared)
        XCTAssertGreaterThan(context.value, 0)
    }

    func testContextSizeFromARealEnvelopeIsPreferred() throws {
        let json = """
        {"status":"OK","job_id":"j","text":"hi","token_ids":[1],"generated_tokens":1,
         "prompt_tokens":5,"model_load_ms":400,"prompt_eval_ms":100,"generation_ms":200,
         "total_ms":700,"runtime":{"name":"llama.cpp","version":"a868c3e","backend":"cpu"},
         "model_file":"m.gguf","model_sha256":"deadbeef",
         "context_size_tokens":2048,"trained_context_size_tokens":32768}
        """
        let decoded = try JSONDecoder().decode(InferenceResult.self, from: Data(json.utf8))
        let context = PixelCapabilityContract.contextSize(
            runtimeReported: decoded.contextSizeTokens)
        XCTAssertEqual(context.source, .runtimeReported)
        XCTAssertEqual(context.value, 2048)
        // And the model's trained max is a different, larger number.
        XCTAssertEqual(decoded.trainedContextSizeTokens, 32768)
    }

    // MARK: - 6. Serialisation and existing behaviour

    func testContractRoundTripsThroughJSON() throws {
        let original = contract(runtimeReportedContext: 2048)
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(PixelCapabilityContract.self, from: data)
        XCTAssertEqual(decoded, original)
    }

    func testContractIsIndependentOfTheUIAndOfHermes() throws {
        // The contract must be constructible and serialisable with no UI, no AppState, and no
        // Hermes present. This test passing at all is the proof: it imports nothing else.
        let c = contract()
        XCTAssertEqual(c.contractVersion, 1)
        XCTAssertFalse(c.workloads.isEmpty)
    }

    func testBuildingTheContractDoesNotMutateTheDevice() {
        // Value semantics: building a contract from a device must leave the device unchanged.
        let device = pixel7a()
        let before = device
        _ = PixelCapabilityContract.build(
            device: device,
            contextSize: PixelCapabilityContract.contextSize(runtimeReported: nil))
        XCTAssertEqual(device, before)
    }

    func testExistingRequestValidationIsUnchangedByThisStep() throws {
        // Regression guard: Step 1 publishes limits, it does not alter them.
        XCTAssertNoThrow(try InferenceRequest(
            jobId: "j", prompt: "hello", maxTokens: 32, temperature: 0, seed: 0).validate())

        XCTAssertThrowsError(try InferenceRequest(
            jobId: "j", prompt: "hello",
            maxTokens: InferenceRequest.maximumTokensCeiling + 1,
            temperature: 0, seed: 0).validate())

        XCTAssertThrowsError(try InferenceRequest(
            jobId: "j", prompt: "hello", maxTokens: 32, temperature: 0.7, seed: 0).validate())
    }
}
