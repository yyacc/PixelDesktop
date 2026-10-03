//
//  CLIJSONPresentation.swift
//  PixelDesktopCLI
//
//  Phase 9 Step 1 — the two presentation rules, as pure transformations.
//
//  **This file depends on Foundation only.** It references no PixelDesktop type, which is what
//  lets it be compiled directly into the test bundle for unit testing while the CLI target
//  compiles it into the tool. (Compiling a file that referenced `PixelDesktop` types into the
//  test bundle would put two copies of every shared type in one module.)
//
//  THE PROBLEM THIS SOLVES
//  `CapabilityValue` carries a non-optional `value`, so an unreadable field is encoded as
//  `value: 0` with `source: "unknown"`. Semantically that is correct — the source is the
//  load-bearing marker — but a consumer that reads `value` without reading `source` is told
//  "zero bytes of memory are available", which is the most damaging possible misreading.
//
//  The rule applied here is therefore: **an unknown-source value is published without its
//  `value` key at all.** Absent cannot be misread as a measurement. This is a presentation rule
//  applied uniformly to every `CapabilityValue` in the tree — it is NOT a parallel DTO
//  hierarchy, and it requires no change to the contract or evidence types.
//
//  The same rule covers a field the command did not read: the key is removed and the reason is
//  recorded in the envelope's `not_read` list.
//

import Foundation

enum CLIJSONPresentation {

    /// Recursively removes `value` from every object whose `source` is `unknown`.
    ///
    /// An object is treated as a capability value iff it carries a `source` key. Nothing else
    /// in the envelope does, so this cannot reach an unrelated structure.
    static func omittingUnknownValues(_ any: Any) -> Any {
        if let array = any as? [Any] {
            return array.map(omittingUnknownValues)
        }

        guard let dictionary = any as? [String: Any] else {
            return any
        }

        var transformed: [String: Any] = [:]
        for (key, value) in dictionary {
            transformed[key] = omittingUnknownValues(value)
        }

        if let source = transformed["source"] as? String, source == "unknown" {
            transformed.removeValue(forKey: "value")
        }

        return transformed
    }

    /// Removes the named fields, so a field that was not read is absent rather than fabricated.
    ///
    /// Field paths are dotted (`contract.device`); only the first two segments are used, which
    /// is all the envelope needs and keeps this function free of a path library.
    static func omittingUnreadFields(_ any: [String: Any], fields: [String]) -> [String: Any] {
        var object = any

        for field in fields {
            let path = field.split(separator: ".").map(String.init)
            guard path.count >= 2 else {
                object.removeValue(forKey: path.first ?? "")
                continue
            }

            let parentKey = path[0]
            let childKey = path[1]

            guard var parent = object[parentKey] as? [String: Any] else { continue }
            parent.removeValue(forKey: childKey)
            object[parentKey] = parent
        }

        return object
    }
}

enum CLIJSONError: Error {
    case notAnObject
    case notUTF8
}
