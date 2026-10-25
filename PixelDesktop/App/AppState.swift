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

    /// Phase 1 (C1) — Termux + llama-server provisioning.
    var termuxInstaller: TermuxNodeInstallerProtocol {
        ADBTermuxNodeInstaller(transport: transport)
    }

    /// Phase 1 (C1) — on-device llama-server lifecycle.
    var llamaServer: LlamaServerServiceProtocol {
        ADBLlamaServerService(transport: transport)
    }

    // MARK: - Phase 1 (C1 + C2) — on-device compute node
    //
    // These expose the two Compute types that were instantiated here but never surfaced
    // (handoff step 8). Nothing is computed in the UI: every value comes from the service or
    // the job runner, and an operation the device cannot perform is reported as a failure
    // rather than rendered as a plausible default.
    //
    // `start`/`stop` are **blocked on the current device** by a Termux 0.118 permission the
    // adb shell cannot hold — see `LlamaServerService.swift`'s channel table. `status`,
    // `healthCheck` and the inference path all work; the real-device evidence is in
    // `docs/handoffs/handoff-pixeldesktop-phase1-device-verification.md`.

    /// The port the on-device server is expected to listen on, and the local port
    /// `adb forward` maps it to. One value because the two must agree.
    static let llamaServerPort = 8080

    /// The last known server status, or `.unknown` before the first read.
    @Published var llamaStatus: LlamaServerStatus = .unknown

    /// Whether a start or stop request is in flight.
    @Published var llamaIsBusy: Bool = false

    /// The result of the last health probe: `true`/`false`, or `nil` before one has run.
    ///
    /// Tri-state on purpose — "not probed yet" and "probed and down" are different answers.
    @Published var llamaHealthy: Bool?

    /// The last completed inference result, or `nil` before one has run.
    @Published var inferenceResult: InferenceJobResult?

    /// Whether an inference job is running.
    @Published var inferenceIsRunning: Bool = false

    /// The prompt the next inference job will send.
    @Published var inferencePrompt: String = ""

    /// The token budget for the next inference job.
    @Published var inferenceMaxTokens: Int = 64

    /// The runner used for inference jobs. Injectable so the job path is testable without a
    /// live server; the production default talks to the forwarded port over HTTP.
    private let inferenceRunner: OnDeviceInferenceJobRunnerProtocol

    /// The local port the on-device server is forwarded to.
    var llamaLocalPort: Int { Self.llamaServerPort }

    /// Reads the server's process status from the device.
    func refreshLlamaStatus() async {
        guard let serial = selectedSerial else {
            llamaStatus = .unknown
            return
        }
        llamaStatus = .unknown
        do {
            llamaStatus = try await llamaServer.status(
                deviceSerial: serial, port: Self.llamaServerPort, timeout: 15
            )
        } catch {
            llamaStatus = .failed(error.localizedDescription)
        }
    }

    /// Probes the forwarded `/health` endpoint.
    ///
    /// Host-side HTTP against `127.0.0.1`, so it succeeds or fails on the Mac's side of the
    /// tunnel and never touches the device shell.
    func checkLlamaHealth() async {
        llamaHealthy = await llamaServer.healthCheck(
            localPort: Self.llamaServerPort, timeout: 5
        )
    }

    /// Requests the server start and records the outcome.
    ///
    /// The request is issued and its result recorded verbatim. On the current device the
    /// channel is blocked, so the expected outcome is a failure surfaced through `lastError`
    /// — reported, not hidden.
    func startLlamaServer(modelPath: String) async {
        guard let serial = selectedSerial else {
            lastError = PixelDesktopError.deviceNotFound
            return
        }
        llamaIsBusy = true
        defer { llamaIsBusy = false }
        do {
            _ = try await llamaServer.start(
                deviceSerial: serial,
                port: Self.llamaServerPort,
                modelPath: modelPath,
                timeout: 30
            )
            await refreshLlamaStatus()
        } catch {
            lastError = (error as? PixelDesktopError) ?? .unknown(error.localizedDescription)
            await refreshLlamaStatus()
        }
    }

    /// Requests the server stop and records the outcome.
    func stopLlamaServer() async {
        guard let serial = selectedSerial else {
            lastError = PixelDesktopError.deviceNotFound
            return
        }
        llamaIsBusy = true
        defer { llamaIsBusy = false }
        do {
            _ = try await llamaServer.stop(deviceSerial: serial, timeout: 15)
            await refreshLlamaStatus()
        } catch {
            lastError = (error as? PixelDesktopError) ?? .unknown(error.localizedDescription)
            await refreshLlamaStatus()
        }
    }

    /// Runs one inference job against the forwarded port and publishes the result.
    ///
    /// Failures clear the previous result: a failed job is not a result, and leaving the last
    /// successful answer on screen would let a stale answer read as the answer to a new prompt.
    func runInferenceJob() async {
        guard !inferencePrompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            lastError = PixelDesktopError.invalidInput("Inference prompt is empty")
            return
        }
        inferenceIsRunning = true
        defer { inferenceIsRunning = false }
        do {
            inferenceResult = try await inferenceRunner.run(
                localPort: Self.llamaServerPort,
                request: InferenceJobRequest(
                    prompt: inferencePrompt,
                    maxTokens: inferenceMaxTokens,
                    temperature: 0.1
                ),
                timeout: 300
            )
        } catch {
            inferenceResult = nil
            lastError = (error as? PixelDesktopError) ?? .unknown(error.localizedDescription)
        }
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
        appOperations: AppOperationsProtocol? = nil,
        inferenceRunner: OnDeviceInferenceJobRunnerProtocol? = nil,
        deviceAuditLog: DeviceAuditLog? = nil,
        consentRegistry: ConsentRegistry? = nil
    ) {
        let resolvedTransport = transport ?? ADBTransport()
        self.transport = resolvedTransport
        self.appOperations = appOperations ?? ADBAppOperations(transport: resolvedTransport)
        self.deviceManager = deviceManager ?? DeviceManager()
        self.inferenceRunner = inferenceRunner ?? URLSessionOnDeviceInferenceJobRunner()
        // Phase 2 (B1) / Phase 3 (D2): the audit trail persists by default, so an action on a
        // dead-screen phone is reviewable after the fact. A test injects its own log (or an
        // in-memory one) and the suite never writes into Application Support.
        self.deviceAuditLog = deviceAuditLog
            ?? DeviceAuditLog(fileURL: try? DeviceAuditLog.applicationDefaultURL())
        // Phase 3 (D1): consent defaults to deny. An empty registry denies every data class until
        // the owner grants one with a reason — there is no seed that opens anything.
        self.consentRegistry = consentRegistry
            ?? ConsentRegistry(fileURL: try? ConsentRegistry.applicationDefaultURL())
        self.consentGrants = self.consentRegistry.grants
        self.inputAuditRecords = self.deviceAuditLog.records(for: .inputInject)
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

    // MARK: - Phase 2 (A7) — telemetry and thermal history
    //
    // Read-only, and deliberately so: ADR-018 decided the phone throttles and rnz accepts it,
    // so this layer observes and alerts rather than intervening. Nothing here sets a thermal
    // policy, a CPU governor, or a battery-saver state.

    /// The most recent telemetry read, or `nil` before the first one.
    ///
    /// `nil` means "not read yet", which the view renders differently from a read whose
    /// sub-sources were all absent.
    @Published var telemetry: DeviceTelemetry?

    /// The retained time series. Bounded — see `TelemetryHistory.defaultCapacity`.
    @Published var telemetryHistory = TelemetryHistory()

    @Published var isReadingTelemetry: Bool = false
    @Published var telemetryError: PixelDesktopError?

    /// Whether the poll loop is running.
    @Published var telemetryPolling: Bool = false

    private var telemetryPollTask: Task<Void, Never>?

    /// The telemetry reader. Same transport, same pattern as `perception`.
    var telemetryReader: DeviceTelemetryProtocol {
        ADBDeviceTelemetry(transport: transport)
    }

    /// The most recent ADR-018 alert in the retained window, or `nil`.
    ///
    /// Read by `TelemetryView` to render the alert banner, which is what makes
    /// `ThermalStatus.isAlert` an enforced contract rather than a declaration.
    var thermalAlert: TelemetrySample? { telemetryHistory.latestAlert }

    /// Reads one sample and appends it to the history.
    ///
    /// A failed read keeps the previous sample rather than clearing it: a failed read is not
    /// evidence that the device cooled down.
    func readTelemetry() async {
        guard let serial = selectedSerial else {
            telemetryError = .deviceNotFound
            return
        }
        isReadingTelemetry = true
        defer { isReadingTelemetry = false }
        do {
            let sample = try await telemetryReader.read(deviceSerial: serial, timeout: 20)
            telemetry = sample
            telemetryHistory.append(sample)
            telemetryError = nil
        } catch {
            telemetryError = (error as? PixelDesktopError) ?? .unknown(error.localizedDescription)
        }
    }

    /// Starts the poll loop. Idempotent — a second call while running does nothing, so a view
    /// that appears twice does not double the cadence.
    func startTelemetryPolling(interval: TimeInterval = 10) {
        guard telemetryPollTask == nil else { return }
        telemetryPolling = true
        telemetryPollTask = Task { [weak self] in
            guard let self else { return }
            while !Task.isCancelled {
                await self.readTelemetry()
                try? await Task.sleep(nanoseconds: UInt64(max(1, interval) * 1_000_000_000))
            }
            self.telemetryPolling = false
        }
    }

    func stopTelemetryPolling() {
        telemetryPollTask?.cancel()
        telemetryPollTask = nil
        telemetryPolling = false
    }

    // MARK: - Phase 2 (B1) — input injection
    //
    // The dry-run gate lives in the type system (`InputActionPlan.confirmed`), and these
    // wrappers are what the UI drives: propose → render the preview → confirm → execute.
    // There is no path here that executes without a proposal the user saw.

    /// The persistent device audit trail (Phase 3 D2 — generalised from the Phase 2 input-only log).
    let deviceAuditLog: DeviceAuditLog

    /// The persisted consent store (Phase 3 D1).
    let consentRegistry: ConsentRegistry

    /// The plan awaiting confirmation, or `nil` when nothing is proposed.
    @Published var pendingInputPlan: InputActionPlan?

    /// Why the last proposal was refused, or `nil`.
    @Published var inputRefusal: InputRefusal?

    /// Candidates listed when a query matched more than one element.
    @Published var inputCandidates: [String] = []

    /// The last executed action, or `nil`.
    @Published var lastInputResult: InputActionResult?

    @Published var inputIsBusy: Bool = false

    /// A snapshot of the input records, for rendering.
    ///
    /// `DeviceAuditLog` is a reference type whose mutations SwiftUI cannot observe, so the view
    /// reads this published copy instead of reaching into the log. Refreshed after every
    /// execution. Input is a projection of the shared trail, not a second trail.
    @Published var inputAuditRecords: [DeviceAuditRecord] = []

    /// A snapshot of every device record, newest last. The Phase 3 trust view renders this.
    @Published var deviceAuditRecords: [DeviceAuditRecord] = []

    /// A snapshot of the consent decisions, in data-class order.
    @Published var consentGrants: [ConsentGrant] = []

    /// The last consent refusal, or `nil`.
    @Published var consentError: ConsentError?

    var deviceInput: DeviceInputProtocol {
        ADBDeviceInput(transport: transport, auditLog: deviceAuditLog)
    }

    /// The consent gate, for any read of a P4 data class (Phase 3 D1).
    var consentGate: ConsentGate {
        ConsentGate(registry: consentRegistry, auditLog: deviceAuditLog)
    }

    /// The A5 two-tier notification read.
    ///
    /// Both tiers are P4: tier 1 carries package names and tags, tier 2 carries message bodies, so
    /// the gate is inside the reader rather than at this seam — a caller cannot obtain a reader that
    /// skips it.
    var notificationReader: NotificationReading {
        ADBNotificationReader(transport: transport, gate: consentGate)
    }

    /// Proposes a tap on the single element matching `query`, against a fresh dump.
    ///
    /// The dump is read here rather than accepted from the caller because a plan resolved
    /// against a stale hierarchy taps where the element *was*, which on a live phone is a
    /// different screen.
    func proposeTap(query: String) async {
        guard let serial = selectedSerial else {
            pendingInputPlan = nil
            lastError = PixelDesktopError.deviceNotFound
            return
        }
        inputIsBusy = true
        defer { inputIsBusy = false }
        do {
            let hierarchy = try await perception.uiHierarchy(deviceSerial: serial, timeout: 20)
            pendingInputPlan = try deviceInput.planTap(hierarchy: hierarchy, matching: query)
            inputRefusal = nil
            inputCandidates = []
        } catch let refusal as InputRefusal {
            pendingInputPlan = nil
            inputRefusal = refusal
            if case .targetAmbiguous(let candidates) = refusal {
                inputCandidates = candidates
            }
        } catch {
            pendingInputPlan = nil
            lastError = (error as? PixelDesktopError) ?? .unknown(error.localizedDescription)
        }
    }

    /// Proposes a tap on one exact element index, the disambiguation path.
    func proposeTap(elementIndex: Int) async {
        guard let serial = selectedSerial else {
            lastError = PixelDesktopError.deviceNotFound
            return
        }
        inputIsBusy = true
        defer { inputIsBusy = false }
        do {
            let hierarchy = try await perception.uiHierarchy(deviceSerial: serial, timeout: 20)
            pendingInputPlan = try deviceInput.planTap(hierarchy: hierarchy, elementIndex: elementIndex)
            inputRefusal = nil
            inputCandidates = []
        } catch let refusal as InputRefusal {
            pendingInputPlan = nil
            inputRefusal = refusal
        } catch {
            pendingInputPlan = nil
            lastError = (error as? PixelDesktopError) ?? .unknown(error.localizedDescription)
        }
    }

    /// Proposes a key event. No dump needed — a key goes to whatever has focus.
    func proposeKey(_ key: String) {
        do {
            pendingInputPlan = try deviceInput.planKeyEvent(key)
            inputRefusal = nil
            inputCandidates = []
        } catch let refusal as InputRefusal {
            pendingInputPlan = nil
            inputRefusal = refusal
        } catch {
            pendingInputPlan = nil
            lastError = (error as? PixelDesktopError) ?? .unknown(error.localizedDescription)
        }
    }

    /// Proposes typing text into the focused field.
    func proposeText(_ text: String) {
        do {
            pendingInputPlan = try deviceInput.planText(text)
            inputRefusal = nil
            inputCandidates = []
        } catch let refusal as InputRefusal {
            pendingInputPlan = nil
            inputRefusal = refusal
        } catch {
            pendingInputPlan = nil
            lastError = (error as? PixelDesktopError) ?? .unknown(error.localizedDescription)
        }
    }

    /// Confirms the pending plan and runs it.
    ///
    /// This is the only place a plan is promoted to `confirmed`, and it is called from the
    /// user's approval of the preview — not automatically after planning.
    func confirmAndExecuteInput() async {
        guard let plan = pendingInputPlan else { return }
        guard let serial = selectedSerial else {
            lastError = PixelDesktopError.deviceNotFound
            return
        }
        inputIsBusy = true
        defer {
            inputIsBusy = false
            refreshAuditSnapshots()
        }
        do {
            lastInputResult = try await deviceInput.execute(
                plan.confirming(),
                deviceSerial: serial,
                timeout: 20
            )
            pendingInputPlan = nil
            inputRefusal = nil
            inputCandidates = []
        } catch let refusal as InputRefusal {
            inputRefusal = refusal
        } catch {
            lastError = (error as? PixelDesktopError) ?? .unknown(error.localizedDescription)
        }
    }

    /// Discards the pending plan without executing it.
    func cancelInputPlan() {
        pendingInputPlan = nil
        inputRefusal = nil
        inputCandidates = []
    }

    // MARK: - Phase 3 (D1/D2) — consent and the shared trail

    /// Re-reads both published snapshots from the log.
    ///
    /// The log is the source of truth and is append-only; the views read these copies because a
    /// reference type's mutations are invisible to SwiftUI.
    func refreshAuditSnapshots() {
        deviceAuditRecords = deviceAuditLog.records
        inputAuditRecords = deviceAuditLog.records(for: .inputInject)
    }

    /// Grants a data class. A reason is required by the registry, and a refusal is surfaced rather
    /// than swallowed: an empty reason is a decision the registry will not record.
    func grantConsent(_ dataClass: ConsentDataClass, reason: String) {
        do {
            try consentRegistry.grant(dataClass, reason: reason)
            consentError = nil
        } catch let error as ConsentError {
            consentError = error
        } catch {
            consentError = .consentRequired(dataClass: dataClass)
        }
        refreshConsent()
    }

    /// Withdraws a data class. Immediate and sticky — the next read throws.
    func revokeConsent(_ dataClass: ConsentDataClass) {
        consentRegistry.revoke(dataClass)
        consentError = nil
        refreshConsent()
    }

    /// Whether a read of this class is currently permitted.
    func isConsentGranted(_ dataClass: ConsentDataClass) -> Bool {
        consentRegistry.isGranted(dataClass)
    }

    func refreshConsent() {
        consentGrants = consentRegistry.grants
    }
}
