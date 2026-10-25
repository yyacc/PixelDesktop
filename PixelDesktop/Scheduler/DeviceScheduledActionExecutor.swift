//
//  DeviceScheduledActionExecutor.swift
//  PixelDesktop
//
//  Phase 3.4 (C4) — the only place a scheduled action touches the device.
//
//  WHAT IT IS
//  Three read-only actions, each mapped onto a seam the app already owns: `ADBDeviceTelemetry`,
//  `ADBNotificationReader` (tier 1 only), `WorkerLifecycle`. It composes no adb strings of its own,
//  and it returns a short summary — counts and values, never payloads — so the audit trail stays a
//  record of what happened rather than a copy of what was read.
//
//  WHAT IT IS NOT
//  Not a new transport capability. Every command issued here is one the product already issued
//  before Phase 3.4.
//

import Foundation

struct DeviceScheduledActionExecutor: ScheduledActionExecuting {
    let transport: TransportProtocol
    let consentGate: ConsentGate

    func perform(
        action: ScheduledAction,
        deviceSerial: String,
        deadline: Date
    ) async throws -> String {
        // At least a second: a deadline that has already passed should fail on the next call rather
        // than be passed through as a zero timeout.
        let timeout = max(1, deadline.timeIntervalSinceNow)

        switch action {
        case .telemetrySample:
            let telemetry = try await ADBDeviceTelemetry(transport: transport)
                .read(deviceSerial: deviceSerial, timeout: timeout)
            var parts: [String] = []
            if let level = telemetry.battery?.levelPercent { parts.append("battery \(level)%") }
            if let temperature = telemetry.battery?.temperatureCelsius {
                parts.append(String(format: "%.1f°C", temperature))
            }
            if let used = telemetry.memory?.usedFraction {
                parts.append(String(format: "memory %.0f%%", used * 100))
            }
            if let free = telemetry.storage.map({ $0.totalBytes > $0.usedBytes ? $0.totalBytes - $0.usedBytes : 0 }),
               free > 0 {
                parts.append("free \(free / 1_000_000_000) GB")
            }
            return parts.isEmpty ? "Sample returned no readable source." : parts.joined(separator: ", ")

        case .notificationTier1:
            // Keys only. The full dump is 627,757 B on this device; a scheduled job has no reason to
            // fetch it, and the tier-1 path is what ADR-021 measured at 539 B.
            let reader = ADBNotificationReader(transport: transport, gate: consentGate)
            let keys = try await reader.keys(deviceSerial: deviceSerial, timeout: timeout)
            return "\(keys.count) notification key\(keys.count == 1 ? "" : "s")"

        case .workerHealth:
            let state = try await WorkerLifecycle(transport: transport)
                .state(deviceSerial: deviceSerial, timeout: timeout)
            switch state {
            case .running(let pid): return "worker running (pid \(pid))"
            case .notRunning: return "worker not running"
            }
        }
    }
}
