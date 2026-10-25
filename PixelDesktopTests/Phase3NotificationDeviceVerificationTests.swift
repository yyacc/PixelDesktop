//
//  Phase3NotificationDeviceVerificationTests.swift
//  PixelDesktopTests
//
//  Phase 3.2 — A5 on real hardware.
//
//  Skipped unless `PIXELDESKTOP_DEVICE_SERIAL` is set, matching the Phase 2–9 convention, so an
//  offline `xcodebuild test` stays green and the device runs are explicit.
//
//  These are the four claims that cannot be made from a fixture:
//
//  1. Without a `.notifications` grant, **no command is issued to the device** — the refusal happens
//     before `adb` is touched.
//  2. The second poll of an unchanged notification set does **not** pay for the ~780 KB dump.
//  3. Revoking consent makes the very next poll refuse, and records the refusal.
//  4. Nothing the device prints as a message ends up in the audit trail.
//
//  Consent is granted in an **in-memory** registry here on purpose: a test must never write a real
//  grant into the owner's consent file.
//

import XCTest
@testable import PixelDesktop

final class Phase3NotificationDeviceVerificationTests: XCTestCase {

    private func deviceSerial() throws -> String {
        if let serial = ProcessInfo.processInfo.environment["PIXELDESKTOP_DEVICE_SERIAL"],
           !serial.isEmpty {
            return serial
        }
        throw XCTSkip("PIXELDESKTOP_DEVICE_SERIAL not set; skipping real-device A5 verification")
    }

    private func makeStack() -> (ADBNotificationReader, ConsentRegistry, DeviceAuditLog) {
        let log = DeviceAuditLog()
        let registry = ConsentRegistry()
        let reader = ADBNotificationReader(
            transport: ADBTransport(),
            gate: ConsentGate(registry: registry, auditLog: log)
        )
        return (reader, registry, log)
    }

    /// Criterion 1, on hardware: a refusal costs the device nothing.
    func testNoGrantIssuesNoDeviceCommand() async throws {
        let serial = try deviceSerial()
        let (reader, _, log) = makeStack()

        do {
            _ = try await reader.keys(deviceSerial: serial, timeout: 20)
            XCTFail("tier 1 must refuse without a grant")
        } catch let refusal as ConsentError {
            XCTAssertEqual(refusal, .consentRequired(dataClass: .notifications))
        }

        do {
            _ = try await reader.records(deviceSerial: serial, timeout: 30)
            XCTFail("tier 2 must refuse without a grant")
        } catch let refusal as ConsentError {
            XCTAssertEqual(refusal, .consentRequired(dataClass: .notifications))
        }

        XCTAssertEqual(log.records.count, 2, "both refusals are recorded")
        XCTAssertTrue(log.records.allSatisfy { $0.outcome == .refused })
        XCTAssertTrue(
            log.records.allSatisfy { ($0.detail ?? "").contains("refused") || ($0.detail ?? "").isEmpty },
            "the detail must describe the refusal, not an attempt"
        )
    }

    /// Criterion 3, on hardware: the second poll moves the key list only.
    func testTheSecondPollDoesNotPayForTheDump() async throws {
        let serial = try deviceSerial()
        let (reader, registry, log) = makeStack()
        try registry.grant(.notifications, reason: "A5 real-device verification")

        let stream = NotificationStream(reader: reader)
        let first = try await stream.refresh(deviceSerial: serial, timeout: 30)

        if first.keys.isEmpty {
            XCTAssertFalse(first.didFetchPayload, "no notifications: there is nothing for tier 2 to describe")
        } else {
            XCTAssertTrue(first.didFetchPayload, "the first poll has no key set to compare, so it reads the dump")
        }
        let keySet = Set(first.keys.map(\.raw))
        XCTAssertTrue(
            first.records.allSatisfy { keySet.contains($0.key.raw) },
            "every record must trace back to a key the tier-1 list reported"
        )

        let second = try await stream.refresh(deviceSerial: serial, timeout: 30)

        XCTAssertFalse(
            second.didFetchPayload,
            "an unchanged key set must not re-read the dump (the whole point of tier 1)"
        )
        XCTAssertEqual(second.keys.map(\.raw), first.keys.map(\.raw))
        XCTAssertEqual(
            second.records.map(\.id), first.records.map(\.id),
            "the cached records are served, so a poll without changes loses nothing"
        )

        let executed = log.records.filter { $0.outcome == .executed }
        XCTAssertEqual(executed.count, 2, "one audit record per command: tier 1 + tier 2 on the first poll")
        XCTAssertTrue(executed.allSatisfy { $0.operation == .notificationRead })
    }

    /// Criterion 1 in reverse: revoking is effective on the next poll, not the next launch.
    func testRevokingConsentStopsTheNextPoll() async throws {
        let serial = try deviceSerial()
        let (reader, registry, log) = makeStack()
        try registry.grant(.notifications, reason: "A5 revocation verification")
        let stream = NotificationStream(reader: reader)
        _ = try await stream.refresh(deviceSerial: serial, timeout: 30)

        XCTAssertNotNil(registry.revoke(.notifications))

        do {
            _ = try await stream.refresh(deviceSerial: serial, timeout: 30)
            XCTFail("a revoked grant must refuse the next poll")
        } catch let refusal as ConsentError {
            XCTAssertEqual(refusal, .consentRequired(dataClass: .notifications))
        }

        XCTAssertEqual(log.latest?.outcome, .refused)
        XCTAssertEqual(log.latest?.operation, .notificationRead)
    }

    /// Criterion: the trail outlives the session, so it must not carry what the session read.
    func testRealNotificationContentNeverReachesTheAuditTrail() async throws {
        let serial = try deviceSerial()
        let (reader, registry, log) = makeStack()
        try registry.grant(.notifications, reason: "A5 audit-content verification")

        let records = try await reader.records(deviceSerial: serial, timeout: 30)

        let trail = log.records.map { $0.detail ?? "" }.joined(separator: " | ")
        XCTAssertFalse(trail.isEmpty)

        // Long values only: a two-character title could appear inside a byte count by coincidence.
        let values = records.flatMap { [$0.title, $0.text, $0.subText, $0.bigText, $0.tickerText] }
            .compactMap { $0 }
            .filter { $0.count >= 12 }
        XCTAssertFalse(values.isEmpty, "precondition: the phone has readable content")

        for value in values {
            XCTAssertFalse(
                trail.contains(value),
                "notification content reached the audit trail: \(value.prefix(40))…"
            )
        }
    }
}
