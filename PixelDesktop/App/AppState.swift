import SwiftUI
import Combine

@MainActor
final class AppState: ObservableObject {
    @Published var devices: [AndroidDevice] = []
    @Published var isDiscovering: Bool = false
    @Published var lastError: PixelDesktopError?
    @Published var logMessages: [LogEntry] = []

    private let deviceManager: DeviceManager
    private var cancellables = Set<AnyCancellable>()

    init(deviceManager: DeviceManager? = nil) {
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
}
