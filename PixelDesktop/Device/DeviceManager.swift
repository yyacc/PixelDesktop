import Foundation
import Combine

@MainActor
final class DeviceManager: ObservableObject, DeviceDiscoveryProtocol {
    @Published private(set) var devices: [AndroidDevice] = []
    @Published private(set) var isDiscovering: Bool = false
    @Published private(set) var lastError: PixelDesktopError?
    @Published private(set) var logMessages: [LogEntry] = []

    private let transport: TransportProtocol
    private let logger: AppLogger
    private var discoveryTask: Task<Void, Never>?
    private var discoveryInterval: TimeInterval = 5.0

    // MARK: - Phase 1 (Connection Foundation) additions
    //
    // Dual-transport handling: selection (USB > WiFi), wireless-endpoint persistence,
    // and auto-reconnect all live in `ConnectionManager`; the manager is the single
    // driver that feeds it observations and re-lists devices on its request.

    /// The connection coordinator. Always present; reconnect capability depends on
    /// whether the active transport can actually `connect` (see `NullConnectionTransport`).
    let connectionManager: ConnectionManager

    /// Live network-availability monitoring, kept alive for as long as the manager is.
    private let pathMonitor: NetworkPathMonitoring?

    /// The transport the connection layer currently targets, mirroring
    /// `connectionManager.transportState` for the UI layer to observe directly.
    @Published private(set) var transportState: TransportState?

    /// A user-actionable reading of *why* the system is not connected (ADR-017, Option C).
    ///
    /// `nil` means nothing has been read yet — the same "absence is meaningful" discipline
    /// `transportState` uses, so a first paint can never be mistaken for a diagnosed failure.
    /// When non-nil and not connected, `cause` distinguishes "cable unplugged" from
    /// "wireless debugging silently disabled", which the UI previously collapsed into "Offline".
    @Published private(set) var diagnosis: TransportDiagnosis?

    init(
        transport: TransportProtocol? = nil,
        logger: AppLogger? = nil,
        connectionTransport: ConnectionTransporting? = nil,
        pathMonitor: NetworkPathMonitoring? = nil,
        defaults: UserDefaults? = nil,
        reconnectScheduler: ReconnectScheduler = .standard
    ) {
        self.transport = transport ?? ADBTransport()
        self.logger = logger ?? AppLogger()

        // Reconnect reaches the *same* transport the manager polls when that
        // transport IS ADB; a transport without connect capability (a mock double)
        // gets the null object, so auto-reconnect is visibly inert rather than
        // firing at a real `adb` from inside a test run.
        let resolvedConnectionTransport: ConnectionTransporting
        if let connectionTransport {
            resolvedConnectionTransport = connectionTransport
        } else if let adb = self.transport as? ConnectionTransporting {
            resolvedConnectionTransport = adb
        } else {
            resolvedConnectionTransport = NullConnectionTransport()
        }

        let resolvedPathMonitor = pathMonitor ?? NetworkPathMonitor()
        self.pathMonitor = resolvedPathMonitor

        let manager = ConnectionManager(
            transport: resolvedConnectionTransport,
            logger: self.logger,
            defaults: defaults ?? .standard,
            scheduler: reconnectScheduler,
            pathMonitor: resolvedPathMonitor
        )
        self.connectionManager = manager
        manager.refreshHook = { [weak self] in
            await self?.refreshDevices()
        }
    }

    func startDiscovery() async {
        guard !isDiscovering else {
            logger.warning("Discovery already in progress", source: "DeviceManager.startDiscovery")
            return
        }

        isDiscovering = true
        logger.info("Starting device discovery", source: "DeviceManager.startDiscovery")

        discoveryTask = Task {
            while !Task.isCancelled {
                await refreshDevices()
                try? await Task.sleep(nanoseconds: UInt64(discoveryInterval * 1_000_000_000))
            }
        }
    }

    func stopDiscovery() async {
        discoveryTask?.cancel()
        discoveryTask = nil
        isDiscovering = false
        // Teardown only: remembered endpoints survive; a stopped manager must not
        // keep reconnecting in the background.
        connectionManager.stop()
        logger.info("Stopped device discovery", source: "DeviceManager.stopDiscovery")
    }

    /// Re-reads the attached device list and replaces the published state wholesale.
    ///
    /// **Disconnect invalidation:** assigning the fresh list discards any previously enriched
    /// values. A device that disappears is dropped, and one that reappears comes back with
    /// its properties empty until it is enriched again. Enriched properties are therefore
    /// never cached across a disconnect or reconnect, which is the decision recorded in
    /// ADR-009. The properties are constant for a boot session but can change across a
    /// reboot or OS update, and a reconnect is exactly when that becomes possible.
    ///
    /// **Transport selection (Phase 1):** only a *successful* listing is fed to
    /// `ConnectionManager.observe`. A failed listing (`adb` itself broken) is not
    /// evidence that a connected device disappeared, so it neither tears down the
    /// current selection nor triggers reconnect; the next successful poll decides.
    func refreshDevices() async {
        do {
            let deviceList = try await transport.listDevices()
            devices = deviceList
            lastError = nil
            connectionManager.observe(devices: deviceList)
            transportState = connectionManager.transportState
            updateDiagnosis(listingError: nil)
            logger.info("Found \(deviceList.count) device(s)", source: "DeviceManager.refreshDevices")
        } catch let error as PixelDesktopError {
            lastError = error
            updateDiagnosis(listingError: error)
            logger.error(error.description, source: "DeviceManager.refreshDevices")
        } catch {
            lastError = .unknown(error.localizedDescription)
            updateDiagnosis(listingError: lastError)
            logger.error("Unexpected error: \(error.localizedDescription)", source: "DeviceManager.refreshDevices")
        }
    }

    /// Recomputes the user-facing connection diagnosis from the facts currently held.
    ///
    /// Called after every listing attempt, successful or not, because the *failure* of a listing
    /// is itself a diagnosable cause (`adbUnavailable`) and must not be reported as "no device
    /// detected" — a distinction that sends the user to the phone when the fault is on the Mac.
    private func updateDiagnosis(listingError: PixelDesktopError?) {
        let context = TransportDiagnosisContext(
            transportState: connectionManager.transportState,
            devices: devices,
            listingError: listingError,
            rememberedEndpoint: connectionManager.rememberedWirelessEndpoint,
            isReconnecting: connectionManager.isReconnecting,
            reconnectAttempt: connectionManager.reconnectAttempt
        )
        diagnosis = TransportDiagnoser.classify(context)
    }

    func getDevice(bySerialNumber serial: String) -> AndroidDevice? {
        devices.first { $0.serialNumber == serial }
    }

    /// Returns the device only when it is currently connected, otherwise throws.
    ///
    /// Every operation must call this **before** issuing a command, so a stale device fails
    /// predictably instead of hanging or acting on a device that has gone away. This is the
    /// guard-first rule for Phase 4 lifecycle handling.
    ///
    /// - Throws: `deviceNotFound` when the serial is unknown, `deviceOffline` when it is
    ///   known but not in the `device` state.
    func requireConnectedDevice(serial: String) throws -> AndroidDevice {
        guard let device = getDevice(bySerialNumber: serial) else {
            throw PixelDesktopError.deviceNotFound
        }
        guard device.state == .device else {
            throw PixelDesktopError.deviceOffline
        }
        return device
    }

    /// Reads the stable system properties for the selected device and republishes it.
    ///
    /// Kept off the discovery polling path on purpose: these properties do not
    /// change while the device stays booted, so enriching on every poll would add
    /// three ADB round trips per interval for information that cannot change.
    ///
    /// - Returns: the enriched device, or `nil` if the serial is unknown.
    func enrichDevice(serial: String, timeout: TimeInterval = 10) async throws -> AndroidDevice? {
        guard let device = getDevice(bySerialNumber: serial) else {
            logger.warning("Enrich requested for unknown serial \(serial)", source: "DeviceManager.enrichDevice")
            return nil
        }

        let enriched = try await DeviceEnricher(transport: transport).enrich(device, timeout: timeout)

        if let index = devices.firstIndex(where: { $0.serialNumber == serial }) {
            devices[index] = enriched
        }

        logger.info(
            "Enriched \(serial): Android \(enriched.androidVersion), API \(enriched.apiLevel), \(enriched.architecture)",
            source: "DeviceManager.enrichDevice"
        )

        return enriched
    }
}
