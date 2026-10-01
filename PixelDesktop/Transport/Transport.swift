import Foundation

protocol TransportProtocol: AnyObject, Sendable {
    func execute(command: String, arguments: [String], timeout: TimeInterval) async throws -> TransportResult
    func listDevices() async throws -> [AndroidDevice]

    /// Reads a single Android system property via `adb shell getprop <key>`.
    ///
    /// - Returns: the trimmed property value.
    /// - Throws: `PixelDesktopError.adbCommandFailed` when ADB itself reports a
    ///   failure, and `PixelDesktopError.invalidInput` when the property is unset
    ///   (getprop exits 0 with empty output for a missing key).
    func getprop(deviceSerial: String, key: String, timeout: TimeInterval) async throws -> String

    /// Reads every system property in a single `adb shell getprop` invocation.
    ///
    /// Prefer this over repeated `getprop` calls when several properties are needed:
    /// each call spawns an `adb` process, so reading N properties one at a time costs
    /// N process spawns against one here.
    ///
    /// - Returns: a map of property key to trimmed value. Unset properties are absent
    ///   rather than present-with-empty-value.
    func getSystemProperties(deviceSerial: String, timeout: TimeInterval) async throws -> [String: String]
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
/// deliberately excluded: it has a different acquisition mechanism and is outside
/// the current phase's scope.
struct DeviceProperties: Equatable {
    let androidVersion: String
    let apiLevel: Int
    let architecture: String
    let marketingName: String
    let manufacturer: String
    let supportedABIs: [String]

    /// Assembles properties from raw `getprop` output.
    ///
    /// `getprop` exits 0 with empty output when a key is unset, so missing or
    /// malformed values are rejected here rather than by the transport.
    static func make(
        androidVersion: String,
        apiLevelRaw: String,
        architecture: String,
        marketingName: String,
        manufacturer: String,
        abiListRaw: String
    ) throws -> DeviceProperties {
        let version = androidVersion.trimmingCharacters(in: .whitespacesAndNewlines)
        let level = apiLevelRaw.trimmingCharacters(in: .whitespacesAndNewlines)
        let abi = architecture.trimmingCharacters(in: .whitespacesAndNewlines)
        let name = marketingName.trimmingCharacters(in: .whitespacesAndNewlines)
        let maker = manufacturer.trimmingCharacters(in: .whitespacesAndNewlines)

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

        guard !name.isEmpty else {
            throw PixelDesktopError.invalidInput("Product model property is empty")
        }

        guard !maker.isEmpty else {
            throw PixelDesktopError.invalidInput("Manufacturer property is empty")
        }

        let abis = parseABIList(abiListRaw)

        guard !abis.isEmpty else {
            throw PixelDesktopError.invalidInput(
                "ABI list property contains no usable entries: '\(abiListRaw)'"
            )
        }

        return DeviceProperties(
            androidVersion: version,
            apiLevel: apiLevel,
            architecture: abi,
            marketingName: name,
            manufacturer: maker,
            supportedABIs: abis
        )
    }

    /// Parses a comma-separated ABI list such as `arm64-v8a,armeabi-v7a`.
    ///
    /// A single-entry list (`arm64-v8a`) is valid and is the common case: the Pixel 7a
    /// reports exactly one ABI. Blank entries are dropped so a trailing comma does not
    /// produce an empty element.
    static func parseABIList(_ raw: String) -> [String] {
        raw.split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }
}

/// The `getprop` keys that back `DeviceProperties`.
///
/// Keeping the keys beside the model stops the acquisition source from drifting away
/// from the fields it populates.
enum DevicePropertyKey {
    static let androidVersion = "ro.build.version.release"
    static let apiLevel = "ro.build.version.sdk"
    static let architecture = "ro.product.cpu.abi"
    static let marketingName = "ro.product.model"
    static let manufacturer = "ro.product.manufacturer"
    static let supportedABIs = "ro.product.cpu.abilist"

    /// Every key `DeviceProperties` is built from, in the order it is assembled.
    static let all: [String] = [
        androidVersion,
        apiLevel,
        architecture,
        marketingName,
        manufacturer,
        supportedABIs
    ]
}

/// Capabilities of an attached device that are verifiable from stable system properties.
///
/// Deliberately minimal. RAM, GPU, NPU, thermal headroom, storage and battery are
/// **not** modelled: they have no reliable static `getprop` source, and the project
/// roadmap assigns thermal and memory work to later phases. Adding them here would be
/// speculative.
struct DeviceCapabilities: Equatable {
    /// Every ABI the device can run, in the device's own preference order.
    let supportedABIs: [String]

    init(supportedABIs: [String]) {
        self.supportedABIs = supportedABIs
    }

    init(device: AndroidDevice) {
        self.supportedABIs = device.supportedABIs
    }

    /// Whether the device can run code built for the given ABI.
    func supports(abi: String) -> Bool {
        supportedABIs.contains(abi)
    }
}

/// Operations this build can actually perform on a device.
///
/// Only operations that are implemented appear here. Phase 4 (Android Application /
/// Process Control) extends this enum as it implements `shell()` and device lifecycle
/// handling; nothing is listed in advance of being real, so the model cannot advertise
/// functionality the backend does not have.
enum DeviceOperation: String, CaseIterable {
    /// Enumerate attached devices. Implemented in Phase 2.
    case discover = "discover"

    /// Read stable system properties. Implemented in Phase 2.
    case readSystemProperties = "readSystemProperties"

    var description: String {
        switch self {
        case .discover: return "Discover attached devices"
        case .readSystemProperties: return "Read system properties"
        }
    }
}
