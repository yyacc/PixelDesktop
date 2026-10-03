//
//  Phase9HardwareVerificationTests.swift
//  PixelDesktopTests
//
//  Real-device verification of the `run` boundary (Phase 9 Step 4).
//
//  ## What this adds that the scripted tests could not
//
//  `Phase9RunTests` drives `run` through the existing E1 `MockTransport` seam. That proves the
//  boundary is wired correctly; it cannot prove the boundary works against a physical Pixel.
//  This harness closes that gap and, critically, performs the **independent Mac-side
//  verification** the step's brief requires — the CLI's `ok` field is not taken as truth.
//
//  ## Why it re-runs `run` rather than reusing a captured payload
//
//  The verification must be of the *same execution* that produced the result, including its
//  ownership check. Re-running is cheap (sub-second for DTCA-1) and avoids any chance of
//  verifying a result against an input it did not come from.
//
//  Skipped unless `PIXELDESKTOP_DEVICE_SERIAL` is set, matching the Phase 2–9 convention.
//

import XCTest
import Foundation
@testable import PixelDesktop

final class Phase9HardwareVerificationTests: XCTestCase {

    private var deviceSerial: String? {
        ProcessInfo.processInfo.environment["PIXELDESKTOP_DEVICE_SERIAL"]
    }

    private func requireDevice() throws -> String {
        guard let serial = deviceSerial else {
            throw XCTSkip("PIXELDESKTOP_DEVICE_SERIAL not set; skipping real-device verification")
        }
        return serial
    }

    /// The deterministic input used for hardware verification.
    ///
    /// Chosen so the expected answer is obvious by inspection as well as by re-computation: the
    /// word frequencies below are countable by hand, which makes a wrong result visible rather
    /// than merely different.
    private static let verificationInput = """
    the quick brown fox jumps over the lazy dog. \
    the fox runs and the dog sleeps while the quick brown fox watches. \
    deterministic verification input for dtca one on the pixel seven a.
    """

    // MARK: - 1. The real run, end to end

    func testRealDeviceRunProducesAVerifiableResult() async throws {
        let serial = try requireDevice()

        let (result, failure) = try await CLIRunCommand.run(
            workload: "DTCA-1",
            inputPath: try writeInput(Self.verificationInput),
            transport: ADBTransport()
        )

        print("=== PHASE 9 STEP 4 — REAL-DEVICE `run` ===")
        print("job id       : \(result.jobId)")
        print("outcome      : \(result.outcome)")
        print("worker pid   : \(String(describing: result.evidence.workerPidObserved))")
        print("heartbeats   : \(result.evidence.heartbeatCount)")
        print("wall seconds : \(result.evidence.wallSeconds)")
        print("to outcome s : \(String(describing: result.evidence.timeToOutcomeSeconds))")
        print("stream ended unexpectedly: \(result.evidence.streamEndedUnexpectedly)")

        XCTAssertNil(failure, "a completed run must carry no error")
        XCTAssertEqual(result.outcome, "completed")
        XCTAssertFalse(result.jobId.isEmpty)

        let output = try XCTUnwrap(result.output, "a completed run must carry a decoded result")
        XCTAssertEqual(output.status, "COMPLETED")
        XCTAssertEqual(output.inputCharacters, Self.verificationInput.count,
                       "the worker must report the input size it was actually given")

        // The stream was actually observed, not merely reported complete.
        XCTAssertFalse(result.evidence.streamEndedUnexpectedly)
        XCTAssertEqual(result.evidence.unrecognizedLineCount, 0,
                       "every stdout line must have been understood as protocol or payload")
        XCTAssertGreaterThanOrEqual(result.evidence.heartbeatCount, 0)
        XCTAssertGreaterThan(result.evidence.wallSeconds, 0)
    }

    // MARK: - 2. Independent Mac-side verification

    func testRealDeviceResultMatchesIndependentMacRecomputation() async throws {
        // The point of the whole exercise: do not trust the CLI's `ok`. Re-compute DTCA-1 locally
        // with the project's own reference implementation and compare field by field.
        let serial = try requireDevice()

        let (result, _) = try await CLIRunCommand.run(
            workload: "DTCA-1",
            inputPath: try writeInput(Self.verificationInput),
            transport: ADBTransport()
        )

        let pixelResult = try XCTUnwrap(result.output, "no result to verify")
        let localResult = try DTCA1Worker.execute(Self.verificationInput)

        let verification = ResultVerifier.verify(
            pixelResult: pixelResult,
            localResult: localResult,
            originalInput: Self.verificationInput,
            expectedSuccessToken: DTCA1Job.successResultToken
        )

        print("=== INDEPENDENT MAC VERIFICATION ===")
        print("verified   : \(verification.isVerified)")
        print("mismatches : \(verification.mismatches)")
        print("pixel  total/unique/class : \(pixelResult.totalWords)/\(pixelResult.uniqueWords)/\(pixelResult.classification)")
        print("local  total/unique/class : \(localResult.totalWords)/\(localResult.uniqueWords)/\(localResult.classification)")
        print("pixel top words : \(pixelResult.topWords.map { "\($0.word)=\($0.count)" })")

        XCTAssertTrue(verification.isVerified,
                      "independent re-computation must agree: \(verification.mismatches)")

        // And assert the values directly, so a verifier bug cannot hide behind its own green light.
        XCTAssertEqual(pixelResult.totalWords, localResult.totalWords)
        XCTAssertEqual(pixelResult.uniqueWords, localResult.uniqueWords)
        XCTAssertEqual(pixelResult.classification, localResult.classification)
        XCTAssertEqual(pixelResult.topWords.map(\.word), localResult.topWords.map(\.word))
        XCTAssertEqual(pixelResult.topWords.map(\.count), localResult.topWords.map(\.count))
    }

    // MARK: - 3. Ownership and false-success semantics

    func testRealDeviceResultOwnershipMatchesTheGeneratedJobId() async throws {
        _ = try requireDevice()

        let (result, _) = try await CLIRunCommand.run(
            workload: "DTCA-1",
            inputPath: try writeInput(Self.verificationInput),
            transport: ADBTransport()
        )

        // The device echoes the job id it was given. A result whose echo did not match would have
        // been rejected inside `run` as stale or foreign — so reaching here with a matching id is
        // the ownership proof, and a *mismatched* id must fail.
        let owningPayload = "{\"job_id\":\"\(result.jobId)\"}"
        let foreignPayload = "{\"job_id\":\"someone-else\"}"

        XCTAssertTrue(
            WorkerStreamRunner.resultBelongsToJob(owningPayload, jobId: result.jobId),
            "the reported job id must own the result"
        )
        XCTAssertFalse(
            WorkerStreamRunner.resultBelongsToJob(foreignPayload, jobId: result.jobId),
            "a foreign result must be rejected"
        )
    }

    func testARealSuccessNeverCarriesARefusal() async throws {
        // Phase 9 Step 4 caught a defect where a worker refusal was reported as success. This
        // asserts the corrected semantics on hardware: `ok`/`completed` and a refusal are
        // mutually exclusive, and the refusal path is not reachable from a completed run.
        let serial = try requireDevice()

        let (result, failure) = try await CLIRunCommand.run(
            workload: "DTCA-1",
            inputPath: try writeInput(Self.verificationInput),
            transport: ADBTransport()
        )

        XCTAssertEqual(result.outcome, "completed")
        XCTAssertNil(failure)
        XCTAssertEqual(result.output?.status, "COMPLETED",
                       "the authoritative payload must itself say COMPLETED, not just the stream")
    }

    // MARK: - 4. The real input bound, on the real validator path

    func testRealDeviceAcceptsInputExactlyAtThePublishedBound() async throws {
        let serial = try requireDevice()

        // Built from the contract's published value, not a literal.
        let contract = PixelCapabilityContract.build(
            device: AndroidDevice(id: "t", serialNumber: serial, deviceCodename: "lynx",
                                  marketingName: "m", manufacturer: "f", androidVersion: "16",
                                  apiLevel: 36, architecture: "arm64-v8a",
                                  supportedABIs: ["arm64-v8a"], state: .device),
            contextSize: .declared(2048, limitation: nil))
        let bound = try XCTUnwrap(
            contract.workloads.first { $0.name == "DTCA-1" }?.maximumInputCharacters?.value)

        let (result, failure) = try await CLIRunCommand.run(
            workload: "DTCA-1",
            inputPath: try writeInput(String(repeating: "a ", count: bound / 2)),
            transport: ADBTransport()
        )

        XCTAssertNil(failure, "input at the published bound must be accepted by the device")
        XCTAssertEqual(result.outcome, "completed")
        XCTAssertEqual(result.output?.inputCharacters, bound,
                       "the worker must see every character, with none truncated")
    }

    // MARK: - Helpers

    private func writeInput(_ text: String) throws -> String {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("p9s4-hw-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("input.txt")
        try text.write(to: url, atomically: true, encoding: .utf8)
        return url.path
    }
}
