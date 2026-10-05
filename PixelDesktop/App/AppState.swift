import SwiftUI
import Combine

@MainActor
final class AppState: ObservableObject {
    @Published var devices: [AndroidDevice] = []
    @Published var isDiscovering: Bool = false
    @Published var lastError: PixelDesktopError?
    @Published var logMessages: [LogEntry] = []

    // MARK: - Phase 8 (UI) additions
    //
    // These expose backend capability that already existed and was already verified on real
    // hardware, but had no UI path to it. Nothing new is computed here; every value comes from
    // `PixelEvidenceReader` or `AppOperationsProtocol`, the same types the CLI publishes from.

    /// The most recent device observation, or `nil` before one has been taken.
    ///
    /// `nil` is meaningfully different from a populated-but-empty observation: it means "not read
    /// yet", not "read and everything was absent". The view renders those differently.
    @Published var observation: PixelStateObservation?
    @Published var isObserving: Bool = false

    /// The selected device's serial, or `nil` when nothing is connected.
    ///
    /// Selection is by connected device rather than by an explicit picker: the project targets a
    /// single attached Pixel, and inventing multi-device selection would be a capability the
    /// backend does not have.
    var selectedSerial: String? {
        devices.first(where: { $0.state == .device })?.serialNumber
    }

    /// Applications reported by the device, newest read wins.
    @Published var installedApplications: [InstalledApp] = []
    @Published var isListingApplications: Bool = false

    private let deviceManager: DeviceManager
    private let transport: TransportProtocol
    private let appOperations: AppOperationsProtocol
    private var cancellables = Set<AnyCancellable>()

    init(
        deviceManager: DeviceManager? = nil,
        transport: TransportProtocol? = nil,
        appOperations: AppOperationsProtocol? = nil
    ) {
        let resolvedTransport = transport ?? ADBTransport()
        self.transport = resolvedTransport
        self.appOperations = appOperations ?? ADBAppOperations(transport: resolvedTransport)
        self.deviceManager = deviceManager ?? DeviceManager()
        setupBindings()
    }

    private func setupBindings() {
        deviceManager.$devices
            .receive(on: DispatchQueue.main)
            .assign(to: &$devices)

        deviceManager.$isDiscovering
            .receive(on: DispatchQueue.main)
            .assign(to: &$isDiscovering)

        deviceManager.$lastError
            .receive(on: DispatchQueue.main)
            .assign(to: &$lastError)

        deviceManager.$logMessages
            .receive(on: DispatchQueue.main)
            .assign(to: &$logMessages)
    }

    /// Starts discovery and returns once it has begun.
    ///
    /// `async` rather than fire-and-forget: a caller that cannot await the operation cannot know
    /// whether it succeeded, and a test cannot observe its effect. The view wraps this in a
    /// `Task` at the call site, which is where the "don't block the UI" decision belongs.
    func startDiscovery() async {
        await deviceManager.startDiscovery()
    }

    func stopDiscovery() async {
        await deviceManager.stopDiscovery()
    }

    /// Re-reads the device list and enriches the connected device.
    ///
    /// `async` for the same reason as `startDiscovery`. After this returns, `devices` and
    /// `selectedSerial` reflect the current hardware, so a caller that awaits it can act
    /// immediately — previously the enrichment ran in a detached `Task` that nothing could
    /// wait on, and `devices` was only updated via an asynchronous Combine dispatch that tests
    /// (and the "Refresh" button's completion) could not observe.
    ///
    /// The Combine binding from `DeviceManager.$devices` is retained for the **discovery poll**
    /// path (`DeviceManager.startDiscovery` updates `devices` on its own cadence). But for the
    /// explicit `refreshDevices` call, we read `deviceManager.devices` directly so the method's
    /// postcondition is unconditional, not "when the main runloop next turns over".
    ///
    /// The final re-read after `enrichConnectedDevice` is deliberate: enrichment runs through
    /// `deviceManager.enrichDevice`, which mutates `deviceManager.devices` in place but does NOT
    /// touch `self.devices`. Without this re-read, a successful enrichment would not be visible
    /// until the Combine dispatch eventually fired — which was precisely the defect.
    func refreshDevices() async {
        await deviceManager.refreshDevices()
        // Set self.devices before enrichment: enrichConnectedDevice() reads selectedSerial
        // from self.devices, so it must be populated first.
        self.devices = await deviceManager.devices
        await enrichConnectedDevice()
        // Re-read: enrichConnectedDevice may have updated deviceManager.devices in place
        // via enrichDevice, and we need our copy to reflect the enriched values.
        self.devices = await deviceManager.devices
    }

    /// Reads the stable system properties for the connected device.
    ///
    /// **This wires up a path that was implemented in Phase 3 and never called.** The code
    /// documented the omission explicitly — "The UI still does not call `enrichDevice` —
    /// `ContentView` will show 'Unknown' for enrichment fields until Phase 8 wires it" — and the
    /// architecture overview said the same. Phase 8 is the phase that was supposed to wire it, so
    /// this is the deferred work being completed rather than a new feature.
    ///
    /// Enrichment is **not** on the discovery poll. `DeviceManager.enrichDevice` documents why:
    /// these properties cannot change while the device stays booted, so enriching on every 5 s
    /// poll would add ADB round trips for information that cannot change. It runs on connect and
    /// on explicit refresh, which is the same cadence `refreshDevices()` already had.
    ///
    /// Failures are non-fatal and recorded rather than thrown: a device that is present but
    /// cannot be enriched still lists, and its identity fields stay empty (rendered as
    /// "Unknown"). Losing the whole device row because one `getprop` failed would be worse.
    func enrichConnectedDevice() async {
        guard let serial = selectedSerial else { return }
        do {
            _ = try await deviceManager.enrichDevice(serial: serial)
        } catch {
            lastError = (error as? PixelDesktopError) ?? .unknown(error.localizedDescription)
        }
    }

    /// Takes a point-in-time observation of the connected device.
    ///
    /// Reads through `PixelEvidenceReader`, the same type `pixel-desktop observe` publishes from,
    /// so the UI and the CLI cannot disagree about what the device reports.
    func observeDevice() async {
        guard let serial = selectedSerial else {
            observation = nil
            return
        }
        isObserving = true
        defer { isObserving = false }
        do {
            observation = try await PixelEvidenceReader(transport: transport)
                .observeState(deviceSerial: serial)
        } catch {
            // The reader reports an unreachable device as an all-unavailable observation rather
            // than throwing, so reaching here means a genuine failure. Keep the previous
            // observation rather than clearing it: a failed read is not evidence that the
            // device state changed.
            lastError = (error as? PixelDesktopError) ?? .unknown(error.localizedDescription)
        }
    }

    // MARK: - Application operations
    //
    // Phase 4 exposes operations through AppState so callers never reach the transport or a
    // raw shell. Each wrapper is guard-first: it refuses to act on a device that is not
    // currently connected, before any command is issued.

    /// The serial of the device operations should target, or a typed refusal explaining why
    /// there is none.
    ///
    /// **Phase 7 Step 3 (S3-4).** This replaces five copies of
    /// `devices.first(where: { $0.state == .device })`. That predicate was correct but lossy:
    /// an attached-but-unauthorized device matched nothing, so it was reported as
    /// `.deviceNotFound` — "No authorized Android device found" — even though the device *was*
    /// found and the user could fix it by accepting the ADB prompt on the screen.
    ///
    /// The distinction is preserved by checking the failure states **after** the success case,
    /// so a connected device still wins. No new state management is introduced: this reads the
    /// `state` the transport already parses and maps it to the error case that describes it.
    ///
    /// Precedence is `device` → `unauthorized` → `offline` → not found. Unauthorized is checked
    /// before offline because it is the actionable one: an offline device needs a cable check,
    /// but an unauthorized device needs a tap the user can perform right now.
    private func connectedDeviceSerial() throws -> String {
        if let serial = devices.first(where: { $0.state == .device })?.serialNumber {
            return serial
        }
        if devices.contains(where: { $0.state == .unauthorized }) {
            throw PixelDesktopError.deviceUnauthorized
        }
        if devices.contains(where: { $0.state == .offline }) {
            throw PixelDesktopError.deviceOffline
        }
        throw PixelDesktopError.deviceNotFound
    }

    /// Lists third-party applications on the connected device.
    func installedApplications(includeSystem: Bool = false) async throws -> [InstalledApp] {
        let serial = try connectedDeviceSerial()
        return try await appOperations.installedApplications(
            deviceSerial: serial,
            includeSystem: includeSystem,
            timeout: 30
        )
    }

    /// Lists applications and publishes the result, for the UI to render.
    ///
    /// A thin wrapper over `installedApplications(includeSystem:)` so the view does not have to
    /// manage its own `do/catch` and loading flag. The throwing form stays the API for callers
    /// that want to handle the error themselves.
    func loadInstalledApplications(includeSystem: Bool = false) async {
        isListingApplications = true
        defer { isListingApplications = false }
        do {
            installedApplications = try await installedApplications(includeSystem: includeSystem)
        } catch {
            installedApplications = []
            lastError = (error as? PixelDesktopError) ?? .unknown(error.localizedDescription)
        }
    }

    /// Lists applications that expose a launcher activity.
    func launchableApplications() async throws -> [InstalledApp] {
        let serial = try connectedDeviceSerial()
        return try await appOperations.launchableApplications(deviceSerial: serial, timeout: 30)
    }

    /// Starts an application and records any failure, for the UI to render.
    func launchApplicationReportingFailure(packageName: String) async {
        do {
            try await launchApplication(packageName: packageName)
        } catch {
            lastError = (error as? PixelDesktopError) ?? .unknown(error.localizedDescription)
        }
    }

    /// Starts an application. Guard-first; never accepts a shell string.
    func launchApplication(packageName: String) async throws {
        let serial = try connectedDeviceSerial()
        _ = try await appOperations.launchApplication(
            deviceSerial: serial,
            packageName: packageName,
            timeout: 30
        )
    }

    /// Reports whether an application is running. "Not running" is not an error.
    func isApplicationRunning(packageName: String) async throws -> Bool {
        let serial = try connectedDeviceSerial()
        return try await appOperations.isApplicationRunning(
            deviceSerial: serial,
            packageName: packageName,
            timeout: 30
        )
    }

    /// Stops an application. Containment is applied inside the operations layer.
    func stopApplication(packageName: String) async throws {
        let serial = try connectedDeviceSerial()
        _ = try await appOperations.stopApplication(
            deviceSerial: serial,
            packageName: packageName,
            timeout: 30
        )
    }
}
