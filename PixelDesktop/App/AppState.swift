import SwiftUI
import Combine

@MainActor
final class AppState: ObservableObject {
    @Published var devices: [AndroidDevice] = []
    @Published var isDiscovering: Bool = false
    @Published var lastError: PixelDesktopError?
    @Published var logMessages: [LogEntry] = []

    /// Phase 1 (Connection Foundation) — the transport currently in use, wired or
    /// wireless, or `nil` when offline. Pure passthrough of what
    /// `DeviceManager.refreshDevices` selected; Phase 3 renders it in status UI.
    @Published var transportState: TransportState?

    /// Why the system is not connected, in terms a user can act on (ADR-017, Option C).
    ///
    /// `nil` until the first discovery pass completes, so the UI never shows a diagnosed cause
    /// before anything has actually been read.
    @Published var diagnosis: TransportDiagnosis?

    // MARK: - Storage state (Phase 3)
    //
    // These expose the StorageService to the UI. The service is created on-demand
    // when a device is connected; all operations go through it so the UI never
    // touches ADB directly.

    /// The items in the currently-displayed storage directory.
    @Published var storageItems: [StorageItem] = []

    /// The path of the directory whose contents are currently displayed.
    /// Updated on every successful `loadStorageItems` so post-mutation reloads
    /// target the same directory the user is viewing.
    @Published var storageCurrentPath: String = StorageService.storageRoot

    /// Whether a storage operation is in flight.
    @Published var storageIsLoading: Bool = false

    /// The last storage error, or `nil` when the last operation succeeded.
    @Published var storageError: StorageError?

    /// The most recent transfer progress sample, or `nil` when no transfer is active.
    @Published var storageTransferProgress: StorageTransferProgress?

    /// Disk space on the device filesystem, or `nil` when unknown.
    @Published var storageDiskSpace: (used: UInt64, total: UInt64)?

    /// The storage service for the connected device, or `nil` when offline.
    var storageService: StorageService? {
        guard let serial = selectedSerial else { return nil }
        return StorageService(deviceSerial: serial, transport: transport)
    }

    // MARK: - Phase 0 (control plane) accessors
    //
    // Read-only perception and forward management, exposed the same way the storage and
    // application layers are: through a named protocol, never through the transport. There is
    // deliberately no `tap` or `type` here — input injection is Phase 2 and does not exist.

    /// Read-only screen perception (UI hierarchy, screenshot).
    var perception: DevicePerceptionProtocol {
        ADBDevicePerception(transport: transport)
    }

    /// Host→device port forwards.
    var portForwarding: PortForwardingProtocol {
        ADBPortForwarding(transport: transport)
    }

    /// A fresh logcat stream bound to the same transport.
    ///
    /// Returned rather than stored because a stream is a session: the view owns its lifetime,
    /// and a shared instance would let one pane stop another pane's stream.
    func makeLogcatStream(capacity: Int = 2000) -> LogcatStream {
        LogcatStream(transport: transport, capacity: capacity)
    }

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

        deviceManager.$transportState
            .receive(on: DispatchQueue.main)
            .assign(to: &$transportState)

        deviceManager.$diagnosis
            .receive(on: DispatchQueue.main)
            .assign(to: &$diagnosis)
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

        // Mirror the transport readings directly, for the same reason `devices` is read
        // directly above: the Combine binding is eventual, and its delivery depends on the main
        // runloop turning over. When no device is connected, `enrichConnectedDevice()` returns
        // without awaiting anything, so nothing forces that turn — and the mirrored values would
        // still be stale on return. Reading them here makes the postcondition unconditional for
        // every published field, not just `devices`.
        self.transportState = await deviceManager.transportState
        self.diagnosis = await deviceManager.diagnosis

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

    // MARK: - Storage operations (Phase 3)
    //
    // Each wrapper is guard-first: it refuses to act when no device is connected,
    // before any command is issued. Failures are recorded in `storageError` rather
    // than thrown, so the view never has to manage its own do/catch.

    /// Creates the storage root if it does not exist. Idempotent.
    func ensureStorageRoot() async {
        guard let service = storageService else { return }
        _ = try? await service.mkdir(path: StorageService.storageRoot)
    }

    /// Lists the contents of a storage directory.
    func loadStorageItems(path: String) async {
        guard let service = storageService else {
            storageItems = []
            storageError = nil
            return
        }
        storageIsLoading = true
        storageError = nil
        defer { storageIsLoading = false }
        do {
            storageItems = try await service.list(path: path)
            storageCurrentPath = path
        } catch let error as StorageError {
            storageError = error
        } catch {
            storageError = .unknown(error.localizedDescription)
        }
    }

    /// Uploads a local file to the device.
    func uploadFile(localPath: String, remotePath: String) async {
        guard let service = storageService else {
            storageError = .deviceOffline
            return
        }
        storageError = nil
        do {
            try await service.upload(localPath: localPath, remotePath: remotePath) { progress in
                Task { @MainActor in
                    self.storageTransferProgress = progress
                }
            }
            await loadStorageItems(path: storageCurrentPath)
        } catch let error as StorageError {
            storageError = error
        } catch {
            storageError = .unknown(error.localizedDescription)
        }
    }

    /// Downloads a device file to a local path.
    func downloadFile(remotePath: String, localPath: String) async {
        guard let service = storageService else {
            storageError = .deviceOffline
            return
        }
        storageError = nil
        do {
            try await service.download(remotePath: remotePath, localPath: localPath) { progress in
                Task { @MainActor in
                    self.storageTransferProgress = progress
                }
            }
        } catch let error as StorageError {
            storageError = error
        } catch {
            storageError = .unknown(error.localizedDescription)
        }
    }

    /// Deletes a file or folder on the device.
    func deleteStorageItem(path: String) async {
        guard let service = storageService else {
            storageError = .deviceOffline
            return
        }
        storageError = nil
        do {
            try await service.delete(path: path)
            await loadStorageItems(path: storageCurrentPath)
        } catch let error as StorageError {
            storageError = error
        } catch {
            storageError = .unknown(error.localizedDescription)
        }
    }

    /// Creates a directory on the device.
    func createStorageFolder(path: String) async {
        guard let service = storageService else {
            storageError = .deviceOffline
            return
        }
        storageError = nil
        do {
            try await service.mkdir(path: path)
            await loadStorageItems(path: storageCurrentPath)
        } catch let error as StorageError {
            storageError = error
        } catch {
            storageError = .unknown(error.localizedDescription)
        }
    }

    /// Renames or moves an item on the device.
    func renameStorageItem(from: String, to: String) async {
        guard let service = storageService else {
            storageError = .deviceOffline
            return
        }
        storageError = nil
        do {
            try await service.rename(from: from, to: to)
            await loadStorageItems(path: storageCurrentPath)
        } catch let error as StorageError {
            storageError = error
        } catch {
            storageError = .unknown(error.localizedDescription)
        }
    }

    /// Refreshes the disk space display.
    func refreshStorageDiskSpace() async {
        guard let service = storageService else {
            storageDiskSpace = nil
            return
        }
        storageDiskSpace = await service.diskSpace()
    }

}
