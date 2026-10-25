//
//  Phase3TrustFoundationTests.swift
//  PixelDesktopTests
//
//  Phase 3.1 — the trust foundation: D1 consent, D2 generalised audit, D3 universal dry run.
//
//  ## The property under test
//
//  Phase 3's ordering constraint is that nothing which reads personal data or destroys state ships
//  before the trust layer exists. So the trust layer has to be true *before* it has a consumer, and
//  these tests are that proof. Five claims, each measured rather than asserted in prose:
//
//  - **default deny** — a read with no grant throws and issues zero device commands;
//  - **revocation is sticky** — a revoke survives a reload and wins over `granted == true`;
//  - **append before execute** — the record exists *at the moment* the command is issued;
//  - **the trail is bounded and ordered** — 5,000 records, millisecond precision;
//  - **no destructive plan runs unconfirmed** — the body is called zero times.
//
//  Every test writes to a temporary directory. Nothing here touches Application Support.
//

import XCTest
@testable import PixelDesktop

// MARK: - D1: consent registry

final class Phase3ConsentTests: XCTestCase {

    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("pd-consent-\(UUID().uuidString)")
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private func fileURL() -> URL {
        directory.appendingPathComponent("consent.json")
    }

    // MARK: Default deny

    func testNoGrantIsDeniedByDefault() throws {
        let registry = ConsentRegistry()

        for dataClass in ConsentDataClass.allCases {
            XCTAssertFalse(
                registry.isGranted(dataClass),
                "\(dataClass.rawValue) must be denied with no record"
            )
            XCTAssertThrowsError(try registry.permit(for: dataClass)) { error in
                XCTAssertEqual(error as? ConsentError, .consentRequired(dataClass: dataClass))
            }
        }
        XCTAssertTrue(registry.grants.isEmpty, "an untouched registry records no decisions")
    }

    /// The gate's whole purpose: refuse before anything reaches the device.
    func testReadWithoutAGrantIssuesZeroCommands() async throws {
        let transport = MockTransport()
        let log = DeviceAuditLog()
        let registry = ConsentRegistry()
        let gate = ConsentGate(registry: registry, auditLog: log)
        let calls = CallCounter()

        do {
            try await gate.performing(.notifications, target: "device") {
                calls.increment()
                _ = try await transport.shell(
                    deviceSerial: "serial",
                    command: "dumpsys notification --noredact",
                    timeout: 5
                )
            }
            XCTFail("an ungranted read must not run")
        } catch let error as ConsentError {
            XCTAssertEqual(error, .consentRequired(dataClass: .notifications))
        }

        XCTAssertEqual(calls.count, 0, "the body must not be reached")
        let invocations = await transport.invocations
        XCTAssertTrue(invocations.isEmpty, "a refused read must issue no device command")

        // A refusal is an event, not an absence: it is in the trail.
        XCTAssertEqual(log.latest?.outcome, .refused)
        XCTAssertEqual(log.latest?.operation, .notificationRead)
    }

    func testGrantPermitsTheReadAndTheBodyRuns() async throws {
        let log = DeviceAuditLog()
        let registry = ConsentRegistry()
        try registry.grant(.notifications, reason: "A5 notification stream (Q3 approved access)")
        let gate = ConsentGate(registry: registry, auditLog: log)
        let calls = CallCounter()

        let value = try await gate.performing(.notifications, target: "device") {
            calls.increment()
            return 42
        }

        XCTAssertEqual(value, 42)
        XCTAssertEqual(calls.count, 1)
        XCTAssertTrue(log.isEmpty, "a permitted read leaves no refusal record")
    }

    // MARK: Grant hygiene

    func testGrantRequiresAReason() {
        let registry = ConsentRegistry()

        for reason in ["", "   ", "\n"] {
            XCTAssertThrowsError(try registry.grant(.sms, reason: reason)) { error in
                XCTAssertEqual(error as? ConsentError, .reasonRequired(dataClass: .sms))
            }
        }
        XCTAssertFalse(registry.isGranted(.sms), "a rejected grant opens nothing")
    }

    func testConsentIsPerClass() throws {
        let registry = ConsentRegistry()
        try registry.grant(.notifications, reason: "notifications only")

        XCTAssertTrue(registry.isGranted(.notifications))
        for other in ConsentDataClass.allCases where other != .notifications {
            XCTAssertFalse(registry.isGranted(other), "\(other.rawValue) must stay closed")
            XCTAssertThrowsError(try registry.permit(for: other))
        }
    }

    /// The unit of consent is the class, not the package (decision Q4a).
    func testTheGrantCarriesItsReasonAndTimestamp() throws {
        let grantedAt = Date(timeIntervalSince1970: 1_800_000_000)
        let registry = ConsentRegistry()

        let grant = try registry.grant(.contacts, reason: "  contact lookup  ", at: grantedAt)

        XCTAssertEqual(grant.dataClass, .contacts)
        XCTAssertTrue(grant.granted)
        XCTAssertEqual(grant.reason, "contact lookup", "the reason is trimmed, not silently kept blank")
        XCTAssertEqual(grant.grantedAt, grantedAt)
        XCTAssertNil(grant.revokedAt)
        XCTAssertTrue(grant.isActive)
    }

    // MARK: Revocation

    func testRevokeIsImmediate() throws {
        let registry = ConsentRegistry()
        try registry.grant(.clipboard, reason: "temporary")
        XCTAssertTrue(registry.isGranted(.clipboard))

        registry.revoke(.clipboard)

        XCTAssertFalse(registry.isGranted(.clipboard))
        XCTAssertThrowsError(try registry.permit(for: .clipboard)) { error in
            XCTAssertEqual(error as? ConsentError, .consentRequired(dataClass: .clipboard))
        }
    }

    /// A flag that says granted must still lose to a recorded revocation.
    func testRevocationWinsOverAGrantedFlag() {
        let grant = ConsentGrant(
            dataClass: .sms,
            granted: true,
            grantedAt: Date(timeIntervalSince1970: 100),
            revokedAt: Date(timeIntervalSince1970: 200),
            reason: "stale write"
        )
        XCTAssertFalse(grant.isActive, "revokedAt != nil must defeat granted == true")
        XCTAssertEqual(grant.statusDescription, "Revoked")
    }

    func testRevokingAnUndecidedClassIsANoOp() {
        let registry = ConsentRegistry()
        XCTAssertNil(registry.revoke(.sms))
        XCTAssertTrue(registry.grants.isEmpty)
    }

    // MARK: Persistence

    func testGrantRoundTripsThroughDisk() throws {
        let url = fileURL()
        let grantedAt = Date(timeIntervalSince1970: 1_800_000_000)

        let registry = ConsentRegistry(fileURL: url)
        try registry.grant(.notifications, reason: "A5", at: grantedAt)

        let reloaded = ConsentRegistry(fileURL: url)
        XCTAssertTrue(reloaded.isGranted(.notifications))
        let permit = try reloaded.permit(for: .notifications)
        XCTAssertEqual(permit.reason, "A5")
        XCTAssertEqual(permit.grantedAt, grantedAt)
    }

    /// The failure this must never have: a revoke lost to a reload.
    func testRevocationSurvivesAReload() throws {
        let url = fileURL()
        let revokedAt = Date(timeIntervalSince1970: 1_900_000_000)

        let registry = ConsentRegistry(fileURL: url)
        try registry.grant(.notifications, reason: "A5")
        registry.revoke(.notifications, at: revokedAt)

        let reloaded = ConsentRegistry(fileURL: url)
        XCTAssertFalse(reloaded.isGranted(.notifications))
        XCTAssertEqual(reloaded.grant(for: .notifications)?.revokedAt, revokedAt)
        XCTAssertThrowsError(try reloaded.permit(for: .notifications))
    }

    func testRegrantingARevokedClassClearsTheRevocation() throws {
        let registry = ConsentRegistry()
        try registry.grant(.sms, reason: "first")
        registry.revoke(.sms)

        try registry.grant(.sms, reason: "again")

        XCTAssertTrue(registry.isGranted(.sms))
        XCTAssertNil(registry.grant(for: .sms)?.revokedAt)
        XCTAssertEqual(registry.grant(for: .sms)?.reason, "again")
    }

    func testRemoveAllClosesEveryClass() throws {
        let registry = ConsentRegistry(fileURL: fileURL())
        for dataClass in ConsentDataClass.allCases {
            try registry.grant(dataClass, reason: "test")
        }

        registry.removeAll()

        XCTAssertTrue(registry.grants.isEmpty)
        for dataClass in ConsentDataClass.allCases {
            XCTAssertFalse(registry.isGranted(dataClass))
        }
    }

    // MARK: Nothing hidden

    /// Consent given without knowing the exposure is not consent, so the text is part of the
    /// contract rather than a view detail.
    func testEveryClassDescribesWhatItExposes() {
        for dataClass in ConsentDataClass.allCases {
            XCTAssertFalse(dataClass.displayName.isEmpty)
            XCTAssertGreaterThan(dataClass.exposure.count, 40, "\(dataClass.rawValue) exposure text")
        }
    }
}

// MARK: - D2: the generalised audit trail

final class Phase3AuditTests: XCTestCase {

    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("pd-audit3-\(UUID().uuidString)")
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private func fileURL() -> URL {
        directory.appendingPathComponent("device-audit.json")
    }

    func testDefaultCapacityIsFiveThousand() {
        XCTAssertEqual(DeviceAuditLog.defaultCapacity, 5_000)
    }

    func testTrailIsBoundedAndDropsOldest() {
        let log = DeviceAuditLog(capacity: 3)

        for index in 0..<5 {
            log.append(
                operation: .shellCommand,
                target: nil,
                outcome: .executed,
                detail: "\(index)"
            )
        }

        XCTAssertEqual(log.records.count, 3)
        XCTAssertEqual(log.records.compactMap(\.detail), ["2", "3", "4"])
    }

    /// Second precision would make two adjacent operations ambiguous; the file must keep
    /// milliseconds.
    func testTimestampsKeepMillisecondPrecisionOnDisk() throws {
        let url = fileURL()
        let log = DeviceAuditLog(fileURL: url)
        let t0 = Date(timeIntervalSince1970: 1_800_000_000.000)

        log.append(operation: .appInstall, target: "com.a", outcome: .executed, at: t0)
        log.append(operation: .appInstall, target: "com.b", outcome: .executed,
                   at: t0.addingTimeInterval(0.005))

        let reloaded = DeviceAuditLog(fileURL: url)
        XCTAssertEqual(reloaded.records.count, 2)
        let delta = reloaded.records[1].at.timeIntervalSince(reloaded.records[0].at)
        XCTAssertEqual(delta, 0.005, accuracy: 0.001, "milliseconds must survive encoding")
        XCTAssertEqual(reloaded.records[0].target, "com.a")
        XCTAssertEqual(reloaded.records[1].target, "com.b")
    }

    /// The core D2 requirement. The transport inspects the log **at the moment the command is
    /// issued** — an append-after-success log would report an empty trail here.
    func testAttemptIsAuditedBeforeTheCommandIsIssued() async throws {
        let log = DeviceAuditLog()
        let transport = AuditProbeTransport(log: log)
        let input = ADBDeviceInput(transport: transport, auditLog: log)

        let plan = try input.planKeyEvent("KEYCODE_HOME").confirming()
        _ = try await input.execute(plan, deviceSerial: "serial", timeout: 5)

        XCTAssertEqual(transport.commandsIssued, ["input keyevent KEYCODE_HOME"])
        XCTAssertEqual(
            transport.outcomesSeenAtIssue,
            [[.pending]],
            "exactly one unresolved attempt must already be on the trail when the command runs"
        )
        XCTAssertEqual(log.latest?.outcome, .executed, "and it is resolved afterwards")
        XCTAssertEqual(log.records.count, 1, "one attempt, one record — begin/resolve, not two appends")
    }

    func testTransportFailureResolvesTheAttemptAsFailed() async throws {
        let log = DeviceAuditLog()
        let transport = AuditProbeTransport(log: log)
        transport.failure = ProbeError.unreachable
        let input = ADBDeviceInput(transport: transport, auditLog: log)

        let plan = try input.planKeyEvent("KEYCODE_HOME").confirming()
        do {
            _ = try await input.execute(plan, deviceSerial: "serial", timeout: 5)
            XCTFail("expected the transport failure to surface")
        } catch let error as PixelDesktopError {
            guard case .adbTransportError = error else {
                return XCTFail("expected adbTransportError, got \(error)")
            }
        }

        XCTAssertEqual(log.records.count, 1)
        XCTAssertEqual(log.latest?.outcome, .failed)
        XCTAssertTrue(log.latest?.detail?.contains("transport error") == true)
    }

    func testNonZeroExitResolvesTheAttemptAsFailed() async throws {
        let log = DeviceAuditLog()
        let transport = AuditProbeTransport(log: log)
        transport.exitCode = 1
        let input = ADBDeviceInput(transport: transport, auditLog: log)

        let plan = try input.planKeyEvent("KEYCODE_HOME").confirming()
        do {
            _ = try await input.execute(plan, deviceSerial: "s", timeout: 5)
            XCTFail("expected the non-zero exit to surface")
        } catch let error as PixelDesktopError {
            guard case .adbCommandFailed = error else {
                return XCTFail("expected adbCommandFailed, got \(error)")
            }
        }

        XCTAssertEqual(log.latest?.outcome, .failed)
    }

    func testRefusalIsRecordedWithItsOperation() async throws {
        let log = DeviceAuditLog()
        let input = ADBDeviceInput(transport: AuditProbeTransport(log: log), auditLog: log)

        let plan = try input.planKeyEvent("KEYCODE_HOME") // not confirmed
        do {
            _ = try await input.execute(plan, deviceSerial: "serial", timeout: 5)
            XCTFail("an unconfirmed plan must not execute")
        } catch let refusal as InputRefusal {
            XCTAssertEqual(refusal, .planNotConfirmed)
        }

        XCTAssertEqual(log.records.count, 1)
        XCTAssertEqual(log.latest?.operation, .inputInject)
        XCTAssertEqual(log.latest?.outcome, .refused)
    }

    func testResolvingAnUnknownIdIsANoOp() {
        let log = DeviceAuditLog()
        log.append(operation: .reboot, target: "device", outcome: .pending)

        log.resolve(UUID(), outcome: .executed, detail: "nothing")

        XCTAssertEqual(log.records.count, 1)
        XCTAssertEqual(log.latest?.outcome, .pending, "an unrelated id must not settle this record")
    }

    func testRecordsCanBeFilteredByOperation() {
        let log = DeviceAuditLog()
        log.append(operation: .inputInject, target: "Allow", outcome: .executed)
        log.append(operation: .notificationRead, target: "device", outcome: .refused)
        log.append(operation: .inputInject, target: "Back", outcome: .executed)

        XCTAssertEqual(log.records(for: .inputInject).count, 2)
        XCTAssertEqual(log.records(for: .notificationRead).count, 1)
        XCTAssertEqual(log.records(for: .reboot).count, 0)
    }

    func testEmptyTrailReportsNoLatest() {
        let log = DeviceAuditLog()
        XCTAssertNil(log.latest)
        XCTAssertTrue(log.isEmpty)
    }

    /// The input projection is what makes a blind tap reviewable, so generalising the record type
    /// must not have dropped it.
    func testInputContextSurvivesTheDiskRoundTrip() throws {
        let url = fileURL()
        let log = DeviceAuditLog(fileURL: url)
        let plan = InputActionPlan(
            kind: .typeText,
            payload: "hello",
            confirmed: true
        )
        log.append(DeviceAuditRecord(plan: plan, outcome: .executed, detail: "input text 'hello'"))

        let reloaded = DeviceAuditLog(fileURL: url)
        XCTAssertEqual(reloaded.latest?.input?.payload, "hello")
        XCTAssertEqual(reloaded.latest?.input?.kind, InputActionKind.typeText.rawValue)
        XCTAssertEqual(reloaded.latest?.operation, .inputInject)
    }
}

// MARK: - D3: universal dry run

final class Phase3DryRunTests: XCTestCase {

    func testUnconfirmedPlanRunsNothing() async throws {
        let plan = DestructiveActionPlan(
            operation: .appUninstall,
            target: "com.example.app",
            command: "pm uninstall com.example.app"
        )
        let calls = CallCounter()

        do {
            _ = try await plan.execute { command in
                calls.increment()
                return command
            }
            XCTFail("an unconfirmed destructive plan must not run")
        } catch let error as DryRunError {
            XCTAssertEqual(error, .dryRunNotConfirmed(operation: .appUninstall))
        }

        XCTAssertEqual(calls.count, 0, "the body must be called zero times")
    }

    func testEveryDestructiveOperationRequiresConfirmation() async throws {
        for operation in DestructiveOperation.allCases {
            let plan = DestructiveActionPlan(operation: operation, command: "<cmd>")
            let calls = CallCounter()

            do {
                _ = try await plan.execute { command in
                    calls.increment()
                    return command
                }
                XCTFail("\(operation.rawValue) executed without confirmation")
            } catch let error as DryRunError {
                XCTAssertEqual(error, .dryRunNotConfirmed(operation: operation))
            }
            XCTAssertEqual(calls.count, 0, "\(operation.rawValue) reached its body")
        }
    }

    func testConfirmingProducesALivePlanAndTheOriginalStaysDead() async throws {
        let plan = DestructiveActionPlan(
            operation: .reboot,
            target: "device",
            command: "reboot",
            notes: ["normal reboot returns"]
        )

        let approved = plan.confirming()
        XCTAssertFalse(plan.confirmed, "approval is a transition, not a mutation")
        XCTAssertTrue(approved.confirmed)
        XCTAssertEqual(approved.id, plan.id, "approval does not re-identify the plan")

        let executed = try await approved.execute { $0 }
        XCTAssertEqual(executed, "reboot")
    }

    func testReportCarriesTheExactCommandAndTheWouldExecuteFlag() {
        let plan = DestructiveActionPlan(
            operation: .appInstall,
            target: "com.pixeldesktop.worker",
            command: "adb install -r /tmp/app-debug.apk",
            notes: ["replaces an existing install"]
        )

        let preview = plan.report
        XCTAssertEqual(preview.command, "adb install -r /tmp/app-debug.apk")
        XCTAssertFalse(preview.wouldExecute, "an unconfirmed report must say it has not run")
        XCTAssertTrue(preview.preview.contains("DRY RUN — NOT EXECUTED"))
        XCTAssertTrue(preview.preview.contains("note: replaces an existing install"))
        XCTAssertTrue(preview.preview.contains(plan.operation.consequence))

        XCTAssertTrue(plan.confirming().report.wouldExecute)
    }

    /// B1 is not a special case in the Phase 3 vocabulary: a tap preview is the same artifact.
    func testInputPlanProducesTheSharedReport() async throws {
        let input = ADBDeviceInput(transport: MockTransport(), auditLog: DeviceAuditLog())
        let plan = try input.planKeyEvent("KEYCODE_BACK")

        let report = input.dryRunReport(for: plan)
        XCTAssertEqual(report.operation, .inputInject)
        XCTAssertEqual(report.command, "input keyevent KEYCODE_BACK")
        XCTAssertFalse(report.wouldExecute)

        let confirmed = input.dryRunReport(for: plan.confirming())
        XCTAssertTrue(confirmed.wouldExecute)
        XCTAssertEqual(confirmed.command, report.command, "confirmation does not change the command")
    }

    func testEveryOperationExplainsItsConsequence() {
        for operation in DestructiveOperation.allCases {
            XCTAssertFalse(operation.displayName.isEmpty)
            XCTAssertGreaterThan(operation.consequence.count, 30, "\(operation.rawValue) consequence")
        }
    }
}

// MARK: - Doubles

/// A transport that inspects the audit trail at the instant a command is issued.
///
/// This is the only way to prove append-before-execute: `MockTransport` records invocations but
/// cannot observe the log mid-call, so an append-after-success implementation would pass every
/// other test in this file.
final class AuditProbeTransport: TransportProtocol, @unchecked Sendable {
    private let log: DeviceAuditLog
    private(set) var commandsIssued: [String] = []
    private(set) var outcomesSeenAtIssue: [[DeviceAuditOutcome]] = []
    var failure: Error?
    var exitCode: Int32 = 0

    init(log: DeviceAuditLog) {
        self.log = log
    }

    func shell(deviceSerial: String, command: String, timeout: TimeInterval) async throws -> TransportResult {
        commandsIssued.append(command)
        outcomesSeenAtIssue.append(log.records.map(\.outcome))
        if let failure { throw failure }
        return TransportResult(exitCode: exitCode, stdout: "", stderr: exitCode == 0 ? "" : "denied")
    }

    func execute(command: String, arguments: [String], timeout: TimeInterval) async throws -> TransportResult {
        TransportResult(exitCode: 0, stdout: "", stderr: "")
    }

    func listDevices() async throws -> [AndroidDevice] { [] }

    func getprop(deviceSerial: String, key: String, timeout: TimeInterval) async throws -> String { "" }

    func getSystemProperties(deviceSerial: String, timeout: TimeInterval) async throws -> [String: String] { [:] }

    func shellStreaming(
        deviceSerial: String,
        command: String,
        stdin: String?,
        onLine: @Sendable @escaping (String) -> Void,
        onStderrLine: @Sendable @escaping (String) -> Void,
        cancellation: CancellationHandle
    ) async throws -> Int32 { 0 }

    func execOut(
        deviceSerial: String,
        arguments: [String],
        timeout: TimeInterval
    ) async throws -> TransportBinaryResult {
        TransportBinaryResult(exitCode: 0, stdout: Data(), stderr: "")
    }

    func push(deviceSerial: String, localPath: String, remotePath: String, timeout: TimeInterval) async throws -> TransportResult {
        TransportResult(exitCode: 0, stdout: "", stderr: "")
    }

    func pull(deviceSerial: String, remotePath: String, localPath: String, timeout: TimeInterval) async throws -> TransportResult {
        TransportResult(exitCode: 0, stdout: "", stderr: "")
    }

    func install(deviceSerial: String, apkPath: String, replace: Bool, timeout: TimeInterval) async throws -> TransportResult {
        TransportResult(exitCode: 0, stdout: "Success", stderr: "")
    }
}

enum ProbeError: Error {
    case unreachable
}

/// Counts body invocations without touching the transport.
final class CallCounter: @unchecked Sendable {
    private(set) var count = 0
    func increment() { count += 1 }
}
