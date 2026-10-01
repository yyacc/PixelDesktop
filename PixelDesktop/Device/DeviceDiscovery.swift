import Foundation

protocol DeviceDiscoveryProtocol: AnyObject {
    var devices: [AndroidDevice] { get }
    var isDiscovering: Bool { get }
    var lastError: PixelDesktopError? { get }
    var logMessages: [LogEntry] { get }

    func startDiscovery() async
    func stopDiscovery() async
    func refreshDevices() async
}
