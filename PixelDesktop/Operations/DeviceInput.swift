import Foundation

/// What an injected action does.
///
/// Deliberately small. There is no `swipe` and no `drag`: a swipe is a gesture whose start,
/// end and duration all have to be chosen, and a blind gesture with no confirmation loop is
/// strictly more dangerous than a tap on a named element. `tap`, `type` and `keyevent` cover
/// the cases the proposal named (permission dialogs, the setup wizard, Developer Options).
enum InputActionKind: String, Sendable, CaseIterable {
    case tap
    case typeText
    case keyEvent
}

/// A concrete element resolved out of a `UIHierarchy` dump.
///
/// This is the *only* way a tap acquires coordinates. The proposal's rule (§6.2) is that
/// input is **element-addressed, not coordinate-addressed**, so a caller never supplies an
/// `(x, y)` — it supplies a query or an element index, and the centre is derived from the
/// bounds the device itself reported.
struct ResolvedTarget: Equatable, Sendable {
    /// Document order in the dump the element came from. Stable for that dump only.
    let index: Int
    let label: String
    let className: String
    let resourceID: String?
    let bounds: UIElementBounds

    var centerX: Int { bounds.centerX }
    var centerY: Int { bounds.centerY }

    /// Resolves an element from a dump. Returns `nil` for a node with no area, because a
    /// zero-area node has no centre to tap.
    init?(element: UIElement) {
        guard element.isVisible else { return nil }
        self.index = element.index
        self.label = element.label
        self.className = element.className
        self.resourceID = element.resourceID
        self.bounds = element.bounds
    }

    /// The line a human reads in the dry-run preview.
    var preview: String {
        var parts = ["\"\(label)\""]
        if let resourceID, !resourceID.isEmpty { parts.append(resourceID) }
        parts.append(className)
        parts.append("[\(bounds.left),\(bounds.top)][\(bounds.right),\(bounds.bottom)]")
        parts.append("centre (\(centerX), \(centerY))")
        return parts.joined(separator: " · ")
    }
}

/// A proposed input action, before it is allowed to run.
///
/// **This type is the gate.** `confirmed` is `let`, and the only way to obtain a confirmed
/// plan is `confirming()`, which the UI calls from the user's explicit approval. `execute`
/// refuses anything else with `InputRefusal.planNotConfirmed`, so the dry-run requirement is
/// enforced in the type system rather than documented and hoped for.
struct InputActionPlan: Identifiable, Equatable, Sendable {
    let id: UUID
    let kind: InputActionKind
    let target: ResolvedTarget?
    let payload: String?
    let confirmed: Bool
    let createdAt: Date

    init(
        id: UUID = UUID(),
        kind: InputActionKind,
        target: ResolvedTarget? = nil,
        payload: String? = nil,
        confirmed: Bool = false,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.kind = kind
        self.target = target
        self.payload = payload
        self.confirmed = confirmed
        self.createdAt = createdAt
    }

    /// Returns an approved copy. The unconfirmed original stays unconfirmed — approval is a
    /// transition, not a mutation, so a caller cannot hold a plan that silently became live.
    func confirming() -> InputActionPlan {
        InputActionPlan(
            id: id,
            kind: kind,
            target: target,
            payload: payload,
            confirmed: true,
            createdAt: createdAt
        )
    }

    /// Exactly what will happen, in words, for the dry-run preview.
    var preview: String {
        switch kind {
        case .tap:
            let where_ = target?.preview ?? "(no target)"
            return "TAP \(where_)"
        case .typeText:
            return "TYPE \"\(payload ?? "")\""
        case .keyEvent:
            return "KEY \(payload ?? "")"
        }
    }
}

/// A refused input action, with the reason.
///
/// A dedicated vocabulary rather than `PixelDesktopError.invalidInput(String)`: the proposal
/// requires that blind input cannot execute without a previewed, confirmed target, and a
/// refusal that collapses into prose cannot be asserted on. Every case here is thrown by
/// `ADBDeviceInput` and is reachable from the UI.
enum InputRefusal: Error, Equatable, CustomStringConvertible {
    /// `execute` was handed a plan that was never confirmed.
    case planNotConfirmed

    /// No interactive element matched the query.
    case targetNotFound(query: String)

    /// The query matched elements, but none is interactive or on screen.
    case targetNotInteractive(label: String)

    /// The query matched more than one interactive element, so the preview would not be
    /// determinate. The caller must disambiguate by element index.
    case targetAmbiguous(candidates: [String])

    /// The text cannot be delivered by `input text`.
    case textRejected(reason: String)

    /// The key name is not in the supported vocabulary.
    case keyRejected(reason: String)

    var description: String {
        switch self {
        case .planNotConfirmed:
            return "Refused: the action was not confirmed against a dry-run preview"
        case .targetNotFound(let query):
            return "Refused: no element matches \"\(query)\""
        case .targetNotInteractive(let label):
            return "Refused: \"\(label)\" is not interactive or is off screen"
        case .targetAmbiguous(let candidates):
            return "Refused: \(candidates.count) elements match — disambiguate by index: "
                + candidates.joined(separator: " | ")
        case .textRejected(let reason):
            return "Refused: text rejected — \(reason)"
        case .keyRejected(let reason):
            return "Refused: key rejected — \(reason)"
        }
    }
}

/// What actually ran.
struct InputActionResult: Equatable, Sendable {
    let planID: UUID
    let kind: InputActionKind
    /// The exact device command, retained for the audit trail.
    let command: String
    let executedAt: Date
    let exitCode: Int32
    let stderr: String
}

/// Quoting and validation for values that become part of a device shell command.
///
/// ## Why quoting rather than an allowlist
///
/// `input text` is the one place caller-supplied text reaches the device shell, so it is the
/// one place a shell fragment could be smuggled in. An allowlist of "safe" characters is the
/// usual answer and it is the wrong one: it silently mangles a password containing `$` or a
/// URL containing `&`, and the user cannot tell a rejected character from a typo.
///
/// Instead the text is single-quoted for the shell, which suppresses **all** expansion
/// (`$`, backticks, globs, `~`, `;`, `|`, `&`, redirection), and embedded single quotes are
/// closed and re-opened. Spaces become `%s`, which is `input text`'s own encoding for a space.
///
/// Newlines are refused rather than quoted: `input text` cannot deliver them, and a silently
/// truncated string is a different command.
enum InputContainment {
    /// Encodes text for `input text` and quotes it for the device shell.
    ///
    /// - Throws: `InputRefusal.textRejected` for empty text, embedded newlines, or text long
    ///   enough to be a paste rather than a field entry.
    static func quotedTextArgument(_ text: String) throws -> String {
        guard !text.isEmpty else {
            throw InputRefusal.textRejected(reason: "text is empty")
        }
        guard !text.contains(where: { $0 == "\n" || $0 == "\r" }) else {
            throw InputRefusal.textRejected(reason: "text contains a line break")
        }
        // `input text` is an IME-level injector; long payloads take seconds and can be
        // truncated by the shell buffer. A field entry is not a document.
        guard text.count <= 512 else {
            throw InputRefusal.textRejected(
                reason: "text is \(text.count) characters; the limit is 512"
            )
        }

        let spaced = text.replacingOccurrences(of: " ", with: "%s")
        return shellSingleQuote(spaced)
    }

    /// Single-quotes a value for `sh`, escaping embedded single quotes.
    ///
    /// The idiom `'\''` closes the quote, emits a literal quote, and re-opens — the only
    /// correct way to embed a quote in a single-quoted shell string.
    static func shellSingleQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    /// The key-event vocabulary this build accepts.
    ///
    /// An allowlist is correct here, unlike for text: key names are a fixed platform
    /// vocabulary, not user content, so anything outside it is a programming error rather
    /// than an input the user meant. `KEYCODE_` prefix only — no raw numeric codes, which
    /// would be an unreadable audit record.
    static let supportedKeys: [String] = [
        "KEYCODE_BACK",
        "KEYCODE_HOME",
        "KEYCODE_APP_SWITCH",
        "KEYCODE_ENTER",
        "KEYCODE_DEL",
        "KEYCODE_TAB",
        "KEYCODE_ESCAPE",
        "KEYCODE_DPAD_UP",
        "KEYCODE_DPAD_DOWN",
        "KEYCODE_DPAD_LEFT",
        "KEYCODE_DPAD_RIGHT",
        "KEYCODE_DPAD_CENTER",
        "KEYCODE_VOLUME_UP",
        "KEYCODE_VOLUME_DOWN",
        "KEYCODE_POWER",
        "KEYCODE_WAKEUP",
        "KEYCODE_SLEEP",
        "KEYCODE_MENU",
        "KEYCODE_SEARCH"
    ]

    /// Validates a key name.
    ///
    /// - Throws: `InputRefusal.keyRejected` when the name is not in `supportedKeys`.
    static func validatedKey(_ key: String) throws -> String {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        guard supportedKeys.contains(trimmed) else {
            throw InputRefusal.keyRejected(
                reason: "\"\(key)\" is not one of: \(supportedKeys.joined(separator: ", "))"
            )
        }
        return trimmed
    }
}
