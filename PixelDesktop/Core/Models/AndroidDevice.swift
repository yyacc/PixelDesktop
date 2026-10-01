import Foundation

/// Internal representation of an attached Android device.
///
/// This type is pure representation: it holds facts about a device and performs no
/// device I/O. Discovery (`ADBTransport.parseDeviceList`) creates it with identity
/// fields only; `DeviceEnricher` fills in the system properties it cannot know from
/// `adb devices -l`.
///
/// Identity comes from two different places and they are deliberately distinct:
///
/// - `deviceCodename` — the build codename, from the `device:` token of
///   `adb devices -l` (`lynx` for a Pixel 7a).
/// - `marketingName` — the human-facing product name, from `ro.product.model`
///   (`Pixel 7a`).
///
/// These are not interchangeable. `Pixel_7a` appears in `adb devices -l` as the
/// `model:` token, but that is also the build name, not the marketing name.
struct AndroidDevice: Identifiable, Equatable {
    let id: String
    let serialNumber: String

    /// Build codename, e.g. `lynx`. From the `device:` token of `adb devices -l`.
    let deviceCodename: String

    /// Human-facing product name, e.g. `Pixel 7a`. From `ro.product.model`.
    let marketingName: String

    /// Device manufacturer, e.g. `Google`. From `ro.product.manufacturer`.
    let manufacturer: String

    let androidVersion: String
    let apiLevel: Int

    /// Primary ABI, e.g. `arm64-v8a`. From `ro.product.cpu.abi`.
    let architecture: String

    /// All supported ABIs, e.g. `["arm64-v8a"]`. From `ro.product.cpu.abilist`.
    let supportedABIs: [String]

    let state: DeviceState

    /// The best available human-readable name for this device.
    ///
    /// Prefers the marketing name, falls back to the codename, then the serial.
    /// Never returns an empty string.
    var displayName: String {
        if !marketingName.isEmpty {
            return marketingName
        }
        if !deviceCodename.isEmpty {
            return deviceCodename
        }
        return serialNumber
    }
}

enum DeviceState: String, CaseIterable {
    case device = "device"
    case unauthorized = "unauthorized"
    case offline = "offline"
    case unknown = "unknown"

    var isConnected: Bool {
        self == .device
    }

    var description: String {
        switch self {
        case .device: return "Connected"
        case .unauthorized: return "Unauthorized"
        case .offline: return "Offline"
        case .unknown: return "Unknown"
        }
    }
}
