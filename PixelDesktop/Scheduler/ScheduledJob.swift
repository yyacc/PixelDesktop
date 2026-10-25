//
//  ScheduledJob.swift
//  PixelDesktop
//
//  Phase 3.4 (C4) — the job vocabulary.
//
//  WHAT IT IS
//  A scheduled job is **data**: a name, a cadence, and one action from a closed enum. The action
//  enum is the safety boundary — it contains only read-only operations, so "schedule an uninstall"
//  is not a validation that can be forgotten, it is a value that cannot be constructed.
//
//  WHAT IT IS NOT
//  Not a script, not a shell line, not a stored adb command. Adding an action is a code change and
//  a test, never a JSON edit.
//

import Foundation

// MARK: - Actions

/// The closed set of operations a scheduled job may perform.
///
/// **Destructive operations are absent by construction.** `appInstall`, `appUninstall`, `reboot`,
/// storage delete and input injection require a per-call human confirmation (ADR-020 D1/D3); a
/// headless 03:00 tick cannot supply one, and a job that remembered a consent would be exactly the
/// remembered-consent failure the trust foundation refuses.
enum ScheduledAction: String, Codable, Sendable, CaseIterable {
    /// One telemetry sample (battery, thermal, memory, storage). No personal data class.
    case telemetrySample
    /// Tier 1 notification keys only — `cmd notification list`, ~539 B, never the full dump.
    case notificationTier1
    /// Whether the on-device worker process is running, and its pid.
    case workerHealth

    var displayName: String {
        switch self {
        case .telemetrySample: return "Telemetry sample"
        case .notificationTier1: return "Notification keys (tier 1)"
        case .workerHealth: return "Worker health"
        }
    }

    /// The consent class this action reads, if any. Re-checked on **every** run, never cached
    /// in the job record.
    var requiredConsent: ConsentDataClass? {
        switch self {
        case .telemetrySample: return nil
        case .notificationTier1: return .notifications
        case .workerHealth: return nil
        }
    }

    /// One line an operator can read in the dry-run/next-run preview.
    var consequence: String {
        switch self {
        case .telemetrySample:
            return "Reads one telemetry sample: battery, thermal, memory and storage. No personal data."
        case .notificationTier1:
            return "Reads notification keys only (no titles, no bodies). Requires notification consent at run time."
        case .workerHealth:
            return "Reads whether the on-device worker process is running. No personal data, no device change."
        }
    }
}

// MARK: - Cadence

enum ScheduledCadence: Equatable, Sendable, Codable {
    case interval(seconds: Int)
    case daily(hour: Int, minute: Int)

    /// A tick faster than a minute buys nothing on a USB-attached phone and costs a battery.
    static let minimumIntervalSeconds = 60

    var displayName: String {
        switch self {
        case .interval(let seconds):
            if seconds % 3600 == 0 { return "Every \(seconds / 3600) h" }
            if seconds % 60 == 0 { return "Every \(seconds / 60) min" }
            return "Every \(seconds) s"
        case .daily(let hour, let minute):
            return String(format: "Daily at %02d:%02d", hour, minute)
        }
    }

    /// Validates the shape, and returns a human reason rather than a bare false.
    func validate() throws {
        switch self {
        case .interval(let seconds):
            guard seconds >= Self.minimumIntervalSeconds else {
                throw ScheduledJobError.invalidCadence(
                    "An interval of \(seconds)s is below the \(Self.minimumIntervalSeconds)s minimum."
                )
            }
        case .daily(let hour, let minute):
            guard (0...23).contains(hour) else {
                throw ScheduledJobError.invalidCadence("Hour \(hour) is outside 0–23.")
            }
            guard (0...59).contains(minute) else {
                throw ScheduledJobError.invalidCadence("Minute \(minute) is outside 0–59.")
            }
        }
    }
}

// MARK: - Outcome

enum ScheduledRunOutcome: String, Codable, Sendable, CaseIterable {
    case succeeded
    case refused
    case failed
    case skipped
    case deferred

    var displayName: String {
        switch self {
        case .succeeded: return "Succeeded"
        case .refused: return "Refused"
        case .failed: return "Failed"
        case .skipped: return "Skipped"
        case .deferred: return "Deferred"
        }
    }
}

// MARK: - Job

struct ScheduledJob: Identifiable, Equatable, Sendable, Codable {
    let id: UUID
    var name: String
    var cadence: ScheduledCadence
    var action: ScheduledAction
    var enabled: Bool
    let createdAt: Date
    var lastRunAt: Date?
    var lastOutcome: ScheduledRunOutcome?
    /// Set when a job is disabled by something other than the operator toggling it — today only the
    /// D4 kill switch. `nil` for an ordinary disable, so the UI can tell "you turned this off" from
    /// "the kill switch stopped it".
    var disabledReason: String?

    init(
        id: UUID = UUID(),
        name: String,
        cadence: ScheduledCadence,
        action: ScheduledAction,
        enabled: Bool = true,
        createdAt: Date,
        lastRunAt: Date? = nil,
        lastOutcome: ScheduledRunOutcome? = nil,
        disabledReason: String? = nil
    ) {
        self.id = id
        self.name = name
        self.cadence = cadence
        self.action = action
        self.enabled = enabled
        self.createdAt = createdAt
        self.lastRunAt = lastRunAt
        self.lastOutcome = lastOutcome
        self.disabledReason = disabledReason
    }
}

// MARK: - Errors

enum ScheduledJobError: Error, Equatable, CustomStringConvertible {
    case unknownJob(String)
    case disabled(String)
    case noDevice
    case deadlineExceeded(seconds: Int)
    case consentDenied(ConsentDataClass)
    case storeCorrupt(String)
    case storeUnwritable(String)
    case invalidCadence(String)
    case duplicateName(String)
    case invalidName(String)

    var description: String {
        switch self {
        case .unknownJob(let id):
            return "No scheduled job with id \(id)."
        case .disabled(let name):
            return "Job “\(name)” is disabled; nothing was executed."
        case .noDevice:
            return "No device serial is available, so the job cannot run."
        case .deadlineExceeded(let seconds):
            return "The job did not finish within \(seconds)s; it was abandoned, not reported as success."
        case .consentDenied(let dataClass):
            return "Consent for \(dataClass.rawValue) is not granted; the job refused before touching the device."
        case .storeCorrupt(let reason):
            return "The schedule store is unreadable and was left untouched: \(reason)"
        case .storeUnwritable(let reason):
            return "The schedule store could not be written: \(reason)"
        case .invalidCadence(let reason):
            return reason
        case .duplicateName(let name):
            return "A job named “\(name)” already exists."
        case .invalidName(let reason):
            return reason
        }
    }
}
