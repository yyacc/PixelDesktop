import Foundation

/// One ADB port forward, as the device daemon reports it.
///
/// `adb forward --list` prints `<serial> tcp:<local> tcp:<remote>` (or `localabstract:` /
/// `localfilesystem:` for other socket types). The spec strings are kept verbatim rather than
/// re-parsed into host/port, because a forward is not necessarily TCP and collapsing the
/// distinction would make the model disagree with the device.
struct PortForward: Equatable, Sendable, Identifiable {
    let serial: String
    let local: String
    let remote: String

    var id: String { "\(serial)|\(local)|\(remote)" }

    /// Listens on the host at `localPort`, reaching the device's `remotePort`.
    static func tcp(serial: String, localPort: Int, remotePort: Int) -> PortForward {
        PortForward(
            serial: serial,
            local: "tcp:\(localPort)",
            remote: "tcp:\(remotePort)"
        )
    }

    /// Parses `adb forward --list`. Lines that do not have exactly three fields are skipped.
    static func parseList(_ output: String) -> [PortForward] {
        var forwards: [PortForward] = []

        for line in output.components(separatedBy: .newlines) {
            let parts = line
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .split(separator: " ", omittingEmptySubsequences: true)
            guard parts.count == 3 else { continue }

            let serial = String(parts[0])
            let local = String(parts[1])
            let remote = String(parts[2])
            guard local.contains(":"), remote.contains(":") else { continue }

            forwards.append(PortForward(serial: serial, local: local, remote: remote))
        }

        return forwards
    }
}

/// Creates and removes host→device port forwards.
///
/// This is the seam the later phases need: a host service reaches a device-side listener
/// (Termux `llama-server`, a worker HTTP endpoint) through a forward, and the app is able to
/// show, create and revoke it instead of asking the user to type `adb forward`.
///
/// ## Why this is not a shell string
///
/// Ports are `Int` and validated to `1...65535` before any command exists. The command is
/// assembled here from a fixed template, so nothing a caller supplies is ever parsed by a
/// shell. This is the same rule `ADBAppOperations` follows for package names.
protocol PortForwardingProtocol: Sendable {
    /// Creates a forward. Idempotent at the device level: `adb forward` replaces an existing
    /// forward on the same local port.
    func forward(
        deviceSerial: String,
        localPort: Int,
        remotePort: Int,
        timeout: TimeInterval
    ) async throws -> PortForward

    /// Lists every forward the local ADB server knows about, for this device.
    func forwards(deviceSerial: String, timeout: TimeInterval) async throws -> [PortForward]

    /// Removes a forward by its local spec (`tcp:8080`).
    ///
    /// Removing a forward that does not exist is not an error in ADB (it prints nothing and
    /// exits 0), so this does not turn it into one.
    func removeForward(
        deviceSerial: String,
        localPort: Int,
        timeout: TimeInterval
    ) async throws -> TransportResult
}

/// `PortForwardingProtocol` over the ADB transport.
struct ADBPortForwarding: PortForwardingProtocol {
    private let transport: TransportProtocol

    init(transport: TransportProtocol) {
        self.transport = transport
    }

    func forward(
        deviceSerial: String,
        localPort: Int,
        remotePort: Int,
        timeout: TimeInterval
    ) async throws -> PortForward {
        try Self.validatePort(localPort, label: "local")
        try Self.validatePort(remotePort, label: "remote")

        let result = try await transport.execute(
            command: "-s",
            arguments: [deviceSerial, "forward", "tcp:\(localPort)", "tcp:\(remotePort)"],
            timeout: timeout
        )

        guard result.isSuccess else {
            throw PixelDesktopError.adbCommandFailed(
                command: "forward tcp:\(localPort) tcp:\(remotePort)",
                exitCode: Int(result.exitCode),
                stderr: result.stderr
            )
        }

        return PortForward.tcp(serial: deviceSerial, localPort: localPort, remotePort: remotePort)
    }

    func forwards(deviceSerial: String, timeout: TimeInterval) async throws -> [PortForward] {
        let result = try await transport.execute(
            command: "-s",
            arguments: [deviceSerial, "forward", "--list"],
            timeout: timeout
        )

        guard result.isSuccess else {
            throw PixelDesktopError.adbCommandFailed(
                command: "forward --list",
                exitCode: Int(result.exitCode),
                stderr: result.stderr
            )
        }

        return PortForward.parseList(result.stdout).filter { $0.serial == deviceSerial }
    }

    func removeForward(
        deviceSerial: String,
        localPort: Int,
        timeout: TimeInterval
    ) async throws -> TransportResult {
        try Self.validatePort(localPort, label: "local")

        let result = try await transport.execute(
            command: "-s",
            arguments: [deviceSerial, "forward", "--remove", "tcp:\(localPort)"],
            timeout: timeout
        )

        guard result.isSuccess else {
            throw PixelDesktopError.adbCommandFailed(
                command: "forward --remove tcp:\(localPort)",
                exitCode: Int(result.exitCode),
                stderr: result.stderr
            )
        }

        return result
    }

    /// A TCP port is an integer in `1...65535`. Port 0 ("pick one") is rejected: the device
    /// would choose a port this code then has to guess, and `adb forward` does not report it
    /// back, so the returned `PortForward` would be a lie.
    static func validatePort(_ port: Int, label: String) throws {
        guard (1...65535).contains(port) else {
            throw PixelDesktopError.invalidInput(
                "\(label.capitalized) port must be between 1 and 65535, got \(port)"
            )
        }
    }
}
