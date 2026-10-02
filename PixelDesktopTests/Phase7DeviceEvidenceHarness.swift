//
//  Phase7DeviceEvidenceHarness.swift
//  PixelDesktopTests
//
//  Phase 7 Step 2 — real-device verification of the evidence layer.
//
//  ADR-012 is explicit that a macOS test establishes nothing about Android correctness. The
//  parsing and provenance logic is unit-tested; whether the READER actually populates real values
//  from a real Pixel can only be established on the device.
//
//  Skipped unless PIXELDESKTOP_DEVICE_SERIAL is set, matching the existing Phase 2–6 convention.
//

import XCTest
@testable import PixelDesktop

final class Phase7DeviceEvidenceHarness: XCTestCase {

    private var deviceSerial: String? {
        ProcessInfo.processInfo.environment["PIXELDESKTOP_DEVICE_SERIAL"]
    }

    private func requireDevice() throws -> String {
        guard let serial = deviceSerial else {
            throw XCTSkip("PIXELDESKTOP_DEVICE_SERIAL not set; skipping real-device verification")
        }
        return serial
    }

    /// Proves the reader populates real values from the real device, with correct provenance and
    /// no invented data.
    func testStateObservationIsPopulatedFromTheRealDevice() async throws {
        let serial = try requireDevice()
        let reader = PixelEvidenceReader(transport: ADBTransport())

        let observation = try await reader.observeState(deviceSerial: serial)

        print("=== PHASE 7 STEP 2 — REAL DEVICE STATE OBSERVATION ===")
        print("device serial   : \(observation.deviceSerial)")
        print("observedAt      : \(observation.observedAt)")
        print("reachable       : \(observation.deviceReachable.value) [\(observation.deviceReachable.source.rawValue)]")
        print("memory avail    : \(observation.availableMemoryBytes.value) bytes [\(observation.availableMemoryBytes.source.rawValue)]")
        print("storage free    : \(observation.freeStorageBytes.value) bytes [\(observation.freeStorageBytes.source.rawValue)]")
        print("worker installed: \(observation.workerInstalled.value) [\(observation.workerInstalled.source.rawValue)]")
        print("worker running  : \(observation.workerRunning.value) [\(observation.workerRunning.source.rawValue)]")
        print("model present   : \(observation.modelPresent.value) [\(observation.modelPresent.source.rawValue)]")
        print("thermal status  : \(observation.thermalStatus.value) [\(observation.thermalStatus.source.rawValue)]")
        print("freshness(60s)  : \(observation.freshness(maxAge: 60).rawValue)")

        // Reachable: the device is attached for this test to run at all.
        XCTAssertTrue(observation.deviceReachable.value)
        XCTAssertEqual(observation.deviceReachable.source, .deviceReported)

        // Memory and storage must be real positive values, not placeholders.
        XCTAssertEqual(observation.availableMemoryBytes.source, .deviceReported,
                       "memory must be a real device read, not unknown")
        XCTAssertGreaterThan(observation.availableMemoryBytes.value, 0)
        XCTAssertEqual(observation.freeStorageBytes.source, .deviceReported)
        XCTAssertGreaterThan(observation.freeStorageBytes.value, 0)

        // The worker is installed (Phase 5/6), so this must be a positive installation fact.
        if case .installed(let versionCode) = observation.workerInstalled.value {
            XCTAssertGreaterThan(versionCode, 0)
        } else {
            XCTFail("the worker should be installed on this device")
        }

        // The model was provisioned in Phase 6 and must be present at the fixed path.
        if case .present(let bytes) = observation.modelPresent.value {
            XCTAssertEqual(bytes, ModelContract.expectedByteCount,
                           "the provisioned model size must match the contract")
        } else {
            XCTFail("the provisioned model should be present on this device")
        }

        // Thermal is readable but system-wide.
        XCTAssertEqual(observation.thermalStatus.source, .deviceReported)
        XCTAssertGreaterThanOrEqual(observation.thermalStatus.value, 0)

        // Every observed field carries a timestamp; none may be a declared value masquerading
        // as an observation.
        XCTAssertNotNil(observation.availableMemoryBytes.observedAt)
        XCTAssertNotNil(observation.modelPresent.observedAt)

        // A just-taken observation is current against any sane window.
        XCTAssertEqual(observation.freshness(maxAge: 60), .current)

        // And stale against a zero window — proving freshness is actually computed, not fixed.
        XCTAssertEqual(observation.freshness(maxAge: 0), .stale)
    }

    /// Proves measurements stay out of the capability contract on a real build.
    func testCapabilityContractStillExcludesMeasurementsOnDevice() async throws {
        let serial = try requireDevice()
        let reader = PixelEvidenceReader(transport: ADBTransport())
        let observation = try await reader.observeState(deviceSerial: serial)

        let observationJSON = (try? JSONEncoder().encode(observation))
            .flatMap { String(data: $0, encoding: .utf8) } ?? ""

        // The observation legitimately carries no token-rate field — it is device STATE, not
        // execution evidence.
        for forbidden in ["tokens_per_second", "generation_ms", "model_load_ms"] {
            XCTAssertFalse(observationJSON.contains(forbidden),
                           "a state observation must not carry '\(forbidden)'")
        }

        // And it does carry the not-a-reservation warning on snapshot fields.
        XCTAssertTrue(observationJSON.contains("NOT A RESERVATION"),
                      "snapshot fields must carry the reservation warning")
        XCTAssertTrue(observationJSON.contains("SYSTEM-WIDE"),
                      "thermal must be flagged as system-wide")
    }
}
