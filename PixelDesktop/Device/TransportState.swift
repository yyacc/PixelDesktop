import Foundation

/// Which physical transport a device connection currently runs over.
///
/// Wired (`USB > WiFi` priority, decision §3.1 of `docs/PROPOSAL-REMOTE-STORAGE.md`)
/// means the device is attached through the USB cable; wireless means ADB over the
/// network (Android Wireless Debugging). USB always wins when both are connected,
/// because it is faster, lower-latency, and has no network dependency.
enum TransportMode: String, Codable, CaseIterable {
    case wired
    case wireless

    /// Human-facing label for status UI delivery (Phase 3).
    var displayName: String {
        switch self {
        case .wired: return "Wired (USB)"
        case .wireless: return "Wireless (WiFi)"
        }
    }
}

/// The selected connection at a point in time, bound to one device serial.
///
/// `nil` (an absent value) means **offline**: no connected device on any transport.
/// Absence is used rather than a third enum case so that an `Optional` value cannot
/// be mistaken for a connected state — the same "nil means not read yet" pattern
/// `AppState.observation` uses.
struct TransportState: Equatable, Codable {
    let mode: TransportMode

    /// The serial the connection currently targets. A wireless serial has the form
    /// `host:port`; a wired serial is the USB serial.
    let deviceSerial: String

    var isWired: Bool { mode == .wired }
    var isWireless: Bool { mode == .wireless }

    var description: String {
        "\(mode.displayName) · \(deviceSerial)"
    }
}

/// Pure transport selection over the devices reported by discovery.
///
/// The classification rule: a serial containing `:` is a wireless endpoint
/// (`host:port`); a wired USB serial never contains a colon. This holds for
/// `adb connect`-style serials (`192.168.1.4:37351`), the mDNS-style serials
/// modern adb reports for paired Wireless Debugging devices
/// (`adb-XXXX-lynx._adb-tls-connect._tcp.-192-168-1-4._port-37351.tcp.`), and the
/// live `host:port` listing. USB serials are bare alphanumeric strings.
///
/// Priority (decision §7.3.1 of the proposal): **wired first**. Only when no device
/// is attached via USB does the first connected wireless device win.
enum TransportSelector {

    /// Classifies one serial into its transport mode.
    ///
    /// A colon means a network endpoint serial. Lacking that, the mDNS service
    /// marker (`.adb-tls-connect._tcp`, the Wireless Debugging service adb announces)
    /// still means wireless even in the colonless mDNS form where the port is
    /// encoded with dashes.
    static func mode(forSerial serial: String) -> TransportMode {
        serial.contains(":") || serial.contains("._adb-tls-connect._tcp") ? .wireless : .wired
    }

    /// The devices currently in the `device` (fully connected) state.
    ///
    /// `unauthorized` and `offline` devices are deliberately excluded: a device that
    /// is attached but not usable is not a connection, and selecting it would let a
    /// command run against hardware that cannot answer.
    static func connectedDevices(_ devices: [AndroidDevice]) -> [AndroidDevice] {
        devices.filter { $0.state == .device }
    }

    /// Selects the transport the system should use for its single-device posture.
    ///
    /// - Returns: the wired device when one is connected, otherwise the first
    ///   connected wireless device, otherwise `nil` (offline).
    static func select(_ devices: [AndroidDevice]) -> TransportState? {
        let connected = connectedDevices(devices)

        if let wired = connected.first(where: { mode(forSerial: $0.serialNumber) == .wired }) {
            return TransportState(mode: .wired, deviceSerial: wired.serialNumber)
        }

        if let wireless = connected.first(where: { mode(forSerial: $0.serialNumber) == .wireless }) {
            return TransportState(mode: .wireless, deviceSerial: wireless.serialNumber)
        }

        return nil
    }
}

/// A parsed wireless ADB endpoint recovered from a device serial.
///
/// Needed because auto-reconnect re-issues `adb connect host:port`, and ADB reports
/// the wireless device *by serial*, not by connectable endpoint. `host:port` serials
/// parse directly; mDNS-form serials are searched for a trailing IPv4 endpoint, which
/// is the form Wireless Debugging produces on a local network. Formats that parse to
/// nothing (e.g. a bare hostname) surface as `nil` — such a device connects, but its
/// endpoint cannot be remembered for auto-reconnect, and that limitation is visible
/// rather than guessed.
struct WirelessEndpoint: Equatable, Codable {
    let host: String
    let port: Int

    var address: String { "\(host):\(port)" }

    /// Parses a wireless endpoint out of a device serial.
    ///
    /// Two forms are handled:
    /// - a trailing IPv4 endpoint (`192.168.1.4:37351`), including a decorated
    ///   serial where it is embedded (`adb-xxxx...._tcp.192.168.1.55:41977`) — the
    ///   **last** IPv4:port occurrence wins, since a plain host:port split would
    ///   otherwise swallow an mDNS name as the "host";
    /// - a bare `hostname:port` form, whose host may not be dotted.
    ///
    /// Formats that parse to nothing (a USB serial, a colonless mDNS name) surface
    /// as `nil`: the device still connects, but its endpoint cannot be remembered
    /// for auto-reconnect, and that limitation is visible rather than guessed.
    static func parse(_ serial: String) -> WirelessEndpoint? {
        let trimmed = serial.trimmingCharacters(in: .whitespaces)

        // Last IPv4:port occurrence (a dotted host would defeat a naive first-split).
        if let regex = try? NSRegularExpression(pattern: #"\d{1,3}(?:\.\d{1,3}){3}:\d+"#) {
            let full = NSRange(trimmed.startIndex..., in: trimmed)
            let matches = regex.matches(in: trimmed, range: full)
            if let last = matches.last,
               let matchRange = Range(last.range, in: trimmed) {
                let address = String(trimmed[matchRange])
                let addressParts = address.split(separator: ":", omittingEmptySubsequences: false)
                if addressParts.count == 2, let port = Int(addressParts[1]) {
                    return WirelessEndpoint(host: String(addressParts[0]), port: port)
                }
            }
        }

        // Bare `hostname:port` form — no dots to avoid a dotted-name false positive.
        let parts = trimmed.split(separator: ":", omittingEmptySubsequences: false)
        if parts.count == 2, let port = Int(parts[1]), !parts[0].isEmpty, !parts[0].contains(".") {
            return WirelessEndpoint(host: String(parts[0]), port: port)
        }

        return nil
    }
}
