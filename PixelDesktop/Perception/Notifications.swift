import Foundation

// MARK: - Key

/// A notification's device-assigned key, kept **verbatim**.
///
/// The shape is not fixed. A normal notification is `user|pkg|id|tag|uid` (5 parts), but Android 16
/// also reports *aggregate* records whose key is 10 parts long
/// (`0|pkg|0|0|pkg|g:Aggregate_SilentSection|1000|…`). Measured on this device: 33 records, two key
/// shapes. Parsing the key into named fields would therefore lose records; the raw string is the
/// identity, and it is what tier 1 (`cmd notification list`) reports, so the two tiers line up
/// exactly without a translation step.
struct NotificationKey: Hashable, Sendable, Codable {
    let raw: String

    init(raw: String) {
        self.raw = raw
    }

    /// The `|`-separated parts, for display and for package extraction. Not an identity contract.
    var parts: [String] {
        raw.split(separator: "|", omittingEmptySubsequences: false).map(String.init)
    }

    /// The package segment. `user|pkg|…` for a normal record; the same position for an aggregate.
    var packageID: String? {
        parts.count > 1 ? parts[1] : nil
    }

    /// Whether this is one of Android's aggregate/section records rather than a real notification.
    var isAggregate: Bool {
        parts.contains { $0.hasPrefix("g:Aggregate") } || raw.contains("::SUMMARY::")
    }
}

// MARK: - Enumerated fields

/// Android's `Notification.visibility` (`vis`).
///
/// **Measured correction to the proposal:** it predicted `PRIVATE` / `PUBLIC` / `SECRET`, but
/// Android 16's `dumpsys` prints the raw integer (`0` / `1` / `-1`). Both forms are accepted,
/// because a different build may print either and silently defaulting either way would mislabel a
/// private notification as unknown.
enum NotificationVisibility: String, Sendable, Codable, CaseIterable {
    case privateVisibility = "PRIVATE"
    case publicVisibility = "PUBLIC"
    case secret = "SECRET"
    case unknown = "UNKNOWN"

    var displayName: String {
        switch self {
        case .privateVisibility: return "Private"
        case .publicVisibility: return "Public"
        case .secret: return "Secret"
        case .unknown: return "Unknown"
        }
    }

    /// Maps `0` / `1` / `-1` **and** the word forms. Anything else is `.unknown`, never `.public`:
    /// failing closed matters when the field describes how much of a message is exposed.
    static func parse(_ raw: String) -> NotificationVisibility {
        switch raw.trimmingCharacters(in: .whitespaces).uppercased() {
        case "0", "PRIVATE", "VISIBILITY_PRIVATE": return .privateVisibility
        case "1", "PUBLIC", "VISIBILITY_PUBLIC": return .publicVisibility
        case "-1", "SECRET", "VISIBILITY_SECRET": return .secret
        default: return .unknown
        }
    }
}

/// Android's `importance` (1–4), read from the record header.
enum NotificationImportance: Int, Sendable, Codable, CaseIterable, Comparable {
    case minimum = 1
    case low = 2
    case normal = 3
    case high = 4

    var displayName: String {
        switch self {
        case .minimum: return "Min"
        case .low: return "Low"
        case .normal: return "Default"
        case .high: return "High"
        }
    }

    static func parse(_ raw: String) -> NotificationImportance {
        NotificationImportance(rawValue: Int(raw.trimmingCharacters(in: .whitespaces)) ?? -1) ?? .normal
    }

    static func < (lhs: NotificationImportance, rhs: NotificationImportance) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

// MARK: - Record

/// One notification, as read from `dumpsys notification --noredact`.
///
/// **This is personal data.** It is only constructible through `NotificationParser` on output from a
/// consent-gated read (`ConsentGate` on `.notifications`), and nothing in this type decides who may
/// see it.
///
/// ## Why five content fields
///
/// Measured on this device: 33 records, of which 29 carry content. Reading `android.text` alone
/// finds **10** of them (30%) because the value's *type* is usually `SpannableString`, not `String` —
/// matching `"String ("` drops the rest. `android.textLines` is additionally a `CharSequence[]`
/// printed as `[0]`…`[n]` items, and `tickerText` is a bare scalar. All five are read, and a record
/// with none of them is surfaced as `isContentless` rather than dropped.
struct NotificationRecord: Identifiable, Equatable, Sendable {
    let key: NotificationKey
    let packageID: String
    let userID: Int
    let notificationID: Int
    let tag: String?
    let importance: NotificationImportance
    let visibility: NotificationVisibility
    let title: String?
    let text: String?
    let textLines: [String]
    let subText: String?
    let bigText: String?
    let tickerText: String?

    var id: String { key.raw }

    /// True when the record exposes no readable content.
    ///
    /// Surfaced, never hidden: 4 of 33 records on this device are contentless, and 3 of those are
    /// Android's own aggregate/section records, which have no message to show. A silently dropped
    /// record and a record with nothing to show look identical to a reader, which is the failure
    /// this flag exists to prevent.
    var isContentless: Bool {
        !Self.hasContent(title)
            && !Self.hasContent(text)
            && !Self.hasContent(subText)
            && !Self.hasContent(bigText)
            && !Self.hasContent(tickerText)
            && !textLines.contains(where: Self.hasContent)
    }

    /// The best available heading. A package name is a poor title but an honest one.
    var displayTitle: String {
        if let title = Self.normalised(title) { return title }
        if let first = textLines.first(where: Self.hasContent) { return first }
        if let ticker = Self.normalised(tickerText) { return ticker }
        if let text = Self.normalised(text) { return text }
        return packageID
    }

    /// The best available body, excluding whatever `displayTitle` took.
    var displayBody: String? {
        if let bigText = Self.normalised(bigText) { return bigText }
        if let text = Self.normalised(text) { return text }
        if textLines.count > 1 { return textLines.dropFirst().joined(separator: "\n") }
        return Self.normalised(subText)
    }

    private static func hasContent(_ value: String?) -> Bool {
        guard let value else { return false }
        return !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private static func normalised(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
