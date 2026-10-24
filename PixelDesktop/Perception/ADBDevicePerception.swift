import Foundation

/// Device perception implemented over ADB.
///
/// Depends on `TransportProtocol`, not `ADBTransport`, so it is unit-testable with no device
/// attached — the same pattern as `ADBAppOperations` and `DeviceEnricher`.
///
/// ## Command construction
///
/// Both commands are **fixed templates with no interpolated caller input**. There is no
/// parameter here that reaches the device as text, so there is nothing to smuggle a shell
/// fragment into. The remote dump path is a constant, not a parameter.
///
/// ## The two-call hierarchy read, and why
///
/// `uiautomator dump` writes a file and prints a sentence. `uiautomator dump /dev/tty` is a
/// single call on most builds but interleaves that sentence with the document on some, and
/// fails outright on others. Writing to a constant path on `/sdcard` and reading it back is
/// deterministic on every build this project has seen, so it is two calls that always work
/// rather than one that sometimes does. Measured on the Pixel 7a: ~1.4 s combined.
struct ADBDevicePerception: DevicePerceptionProtocol {
    private let transport: TransportProtocol

    /// Where the dump is staged on the device. Constant by design — see the type comment.
    static let remoteDumpPath = "/sdcard/window_dump.xml"

    init(transport: TransportProtocol) {
        self.transport = transport
    }

    func uiHierarchy(deviceSerial: String, timeout: TimeInterval) async throws -> UIHierarchy {
        let dumpCommand = "uiautomator dump \(Self.remoteDumpPath)"
        let dump = try await transport.shell(
            deviceSerial: deviceSerial,
            command: dumpCommand,
            timeout: timeout
        )

        guard dump.isSuccess else {
            throw PixelDesktopError.adbCommandFailed(
                command: dumpCommand,
                exitCode: Int(dump.exitCode),
                stderr: dump.stderr
            )
        }

        // `uiautomator dump` reports failure in its text while still exiting 0 on some builds
        // ("ERROR: could not get idle state."). Catching it here keeps a stale file from being
        // read as if it described the current screen.
        let report = dump.stdout.uppercased()
        if report.contains("ERROR") || report.contains("COULD NOT") {
            throw PixelDesktopError.adbCommandFailed(
                command: dumpCommand,
                exitCode: Int(dump.exitCode),
                stderr: dump.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
            )
        }

        let read = try await transport.execOut(
            deviceSerial: deviceSerial,
            arguments: ["cat", Self.remoteDumpPath],
            timeout: timeout
        )

        guard read.isSuccess else {
            throw PixelDesktopError.adbCommandFailed(
                command: "cat \(Self.remoteDumpPath)",
                exitCode: Int(read.exitCode),
                stderr: read.stderr
            )
        }

        guard let xml = String(data: read.stdout, encoding: .utf8) else {
            throw PixelDesktopError.invalidInput(
                "UI hierarchy dump is not valid UTF-8 (\(read.stdout.count) bytes)"
            )
        }

        return try UIHierarchyParser.parse(xml)
    }

    func screenshot(deviceSerial: String, timeout: TimeInterval) async throws -> Data {
        let result = try await transport.execOut(
            deviceSerial: deviceSerial,
            arguments: ["screencap", "-p"],
            timeout: timeout
        )

        guard result.isSuccess else {
            throw PixelDesktopError.adbCommandFailed(
                command: "screencap -p",
                exitCode: Int(result.exitCode),
                stderr: result.stderr
            )
        }

        // Exit code 0 is not proof of a capture. `screencap` has been observed to emit zero
        // bytes and, under memory pressure, a truncated stream — both exit 0. The payload is
        // therefore verified rather than trusted (same rule as `ResultVerifier`).
        guard PNGSignature.isValid(result.stdout) else {
            throw PixelDesktopError.verificationFailed(
                reason: "screencap returned \(result.stdout.count) bytes that are not a complete PNG"
            )
        }

        return result.stdout
    }
}
