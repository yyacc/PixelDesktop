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
struct ADBDeviceInput: DeviceInputProtocol {
    private let transport: TransportProtocol
    private let auditLog: InputAuditLog

    init(transport: TransportProtocol, auditLog: InputAuditLog) {
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

    // MARK: - Execution

    func execute(
        _ plan: InputActionPlan,
        deviceSerial: String,
        timeout: TimeInterval
    ) async throws -> InputActionResult {
        // The gate. An unconfirmed plan is refused before any command is built.
        guard plan.confirmed else {
            auditLog.append(
                InputAuditRecord(
                    plan: plan,
                    outcome: InputAuditRecord.refused,
                    detail: InputRefusal.planNotConfirmed.description
                )
            )
            throw InputRefusal.planNotConfirmed
        }

        let command = try buildCommand(for: plan)

        do {
            let result = try await transport.shell(
                deviceSerial: deviceSerial,
                command: command,
                timeout: timeout
            )

            guard result.isSuccess else {
                auditLog.append(
                    InputAuditRecord(
                        plan: plan,
                        outcome: InputAuditRecord.failed,
                        detail: "\(command) exited \(result.exitCode): \(result.stderr)"
                    )
                )
                throw PixelDesktopError.adbCommandFailed(
                    command: command,
                    exitCode: Int(result.exitCode),
                    stderr: result.stderr
                )
            }

            auditLog.append(
                InputAuditRecord(plan: plan, outcome: InputAuditRecord.executed, detail: command)
            )

            return InputActionResult(
                planID: plan.id,
                kind: plan.kind,
                command: command,
                executedAt: Date(),
                exitCode: result.exitCode,
                stderr: result.stderr
            )
        } catch let error as PixelDesktopError {
            // Already audited above; rethrown so the caller sees the typed failure.
            throw error
        } catch {
            auditLog.append(
                InputAuditRecord(
                    plan: plan,
                    outcome: InputAuditRecord.failed,
                    detail: "transport error: \(error.localizedDescription)"
                )
            )
            throw PixelDesktopError.adbTransportError(error.localizedDescription)
        }
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
