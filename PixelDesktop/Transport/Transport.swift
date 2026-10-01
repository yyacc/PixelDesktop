import Foundation

protocol TransportProtocol: AnyObject, Sendable {
    func execute(command: String, arguments: [String], timeout: TimeInterval) async throws -> TransportResult
    func listDevices() async throws -> [PixelDevice]

    /// Reads a single Android system property via `adb shell getprop <key>`.
    ///
    /// - Returns: the trimmed property value.
    /// - Throws: `PixelDesktopError.adbCommandFailed` when ADB itself reports a
    ///   failure, and `PixelDesktopError.invalidInput` when the property is unset
    ///   (getprop exits 0 with empty output for a missing key).
    func getprop(deviceSerial: String, key: String, timeout: TimeInterval) async throws -> String
}

struct TransportResult: Equatable {
    let exitCode: Int32
    let stdout: String
    let stderr: String

    var isSuccess: Bool {
        exitCode == 0
    }
}

/// Stable, device-identifying system properties retrieved with `getprop`.
///
/// Only values that are fixed for the lifetime of a device boot belong here.
/// Dynamic runtime state (battery, screen, storage, network, process counts) is
/// deliberately excluded: it has a different acquisition mechanism and is
/// outside the current phase's scope.
struct DeviceProperties: Equatable {
    let androidVersion: String
    let apiLevel: Int
    let architecture: String

    /// Assembles properties from raw `getprop` output.
    ///
    /// `getprop` exits 0 with empty output when a key is unset, so missing or
    /// malformed values are rejected here rather than by the transport.
    static func make(
        androidVersion: String,
        apiLevelRaw: String,
        architecture: String
    ) throws -> DeviceProperties {
        let version = androidVersion.trimmingCharacters(in: .whitespacesAndNewlines)
        let level = apiLevelRaw.trimmingCharacters(in: .whitespacesAndNewlines)
        let abi = architecture.trimmingCharacters(in: .whitespacesAndNewlines)

        guard !version.isEmpty else {
            throw PixelDesktopError.invalidInput("Android version property is empty")
        }

        guard let apiLevel = Int(level), apiLevel > 0 else {
            throw PixelDesktopError.invalidInput(
                "API level property is not a positive integer: '\(apiLevelRaw)'"
            )
        }

        guard !abi.isEmpty else {
            throw PixelDesktopError.invalidInput("Architecture property is empty")
        }

        return DeviceProperties(
            androidVersion: version,
            apiLevel: apiLevel,
            architecture: abi
        )
    }
}

/// The `getprop` keys that back `DeviceProperties`.
///
/// Keeping the keys beside the model stops the acquisition source from drifting
/// away from the fields it populates.
enum DevicePropertyKey {
    static let androidVersion = "ro.build.version.release"
    static let apiLevel = "ro.build.version.sdk"
    static let architecture = "ro.product.cpu.abi"
}
