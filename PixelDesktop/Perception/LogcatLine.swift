import Foundation

/// One line of `logcat -v threadtime` output.
///
/// The format is fixed and positional:
///
///     06-12 14:03:22.194  1234  5678 I ActivityManager: Start proc 4321:com.example
///     └──── timestamp ───┘ └pid┘ └tid┘  P └──── tag ────┘  └────── message ─────┘
///
/// Parsing is structural rather than "split on colons": a message routinely contains colons
/// (`Binder:1234_5`, `http://…`), so the only safe separator is the one the format reserves —
/// the padded tag's trailing `:`.
///
/// Lines that do not match (the `--------- beginning of main` buffer banner, a `logcat`
/// stderr diagnostic that arrived on stdout, a partial final line) return `nil`. They are
/// **not** turned into a synthetic entry: a fabricated line would put text into the log that
/// the device never wrote.
struct LogcatLine: Equatable, Sendable, Identifiable {
    /// The fixed-width prefix, verbatim (`06-12 14:03:22.194`).
    ///
    /// Kept as the device's own string rather than a `Date`: `logcat` prints no year and no
    /// timezone, so converting it would be an invention. A caller that needs ordering uses
    /// arrival order, which is what a live stream provides.
    let timestamp: String

    let pid: Int
    let tid: Int
    let priority: Priority
    let tag: String
    let message: String

    /// The original line, for display and for evidence files.
    let raw: String

    var id: String { raw }

    /// Android log priorities, lowest first.
    enum Priority: String, CaseIterable, Sendable {
        case verbose = "V"
        case debug = "D"
        case info = "I"
        case warn = "W"
        case error = "E"
        case fatal = "F"
        case assert = "A"

        /// Severity ordering, so `minimumPriority` comparisons are meaningful.
        var severity: Int {
            switch self {
            case .verbose: return 0
            case .debug: return 1
            case .info: return 2
            case .warn: return 3
            case .error: return 4
            case .fatal: return 5
            case .assert: return 6
            }
        }

        var label: String {
            switch self {
            case .verbose: return "Verbose"
            case .debug: return "Debug"
            case .info: return "Info"
            case .warn: return "Warn"
            case .error: return "Error"
            case .fatal: return "Fatal"
            case .assert: return "Assert"
            }
        }
    }

    /// Parses one `threadtime` line. Returns `nil` for anything the format does not describe.
    static func parse(_ raw: String) -> LogcatLine? {
        let line = raw.hasSuffix("\r") ? String(raw.dropLast()) : raw

        // Timestamp is exactly 18 characters: "MM-DD HH:MM:SS.mmm".
        guard line.count > 32 else { return nil }
        let timestamp = String(line.prefix(18))
        guard isTimestamp(timestamp) else { return nil }

        var rest = Substring(line.dropFirst(18))

        func nextToken() -> Substring? {
            rest = rest.drop(while: { $0 == " " })
            guard let space = rest.firstIndex(of: " ") else { return nil }
            let token = rest[rest.startIndex..<space]
            rest = rest[space...]
            return token
        }

        guard let pidToken = nextToken(), let pid = Int(pidToken),
              let tidToken = nextToken(), let tid = Int(tidToken),
              let priorityToken = nextToken(),
              let priority = Priority(rawValue: String(priorityToken)) else {
            return nil
        }

        // The tag field is `%-8s` followed by `": "`, so the separator is the **first** colon
        // that is followed by a space — not a space-colon-space triple. Short tags therefore
        // arrive as `chatty  : msg` (two spaces before the colon) and long ones as
        // `ActivityManager: msg` (none). Messaging the device's own padding is what this
        // handles; a message may contain colons later in the line, which is why the *first*
        // such boundary wins.
        rest = rest.drop(while: { $0 == " " })
        guard let colon = rest.range(of: ": "), colon.lowerBound != rest.startIndex else {
            return nil
        }

        let tag = String(rest[rest.startIndex..<colon.lowerBound])
            .trimmingCharacters(in: .whitespaces)
        let message = String(rest[colon.upperBound...]).drop(while: { $0 == " " })

        guard !tag.isEmpty else { return nil }

        return LogcatLine(
            timestamp: timestamp,
            pid: pid,
            tid: tid,
            priority: priority,
            tag: tag,
            message: String(message),
            raw: line
        )
    }

    /// `MM-DD HH:MM:SS.mmm` — checked structurally so a text line that happens to be long is
    /// not parsed as a log entry.
    private static func isTimestamp(_ value: String) -> Bool {
        let characters = Array(value)
        guard characters.count == 18 else { return false }

        let digitPositions: Set<Int> = [0, 1, 3, 4, 6, 7, 9, 10, 12, 13, 15, 16, 17]
        for position in digitPositions where !characters[position].isNumber {
            return false
        }

        return characters[2] == "-"
            && characters[5] == " "
            && characters[8] == ":"
            && characters[11] == ":"
            && characters[14] == "."
    }
}

/// Selects which log lines a stream keeps.
///
/// Mirrors the `logcat -s <tag>[:<priority>]` filter spec, and validates the tag because the
/// filter is assembled into a shell command string. A tag is an identifier, never a command.
struct LogcatFilter: Equatable, Sendable {
    /// Optional tag. `nil` keeps every tag.
    let tag: String?

    /// Optional floor. `nil` keeps everything the device emits at the chosen buffers.
    let minimumPriority: LogcatLine.Priority?

    init(tag: String? = nil, minimumPriority: LogcatLine.Priority? = nil) {
        self.tag = tag
        self.minimumPriority = minimumPriority
    }

    /// Builds the arguments for a `logcat` invocation.
    ///
    /// - Throws: `PixelDesktopError.invalidInput` when the tag is not an identifier.
    func arguments() throws -> [String] {
        var arguments = ["logcat", "-v", "threadtime"]

        guard let tag else {
            if let minimumPriority {
                // A bare priority floor with no tag is not expressible in the `-s` spec; `*:P`
                // is the documented wildcard form.
                arguments += ["*:\(minimumPriority.rawValue)"]
            }
            return arguments
        }

        let validated = try LogcatFilter.validateTag(tag)
        if let minimumPriority {
            arguments += ["-s", "\(validated):\(minimumPriority.rawValue)"]
        } else {
            arguments += ["-s", validated]
        }
        return arguments
    }

    /// Tag shape check. `logcat` tags may contain letters, digits, `_`, `-` and `.`.
    static func validateTag(_ tag: String) throws -> String {
        let trimmed = tag.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw PixelDesktopError.invalidInput("Logcat tag must not be empty")
        }

        let pattern = "^[A-Za-z0-9_.-]+$"
        guard trimmed.range(of: pattern, options: .regularExpression) != nil else {
            throw PixelDesktopError.invalidInput(
                "Not a valid logcat tag: '\(tag)' (allowed: letters, digits, '_', '-', '.')"
            )
        }
        return trimmed
    }

    /// Applies the filter to an already-parsed line, for streams that are not device-filtered.
    func accepts(_ line: LogcatLine) -> Bool {
        if let tag, line.tag != tag { return false }
        if let minimumPriority, line.priority.severity < minimumPriority.severity { return false }
        return true
    }
}
