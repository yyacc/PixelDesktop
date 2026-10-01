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

    init(transport: TransportProtocol? = nil, logger: AppLogger? = nil) {
        self.transport = transport ?? ADBTransport()
        self.logger = logger ?? AppLogger()
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
    func refreshDevices() async {
        do {
            let deviceList = try await transport.listDevices()
            devices = deviceList
            lastError = nil
            logger.info("Found \(deviceList.count) device(s)", source: "DeviceManager.refreshDevices")
        } catch let error as PixelDesktopError {
            lastError = error
            logger.error(error.description, source: "DeviceManager.refreshDevices")
        } catch {
            lastError = .unknown(error.localizedDescription)
            logger.error("Unexpected error: \(error.localizedDescription)", source: "DeviceManager.refreshDevices")
        }
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
