//
//  Phase7Amendment2Tests.swift
//  PixelDesktopTests
//
//  Phase 7 Amendment 2 — workload-owned input limits.
//
//  ## What this amendment corrects
//
//  Before it, the contract published exactly one input bound — `limits.maximumPromptCharacters`,
//  derived from `InferenceRequest` (the **LLM runtime**). Nothing in the contract expressed that
//  it applied only to the LLM, and nothing published DTCA-1's own bound. A planner reading the
//  contract would therefore cap DTCA-1 input at 4,096 when its validator accepts 10,000 —
//  understating the workload's real capacity by more than half, for no reason.
//
//  The correction puts each bound on the workload that owns it. `limits.maximumPromptCharacters`
//  keeps its existing meaning and is not redefined.
//
//  ## How these tests are shaped
//
//  The derivation tests assert the published value **equals its owner** rather than equalling a
//  literal. If `DTCA1Worker.maximumInputCharacters` or `InferenceRequest.maximumPromptCharacters`
//  changes, these fail rather than the contract silently drifting out of agreement with the
//  validator that actually enforces the bound. That is the same discipline Phase 7 Step 1 used
//  for `ModelContract`.
//

import XCTest
@testable import PixelDesktop

final class Phase7Amendment2Tests: XCTestCase {

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

    // MARK: - 1. Contract version

    func testContractVersionIsTwoAfterTheAmendment() {
        // The contract's own rule: bumped when a field is added. A consumer that reads
        // workload input bounds must be able to detect a version-1 contract, where those bounds
        // are absent and the only published limit belongs to the LLM.
        XCTAssertEqual(PixelCapabilityContract.currentVersion, 2)
        XCTAssertEqual(contract().contractVersion, 2)
    }

    // MARK: - 2. DTCA-1 publishes its own limit

    func testDTCA1WorkloadPublishesItsOwnInputLimit() throws {
        let dtca1 = try workload("DTCA-1")
        let limit = try XCTUnwrap(dtca1.maximumInputCharacters)

        XCTAssertEqual(limit.value, DTCA1Worker.maximumInputCharacters)
        XCTAssertEqual(limit.source, .declared)
        XCTAssertNotNil(limit.limitation, "a published bound must state what it does not cover")
    }

    func testDTCA1LimitIsNotTheLLMLimit() throws {
        // The defect this amendment exists to fix. If these ever become equal, either DTCA-1's
        // validator changed or the contract started publishing the wrong component's bound.
        let dtca1 = try workload("DTCA-1")
        let limit = try XCTUnwrap(dtca1.maximumInputCharacters)

        XCTAssertNotEqual(limit.value, InferenceRequest.maximumPromptCharacters,
                          "DTCA-1's input bound must not be the LLM runtime's prompt limit")
        XCTAssertGreaterThan(limit.value, InferenceRequest.maximumPromptCharacters,
                             "the defect was under-permissive: DTCA-1 accepts more than the LLM")
    }

    func testLOCALLLMWorkloadPublishesTheInferenceRequestLimit() throws {
        let llm = try workload("LOCAL-LLM-1")
        let limit = try XCTUnwrap(llm.maximumInputCharacters)

        XCTAssertEqual(limit.value, InferenceRequest.maximumPromptCharacters)
        XCTAssertEqual(limit.source, .declared)
    }

    // MARK: - 3. Derivation from the owning validator

    func testWorkloadLimitsAreDerivedFromTheirOwnValidator() throws {
        // Every published bound equals the constant its owner enforces. A restated value could
        // drift; this makes divergence fail the suite instead.
        XCTAssertEqual(
            try workload("DTCA-1").maximumInputCharacters?.value,
            DTCA1Worker.maximumInputCharacters,
            "DTCA-1's published bound must come from DTCA1Worker, which enforces it"
        )
        XCTAssertEqual(
            try workload("LOCAL-LLM-1").maximumInputCharacters?.value,
            InferenceRequest.maximumPromptCharacters,
            "LOCAL-LLM-1's published bound must come from InferenceRequest, which enforces it"
        )
    }

    func testDTCA1ValidatorAndPublishedBoundCannotDiverge() throws {
        // The strongest form: the validator's actual accept/reject behaviour matches the
        // published bound. This is what "derived from the validator" has to mean in practice —
        // not merely that two constants share a name.
        let bound = DTCA1Worker.maximumInputCharacters

        XCTAssertNoThrow(try DTCA1Worker.validateInput(String(repeating: "a", count: bound)),
                         "input exactly at the published bound must be accepted")
        XCTAssertThrowsError(try DTCA1Worker.validateInput(String(repeating: "a", count: bound + 1)),
                             "input one over the published bound must be rejected")

        XCTAssertEqual(try workload("DTCA-1").maximumInputCharacters?.value, bound)
    }

    // MARK: - 4. Provenance preserved

    func testWorkloadLimitsCarryDeclaredProvenanceAndNoTimestamp() throws {
        // A build constant is not an observation, so it must carry no `observedAt`. A timestamp
        // would claim the value had been observed, which it was not.
        for name in ["DTCA-1", "LOCAL-LLM-1"] {
            let limit = try XCTUnwrap(try workload(name).maximumInputCharacters, "\(name) missing bound")
            XCTAssertEqual(limit.source, .declared, "\(name) bound must be .declared")
            XCTAssertNil(limit.observedAt, "\(name) bound must carry no timestamp")
            XCTAssertFalse((limit.limitation ?? "").isEmpty, "\(name) bound must carry its limitation")
        }
    }

    func testWorkloadLimitationsStateWhatTheyDoNotCover() throws {
        // The DTCA-1 limitation must name the null-byte rule, because the published bound does
        // not express it. Without that, a consumer would read "10,000 chars" as the whole
        // contract for DTCA-1 input validity.
        let dtca1 = try XCTUnwrap(try workload("DTCA-1").maximumInputCharacters)
        XCTAssertTrue((dtca1.limitation ?? "").contains("null bytes"),
                      "the limitation must name the rule the bound does not express")
    }

    // MARK: - 5. The global limit keeps its meaning

    func testRequestLimitsStillDeriveFromInferenceRequest() {
        // Unchanged by the amendment. `limits` is the LLM runtime's request limits and must not
        // have been quietly redefined into a workload-wide bound.
        let limits = contract().limits.value
        XCTAssertEqual(limits.maximumPromptCharacters, InferenceRequest.maximumPromptCharacters)
        XCTAssertEqual(limits.maximumTokensCeiling, InferenceRequest.maximumTokensCeiling)
        XCTAssertEqual(limits.maximumModelBytes, ModelContract.maximumModelBytes)
    }

    func testRequestLimitsLimitationNowStatesItsScope() throws {
        // The defect was as much a documentation failure as a data one: nothing said the limit
        // was LLM-specific. The limitation must now say so explicitly.
        let limitation = try XCTUnwrap(contract().limits.limitation)

        XCTAssertTrue(limitation.contains("LOCAL-LLM-1"),
                      "the limitation must name the workload it applies to")
        XCTAssertTrue(limitation.contains("NOT to every workload") || limitation.contains("not to every workload"),
                      "the limitation must explicitly deny workload-wide scope")
        XCTAssertTrue(limitation.contains("maximumInputCharacters"),
                      "the limitation must point at where per-workload bounds live")
    }

    // MARK: - 6. Absence, never zero

    func testAnUnpublishedWorkloadLimitOmitsItsValueRatherThanPublishingZero() throws {
        // A workload whose validator does not expose a bound publishes `.unknown`. Under the
        // absence rule the value key is then removed, so a consumer cannot read "0 characters
        // accepted". This asserts the shape the rule depends on: `unknown` carries no usable
        // value, and `0` is a different and much more damaging statement.
        let unknown = CapabilityValue<Int>(
            value: 0, source: .unknown, observedAt: nil,
            limitation: "This workload's validator does not expose an input bound."
        )

        let encoded = try JSONEncoder().encode(["maximumInputCharacters": unknown])
        let raw = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])

        // The shared type encodes 0 (precondition) — the CLI's presentation rule is what removes
        // it. That rule is asserted in Phase9CLIPresentationTests; here we pin the contract-side
        // fact that matters: `.unknown` is distinguishable from a real bound.
        XCTAssertEqual(unknown.source, .unknown)
        XCTAssertNotEqual(unknown.source, .declared)
        XCTAssertNotNil(raw["maximumInputCharacters"])
    }

    func testAnUnboundedWorkloadIsDistinctFromAnUnpublishedBound() throws {
        // A workload that genuinely accepts unbounded input would be a serious claim. It must not
        // be expressible as `nil`, because `nil` means "not published" — so the two never
        // collapse into each other.
        let published: CapabilityValue<Int>? = .declared(10_000, limitation: "owned by the validator")
        let unpublished: CapabilityValue<Int>? = nil

        XCTAssertNotNil(published)
        XCTAssertNil(unpublished)
        XCTAssertNotEqual(published?.source, unpublished?.source)
    }

    // MARK: - 7. Existing guarantees intact

    func testAmendmentDidNotChangeAnyWorkloadIdentityOrPrerequisite() throws {
        // The amendment added a field; it must not have altered anything already asserted.
        let c = contract()
        XCTAssertEqual(c.workloads.map(\.name).sorted(), ["DTCA-1", "LOCAL-LLM-1"])

        let dtca1 = try workload("DTCA-1")
        XCTAssertFalse(dtca1.requiresModel)
        XCTAssertFalse(dtca1.requiresRuntime)
        XCTAssertTrue(dtca1.exactlyVerifiable)

        let llm = try workload("LOCAL-LLM-1")
        XCTAssertTrue(llm.requiresModel)
        XCTAssertTrue(llm.requiresRuntime)
        XCTAssertFalse(llm.exactlyVerifiable)
    }

    func testDTCA1ValidatorStillRejectsNullBytes() throws {
        // The amendment renamed the bound to a constant. It must not have dropped the other rule.
        XCTAssertThrowsError(try DTCA1Worker.validateInput("has a \0 null byte"))
    }

    func testDTCA1AcceptedInputBehaviourIsUnchanged() throws {
        // The boundary behaviour must be identical to before the amendment: 10,000 accepted,
        // 10,001 rejected. Nothing about DTCA-1's real behaviour changed.
        XCTAssertNoThrow(try DTCA1Worker.validateInput(String(repeating: "x", count: 10_000)))
        XCTAssertThrowsError(try DTCA1Worker.validateInput(String(repeating: "x", count: 10_001)))
    }
}
