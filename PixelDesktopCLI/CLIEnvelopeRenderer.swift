//
//  CLIEnvelopeRenderer.swift
//  PixelDesktopCLI
//
//  Phase 9 Step 1 — envelope serialisation.
//
//  Kept apart from `CLIJSONPresentation` so the pure transformation rules stay free of any
//  PixelDesktop dependency and remain unit-testable in isolation. This file is the part that
//  knows about `CLIEnvelope`, and it is exercised black-box through the built binary.
//

import Foundation

enum CLIEnvelopeRenderer {

    /// Serialises an envelope to JSON text.
    ///
    /// Order of operations matters: encode, transform, then pretty-print.
    static func render(_ envelope: CLIEnvelope) throws -> String {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]

        let encoded = try encoder.encode(envelope)

        guard var object = try JSONSerialization.jsonObject(with: encoded) as? [String: Any] else {
            throw CLIJSONError.notAnObject
        }

        object = CLIJSONPresentation.omittingUnknownValues(object) as? [String: Any] ?? object
        object = CLIJSONPresentation.omittingUnreadFields(
            object, fields: envelope.notRead.map(\.field)
        )

        let data = try JSONSerialization.data(
            withJSONObject: object,
            options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        )

        guard let text = String(data: data, encoding: .utf8) else {
            throw CLIJSONError.notUTF8
        }
        return text
    }
}
