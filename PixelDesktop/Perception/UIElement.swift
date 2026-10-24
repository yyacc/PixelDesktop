import Foundation

/// A rectangle in device screen coordinates.
///
/// Stock `uiautomator dump` prints bounds as `[left,top][right,bottom]`. This type keeps the
/// four edges rather than an origin and a size, because that is what the device reports and
/// re-deriving one from the other loses the distinction between an inverted rectangle
/// (right < left) and an empty one. Width and height are clamped at zero for that reason.
///
/// Deliberately not `CGRect`: this model is Foundation-only so it compiles into the CLI
/// target, which links no SwiftUI and no AppKit.
struct UIElementBounds: Equatable, Sendable {
    let left: Int
    let top: Int
    let right: Int
    let bottom: Int

    var width: Int { max(0, right - left) }
    var height: Int { max(0, bottom - top) }
    var isEmpty: Bool { width == 0 || height == 0 }
    var centerX: Int { left + width / 2 }
    var centerY: Int { top + height / 2 }

    func contains(x: Int, y: Int) -> Bool {
        x >= left && x < right && y >= top && y < bottom
    }

    /// Parses `uiautomator`'s `[x1,y1][x2,y2]` form.
    ///
    /// Returns `nil` rather than a default rectangle when the string is not exactly that
    /// shape. A fabricated `[0,0][0,0]` would read as "a real element with no area", which is
    /// a different claim from "the device printed something this parser does not understand".
    static func parse(_ raw: String) -> UIElementBounds? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("["), trimmed.hasSuffix("]") else { return nil }

        // Split into the two bracket groups: `[a,b]` and `[c,d]`.
        let groups = trimmed.components(separatedBy: "][")
        guard groups.count == 2 else { return nil }

        let first = groups[0].dropFirst()
        let second = groups[1].dropLast()

        let firstParts = first.split(separator: ",")
        let secondParts = second.split(separator: ",")
        guard firstParts.count == 2, secondParts.count == 2,
              let left = Int(firstParts[0]),
              let top = Int(firstParts[1]),
              let right = Int(secondParts[0]),
              let bottom = Int(secondParts[1]) else {
            return nil
        }

        return UIElementBounds(left: left, top: top, right: right, bottom: bottom)
    }
}

/// One node from the device's accessibility/UI hierarchy.
///
/// This is the perception primitive that makes blind operation *targeted*: an action can
/// address "the element labelled 'Allow'" instead of "the pixel at (412, 1033)". The fields
/// are exactly what `uiautomator dump` reports — nothing is inferred. In particular there is
/// no `confidence`, no heuristics and no OCR.
struct UIElement: Identifiable, Equatable, Sendable {
    /// Document order within the dump. Stable for one dump, and the only identity available:
    /// `uiautomator` does not emit unique node ids.
    let index: Int

    /// Fully qualified class, e.g. `android.widget.TextView`.
    let className: String

    /// `resource-id` attribute, e.g. `com.android.settings:id/allow_button`. Often empty.
    let resourceID: String?

    /// Visible text. Empty for most container nodes.
    let text: String?

    /// Accessibility label. Frequently the only label an icon button has.
    let contentDescription: String?

    let bounds: UIElementBounds
    let packageName: String?
    let isEnabled: Bool
    let isClickable: Bool
    let isScrollable: Bool
    let isFocused: Bool
    let isChecked: Bool
    let isSelected: Bool
    let isPassword: Bool

    var id: Int { index }

    /// Whether the node occupies any area on screen.
    ///
    /// The dump includes off-screen and zero-area nodes; they are kept (they carry structure)
    /// but must not be offered as tap targets.
    var isVisible: Bool { !bounds.isEmpty }

    /// Whether the node can be the target of an input action.
    var isInteractive: Bool { (isClickable || isScrollable) && isVisible }

    /// The best human-readable label available, in order of how unambiguous it is.
    ///
    /// `contentDescription` is preferred over `text` for icon-only nodes and is what a screen
    /// reader would announce, so a tap plan that quotes it matches what a person sees.
    var label: String {
        if let text, !text.isEmpty { return text }
        if let contentDescription, !contentDescription.isEmpty { return contentDescription }
        if let resourceID, !resourceID.isEmpty { return resourceID }
        return className
    }

    /// Least-qualified form of `resourceID` (`...:id/ok` → `ok`), for display and matching.
    var shortResourceID: String? {
        guard let resourceID, !resourceID.isEmpty else { return nil }
        return resourceID.split(separator: "/").last.map(String.init) ?? resourceID
    }

    /// Case-insensitive substring match across label fields.
    ///
    /// Substring rather than equality because the caller is usually a person typing a partial
    /// label, and a strict match would silently offer nothing where the intent is obvious.
    func matches(_ query: String) -> Bool {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !needle.isEmpty else { return false }

        let haystacks = [text, contentDescription, resourceID, shortResourceID, className]
            .compactMap { $0?.lowercased() }
        return haystacks.contains { $0.contains(needle) }
    }
}

/// A complete UI hierarchy dump from one device moment.
struct UIHierarchy: Equatable, Sendable {
    let elements: [UIElement]

    /// `hierarchy/@rotation`, or `nil` when absent. Degrees, as reported by the device.
    let rotation: Int?

    /// The package that owns the focused window, when a node reported one.
    let packageName: String?

    /// Interactive nodes that are actually on screen — the only candidates for a tap.
    var tapTargets: [UIElement] {
        elements.filter { $0.isInteractive && $0.isVisible }
    }

    var isEmpty: Bool { elements.isEmpty }

    /// The topmost interactive element containing a point.
    ///
    /// "Topmost" is approximated by smallest area: the dump's document order is parent-first,
    /// so a container precedes its children, and the smallest matching rectangle is the
    /// innermost node at that point. Returns `nil` when the point hits no interactive node,
    /// which is the honest answer for a tap that would land on nothing.
    func interactiveElement(atX x: Int, y: Int) -> UIElement? {
        tapTargets
            .filter { $0.bounds.contains(x: x, y: y) }
            .min { lhs, rhs in
                (lhs.bounds.width * lhs.bounds.height) < (rhs.bounds.width * rhs.bounds.height)
            }
    }

    func elements(matching query: String) -> [UIElement] {
        elements.filter { $0.matches(query) }
    }
}
