import Foundation

struct PixelDevice: Identifiable, Equatable {
    let id: String
    let serialNumber: String
    let model: String
    let manufacturer: String
    let androidVersion: String
    let apiLevel: Int
    let architecture: String
    let state: DeviceState

    var displayName: String {
        if !model.isEmpty {
            return model
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
