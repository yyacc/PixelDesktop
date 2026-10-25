import Foundation

/// Pure parsers for the notification read (A5).
///
/// ## What this parser had to be built against
///
/// Not an assumed shape — a live `dumpsys notification --noredact` from this device (33 records,
/// 840 KB, Android 16). Three measured properties drove the design:
///
/// 1. **The content type is usually `SpannableString`, not `String`.** 19 of 29 present `android.text`
///    values are spannable. A parser that matches `"String ("` reads 10 of 33 records (30%).
///    So the type is captured generically (`TypeName (`) rather than enumerated — a new type must
///    be *read*, not silently dropped.
/// 2. **Values can span lines.** 17 of 33 records carry at least one multi-line value. `dumpsys`
///    prints the value's first line after `key=Type (` and continues at **column 0** until a line
///    ending in `)`. A per-line regex silently truncates the body to its first line — the same class
///    of defect as reading one field, and invisible in a fixture that has no multi-line text.
/// 3. **Fields repeat.** Each record contains a `notification=` block and a `publicNotification=`
///    block, both with `vis=`, `tickerText=`. Parsing stops at `publicNotification=`, or the public
///    (redacted) variant would overwrite the real one.
///
/// ## Identity
///
/// The record's key comes from the header verbatim, which is the same string tier 1
/// (`cmd notification list`) reports. No translation, no reconstruction.
enum NotificationParser {

    // MARK: - Tier 1: the cheap key list

    /// Parses `cmd notification list` — one `user|pkg|id|tag|uid` key per line.
    ///
    /// Lines that are not a key are skipped rather than throwing: this output has no framing, so a
    /// banner or a warning on stderr-mixed stdout is expected and is not a parse failure. An empty
    /// result means *no notifications*, not *parse failure* — the caller already knows the command
    /// succeeded.
    static func keys(fromList output: String) -> [NotificationKey] {
        output
            .components(separatedBy: .newlines)
            .compactMap { line -> NotificationKey? in
                let raw = line.trimmingCharacters(in: .whitespaces)
                guard !raw.isEmpty else { return nil }
                let parts = raw.split(separator: "|", omittingEmptySubsequences: false)
                // `user|pkg|id|tag|uid`: five parts, with a numeric user and id.
                guard parts.count >= 5,
                      Int(parts[0]) != nil,
                      Int(parts[2]) != nil
                else { return nil }
                return NotificationKey(raw: raw)
            }
    }

    // MARK: - Tier 2: the full dump

    private static let header =
        /^\s+NotificationRecord\(0x[0-9A-Fa-f]+: pkg=(\S+) user=UserHandle\{(-?\d+)\} id=(-?\d+) tag=(.*?) importance=(\d+) key=(.*?): Notification\(/

    private static let extras =
        /^(android\.(?:title|text|textLines|subText|bigText))=([A-Za-z][A-Za-z0-9_.]*) \((.*)$/

    private static let lineItem = /^\[(\d+)\]\s?(.*)$/

    private static let textLinesHeader = "android.textLines=CharSequence[] ("

    /// Parses `dumpsys notification --noredact` into records.
    ///
    /// Every recognised record is returned, including ones with no readable content
    /// (`NotificationRecord.isContentless`). Dropping them would make "the device has 33
    /// notifications" and "the parser found 29" indistinguishable to a reader.
    static func records(fromDump output: String) -> [NotificationRecord] {
        let lines = output.components(separatedBy: "\n")
        var records: [NotificationRecord] = []
        var index = 0

        while index < lines.count {
            guard let headerMatch = try? header.firstMatch(in: lines[index]) else {
                index += 1
                continue
            }

            let packageID = String(headerMatch.1)
            let userID = Int(headerMatch.2) ?? 0
            let notificationID = Int(headerMatch.3) ?? 0
            let rawTag = String(headerMatch.4)
            let importance = NotificationImportance.parse(String(headerMatch.5))
            let key = NotificationKey(raw: String(headerMatch.6))

            var fields = Fields()
            index += 1
            var inPublicVersion = false

            while index < lines.count {
                let line = lines[index]
                if (try? header.firstMatch(in: line)) != nil { break }

                let trimmed = line.trimmingCharacters(in: .whitespaces)

                if trimmed.hasPrefix("publicNotification=") {
                    inPublicVersion = true
                    index += 1
                    continue
                }

                guard !inPublicVersion else {
                    index += 1
                    continue
                }

                if trimmed.hasPrefix("tickerText=") {
                    // A bare scalar, and `null` is a value the device prints — not an absence.
                    let value = String(trimmed.dropFirst("tickerText=".count))
                    fields.tickerText = value == "null" ? nil : value
                    index += 1
                    continue
                }

                if trimmed.hasPrefix("vis=") {
                    fields.visibility = NotificationVisibility.parse(
                        String(trimmed.dropFirst("vis=".count))
                    )
                    index += 1
                    continue
                }

                // `android.textLines=CharSequence[] (n)` then `[0]`…`[n]` items. Checked by prefix
                // because the type name contains `[]`, which the generic extras pattern excludes.
                if trimmed.hasPrefix(textLinesHeader) {
                    index += 1
                    while index < lines.count,
                          let item = try? lineItem.firstMatch(
                            in: lines[index].trimmingCharacters(in: .whitespaces)
                          ) {
                        fields.textLines.append(String(item.2))
                        index += 1
                    }
                    continue
                }

                if let extrasMatch = try? extras.firstMatch(in: trimmed) {
                    let field = String(extrasMatch.1)
                    var value = String(extrasMatch.3)

                    if !value.hasSuffix(")") {
                        // Multi-line value: continue at column 0 until one line closes it.
                        var parts = [value]
                        index += 1
                        while index < lines.count {
                            let continuation = lines[index]
                            if continuation.hasSuffix(")") {
                                parts.append(String(continuation.dropLast()))
                                break
                            }
                            parts.append(continuation)
                            index += 1
                        }
                        value = parts.joined(separator: "\n")
                    } else {
                        value = String(value.dropLast())
                    }

                    fields.set(field: field, value: value == "null" ? nil : value)
                    index += 1
                    continue
                }

                index += 1
            }

            records.append(
                NotificationRecord(
                    key: key,
                    packageID: packageID,
                    userID: userID,
                    notificationID: notificationID,
                    tag: rawTag == "null" ? nil : rawTag,
                    importance: importance,
                    visibility: fields.visibility,
                    title: fields.title,
                    text: fields.text,
                    textLines: fields.textLines,
                    subText: fields.subText,
                    bigText: fields.bigText,
                    tickerText: fields.tickerText
                )
            )
        }

        return records
    }

    /// Mutable accumulation for one record's notification block.
    private struct Fields {
        var visibility: NotificationVisibility = .unknown
        var title: String?
        var text: String?
        var textLines: [String] = []
        var subText: String?
        var bigText: String?
        var tickerText: String?

        mutating func set(field: String, value: String?) {
            switch field {
            case "android.title": title = value
            case "android.text": text = value
            case "android.subText": subText = value
            case "android.bigText": bigText = value
            default: break
            }
        }
    }
}
