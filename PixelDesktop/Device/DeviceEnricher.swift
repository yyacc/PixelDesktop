import Foundation

/// Populates the stable system properties on a discovered `PixelDevice`.
///
/// This is a separate responsibility from discovery parsing:
///
/// - `ADBTransport.parseDeviceList` answers *which devices are attached* from a
///   single `adb devices -l` call.
/// - `DeviceEnricher` answers *what is this device* and costs one ADB round trip
///   per property.
///
/// Keeping them apart matters because discovery polls on an interval while these
/// properties never change while the device stays booted. Enriching on the
/// discovery path would multiply ADB traffic for information that cannot change.
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
    /// The device identity, model and manufacturer from discovery are preserved;
    /// only `androidVersion`, `apiLevel` and `architecture` are replaced.
    ///
    /// Calls are issued sequentially. `ADBTransport` is an actor, so concurrent
    /// calls would serialise there anyway while making timeout behaviour harder to
    /// reason about.
    func enrich(_ device: PixelDevice, timeout: TimeInterval = 10) async throws -> PixelDevice {
        guard device.state == .device else {
            throw PixelDesktopError.deviceOffline
        }

        let version = try await transport.getprop(
            deviceSerial: device.serialNumber,
            key: DevicePropertyKey.androidVersion,
            timeout: timeout
        )
        let sdk = try await transport.getprop(
            deviceSerial: device.serialNumber,
            key: DevicePropertyKey.apiLevel,
            timeout: timeout
        )
        let abi = try await transport.getprop(
            deviceSerial: device.serialNumber,
            key: DevicePropertyKey.architecture,
            timeout: timeout
        )

        let properties = try DeviceProperties.make(
            androidVersion: version,
            apiLevelRaw: sdk,
            architecture: abi
        )

        return PixelDevice(
            id: device.id,
            serialNumber: device.serialNumber,
            model: device.model,
            manufacturer: device.manufacturer,
            androidVersion: properties.androidVersion,
            apiLevel: properties.apiLevel,
            architecture: properties.architecture,
            state: device.state
        )
    }
}
