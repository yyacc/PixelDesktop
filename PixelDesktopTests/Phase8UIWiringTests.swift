import XCTest
@testable import PixelDesktop

/// Tests for the Phase 8 UI wiring.
///
/// ## What this covers, and why it is worth testing
///
/// The view layer itself is not unit-tested — SwiftUI views are not meaningfully testable without
/// a snapshot harness this project does not have, and asserting on rendered text would test the
/// renderer rather than the behaviour. What *is* tested here is the `AppState` surface the views
/// call, because that surface is where two real defects lived:
///
/// 1. **`enrichDevice` was never called.** Phase 3 implemented enrichment and explicitly deferred
///    wiring it to the UI until Phase 8. Until this work, the Refresh path only discovered
///    devices — `ContentView` would show "Unknown" for model, manufacturer, Android version,
///    API level, architecture and ABIs on every launch, because nothing ever read them.
/// 2. **`installedApplications` had no non-test caller.** Phase 4 implemented the app-operations
///    layer, `AppState` wrapped it, and no UI reached it. The capability existed and was verified;
///    it was simply unreachable.
///
/// Both are now reachable. These tests hold that in place.
///
/// ## Test strategy
///
/// `AppState` is `@MainActor`, and `refreshDevices()` is `async` with an explicit postcondition:
/// "after `await`, `self.devices` reflects the current hardware." The tests rely on that
/// postcondition rather than observing Combine publishers, which is both simpler and stronger —
/// it asserts the contract the calling view actually depends on.
@MainActor
final class Phase8UIWiringTests: XCTestCase {

    // MARK: - Helpers

    private func device(state: DeviceState = .device, serial: String = "SERIAL-1") -> AndroidDevice {
        AndroidDevice(
            id: serial,
            serialNumber: serial,
            deviceCodename: "lynx",
            marketingName: "",
            manufacturer: "",
            androidVersion: "",
            apiLevel: 0,
            architecture: "",
            supportedABIs: [],
            state: state
        )
    }

    /// The batched `getprop` payload `DeviceEnricher` expects.
    private func propertyPayload() -> String {
        """
        [ro.build.version.release]: [16]
        [ro.build.version.sdk]: [36]
        [ro.product.model]: [Pixel 7a]
        [ro.product.manufacturer]: [Google]
        [ro.product.cpu.abi]: [arm64-v8a]
        [ro.product.cpu.abilist]: [arm64-v8a,armeabi-v7a]
        """
    }

    private func makeState(
        transport: MockTransport,
        appOperations: MockAppOperations? = nil
    ) async -> AppState {
        let manager = await DeviceManager(transport: transport)
        return AppState(
            deviceManager: manager,
            transport: transport,
            appOperations: appOperations
        )
    }

    // MARK: - 1. Selection

    func testSelectedSerialPrefersAConnectedDevice() async {
        let transport = MockTransport()
        await transport.setDeviceList([device(state: .unauthorized, serial: "UNAUTH")])
        let state = await makeState(transport: transport)
        await state.refreshDevices()

        XCTAssertNil(state.selectedSerial, "an unauthorized device is not selectable")

        await transport.setDeviceList([device(state: .device, serial: "OK-1")])
        await state.refreshDevices()

        XCTAssertEqual(state.selectedSerial, "OK-1")
    }

    // MARK: - 2. Enrichment is actually wired

    /// The regression this file exists for: refresh must enrich, or identity fields stay empty.
    func testRefreshEnrichesTheConnectedDevice() async {
        let transport = MockTransport()
        await transport.setDeviceList([device()])
        await transport.setProperties(ADBTransport.parseSystemProperties(propertyPayload()))

        let state = await makeState(transport: transport)
        await state.refreshDevices()

        guard let enriched = state.devices.first else {
            return XCTFail("expected a device")
        }
        XCTAssertEqual(enriched.marketingName, "Pixel 7a", "enrichment must have run")
        XCTAssertEqual(enriched.manufacturer, "Google")
        XCTAssertEqual(enriched.androidVersion, "16")
        XCTAssertEqual(enriched.apiLevel, 36)
        XCTAssertEqual(enriched.architecture, "arm64-v8a")
        XCTAssertEqual(enriched.supportedABIs, ["arm64-v8a", "armeabi-v7a"])
    }

    /// Enrichment must not run for a device that is not connected.
    func testRefreshDoesNotEnrichAnUnauthorizedDevice() async {
        let transport = MockTransport()
        await transport.setDeviceList([device(state: .unauthorized)])
        let state = await makeState(transport: transport)
        await state.refreshDevices()

        XCTAssertNil(state.selectedSerial)
        XCTAssertEqual(state.devices.first?.marketingName, "")
    }

    /// A failed enrichment must not drop the device or crash — it records an error and leaves the
    /// identity fields empty.
    func testFailedEnrichmentIsRecordedAndNonFatal() async {
        let transport = MockTransport()
        await transport.setDeviceList([device()])
        // No properties configured → getSystemProperties fails.
        let state = await makeState(transport: transport)
        await state.refreshDevices()

        XCTAssertEqual(state.devices.count, 1, "the device must still be listed")
        XCTAssertNotNil(state.lastError, "the failure must be visible")
    }

    // MARK: - 3. Observation

    /// `observeDevice` must publish an observation from the existing reader.
    func testObserveDevicePublishesAnObservation() async {
        let transport = MockTransport()
        await transport.setDeviceList([device()])
        let state = await makeState(transport: transport)
        await state.refreshDevices()

        await state.observeDevice()

        XCTAssertNotNil(state.observation, "an observation must be published")
        XCTAssertFalse(state.isObserving, "the loading flag must be cleared")
    }

    /// With nothing connected there is nothing to observe.
    func testObserveWithNoDeviceLeavesObservationNil() async {
        let transport = MockTransport()
        await transport.setDeviceList([])
        let state = await makeState(transport: transport)
        await state.refreshDevices()

        await state.observeDevice()

        XCTAssertNil(state.observation)
        XCTAssertNil(state.selectedSerial)
    }

    // MARK: - 4. Application operations are reachable

    /// The second regression this file exists for: the app list must reach the UI.
    func testLoadInstalledApplicationsPublishesTheList() async {
        let transport = MockTransport()
        await transport.setDeviceList([device()])
        let apps = MockAppOperations()
        apps.installedResult = [
            InstalledApp(packageName: "com.example.one", launchActivity: "com.example.one/.Main"),
            InstalledApp(packageName: "com.example.two", launchActivity: nil)
        ]
        let state = await makeState(transport: transport, appOperations: apps)
        await state.refreshDevices()

        await state.loadInstalledApplications()

        XCTAssertEqual(state.installedApplications.count, 2)
        XCTAssertFalse(state.isListingApplications)
        XCTAssertEqual(state.installedApplications.first?.packageName, "com.example.one")
    }

    /// A failure clears the list and records an error.
    func testFailedApplicationListClearsAndReports() async {
        let transport = MockTransport()
        await transport.setDeviceList([device()])
        let apps = MockAppOperations()
        apps.installedError = PixelDesktopError.adbCommandFailed(
            command: "pm list packages", exitCode: 1, stderr: "boom")
        let state = await makeState(transport: transport, appOperations: apps)
        await state.refreshDevices()

        await state.loadInstalledApplications()

        XCTAssertTrue(state.installedApplications.isEmpty)
        XCTAssertNotNil(state.lastError)
    }

    /// With no device, the guard-first rule applies before any command is issued.
    func testApplicationListRefusesWithNoConnectedDevice() async {
        let transport = MockTransport()
        await transport.setDeviceList([])
        let apps = MockAppOperations()
        apps.installedResult = [InstalledApp(packageName: "should.not.appear", launchActivity: nil)]
        let state = await makeState(transport: transport, appOperations: apps)
        await state.refreshDevices()

        await state.loadInstalledApplications()

        XCTAssertTrue(state.installedApplications.isEmpty, "no command may be issued with no device")
        guard case .deviceNotFound? = state.lastError else {
            return XCTFail("expected .deviceNotFound, got \(String(describing: state.lastError))")
        }
    }

    /// Launching routes through the contained operations layer and records failures.
    func testLaunchApplicationReportingFailureRecordsTheError() async {
        let transport = MockTransport()
        await transport.setDeviceList([device()])
        let apps = MockAppOperations()
        apps.launchError = PixelDesktopError.invalidInput("no launcher activity")
        let state = await makeState(transport: transport, appOperations: apps)
        await state.refreshDevices()

        await state.launchApplicationReportingFailure(packageName: "com.example.one")

        XCTAssertNotNil(state.lastError, "a launch failure must be recorded, not swallowed")
    }

    /// A successful launch records no error.
    func testSuccessfulLaunchRecordsNoError() async {
        let transport = MockTransport()
        await transport.setDeviceList([device()])
        await transport.setProperties(ADBTransport.parseSystemProperties(propertyPayload()))
        let apps = MockAppOperations()
        let state = await makeState(transport: transport, appOperations: apps)
        await state.refreshDevices()

        await state.launchApplicationReportingFailure(packageName: "com.example.one")

        XCTAssertNil(state.lastError)
        XCTAssertEqual(apps.launchedPackages, ["com.example.one"])
    }
}

// MARK: - Test double

/// A minimal `AppOperationsProtocol` double.
///
/// The project had no app-operations double because nothing outside the operations layer's own
/// tests called it. Now that `AppState` reaches it, this is the smallest thing that makes the
/// surface testable without a device.
@MainActor
final class MockAppOperations: AppOperationsProtocol {
    var installedResult: [InstalledApp] = []
    var installedError: Error?
    var launchError: Error?
    private(set) var launchedPackages: [String] = []

    func installedApplications(
        deviceSerial: String,
        includeSystem: Bool,
        timeout: TimeInterval
    ) async throws -> [InstalledApp] {
        if let installedError { throw installedError }
        return installedResult
    }

    func launchableApplications(
        deviceSerial: String,
        timeout: TimeInterval
    ) async throws -> [InstalledApp] {
        installedResult.filter { $0.isLaunchable }
    }

    func launchApplication(
        deviceSerial: String,
        packageName: String,
        timeout: TimeInterval
    ) async throws -> TransportResult {
        if let launchError { throw launchError }
        launchedPackages.append(packageName)
        return TransportResult(exitCode: 0, stdout: "", stderr: "")
    }

    func isApplicationRunning(
        deviceSerial: String,
        packageName: String,
        timeout: TimeInterval
    ) async throws -> Bool {
        false
    }

    func stopApplication(
        deviceSerial: String,
        packageName: String,
        timeout: TimeInterval
    ) async throws -> TransportResult {
        TransportResult(exitCode: 0, stdout: "", stderr: "")
    }
}
