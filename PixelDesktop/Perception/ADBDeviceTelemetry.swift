import Foundation

/// Device telemetry implemented over ADB.
///
/// Depends on `TransportProtocol`, not `ADBTransport`, so it is unit-testable with no device
/// attached — the same pattern as `ADBDevicePerception`, `ADBAppOperations` and
/// `DeviceEnricher`.
///
/// ## Command construction
///
/// All four commands are **fixed constants with no interpolated caller input**. There is no
/// parameter here that reaches the device as text.
///
/// ## Why each source is read independently
///
/// `dumpsys thermalservice` is the one that matters most and is also the one most likely to
/// be restricted or reshaped by a platform update. Reading the four in parallel and keeping
/// whatever answers means a thermal-service change degrades one field instead of blanking the
/// whole dashboard.
struct ADBDeviceTelemetry: DeviceTelemetryProtocol {
    private let transport: TransportProtocol

    /// The four commands, as constants. Kept together so a reader can see the entire surface
    /// this type touches.
    enum Command {
        static let battery = "dumpsys battery"
        static let thermal = "dumpsys thermalservice"
        static let memory = "cat /proc/meminfo"
        /// `-k` forces 1K blocks regardless of the device's default block size, so the parser
        /// has one unit to assume rather than a unit that varies by build.
        static let storage = "df -k /data"
    }

    init(transport: TransportProtocol) {
        self.transport = transport
    }

    func read(deviceSerial: String, timeout: TimeInterval) async throws -> DeviceTelemetry {
        async let batteryText = text(deviceSerial: deviceSerial, command: Command.battery, timeout: timeout)
        async let thermalText = text(deviceSerial: deviceSerial, command: Command.thermal, timeout: timeout)
        async let memoryText = text(deviceSerial: deviceSerial, command: Command.memory, timeout: timeout)
        async let storageText = text(deviceSerial: deviceSerial, command: Command.storage, timeout: timeout)

        let (batteryRaw, thermalRaw, memoryRaw, storageRaw) =
            await (batteryText, thermalText, memoryText, storageText)

        // Every source silent is a read failure, not an empty sample. Reporting an all-nil
        // telemetry would render as "nothing to report" — the opposite of the truth.
        guard batteryRaw != nil || thermalRaw != nil || memoryRaw != nil || storageRaw != nil else {
            throw PixelDesktopError.verificationFailed(
                reason: "no telemetry source answered (battery, thermal, memory, storage all failed)"
            )
        }

        let thermalStatus = thermalRaw.flatMap(TelemetryParser.parseThermalStatus)
        let thermalZones = thermalRaw.map(TelemetryParser.parseThermalZones) ?? []

        // A thermal service that answered but printed an unrecognised status is a parse
        // failure worth surfacing, because the alert path depends on that number.
        if let thermalRaw, thermalStatus == nil {
            throw PixelDesktopError.verificationFailed(
                reason: "dumpsys thermalservice answered but 'Thermal Status' did not parse"
            )
        }

        return DeviceTelemetry(
            capturedAt: Date(),
            battery: batteryRaw.flatMap(TelemetryParser.parseBattery),
            thermalStatus: thermalStatus,
            thermalZones: thermalZones,
            memory: memoryRaw.flatMap(TelemetryParser.parseMemory),
            storage: storageRaw.flatMap(TelemetryParser.parseStorage)
        )
    }

    /// Runs one read command and returns its stdout, or `nil` when it failed **or printed
    /// nothing**.
    ///
    /// Deliberately non-throwing: a failed source is data about the device, not an error for
    /// the caller. The caller decides whether *enough* sources answered.
    ///
    /// Empty stdout is folded into `nil` because exit code 0 with no output is not an answer.
    /// Treating it as one would make a silent `dumpsys thermalservice` indistinguishable from
    /// a reshaped one, and the two need different responses: silence is a source that did not
    /// run, a reshaped body is a parser that needs updating.
    private func text(deviceSerial: String, command: String, timeout: TimeInterval) async -> String? {
        do {
            let result = try await transport.shell(
                deviceSerial: deviceSerial,
                command: command,
                timeout: timeout
            )
            guard result.isSuccess else { return nil }
            let output = result.stdout
            guard !output.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
            return output
        } catch {
            return nil
        }
    }
}
