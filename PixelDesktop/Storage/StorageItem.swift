import Foundation

/// One entry in a device directory, as reported by `adb shell ls -la`.
///
/// The model is deliberately flat — name, path, size, kind, modified date — because that is
/// exactly what the storage browser lists and everything else would be speculative. Recursive
/// sizes, permissions and MIME types are *not* modelled: none has a source in the listing and
/// each would require an extra ADB round trip per entry.
struct StorageItem: Identifiable, Equatable, Sendable {

    /// The entry's own name (no path), e.g. `notes.txt`.
    let name: String

    /// The absolute device path, built from the parent path and `name`.
    let path: String

    /// Size in bytes as reported by `ls`.
    ///
    /// - Important: For a directory this is the directory entry's own size (commonly 4096
    ///   bytes on ext4/f2fs), **not** the recursive size of its contents. `ls` cannot report
    ///   a recursive size without walking the tree, which is why this is documented rather
    ///   than left to look like a bug.
    let size: UInt64

    /// Whether the entry is a directory. Symlinks are reported as non-directories.
    let isDirectory: Bool

    /// Last-modified time, or `nil` when the listing's date column could not be parsed.
    let modifiedDate: Date?

    /// Identity for SwiftUI lists. The device path is unique within the storage root.
    var id: String { path }
}

// MARK: - Listing parser

extension StorageItem {

    /// Parses `ls -la` output for a directory.
    ///
    /// ## Format handled
    ///
    /// This parses the **Toybox** `ls -l` layout that Android ships — the one the Pixel 7a
    /// produces — not the GNU layout:
    ///
    /// ```
    /// total 8
    /// drwxrwx--x 2 root sdcard_rw 4096 2026-10-16 10:30 Pictures
    /// -rw-rw---- 1 root sdcard_rw  123 2026-10-16 10:31 notes.txt
    /// lrwxrwxrwx 1 root root          8 2026-10-16 10:31 latest -> 2026-10-16
    /// ```
    ///
    /// Anything that does not match is skipped rather than mis-parsed: the `total N` header,
    /// blank lines, and any future column additions. A skipped line becomes a missing entry,
    /// never a fabricated one.
    ///
    /// ## What is filtered
    ///
    /// `.` and `..` are dropped. They are traversal devices, not storage contents, and the
    /// browser navigates through explicit parent state rather than by listing them.
    static func parseListing(_ output: String, parentPath: String) -> [StorageItem] {
        output
            .components(separatedBy: .newlines)
            .compactMap { parseLine($0, parentPath: parentPath) }
    }

    /// The `ls -l` long-format line:
    ///
    /// `type` + 9 permission chars + optional ACL/SELinux suffix, then link count, owner,
    /// group, size, `YYYY-MM-DD`, `HH:MM[:SS]`, and finally the name (which may contain spaces,
    /// so it is captured as the remainder of the line).
    ///
    /// Group 1 = type, 3 = size, 4 = date, 5 = time, 6 = name.
    private static let listingPattern =
        #"^([\-dlbcpsDLBCPS])([rwxsStT\-]{9})[\.\+@]?\s+\d+\s+\S+\s+\S+\s+(\d+)\s+(\d{4}-\d{2}-\d{2})\s+(\d{2}:\d{2}(?::\d{2})?)\s+(.+)$"#

    private static let listingRegex = try! NSRegularExpression(pattern: listingPattern)

    /// Parses a single `ls -l` line. Returns `nil` for headers, blanks, and unparseable lines.
    static func parseLine(_ line: String, parentPath: String) -> StorageItem? {
        let nsLine = line as NSString
        let fullRange = NSRange(location: 0, length: nsLine.length)

        guard let match = listingRegex.firstMatch(in: line, options: [], range: fullRange),
              match.numberOfRanges == 7 else {
            return nil
        }

        let type = nsLine.substring(with: match.range(at: 1))
        let sizeString = nsLine.substring(with: match.range(at: 3))
        let dateString = nsLine.substring(with: match.range(at: 4))
        let timeString = nsLine.substring(with: match.range(at: 5))
        var name = nsLine.substring(with: match.range(at: 6))

        // A symlink prints as `name -> target`; the entry's name is everything before the arrow.
        if let arrow = name.range(of: " -> ") {
            name = String(name[name.startIndex..<arrow.lowerBound])
        }

        name = name.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty, name != ".", name != ".." else { return nil }

        let path = parentPath.hasSuffix("/") ? parentPath + name : parentPath + "/" + name

        return StorageItem(
            name: name,
            path: path,
            size: UInt64(sizeString) ?? 0,
            isDirectory: type == "d",
            modifiedDate: parseModifiedDate(dateString, timeString)
        )
    }

    /// Parses the Toybox `YYYY-MM-DD HH:MM[:SS]` timestamp.
    ///
    /// Two formats are tried because Toybox emits seconds only for a subset of builds. A value
    /// that matches neither yields `nil` rather than a guessed date.
    static func parseModifiedDate(_ date: String, _ time: String) -> Date? {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone.current

        let combined = "\(date) \(time)"
        for format in ["yyyy-MM-dd HH:mm:ss", "yyyy-MM-dd HH:mm"] {
            formatter.dateFormat = format
            if let parsed = formatter.date(from: combined) {
                return parsed
            }
        }
        return nil
    }
}
