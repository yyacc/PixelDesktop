import XCTest
import Foundation
@testable import PixelDesktop

// MARK: - Phase 1 (Connection Foundation)
//
// Transport selection (USB > WiFi), connection persistence (UserDefaults),
// auto-reconnect with exponential backoff (max 5 attempts), network-change
// triggering, adb connect-result interpretation, and the DeviceManager
// dual-transport integration. Everything runs against mocks — no device and no
// real `adb` on this path.

private func makeDevice(serial: String, state: DeviceState = .device) -> AndroidDevice {
    AndroidDevice(
        id: serial,
        serialNumber: serial,
        deviceCodename: "lynx",
        marketingName: "Pixel 7a",
        manufacturer: "Google",
        androidVersion: "16",
        apiLevel: 36,
        architecture: "arm64-v8a",
        supportedABIs: ["arm64-v8a"],
        state: state
    )
}

private let wiredSerial = "3A8C1F5D0B2E4726"
private let wirelessSerial = "192.168.1.4:37351"
private let wirelessEndpoint = WirelessEndpoint(host: "192.168.1.4", port: 37351)

private func freshDefaults() -> UserDefaults {
    let suite = "ConnectionFoundationTests.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suite)!
    defaults.removePersistentDomain(forName: suite)
    return defaults
}

/// Bounded poll on a locally-computed condition. Conditions hop to the main actor
/// where the inspected state lives.
@MainActor
private func waitUntil(timeout: TimeInterval = 2, _ condition: () async -> Bool) async -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        if await condition() { return true }
        try? await Task.sleep(nanoseconds: 10_000_000)
    }
    return await condition()
}

/// Records every connect attempt. Failures are consumed from a plan in order; when
/// the plan is empty, `connect` succeeds — so "two failures, then the endpoint
/// answers" is one array.
private actor MockConnectionTransport: ConnectionTransporting {
    private(set) var connectAttempts: [String] = []
    private var failurePlan: [Error]

    init(failurePlan: [Error] = []) {
        self.failurePlan = failurePlan
    }

    func listDevices() async throws -> [AndroidDevice] { [] }

    func connect(host: String, port: Int) async throws {
        connectAttempts.append("\(host):\(port)")
        if !failurePlan.isEmpty {
            throw failurePlan.removeFirst()
        }
    }
}

final class MockNetworkPathMonitor: NetworkPathMonitoring {
    var onUpdate: (@Sendable (NetworkPathStatus) -> Void)?
    private(set) var started = false
    private(set) var cancelled = false

    func start() { started = true }
    func cancel() { cancelled = true }

    func simulate(_ status: NetworkPathStatus) {
        onUpdate?(status)
    }
}

/// Serial transport failure: every attempt fails against an unreachable endpoint.
private let refusedFailure = PixelDesktopError.adbTransportError(
    "cannot connect to 192.168.1.4:37351: Connection refused"
)

@MainActor
private func makeManager(
    connectFailures: [Error],
    defaults: UserDefaults,
    scheduler: ReconnectScheduler,
    pathMonitor: NetworkPathMonitoring? = nil
) -> (ConnectionManager, MockConnectionTransport) {
    let mock = MockConnectionTransport(failurePlan: connectFailures)
    let manager = ConnectionManager(
        transport: mock,
        logger: AppLogger(),
        defaults: defaults,
        scheduler: scheduler,
        pathMonitor: pathMonitor
    )
    return (manager, mock)
}

/// The production loop shape at millisecond scale.
private let fastScheduler = ReconnectScheduler(
    maxAttempts: 5,
    baseDelay: 0.01,
    maxDelay: 0.05
)

// MARK: - 1. Transport selection

final class TransportSelectionTests: XCTestCase {

    /// The wired device wins even when the wireless device would come first.
    func testSelectPrefersWiredOverWireless() {
        let devices = [
            makeDevice(serial: wirelessSerial),
            makeDevice(serial: wiredSerial)
        ]

        XCTAssertEqual(
            TransportSelector.select(devices),
            TransportState(mode: .wired, deviceSerial: wiredSerial)
        )
    }

    /// Without a usable wired device, the wireless one is used.
    func testSelectFallsBackToWireless() {
        XCTAssertEqual(
            TransportSelector.select([makeDevice(serial: wirelessSerial)]),
            TransportState(mode: .wireless, deviceSerial: wirelessSerial)
        )
    }

    /// Attached-but-unusable devices are not connections.
    func testSelectIgnoresUnauthorizedAndOfflineDevices() {
        let devices = [
            makeDevice(serial: wiredSerial, state: .unauthorized),
            makeDevice(serial: wirelessSerial, state: .offline)
        ]

        XCTAssertNil(TransportSelector.select(devices))
    }

    func testSelectIsNilForEmptyList() {
        XCTAssertNil(TransportSelector.select([]))
    }

    /// Serial classification: a colon marks the ADB-over-network serial form.
    func testSerialClassification() {
        XCTAssertEqual(TransportSelector.mode(forSerial: wiredSerial), .wired)
        XCTAssertEqual(TransportSelector.mode(forSerial: wirelessSerial), .wireless)
        XCTAssertEqual(
            TransportSelector.mode(forSerial: "adb-3X4S2L1Q8G-lynx._adb-tls-connect._tcp.-192-168-1-4._port-37351.tcp."),
            .wireless
        )
    }

    // MARK: Endpoint parsing

    func testEndpointParseDirectHostPortForm() {
        XCTAssertEqual(WirelessEndpoint.parse(wirelessSerial), wirelessEndpoint)
    }

    /// The mDNS-style serial a paired Wireless Debugging device reports still
    /// carries the IPv4 endpoint; that occurrence must be recoverable.
    func testEndpointParseRecoversIPFromDecoratedSerial() {
        let decorated = "adb-3X4S2L1Q8G-lynx._adb-tls-connect._tcp.192.168.1.55:41977"

        XCTAssertEqual(WirelessEndpoint.parse(decorated), WirelessEndpoint(host: "192.168.1.55", port: 41977))
    }

    /// A USB serial carries no endpoint — remembering one from it would be fiction.
    func testEndpointParseNilForUSBSerial() {
        XCTAssertNil(WirelessEndpoint.parse(wiredSerial))
    }
}

// MARK: - 2. Reconnect scheduler (pure)

final class ReconnectSchedulerTests: XCTestCase {

    /// The documented schedule: 1 s, 2 s, 4 s, 8 s, 16 s across five attempts.
    func testStandardScheduleIsOneTwoFourEightSixteen() {
        let scheduler = ReconnectScheduler.standard

        XCTAssertEqual(scheduler.maxAttempts, 5)
        XCTAssertEqual(
            (0..<5).map { scheduler.delay(beforeAttempt: $0) },
            [1.0, 2.0, 4.0, 8.0, 16.0]
        )
    }

    func testDelayIsClampedToMaxDelay() {
        let scheduler = ReconnectScheduler(maxAttempts: 5, baseDelay: 10.0, maxDelay: 15.0)

        XCTAssertEqual(scheduler.delay(beforeAttempt: 0), 10.0)
        XCTAssertEqual(scheduler.delay(beforeAttempt: 1), 15.0)
        XCTAssertEqual(scheduler.delay(beforeAttempt: 4), 15.0)
    }

    func testExhaustionRequiresMaxAttempts() {
        let scheduler = ReconnectScheduler.standard

        XCTAssertFalse(scheduler.isExhausted(afterAttempt: 4))
        XCTAssertTrue(scheduler.isExhausted(afterAttempt: 5))
    }
}

// MARK: - 3. Connection persistence (UserDefaults)

@MainActor
final class ConnectionPersistenceTests: XCTestCase {

    /// Observing a connected wireless device persists the endpoint.
    func testWirelessObservationPersistsEndpoint() throws {
        let defaults = freshDefaults()
        let (manager, _) = makeManager(connectFailures: [], defaults: defaults, scheduler: .standard)

        _ = manager.observe(devices: [makeDevice(serial: wirelessSerial)])

        let data = try XCTUnwrap(defaults.data(forKey: ConnectionManager.persistedStateKey))
        let state = try JSONDecoder().decode(PersistedConnectionState.self, from: data)
        XCTAssertEqual(state.wirelessEndpoint, wirelessEndpoint)
        XCTAssertEqual(state.lastMode, .wireless)
        XCTAssertEqual(state.lastSerial, wirelessSerial)
    }

    /// A wired snapshot is persisted for information but never invents an endpoint.
    func testWiredObservationPersistsWithoutEndpoint() throws {
        let defaults = freshDefaults()
        let (manager, _) = makeManager(connectFailures: [], defaults: defaults, scheduler: .standard)

        _ = manager.observe(devices: [makeDevice(serial: wiredSerial)])

        let data = try XCTUnwrap(defaults.data(forKey: ConnectionManager.persistedStateKey))
        let state = try JSONDecoder().decode(PersistedConnectionState.self, from: data)
        XCTAssertNil(state.wirelessEndpoint)
        XCTAssertEqual(state.lastMode, .wired)
    }

    /// A drop to offline must not wipe the remembered endpoint — that record is
    /// exactly what the reconnect sequence needs.
    func testOfflineObservationKeepsRememberedEndpoint() {
        let defaults = freshDefaults()
        let (manager, _) = makeManager(
            connectFailures: [refusedFailure],
            defaults: defaults,
            scheduler: ReconnectScheduler(maxAttempts: 1, baseDelay: 0.005, maxDelay: 0.01)
        )

        _ = manager.observe(devices: [makeDevice(serial: wirelessSerial)])
        XCTAssertEqual(manager.rememberedWirelessEndpoint, wirelessEndpoint)

        _ = manager.observe(devices: [])
        XCTAssertEqual(manager.rememberedWirelessEndpoint, wirelessEndpoint)
    }
}

// MARK: - 4. Auto-reconnect sequence

@MainActor
final class ConnectionReconnectSequenceTests: XCTestCase {

    /// Total failure: five attempts at widening gaps, then the sequence stops
    /// exhausted with no transport claimed.
    func testReconnectExhaustsMaxAttemptsWhenConnectKeepsFailing() async {
        let (manager, mock) = makeManager(
            connectFailures: Array(repeating: refusedFailure, count: 5),
            defaults: freshDefaults(),
            scheduler: fastScheduler
        )

        manager.observe(devices: [makeDevice(serial: wirelessSerial)])
        manager.observe(devices: [])

        let ended = await waitUntil {
            await manager.isReconnecting == false
        }
        XCTAssertTrue(ended, "sequence should have ended exhausted")

        let attempts = await mock.connectAttempts
        XCTAssertEqual(attempts, Array(repeating: wirelessSerial, count: 5))
        XCTAssertEqual(manager.reconnectAttempt, 5)
        XCTAssertNil(manager.transportState)
        XCTAssertNotNil(manager.lastReconnectFailure)
    }

    /// Recovery: two attempts fail, the endpoint then answers, the re-list finds the
    /// device again, and the sequence stops with the wireless state restored.
    func testReconnectStopsOnceDeviceReappears() async {
        let (manager, mock) = makeManager(
            connectFailures: Array(repeating: refusedFailure, count: 2),
            defaults: freshDefaults(),
            scheduler: fastScheduler
        )
        let device = makeDevice(serial: wirelessSerial)

        manager.observe(devices: [device])
        manager.observe(devices: [])

        // Model the consumer's re-list: after a connect, `refreshDevices` runs and
        // the fresh listing again contains the device.
        manager.refreshHook = { [weak manager] in
            manager?.observe(devices: [device])
        }

        let recovered = await waitUntil {
            await manager.transportState != nil
        }
        XCTAssertTrue(recovered, "reconnect should have completed")

        XCTAssertEqual(
            manager.transportState,
            TransportState(mode: .wireless, deviceSerial: wirelessSerial)
        )
        XCTAssertFalse(manager.isReconnecting)
        let attempts = await mock.connectAttempts
        XCTAssertEqual(attempts, Array(repeating: wirelessSerial, count: 3), "two failures plus one success")
    }

    /// `adb connect` can return success against an endpoint that immediately drops.
    /// A connect acknowledgement with no device in the re-listing is NOT recovery:
    /// the sequence must keep going to exhaustion.
    func testConnectAcknowledgementWithoutDeviceIsNotRecovery() async {
        let (manager, mock) = makeManager(
            connectFailures: [],
            defaults: freshDefaults(),
            scheduler: fastScheduler
        )
        manager.refreshHook = {} // the re-list finds nothing

        manager.observe(devices: [makeDevice(serial: wirelessSerial)])
        manager.observe(devices: [])

        let ended = await waitUntil {
            await manager.isReconnecting == false
        }
        XCTAssertTrue(ended)

        let attempts = await mock.connectAttempts
        XCTAssertEqual(attempts.count, 5)
        XCTAssertEqual(manager.reconnectAttempt, 5)
        XCTAssertNil(manager.transportState)
    }

    /// Further offline observations during a running sequence must not start
    /// another one.
    func testObserveDoesNotStackSequences() async {
        let (manager, mock) = makeManager(
            connectFailures: Array(repeating: refusedFailure, count: 5),
            defaults: freshDefaults(),
            scheduler: fastScheduler
        )

        manager.observe(devices: [makeDevice(serial: wirelessSerial)])
        manager.observe(devices: [])
        manager.observe(devices: [])
        manager.observe(devices: [])

        let ended = await waitUntil {
            await manager.isReconnecting == false
        }
        XCTAssertTrue(ended)

        let attempts = await mock.connectAttempts
        XCTAssertEqual(attempts.count, 5, "exactly the running sequence, no stacking")
    }

    /// An exhausted sequence is terminal — but a device sighting resets it, so the
    /// next drop is allowed to reconnect again.
    func testExhaustionResetsAfterSuccessfulObservation() async {
        let (manager, mock) = makeManager(
            connectFailures: Array(repeating: refusedFailure, count: 5),
            defaults: freshDefaults(),
            scheduler: fastScheduler
        )
        let device = makeDevice(serial: wirelessSerial)

        manager.observe(devices: [device])
        manager.observe(devices: [])

        let exhausted = await waitUntil {
            await manager.isReconnecting == false && manager.reconnectAttempt == 5
        }
        XCTAssertTrue(exhausted, "the first sequence should exhaust")

        let firstRunCount = await mock.connectAttempts.count
        XCTAssertEqual(firstRunCount, 5)

        manager.observe(devices: [device])
        let afterRecoveryCount = await mock.connectAttempts.count
        XCTAssertEqual(afterRecoveryCount, 5, "no connect needed when re-sighted")

        manager.observe(devices: [])
        let restarted = await waitUntil {
            await mock.connectAttempts.count > firstRunCount
        }
        XCTAssertTrue(restarted, "a second drop must restart the sequence, not stay exhausted")
    }

    /// Persistence drives recovery across restarts: a fresh manager over the same
    /// defaults re-dials the remembered endpoint on an offline observation.
    func testLoadedEndpointDrivesReconnectAcrossRestart() async {
        let defaults = freshDefaults()
        let firstManager = makeManager(connectFailures: [], defaults: defaults, scheduler: fastScheduler).0
        firstManager.observe(devices: [makeDevice(serial: wirelessSerial)])

        // Simulate a restart: a brand-new manager over the same defaults storage.
        let (fresh, mock) = makeManager(
            connectFailures: Array(repeating: refusedFailure, count: 5),
            defaults: defaults,
            scheduler: fastScheduler
        )
        fresh.observe(devices: [])

        let dialled = await waitUntil {
            await mock.connectAttempts.first == wirelessSerial
        }
        XCTAssertTrue(dialled, "the loaded endpoint must be what gets re-dialled")

        let settled = await waitUntil {
            await mock.connectAttempts.count == 5
        }
        XCTAssertTrue(settled)
        XCTAssertNotNil(
            defaults.data(forKey: ConnectionManager.persistedStateKey),
            "the persistence record must survive the restart"
        )
    }
}

// MARK: - 5. Network-change triggering

@MainActor
final class NetworkPathMonitorTriggerTests: XCTestCase {

    /// A network coming up is the actionable direction: a remembered endpoint plus
    /// an offline transport must start re-dialling on `.satisfied`.
    func testSatisfiedPathStartsReconnectWhenOffline() async {
        let monitor = MockNetworkPathMonitor()
        let (manager, mock) = makeManager(
            connectFailures: Array(repeating: refusedFailure, count: 5),
            defaults: freshDefaults(),
            scheduler: fastScheduler,
            pathMonitor: monitor
        )
        manager.observe(devices: [makeDevice(serial: wirelessSerial)])
        manager.observe(devices: [])

        // The first sequence must drain before the network event, so this test
        // measures only the path-triggered path.
        let ended = await waitUntil {
            await manager.isReconnecting == false
        }
        XCTAssertTrue(ended)
        let runCount = await mock.connectAttempts.count
        XCTAssertEqual(runCount, 5)

        monitor.simulate(.unsatisfied)
        let afterUnsatisfiedCount = await mock.connectAttempts.count
        let afterUnsatisfiedMessage = "a network going down is not actionable"
        XCTAssertEqual(afterUnsatisfiedCount, 5, afterUnsatisfiedMessage)

        monitor.simulate(.satisfied)
        let restarted = await waitUntil {
            await mock.connectAttempts.count > runCount
        }
        XCTAssertTrue(restarted, "a network coming up must start a new sequence")
    }

    /// The seam must be started by its owner.
    func testMonitorStartsWhenAttached() {
        let monitor = MockNetworkPathMonitor()
        _ = makeManager(connectFailures: [], defaults: freshDefaults(), scheduler: .standard, pathMonitor: monitor)

        XCTAssertTrue(monitor.started)
    }
}

// MARK: - 6. DeviceManager dual-transport integration

@MainActor
final class DeviceManagerConnectionIntegrationTests: XCTestCase {

    /// The wired device wins and is published as the active transport.
    func testWiredDeviceIsPublishedAsActiveTransport() async {
        let transport = MockTransport()
        await transport.setDeviceList([
            makeDevice(serial: wirelessSerial),
            makeDevice(serial: wiredSerial)
        ])
        let manager = DeviceManager(
            transport: transport,
            pathMonitor: MockNetworkPathMonitor(),
            defaults: freshDefaults(),
            reconnectScheduler: fastScheduler
        )

        await manager.refreshDevices()

        XCTAssertEqual(
            manager.transportState,
            TransportState(mode: .wired, deviceSerial: wiredSerial)
        )
    }

    /// Unplugging the cable drops the published state; the remembered wireless
    /// endpoint is then re-dialled.
    func testUnplugFallsBackAndDialsRememberedWirelessEndpoint() async {
        let transport = MockTransport()
        await transport.setDeviceList([makeDevice(serial: wirelessSerial)])
        let connectionTransport = MockConnectionTransport(failurePlan: Array(repeating: refusedFailure, count: 5))
        let manager = DeviceManager(
            transport: transport,
            connectionTransport: connectionTransport,
            pathMonitor: MockNetworkPathMonitor(),
            defaults: freshDefaults(),
            reconnectScheduler: fastScheduler
        )

        await manager.refreshDevices()
        XCTAssertEqual(
            manager.transportState,
            TransportState(mode: .wireless, deviceSerial: wirelessSerial)
        )

        // Both transports gone.
        await transport.setDeviceList([])
        await manager.refreshDevices()
        XCTAssertNil(manager.transportState)
        XCTAssertEqual(manager.connectionManager.rememberedWirelessEndpoint, wirelessEndpoint)

        let dialled = await waitUntil {
            await connectionTransport.connectAttempts.contains(wirelessSerial)
        }
        XCTAssertTrue(dialled, "the remembered wireless endpoint must be re-dialled")
    }

    /// AppState mirrors the selection for status UI delivery.
    func testAppStateMirrorsTransportState() async {
        let transport = MockTransport()
        await transport.setDeviceList([makeDevice(serial: wiredSerial)])
        let manager = DeviceManager(
            transport: transport,
            pathMonitor: MockNetworkPathMonitor(),
            defaults: freshDefaults(),
            reconnectScheduler: fastScheduler
        )
        let state = AppState(deviceManager: manager, transport: transport)

        await state.refreshDevices()

        XCTAssertEqual(
            state.transportState,
            TransportState(mode: .wired, deviceSerial: wiredSerial)
        )
    }
}

// MARK: - 7. adb connect result interpretation

final class ADBConnectValidationTests: XCTestCase {

    func testConnectedOutputIsSuccess() {
        let result = TransportResult(
            exitCode: 0,
            stdout: "connected to 192.168.1.4:37351\n",
            stderr: ""
        )

        XCTAssertNoThrow(try ADBTransport.validateConnectResult(result, endpoint: "192.168.1.4:37351"))
    }

    /// `already connected` — a reconnect attempt racing a live connection — is a
    /// success, not a failure.
    func testAlreadyConnectedOutputIsSuccess() {
        let result = TransportResult(
            exitCode: 0,
            stdout: "already connected to 192.168.1.4:37351\n",
            stderr: ""
        )

        XCTAssertNoThrow(try ADBTransport.validateConnectResult(result, endpoint: "192.168.1.4:37351"))
    }

    /// The documented trap: `adb connect` to a dead endpoint exits 0 and prints the
    /// failure on stdout. Exit status alone must never decide success.
    func testCannotConnectOutputIsFailureDespiteExitZero() {
        let result = TransportResult(
            exitCode: 0,
            stdout: "cannot connect to 192.168.1.4:37351: Connection refused\n",
            stderr: ""
        )

        XCTAssertThrowsError(try ADBTransport.validateConnectResult(result, endpoint: "192.168.1.4:37351")) { error in
            guard case PixelDesktopError.adbTransportError = error else {
                return XCTFail("expected adbTransportError, got \(error)")
            }
        }
    }

    func testNonZeroExitIsCommandFailure() {
        let result = TransportResult(exitCode: 1, stdout: "", stderr: "boom")

        XCTAssertThrowsError(try ADBTransport.validateConnectResult(result, endpoint: "192.168.1.4:37351")) { error in
            guard case PixelDesktopError.adbCommandFailed = error else {
                return XCTFail("expected adbCommandFailed, got \(error)")
            }
        }
    }

    func testUnrecognizedOutputIsFailure() {
        let result = TransportResult(exitCode: 0, stdout: "definitely not a connect reply", stderr: "")

        XCTAssertThrowsError(try ADBTransport.validateConnectResult(result, endpoint: "192.168.1.4:37351"))
    }
}

// MARK: - 8. Connection diagnosis (ADR-017, Option C)
//
// The defect this closes: `transportState == nil` rendered as the single word "Offline" collapses
// four situations with four different remedies into one undifferentiated state. The order of the
// checks below is the decision, not an implementation detail — a failed listing is not evidence
// about the device, and an unauthorised device is strictly more information than an endpoint that
// is not answering.

/// A transport whose listing always fails, modelling an `adb` that does not answer.
///
/// `MockTransport` cannot express this — its `listDevices` returns the canned array and never
/// throws — and a failed listing is a genuinely different cause from an empty one, so the
/// distinction is worth a dedicated double rather than a flag on the shared mock.
private actor ListingFailureTransport: TransportProtocol {
    func listDevices() async throws -> [AndroidDevice] {
        throw PixelDesktopError.adbTransportError("adb server not responding")
    }

    func execute(command: String, arguments: [String], timeout: TimeInterval) async throws -> TransportResult {
        TransportResult(exitCode: 1, stdout: "", stderr: "adb: command not found")
    }

    func getprop(deviceSerial: String, key: String, timeout: TimeInterval) async throws -> String {
        throw PixelDesktopError.adbCommandFailed(command: "getprop", exitCode: 1, stderr: "unavailable")
    }

    func shell(deviceSerial: String, command: String, timeout: TimeInterval) async throws -> TransportResult {
        TransportResult(exitCode: 1, stdout: "", stderr: "unavailable")
    }

    func shellStreaming(
        deviceSerial: String,
        command: String,
        stdin: String?,
        onLine: @Sendable @escaping (String) -> Void,
        onStderrLine: @Sendable @escaping (String) -> Void,
        cancellation: CancellationHandle
    ) async throws -> Int32 {
        1
    }

    func execOut(deviceSerial: String, arguments: [String], timeout: TimeInterval) async throws -> TransportBinaryResult {
        TransportBinaryResult(exitCode: 1, stdout: Data(), stderr: "execOut is not used by this test double")
    }

    func push(deviceSerial: String, localPath: String, remotePath: String, timeout: TimeInterval) async throws -> TransportResult {
        TransportResult(exitCode: 1, stdout: "", stderr: "unavailable")
    }

    func pull(deviceSerial: String, remotePath: String, localPath: String, timeout: TimeInterval) async throws -> TransportResult {
        TransportResult(exitCode: 1, stdout: "", stderr: "unavailable")
    }

    func install(deviceSerial: String, apkPath: String, replace: Bool, timeout: TimeInterval) async throws -> TransportResult {
        TransportResult(exitCode: 1, stdout: "", stderr: "unavailable")
    }

    func getSystemProperties(deviceSerial: String, timeout: TimeInterval) async throws -> [String: String] {
        [:]
    }
}

final class TransportDiagnosisTests: XCTestCase {

    private func context(
        transportState: TransportState? = nil,
        devices: [AndroidDevice] = [],
        listingError: PixelDesktopError? = nil,
        rememberedEndpoint: WirelessEndpoint? = nil,
        isReconnecting: Bool = false,
        reconnectAttempt: Int = 0
    ) -> TransportDiagnosisContext {
        TransportDiagnosisContext(
            transportState: transportState,
            devices: devices,
            listingError: listingError,
            rememberedEndpoint: rememberedEndpoint,
            isReconnecting: isReconnecting,
            reconnectAttempt: reconnectAttempt
        )
    }

    // MARK: Classification

    /// A selected transport is a fact, reported as such — never diagnosed as a failure.
    func testConnectedTransportHasNoCause() {
        let diagnosis = TransportDiagnoser.classify(
            context(
                transportState: TransportState(mode: .wired, deviceSerial: wiredSerial),
                devices: [makeDevice(serial: wiredSerial)]
            )
        )

        XCTAssertTrue(diagnosis.isConnected)
        XCTAssertNil(diagnosis.cause)
        XCTAssertNil(diagnosis.action)
        XCTAssertEqual(diagnosis.summary, "Connected")
    }

    /// Nothing attached and no remembered endpoint: the "cable unplugged" case.
    func testNoDeviceAndNoEndpointIsNoDeviceDetected() {
        let diagnosis = TransportDiagnoser.classify(context())

        XCTAssertFalse(diagnosis.isConnected)
        XCTAssertEqual(diagnosis.cause, .noDeviceDetected)
    }

    /// An endpoint is remembered but not answering — the "wireless debugging silently disabled"
    /// case, and the one the user cannot fix from the Mac.
    func testRememberedEndpointWithoutDeviceIsWirelessUnreachable() {
        let diagnosis = TransportDiagnoser.classify(
            context(rememberedEndpoint: wirelessEndpoint)
        )

        XCTAssertEqual(diagnosis.cause, .wirelessUnreachable)
        XCTAssertEqual(diagnosis.rememberedEndpoint, wirelessEndpoint)
    }

    /// A device is attached but unauthorised: the phone is present, the user must tap Allow.
    func testUnauthorizedDeviceIsPairingRequired() {
        let diagnosis = TransportDiagnoser.classify(
            context(devices: [makeDevice(serial: wiredSerial, state: .unauthorized)])
        )

        XCTAssertEqual(diagnosis.cause, .pairingRequired)
    }

    /// A failed listing is a fault on the Mac, not evidence about the phone.
    func testFailedListingIsADBUnavailable() {
        let diagnosis = TransportDiagnoser.classify(
            context(
                devices: [makeDevice(serial: wiredSerial)],
                listingError: PixelDesktopError.adbTransportError("adb server not responding")
            )
        )

        XCTAssertEqual(diagnosis.cause, .adbUnavailable)
    }

    // MARK: Priority — the order is the decision

    /// A failed listing wins even when a device appears to be attached: the listing is the
    /// evidence, and when it fails nothing is known.
    func testListingFailureBeatsUnauthorizedDevice() {
        let diagnosis = TransportDiagnoser.classify(
            context(
                devices: [makeDevice(serial: wiredSerial, state: .unauthorized)],
                listingError: PixelDesktopError.adbTransportError("boom")
            )
        )

        XCTAssertEqual(diagnosis.cause, .adbUnavailable)
    }

    /// An unauthorised device wins over a remembered endpoint: the phone is physically present,
    /// so "tap Allow" is a different and better instruction than "re-enable wireless".
    func testUnauthorizedBeatsRememberedEndpoint() {
        let diagnosis = TransportDiagnoser.classify(
            context(
                devices: [makeDevice(serial: wiredSerial, state: .unauthorized)],
                rememberedEndpoint: wirelessEndpoint
            )
        )

        XCTAssertEqual(diagnosis.cause, .pairingRequired)
    }

    // MARK: Presentation

    /// Every cause must be actionable: a summary without an action is a dead end for the user.
    func testEveryCauseHasSummaryAndAction() {
        for cause in TransportCause.allCases {
            XCTAssertFalse(cause.summary.isEmpty, "\(cause) has no summary")
            XCTAssertFalse(cause.action.isEmpty, "\(cause) has no action")
        }
    }

    /// A reconnect in flight is visible, so the UI shows progress rather than a dead end.
    func testRecoveringStateIsVisible() {
        let diagnosis = TransportDiagnoser.classify(
            context(rememberedEndpoint: wirelessEndpoint, isReconnecting: true, reconnectAttempt: 2)
        )

        XCTAssertTrue(diagnosis.isRecovering)
        XCTAssertEqual(diagnosis.reconnectAttempt, 2)
    }

    /// A remembered endpoint is not proof of reachability, so it is carried as context rather
    /// than reported as a connection.
    func testRememberedEndpointDoesNotMakeItConnected() {
        let diagnosis = TransportDiagnoser.classify(
            context(rememberedEndpoint: wirelessEndpoint)
        )

        XCTAssertFalse(diagnosis.isConnected)
        XCTAssertNotNil(diagnosis.rememberedEndpoint)
    }

    /// The diagnosis survives a round trip, so it can be persisted or published as JSON.
    func testDiagnosisRoundTripsThroughCodable() throws {
        let diagnosis = TransportDiagnoser.classify(
            context(
                transportState: TransportState(mode: .wireless, deviceSerial: wirelessSerial),
                rememberedEndpoint: wirelessEndpoint
            )
        )

        let decoded = try JSONDecoder().decode(
            TransportDiagnosis.self,
            from: JSONEncoder().encode(diagnosis)
        )

        XCTAssertEqual(decoded, diagnosis)
    }

    // MARK: Integration — DeviceManager publishes the diagnosis

    @MainActor
    private func makeManager(
        transport: MockTransport,
        defaults: UserDefaults
    ) -> DeviceManager {
        DeviceManager(
            transport: transport,
            pathMonitor: MockNetworkPathMonitor(),
            defaults: defaults,
            reconnectScheduler: fastScheduler
        )
    }

    @MainActor
    func testDeviceManagerPublishesNoDeviceDetectedWhenNothingAttached() async {
        let transport = MockTransport()
        await transport.setDeviceList([])
        let manager = makeManager(transport: transport, defaults: freshDefaults())

        await manager.refreshDevices()

        XCTAssertNil(manager.transportState)
        XCTAssertEqual(manager.diagnosis?.cause, .noDeviceDetected)
    }

    @MainActor
    func testDeviceManagerPublishesPairingRequiredForUnauthorizedDevice() async {
        let transport = MockTransport()
        await transport.setDeviceList([makeDevice(serial: wiredSerial, state: .unauthorized)])
        let manager = makeManager(transport: transport, defaults: freshDefaults())

        await manager.refreshDevices()

        XCTAssertEqual(manager.diagnosis?.cause, .pairingRequired)
        XCTAssertNotNil(manager.diagnosis?.action)
    }

    @MainActor
    func testDeviceManagerPublishesConnectedDiagnosisWithNoCause() async {
        let transport = MockTransport()
        await transport.setDeviceList([makeDevice(serial: wiredSerial)])
        let manager = makeManager(transport: transport, defaults: freshDefaults())

        await manager.refreshDevices()

        XCTAssertEqual(manager.transportState, TransportState(mode: .wired, deviceSerial: wiredSerial))
        XCTAssertEqual(manager.diagnosis?.isConnected, true)
        XCTAssertNil(manager.diagnosis?.cause)
    }

    /// A listing failure is diagnosed as an adb fault, not as an absent device — the distinction
    /// that stops the user being sent to the phone when the fault is on the Mac.
    @MainActor
    func testDeviceManagerPublishesADBUnavailableOnListingFailure() async {
        let manager = DeviceManager(
            transport: ListingFailureTransport(),
            pathMonitor: MockNetworkPathMonitor(),
            defaults: freshDefaults(),
            reconnectScheduler: fastScheduler
        )

        await manager.refreshDevices()

        XCTAssertNotNil(manager.lastError)
        XCTAssertNil(manager.transportState)
        XCTAssertEqual(manager.diagnosis?.cause, .adbUnavailable)
    }

    /// AppState mirrors the diagnosis for status UI delivery.
    @MainActor
    func testAppStateMirrorsDiagnosis() async {
        let transport = MockTransport()
        await transport.setDeviceList([])
        let manager = makeManager(transport: transport, defaults: freshDefaults())
        let state = AppState(deviceManager: manager, transport: transport)

        await state.refreshDevices()

        XCTAssertEqual(state.diagnosis?.cause, .noDeviceDetected)
        XCTAssertEqual(state.diagnosis?.summary, "No device detected")
    }
}
