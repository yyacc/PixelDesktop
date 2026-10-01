import SwiftUI
import Combine

@MainActor
final class AppState: ObservableObject {
    @Published var devices: [AndroidDevice] = []
    @Published var isDiscovering: Bool = false
    @Published var lastError: PixelDesktopError?
    @Published var logMessages: [LogEntry] = []

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

    func startDiscovery() {
        Task {
            await deviceManager.startDiscovery()
        }
    }

    func stopDiscovery() {
        Task {
            await deviceManager.stopDiscovery()
        }
    }

    func refreshDevices() {
        Task {
            await deviceManager.refreshDevices()
        }
    }

    // MARK: - Application operations
    //
    // Phase 4 exposes operations through AppState so callers never reach the transport or a
    // raw shell. Each wrapper is guard-first: it refuses to act on a device that is not
    // currently connected, before any command is issued.

    /// Lists third-party applications on the connected device.
    func installedApplications(includeSystem: Bool = false) async throws -> [InstalledApp] {
        guard let serial = devices.first(where: { $0.state == .device })?.serialNumber else {
            throw PixelDesktopError.deviceNotFound
        }
        return try await appOperations.installedApplications(
            deviceSerial: serial,
            includeSystem: includeSystem,
            timeout: 30
        )
    }

    /// Lists applications that expose a launcher activity.
    func launchableApplications() async throws -> [InstalledApp] {
        guard let serial = devices.first(where: { $0.state == .device })?.serialNumber else {
            throw PixelDesktopError.deviceNotFound
        }
        return try await appOperations.launchableApplications(deviceSerial: serial, timeout: 30)
    }

    /// Starts an application. Guard-first; never accepts a shell string.
    func launchApplication(packageName: String) async throws {
        guard let serial = devices.first(where: { $0.state == .device })?.serialNumber else {
            throw PixelDesktopError.deviceNotFound
        }
        _ = try await appOperations.launchApplication(
            deviceSerial: serial,
            packageName: packageName,
            timeout: 30
        )
    }

    /// Reports whether an application is running. "Not running" is not an error.
    func isApplicationRunning(packageName: String) async throws -> Bool {
        guard let serial = devices.first(where: { $0.state == .device })?.serialNumber else {
            throw PixelDesktopError.deviceNotFound
        }
        return try await appOperations.isApplicationRunning(
            deviceSerial: serial,
            packageName: packageName,
            timeout: 30
        )
    }

    /// Stops an application. Containment is applied inside the operations layer.
    func stopApplication(packageName: String) async throws {
        guard let serial = devices.first(where: { $0.state == .device })?.serialNumber else {
            throw PixelDesktopError.deviceNotFound
        }
        _ = try await appOperations.stopApplication(
            deviceSerial: serial,
            packageName: packageName,
            timeout: 30
        )
    }
}
