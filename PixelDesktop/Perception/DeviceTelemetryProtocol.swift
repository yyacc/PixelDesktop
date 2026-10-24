import Foundation

/// Read-only device telemetry: battery, thermal, memory, storage.
///
/// ## Why this is a separate seam from `DevicePerceptionProtocol`
///
/// Perception answers "what is on the screen" — hierarchy and framebuffer, both of which the
/// user is looking at. Telemetry answers "how is the device doing" — thermal headroom, memory
/// pressure, battery — which is what decides whether a sustained inference job is safe to
/// start and whether it is degrading while it runs. They have different cadences (a hierarchy
/// read costs ~1.4 s and is user-initiated; telemetry is polled) and different failure
/// tolerances, so they are separate protocols rather than one "device state" blob.
///
/// ## Read-only
///
/// Nothing here changes device state. There is no thermal-policy setter, no CPU-governor
/// control and no battery-saver toggle: ADR-018 decided the phone throttles and rnz accepts
/// it, so this layer observes and alerts rather than intervenes.
protocol DeviceTelemetryProtocol: Sendable {
    /// Reads one telemetry sample.
    ///
    /// The four underlying sources (battery, thermal, memory, storage) are read independently
    /// and assembled. A source that fails or does not parse leaves its field `nil` while the
    /// rest of the sample is still returned — a device that will not answer
    /// `dumpsys thermalservice` still has a readable battery.
    ///
    /// - Throws: `PixelDesktopError.verificationFailed` when **every** source fails. That is
    ///   a real read failure rather than a partial sample, and returning an all-`nil` telemetry
    ///   would let it render as "device is fine, nothing to report".
    func read(deviceSerial: String, timeout: TimeInterval) async throws -> DeviceTelemetry
}
