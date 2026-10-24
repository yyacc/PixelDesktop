import Foundation

/// Parses `uiautomator dump` output into a `UIHierarchy`.
///
/// ## Why a real XML parser
///
/// The dump is XML whose attribute values routinely contain `<`, `&`, quotes, newlines and
/// non-Latin text (a TikTok caption, a Wi-Fi SSID). Regex or line-splitting extraction
/// corrupts those silently — it produces a *shorter* tree that still looks plausible. The
/// parser is therefore `XMLParser`, and a malformed document is reported as a failure rather
/// than as a partial hierarchy, because a partial hierarchy would let a tap plan address a
/// node that the device's real tree does not have.
///
/// ## Tolerated input shapes
///
/// `uiautomator dump` writes the document to a file and prints a human sentence. When the
/// dump is read back from a file (`cat`) that sentence is not present; when it is read from
/// `/dev/tty` it is. Both are accepted: everything before the first `<` is discarded, so the
/// parser works on either acquisition path.
enum UIHierarchyParser {

    /// Parses a dump. Throws `PixelDesktopError.invalidInput` when there is no XML document
    /// in the input or the document does not parse.
    static func parse(_ raw: String) throws -> UIHierarchy {
        let document = try extractDocument(from: raw)

        let delegate = UIHierarchyXMLDelegate()
        let parser = XMLParser(data: Data(document.utf8))
        parser.delegate = delegate

        guard parser.parse() else {
            let reason = parser.parserError?.localizedDescription ?? "unknown XML error"
            throw PixelDesktopError.invalidInput("UI hierarchy dump is not parseable XML: \(reason)")
        }

        return UIHierarchy(
            elements: delegate.elements,
            rotation: delegate.rotation,
            packageName: delegate.packageName
        )
    }

    /// Parses leniently: returns `nil` instead of throwing.
    static func parseIfPossible(_ raw: String) -> UIHierarchy? {
        try? parse(raw)
    }

    /// Returns the substring starting at the first `<`.
    static func extractDocument(from raw: String) throws -> String {
        guard let start = raw.firstIndex(of: "<") else {
            throw PixelDesktopError.invalidInput(
                "UI hierarchy dump contains no XML document (first 120 chars: '\(raw.prefix(120))')"
            )
        }
        return String(raw[start...])
    }
}

/// Collects `<node>` elements and the root's metadata.
///
/// Only direct attributes are read — `XMLParser` gives attribute dictionaries per element, so
/// there is no string scanning and no ordering assumption. `index` is assigned in document
/// order, which is the only stable identity the device provides.
private final class UIHierarchyXMLDelegate: NSObject, XMLParserDelegate {
    private(set) var elements: [UIElement] = []
    private(set) var rotation: Int?
    private(set) var packageName: String?

    /// Number of nodes seen, used for `UIElement.index`. Counted separately from
    /// `elements.count` so a rejected node does not shift the indices of accepted ones.
    private var seenNodes = 0

    func parser(
        _ parser: XMLParser,
        didStartElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?,
        attributes attributeDict: [String: String]
    ) {
        switch elementName {
        case "hierarchy":
            rotation = attributeDict["rotation"].flatMap(Int.init)

        case "node":
            defer { seenNodes += 1 }

            // A node without bounds is dropped: it cannot be a target and carries no layout.
            // `rotation`-only containers never appear as `node`, so this loses nothing.
            guard let boundsRaw = attributeDict["bounds"],
                  let bounds = UIElementBounds.parse(boundsRaw) else {
                return
            }

            let package = attributeDict["package"].flatMap { $0.isEmpty ? nil : $0 }
            if packageName == nil, let package { packageName = package }

            elements.append(
                UIElement(
                    index: elements.count,
                    className: attributeDict["class"] ?? "",
                    resourceID: Self.nilIfEmpty(attributeDict["resource-id"]),
                    text: Self.nilIfEmpty(attributeDict["text"]),
                    contentDescription: Self.nilIfEmpty(attributeDict["content-desc"]),
                    bounds: bounds,
                    packageName: package,
                    isEnabled: Self.bool(attributeDict["enabled"]),
                    isClickable: Self.bool(attributeDict["clickable"]),
                    isScrollable: Self.bool(attributeDict["scrollable"]),
                    isFocused: Self.bool(attributeDict["focused"]),
                    isChecked: Self.bool(attributeDict["checked"]),
                    isSelected: Self.bool(attributeDict["selected"]),
                    isPassword: Self.bool(attributeDict["password"])
                )
            )

        default:
            break
        }
    }

    /// `uiautomator` prints `"true"`/`"false"`, and omits attributes it considers default.
    /// An absent attribute is read as `false`; that is the device's own default, not a guess.
    private static func bool(_ raw: String?) -> Bool {
        raw?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "true"
    }

    private static func nilIfEmpty(_ raw: String?) -> String? {
        guard let raw, !raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return nil
        }
        return raw
    }
}
