import Foundation
import Combine

@MainActor
final class DeviceManager: ObservableObject, DeviceDiscoveryProtocol {
    @Published private(set) var devices: [PixelDevice] = []
    @Published private(set) var isDiscovering: Bool = false
    @Published private(set) var lastError: PixelDesktopError?
    @Published private(set) var logMessages: [LogEntry] = []

    private let transport: ADBTransport
    private let logger: AppLogger
    private var discoveryTask: Task<Void, Never>?
    private var discoveryInterval: TimeInterval = 5.0

    init(transport: ADBTransport? = nil, logger: AppLogger? = nil) {
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

    func getDevice(bySerialNumber serial: String) -> PixelDevice? {
        devices.first { $0.serialNumber == serial }
    }
}
