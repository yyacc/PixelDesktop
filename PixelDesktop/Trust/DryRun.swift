import Foundation

// MARK: - Vocabulary

/// Operations that change the device's state and therefore require a confirmed dry run
/// (Phase 3 proposal D3, §5.3).
///
/// The list is deliberately closed. An operation that destroys state but is not named here is a
/// gap in this enum, not a licence to execute — `DestructiveActionPlan` is the only path that
/// runs one, and building a plan requires naming the operation.
enum DestructiveOperation: String, Codable, Sendable, CaseIterable {
    case inputInject
    case appInstall
    case appUninstall
    case reboot
    case storageDelete

    var displayName: String {
        switch self {
        case .inputInject: return "Input injection"
        case .appInstall: return "App install"
        case .appUninstall: return "App uninstall"
        case .reboot: return "Reboot"
        case .storageDelete: return "Storage delete"
        }
    }

    /// What a wrong execution costs. Shown in the preview, because the report exists to make the
    /// consequence legible before the command runs.
    var consequence: String {
        switch self {
        case .inputInject:
            return "Injects input into whatever has focus. On this device nothing displays, so a "
                + "misdirected tap has no visual confirmation loop."
        case .appInstall:
            return "Writes a package to the device. Reversible with an uninstall."
        case .appUninstall:
            return "Removes the package and its data. Not reversible without a backup."
        case .reboot:
            return "Restarts the device. `recovery` and `bootloader` leave the normal system and "
                + "need physical buttons to get back — and this device's screen does not display."
        case .storageDelete:
            return "Deletes files from the device. Not reversible."
        }
    }
}

// MARK: - Report

/// Exactly what a destructive operation would do, and whether anything ran.
///
/// This is the dry-run artifact the UI renders. It carries the command string verbatim so the
/// preview is not a paraphrase — a summary that rounds off a flag is a preview of a different
/// command.
struct DryRunReport: Equatable, Sendable {
    let operation: DestructiveOperation
    let target: String?
    /// The exact command that *would* run, built from already-validated values.
    let command: String
    /// `false` while the plan is unconfirmed — the report is honest about not having run.
    let wouldExecute: Bool
    /// Operation-specific warnings, e.g. the reboot recovery path.
    let notes: [String]

    var preview: String {
        var lines = [
            "\(wouldExecute ? "WOULD RUN" : "DRY RUN — NOT EXECUTED"): \(operation.displayName)",
            "command: \(command)"
        ]
        if let target, !target.isEmpty { lines.insert("target: \(target)", at: 1) }
        lines.append(contentsOf: notes.map { "note: \($0)" })
        lines.append("consequence: \(operation.consequence)")
        return lines.joined(separator: "\n")
    }
}

// MARK: - Error

/// Why a destructive operation did not run.
enum DryRunError: Error, Equatable, CustomStringConvertible {
    /// The plan was never confirmed, so the dry run is all that happened.
    case dryRunNotConfirmed(operation: DestructiveOperation)

    var description: String {
        switch self {
        case .dryRunNotConfirmed(let operation):
            return "Refused: \(operation.displayName.lowercased()) requires a confirmed dry run; "
                + "nothing was sent to the device"
        }
    }
}

// MARK: - Plan

/// A proposed destructive action, before it is allowed to run.
///
/// **This type is the gate**, and it is the same gate ADR-019 built for input, generalised rather
/// than redesigned: `confirmed` is `let`, the only way to obtain a confirmed plan is
/// `confirming()`, and `execute(using:)` refuses anything else **before** the body is called. The
/// requirement is therefore enforced by the type system rather than documented and hoped for.
///
/// B4 (install/uninstall), B5 (reboot) and storage delete all express themselves as one of these.
/// There is no second execution path, so a future caller cannot skip the preview by calling the
/// transport directly without visibly bypassing this type.
struct DestructiveActionPlan: Identifiable, Equatable, Sendable {
    let id: UUID
    let operation: DestructiveOperation
    let target: String?
    /// The exact command, pre-built from validated values.
    let command: String
    let notes: [String]
    let confirmed: Bool
    let createdAt: Date

    init(
        id: UUID = UUID(),
        operation: DestructiveOperation,
        target: String? = nil,
        command: String,
        notes: [String] = [],
        confirmed: Bool = false,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.operation = operation
        self.target = target
        self.command = command
        self.notes = notes
        self.confirmed = confirmed
        self.createdAt = createdAt
    }

    /// Returns an approved copy. The unconfirmed original stays unconfirmed — approval is a
    /// transition, not a mutation, so a caller cannot hold a plan that silently became live.
    func confirming() -> DestructiveActionPlan {
        DestructiveActionPlan(
            id: id,
            operation: operation,
            target: target,
            command: command,
            notes: notes,
            confirmed: true,
            createdAt: createdAt
        )
    }

    /// What the user is shown, and what they approve.
    var report: DryRunReport {
        DryRunReport(
            operation: operation,
            target: target,
            command: command,
            wouldExecute: confirmed,
            notes: notes
        )
    }

    /// **The only sanctioned execution path.**
    ///
    /// The gate is checked first, so an unconfirmed plan calls `body` zero times. `body` receives
    /// the plan's command string — already validated when the plan was built, never assembled here.
    ///
    /// - Throws: `DryRunError.dryRunNotConfirmed` when the plan was not approved.
    func execute<T>(using body: (String) async throws -> T) async throws -> T {
        guard confirmed else {
            throw DryRunError.dryRunNotConfirmed(operation: operation)
        }
        return try await body(command)
    }
}
