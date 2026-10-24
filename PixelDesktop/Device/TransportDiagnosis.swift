import Foundation

/// Why the system is not connected, expressed so a user can act on it.
///
/// ## The defect this exists to close
///
/// Before this type, the only offline signal was `transportState == nil`, and the status UI
/// rendered it as the single word **"Offline"**. That collapses four situations a user must
/// handle differently into one undifferentiated state:
///
/// | Situation | What the user must actually do |
/// |---|---|
/// | Cable unplugged / phone off | Plug in USB, or turn the phone on |
/// | Wireless Debugging silently disabled | Re-enable it **on the phone** — nothing on the Mac can |
/// | Phone present but unauthorised | Tap "Allow" on the phone's debugging prompt |
/// | `adb` itself broken | Fix the Mac's adb, not the phone |
///
/// The second row is the one that matters most and was previously invisible: Android disables
/// Wireless Debugging on inactivity, Wi-Fi change, and reboot, and when it does the Mac has no
/// channel to turn it back on. The user saw "Offline" and had no way to tell that from a loose
/// cable.
///
/// ## Design rules
///
/// - **Pure classification.** `TransportDiagnoser.classify` takes values and returns a value.
///   No IOKit, no `adb`, no `UserDefaults` — so the whole decision table is unit-testable
///   without a device, which is the property that makes this worth having.
/// - **Honest, never optimistic.** A cause is only reported when the evidence supports it.
///   In particular a remembered endpoint is *not* proof the device is reachable — it is proof
///   the system once knew where to dial, which is a different and weaker fact.
/// - **Additive.** Nothing here changes transport selection or reconnect behaviour. This is a
///   reading of existing state, so it cannot regress the paths it describes.
enum TransportCause: String, Codable, Equatable, CaseIterable {

    /// Nothing is attached on any transport.
    ///
    /// No connected device, no unauthorised device, and **no remembered endpoint** — so the
    /// system has never known where the phone is on the network. This is the "cable unplugged"
    /// case, and it is the only case where "plug in USB" is the complete answer.
    case noDeviceDetected

    /// An endpoint is remembered, but it is not answering.
    ///
    /// The system knows where the phone *was* on the network and has tried to re-dial it.
    /// This is the "wireless debugging silently turned itself off" case, and it is the one the
    /// user cannot fix from the Mac.
    case wirelessUnreachable

    /// A device is attached but has not been authorised for debugging.
    ///
    /// `adb` reports it as `unauthorized`, which means the phone is physically present and the
    /// cable/network is fine — the user simply has not accepted the prompt.
    case pairingRequired

    /// The device listing itself failed.
    ///
    /// `adb` did not answer at all, so **nothing is known** about the device. This is
    /// deliberately checked *before* the device-based causes: a failed listing is not evidence
    /// that a device disappeared, and reporting "no device detected" here would send the user to
    /// the phone when the fault is on the Mac.
    case adbUnavailable

    /// One-line reading for the status UI.
    var summary: String {
        switch self {
        case .noDeviceDetected: return "No device detected"
        case .wirelessUnreachable: return "Wireless connection lost"
        case .pairingRequired: return "Phone not authorised for debugging"
        case .adbUnavailable: return "ADB is not responding"
        }
    }

    /// What the user should do, in one line. Always actionable.
    var action: String {
        switch self {
        case .noDeviceDetected:
            return "Connect the Pixel over USB, or enable Wireless Debugging on the phone."
        case .wirelessUnreachable:
            return "Re-enable Wireless Debugging on the phone — the Mac cannot turn it back on."
        case .pairingRequired:
            return "Accept the “Allow USB debugging?” prompt on the phone."
        case .adbUnavailable:
            return "Check that adb is installed and no other tool is holding the server."
        }
    }
}

/// A user-actionable reading of the current connection state.
///
/// `isConnected == true` means a transport is selected and a device answered. Otherwise `cause`
/// says why, and `action` says what to do about it.
///
/// `cause` is `Optional` rather than a `.connected` enum case so that a connected state can never
/// be confused with a diagnosed one — the same "absence means not read yet" discipline
/// `TransportState` uses for offline.
struct TransportDiagnosis: Equatable, Codable {

    let isConnected: Bool

    /// Why the system is not connected; `nil` when connected.
    let cause: TransportCause?

    /// The endpoint the system last knew, when one is remembered. Included so the UI can show
    /// *where* it is trying to reach, which turns an abstract failure into a concrete one.
    let rememberedEndpoint: WirelessEndpoint?

    /// Whether a reconnect sequence is currently running.
    let isReconnecting: Bool

    /// Zero-based attempt counter of the running or last reconnect sequence.
    let reconnectAttempt: Int

    /// One-line reading for the status UI.
    var summary: String {
        isConnected
            ? "Connected"
            : (cause?.summary ?? "Offline")
    }

    /// What the user should do; `nil` when connected.
    var action: String? {
        guard !isConnected else { return nil }
        return cause?.action
    }

    /// True when the system is actively trying to recover, so the UI can show progress rather
    /// than a dead-end.
    var isRecovering: Bool {
        !isConnected && isReconnecting
    }
}

/// The inputs to diagnosis, captured as a value so the classifier stays pure.
struct TransportDiagnosisContext: Equatable {

    /// The transport currently selected; `nil` when offline.
    let transportState: TransportState?

    /// The devices from the most recent listing.
    ///
    /// Only meaningful when `listingError == nil`; on a failed listing this is the stale list and
    /// must not be read as evidence.
    let devices: [AndroidDevice]

    /// Whether the most recent listing attempt failed.
    let listingError: PixelDesktopError?

    /// The endpoint auto-reconnect re-dials, when one is remembered.
    let rememberedEndpoint: WirelessEndpoint?

    let isReconnecting: Bool
    let reconnectAttempt: Int
}

/// Pure classifier from connection facts to a user-actionable cause.
///
/// The order of the checks is the decision, and it is not arbitrary:
///
/// 1. **Connected** wins — a selected transport is a fact, not an inference.
/// 2. **`adbUnavailable` before any device-based cause** — a failed listing means nothing is
///    known, and the fault is on the Mac, not the phone.
/// 3. **`pairingRequired` before `wirelessUnreachable`** — an unauthorised device is physically
///    present, which is strictly more information than "an endpoint is not answering". Sending
///    this user to the phone's debugging prompt is a different instruction from sending them to
///    its Wireless Debugging toggle.
/// 4. **`wirelessUnreachable` only when an endpoint is remembered** — without one, the system
///    has no evidence the phone was ever on the network, so claiming "wireless lost" would be a
///    guess.
enum TransportDiagnoser {

    static func classify(_ context: TransportDiagnosisContext) -> TransportDiagnosis {

        // 1. A selected transport is a fact, reported as such.
        if context.transportState != nil {
            return TransportDiagnosis(
                isConnected: true,
                cause: nil,
                rememberedEndpoint: context.rememberedEndpoint,
                isReconnecting: context.isReconnecting,
                reconnectAttempt: context.reconnectAttempt
            )
        }

        // 2. A failed listing is not evidence about the device — the fault is on the Mac.
        if context.listingError != nil {
            return diagnose(.adbUnavailable, from: context)
        }

        // 3. A device is attached but unauthorised: the phone is present, the user must tap Allow.
        if context.devices.contains(where: { $0.state == .unauthorized }) {
            return diagnose(.pairingRequired, from: context)
        }

        // 4. An endpoint is remembered but not answering: wireless was on, and now is not.
        if context.rememberedEndpoint != nil {
            return diagnose(.wirelessUnreachable, from: context)
        }

        // 5. Nothing on any transport, and the system never knew a network endpoint.
        return diagnose(.noDeviceDetected, from: context)
    }

    private static func diagnose(
        _ cause: TransportCause,
        from context: TransportDiagnosisContext
    ) -> TransportDiagnosis {
        TransportDiagnosis(
            isConnected: false,
            cause: cause,
            rememberedEndpoint: context.rememberedEndpoint,
            isReconnecting: context.isReconnecting,
            reconnectAttempt: context.reconnectAttempt
        )
    }
}
