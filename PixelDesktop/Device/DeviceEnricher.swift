import Foundation

/// Populates the stable system properties on a discovered `AndroidDevice`.
///
/// This is a separate responsibility from discovery parsing:
///
/// - `ADBTransport.parseDeviceList` answers *which devices are attached* from a single
///   `adb devices -l` call, and can only supply identity and connection state.
/// - `DeviceEnricher` answers *what is this device* by reading stable system properties.
///
/// Keeping them apart matters because discovery polls on an interval while these
/// properties never change while the device stays booted. Enriching on the discovery path
/// would multiply ADB traffic for information that cannot change.
///
/// Enrichment depends on `TransportProtocol`, not on `ADBTransport`, so it can be
/// exercised against a mock transport without a physical device.
struct DeviceEnricher {
    private let transport: TransportProtocol

    init(transport: TransportProtocol) {
        self.transport = transport
    }

    /// Reads the stable system properties and returns an enriched copy of the device.
    ///
    /// Device identity from discovery (`serialNumber`, `deviceCodename`, `state`) is
    /// preserved. Everything else is replaced with values read from the device.
    ///
    /// Uses a single batched `getprop` rather than one call per property: each call
    /// spawns an `adb` process, so six properties would otherwise cost six spawns.
    /// See ADR-005, which authorises this once the property count exceeds five.
    func enrich(_ device: AndroidDevice, timeout: TimeInterval = 10) async throws -> AndroidDevice {
        guard device.state == .device else {
            throw PixelDesktopError.deviceOffline
        }

        let raw = try await transport.getSystemProperties(
            deviceSerial: device.serialNumber,
            timeout: timeout
        )

        let properties = try DeviceProperties.make(
            androidVersion: raw[DevicePropertyKey.androidVersion] ?? "",
            apiLevelRaw: raw[DevicePropertyKey.apiLevel] ?? "",
            architecture: raw[DevicePropertyKey.architecture] ?? "",
            marketingName: raw[DevicePropertyKey.marketingName] ?? "",
            manufacturer: raw[DevicePropertyKey.manufacturer] ?? "",
            abiListRaw: raw[DevicePropertyKey.supportedABIs] ?? ""
        )

        return AndroidDevice(
            id: device.id,
            serialNumber: device.serialNumber,
            deviceCodename: device.deviceCodename,
            marketingName: properties.marketingName,
            manufacturer: properties.manufacturer,
            androidVersion: properties.androidVersion,
            apiLevel: properties.apiLevel,
            architecture: properties.architecture,
            supportedABIs: properties.supportedABIs,
            state: device.state
        )
    }
}
