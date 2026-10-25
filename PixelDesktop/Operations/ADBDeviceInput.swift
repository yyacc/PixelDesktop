import Foundation

/// Input injection implemented over ADB.
///
/// Depends on `TransportProtocol`, not `ADBTransport`, so the whole gate is testable with a
/// mock transport and no device attached.
///
/// ## Command construction
///
/// The three commands are built from **already-resolved** values:
///
/// - tap: integer coordinates taken from the device's own reported bounds.
/// - text: single-quoted and `%s`-encoded by `InputContainment`.
/// - key: a name validated against `InputContainment.supportedKeys`.
///
/// No caller-supplied string reaches the device unquoted, and no caller supplies coordinates
/// at all.
///
/// ## Phase 3 — generalised trail, unchanged gate
///
/// The audit trail is now the shared `DeviceAuditLog` (D2) rather than an input-only log, and it
/// is written **before** the command is issued (`begin`/`resolve`) rather than after. The gate
/// itself is untouched: `InputActionPlan.confirmed` still decides whether anything runs. Input also
/// joins the universal dry-run vocabulary via `dryRunReport(for:)` (D3), so a tap preview and an
/// uninstall preview are the same artifact type.
struct ADBDeviceInput: DeviceInputProtocol {
    private let transport: TransportProtocol
    private let auditLog: DeviceAuditLog

    init(transport: TransportProtocol, auditLog: DeviceAuditLog) {
        self.transport = transport
        self.auditLog = auditLog
    }

    // MARK: - Planning

    func planTap(hierarchy: UIHierarchy, matching query: String) throws -> InputActionPlan {
        let interactive = hierarchy.tapTargets.filter { $0.matches(query) }

        if interactive.isEmpty {
            // Distinguish "nothing matched" from "matched something untappable": the second
            // is a wrong-target mistake the user can fix, the first is a wrong-query mistake.
            let anyMatch = hierarchy.elements(matching: query)
            if let first = anyMatch.first {
                throw InputRefusal.targetNotInteractive(label: first.label)
            }
            throw InputRefusal.targetNotFound(query: query)
        }

        if interactive.count > 1 {
            throw InputRefusal.targetAmbiguous(
                candidates: interactive.map { "#\($0.index) \($0.label)" }
            )
        }

        guard let target = ResolvedTarget(element: interactive[0]) else {
            throw InputRefusal.targetNotInteractive(label: interactive[0].label)
        }

        return InputActionPlan(kind: .tap, target: target)
    }

    func planTap(hierarchy: UIHierarchy, elementIndex: Int) throws -> InputActionPlan {
        guard let element = hierarchy.elements.first(where: { $0.index == elementIndex }) else {
            throw InputRefusal.targetNotFound(query: "#\(elementIndex)")
        }
        guard element.isInteractive, let target = ResolvedTarget(element: element) else {
            throw InputRefusal.targetNotInteractive(label: element.label)
        }
        return InputActionPlan(kind: .tap, target: target)
    }

    func planText(_ text: String) throws -> InputActionPlan {
        // Validated at plan time so the preview only ever shows text that can actually be
        // delivered — a preview of a string that will be rejected is not a preview.
        _ = try InputContainment.quotedTextArgument(text)
        return InputActionPlan(kind: .typeText, payload: text)
    }

    func planKeyEvent(_ key: String) throws -> InputActionPlan {
        let validated = try InputContainment.validatedKey(key)
        return InputActionPlan(kind: .keyEvent, payload: validated)
    }

    // MARK: - Dry run (D3)

    /// The shared dry-run report for an input plan.
    ///
    /// Input was the first operation to grow a gate (ADR-019); it is not a special case in the
    /// Phase 3 vocabulary. An unbuildable plan still produces a report — with the failure as the
    /// command — because "this plan cannot produce a command" is itself what the operator needs to
    /// see before confirming.
    func dryRunReport(for plan: InputActionPlan) -> DryRunReport {
        let command: String
        do {
            command = try buildCommand(for: plan)
        } catch {
            command = "invalid plan: \(error)"
        }
        return DryRunReport(
            operation: .inputInject,
            target: plan.target?.label ?? plan.kind.rawValue,
            command: command,
            wouldExecute: plan.confirmed,
            notes: [plan.preview]
        )
    }

    // MARK: - Execution

    func execute(
        _ plan: InputActionPlan,
        deviceSerial: String,
        timeout: TimeInterval
    ) async throws -> InputActionResult {
        let context = InputAuditContext(plan: plan)

        // The gate. An unconfirmed plan is refused before any command is built.
        guard plan.confirmed else {
            auditLog.append(
                operation: .inputInject,
                target: plan.target?.label,
                outcome: .refused,
                detail: InputRefusal.planNotConfirmed.description,
                input: context
            )
            throw InputRefusal.planNotConfirmed
        }

        let command = try buildCommand(for: plan)

        // Append-before-execute: the attempt is durable before the device is touched, so a crash
        // mid-command still leaves evidence that it was issued.
        let attempt = auditLog.begin(
            operation: .inputInject,
            target: plan.target?.label,
            detail: command,
            input: context
        )

        let result: TransportResult
        do {
            result = try await transport.shell(
                deviceSerial: deviceSerial,
                command: command,
                timeout: timeout
            )
        } catch {
            auditLog.resolve(
                attempt,
                outcome: .failed,
                detail: "transport error: \(error.localizedDescription)"
            )
            throw PixelDesktopError.adbTransportError(error.localizedDescription)
        }

        guard result.isSuccess else {
            auditLog.resolve(
                attempt,
                outcome: .failed,
                detail: "\(command) exited \(result.exitCode): \(result.stderr)"
            )
            throw PixelDesktopError.adbCommandFailed(
                command: command,
                exitCode: Int(result.exitCode),
                stderr: result.stderr
            )
        }

        auditLog.resolve(attempt, outcome: .executed, detail: command)

        return InputActionResult(
            planID: plan.id,
            kind: plan.kind,
            command: command,
            executedAt: Date(),
            exitCode: result.exitCode,
            stderr: result.stderr
        )
    }

    /// Builds the device command for a confirmed plan.
    ///
    /// - Throws: `PixelDesktopError.invalidInput` for a plan whose shape does not match its
    ///   kind — a programming error, not a user error, but typed rather than force-unwrapped.
    func buildCommand(for plan: InputActionPlan) throws -> String {
        switch plan.kind {
        case .tap:
            guard let target = plan.target else {
                throw PixelDesktopError.invalidInput("tap plan has no resolved target")
            }
            // Integers the device itself reported. Nothing to inject.
            return "input tap \(target.centerX) \(target.centerY)"

        case .typeText:
            guard let payload = plan.payload else {
                throw PixelDesktopError.invalidInput("text plan has no payload")
            }
            let quoted = try InputContainment.quotedTextArgument(payload)
            return "input text \(quoted)"

        case .keyEvent:
            guard let payload = plan.payload else {
                throw PixelDesktopError.invalidInput("key plan has no payload")
            }
            let key = try InputContainment.validatedKey(payload)
            return "input keyevent \(key)"
        }
    }
}
