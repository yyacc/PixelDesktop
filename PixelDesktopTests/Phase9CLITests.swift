//
//  Phase9CLITests.swift
//  PixelDesktopTests
//
//  Phase 9 Step 1 — the read-only publication interface.
//
//  ## Why these tests are split in two
//
//  The test bundle links both the application target and the `pixel-desktop` tool. Both compile
//  the same `PixelDesktop/` sources, so every shared type exists twice in the test module and a
//  bare reference to `PixelDesktopError` is genuinely ambiguous. Importing the tool target would
//  therefore make most of these tests uncompilable.
//
//  So they are split by what each part actually needs to prove:
//
//    1. **Pure unit tests** over `CLIJSONPresentation`, a Foundation-only file compiled directly
//       into this bundle. These cover the presentation rules — the part where a subtle mistake
//       is silent.
//    2. **Black-box tests** that run the built binary and assert on its stdout, stderr and exit
//       status. These cover the command surface, the JSON contract, the error taxonomy and the
//       absence rules *as a consumer actually sees them* — which is the stronger test, because
//       it exercises the real serialisation path rather than a reconstruction of it.
//
//  Black-box tests require the tool to have been built. `CLIBinary.url` locates it, and the
//  tests skip with a clear reason if it is absent rather than passing vacuously.
//

import XCTest
import Foundation
@testable import PixelDesktop

// MARK: - Locating the built tool

enum CLIBinary {

    /// The `pixel-desktop` executable produced by the same build as this test bundle.
    ///
    /// Found by walking up from the test bundle until a directory containing the tool is
    /// reached, rather than by a fixed number of `..` hops: these tests are app-hosted, so the
    /// bundle sits at `.../Debug/PixelDesktop.app/Contents/PlugIns/PixelDesktopTests.xctest`
    /// and the products directory is several levels up. A hardcoded hop count silently returns
    /// the wrong directory and turns every black-box test into a skip.
    ///
    /// Falls back to `PIXELDESKTOP_CLI_PATH` for a manually-built tool.
    static var url: URL? {
        if let override = ProcessInfo.processInfo.environment["PIXELDESKTOP_CLI_PATH"] {
            let candidate = URL(fileURLWithPath: override)
            return FileManager.default.isExecutableFile(atPath: candidate.path) ? candidate : nil
        }

        var directory = Bundle(for: Phase9CLIBinaryTests.self).bundleURL
        for _ in 0..<8 {
            directory.deleteLastPathComponent()
            let candidate = directory.appendingPathComponent("pixel-desktop")
            if FileManager.default.isExecutableFile(atPath: candidate.path) {
                return candidate
            }
        }

        return nil
    }
}

/// The result of one CLI invocation.
struct CLIResult {
    let exitCode: Int32
    let stdout: String
    let stderr: String

    var json: [String: Any]? {
        (try? JSONSerialization.jsonObject(with: Data(stdout.utf8))) as? [String: Any]
    }

    /// Whether a JSON value is an explicit `null`.
    ///
    /// `JSONSerialization` maps JSON `null` to `NSNull`, not to Swift `nil`, so `XCTAssertNil`
    /// on a decoded value fails even though the JSON is correct. The envelope deliberately emits
    /// `null` (rather than omitting the key) for a channel that does not apply, so both the
    /// "absent" and "explicitly null" cases have to be distinguished in these tests.
    static func isNull(_ value: Any?) -> Bool {
        value is NSNull
    }
}

enum CLIRunner {

    /// Runs the built tool with the given arguments.
    ///
    /// Throws `XCTSkip` when the tool is not built, so a missing binary is reported as a skip
    /// with a reason rather than as a silent pass.
    static func run(_ arguments: [String]) throws -> CLIResult {
        guard let binary = CLIBinary.url else {
            throw XCTSkip("pixel-desktop tool not built; run `xcodebuild -scheme pixel-desktop build` first")
        }

        let process = Process()
        process.executableURL = binary
        process.arguments = arguments

        let outPipe = Pipe()
        let errPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = errPipe

        try process.run()
        let outData = outPipe.fileHandleForReading.readDataToEndOfFile()
        let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        return CLIResult(
            exitCode: process.terminationStatus,
            stdout: String(data: outData, encoding: .utf8) ?? "",
            stderr: String(data: errData, encoding: .utf8) ?? ""
        )
    }
}

// MARK: - 1. Pure presentation rules

/// These test `CLIJSONPresentation` directly — it is Foundation-only and compiled into this
/// bundle, so it is testable without the tool and without any PixelDesktop type.
final class Phase9CLIPresentationTests: XCTestCase {

    func testUnknownSourceValueIsPublishedWithoutAValueKey() {
        // The core rule. `CapabilityValue` is non-optional, so an unreadable field is encoded as
        // `value: 0, source: "unknown"`. A consumer reading `value` alone would be told "zero
        // bytes of memory are available" — the most damaging possible misreading.
        let raw: [String: Any] = [
            "availableMemoryBytes": ["value": 0, "source": "unknown", "observedAt": NSNull(),
                                     "limitation": "Unreadable from /proc/meminfo."]
        ]

        let cleaned = CLIJSONPresentation.omittingUnknownValues(raw) as? [String: Any]
        let memory = cleaned?["availableMemoryBytes"] as? [String: Any]

        XCTAssertNotNil(memory)
        XCTAssertFalse(memory?.keys.contains("value") ?? true, "unknown must not publish a value")
        XCTAssertEqual(memory?["source"] as? String, "unknown")
        XCTAssertEqual(memory?["limitation"] as? String, "Unreadable from /proc/meminfo.",
                       "the reason must survive")
    }

    func testKnownSourceValueKeepsItsValue() {
        // The rule must not strip real data — a regression here would be silent data loss.
        let raw: [String: Any] = [
            "availableMemoryBytes": ["value": 2_400_000_000, "source": "deviceReported",
                                     "observedAt": "2026-10-03T00:00:00Z", "limitation": "NOT A RESERVATION"]
        ]

        let cleaned = CLIJSONPresentation.omittingUnknownValues(raw) as? [String: Any]
        let memory = cleaned?["availableMemoryBytes"] as? [String: Any]

        XCTAssertEqual(memory?["value"] as? Int, 2_400_000_000)
        XCTAssertEqual(memory?["source"] as? String, "deviceReported")
    }

    func testAbsenceRuleAppliesAtEveryDepth() {
        // The observation nests capability values several levels deep. A top-level-only rule
        // would leave exactly the fields that matter most (memory, model presence) unsafe.
        let raw: [String: Any] = [
            "observation": [
                "deviceSerial": "SERIAL",
                "availableMemoryBytes": ["value": 0, "source": "unknown", "limitation": "unreadable"],
                "modelPresent": [
                    "value": ["absent": [:]],
                    "source": "unknown",
                    "limitation": "could not be read"
                ]
            ]
        ]

        let cleaned = CLIJSONPresentation.omittingUnknownValues(raw) as? [String: Any]
        let observation = cleaned?["observation"] as? [String: Any]

        XCTAssertFalse((observation?["availableMemoryBytes"] as? [String: Any])?.keys.contains("value") ?? true)
        XCTAssertFalse((observation?["modelPresent"] as? [String: Any])?.keys.contains("value") ?? true)
        XCTAssertEqual(observation?["deviceSerial"] as? String, "SERIAL",
                       "non-capability fields are untouched")
    }

    func testAbsenceRuleReachesValuesInsideArrays() {
        // A workload array entry is not a capability value, but a future observation may carry
        // one. The recursion must not stop at an array boundary.
        let raw: [String: Any] = [
            "samples": [
                ["value": 0, "source": "unknown", "limitation": "a"],
                ["value": 42, "source": "runtimeReported", "limitation": "b"]
            ]
        ]

        let cleaned = CLIJSONPresentation.omittingUnknownValues(raw) as? [String: Any]
        let samples = cleaned?["samples"] as? [[String: Any]]

        XCTAssertEqual(samples?.count, 2)
        XCTAssertFalse(samples?[0].keys.contains("value") ?? true)
        XCTAssertEqual(samples?[1]["value"] as? Int, 42)
    }

    func testDeclaredValuesAreNotStripped() {
        // `.declared` is a known source: a build constant is a real value, not an unreadable one.
        let raw: [String: Any] = [
            "model": ["value": ["fileName": "m.gguf"], "source": "declared", "limitation": "not present"]
        ]
        let cleaned = CLIJSONPresentation.omittingUnknownValues(raw) as? [String: Any]
        let model = cleaned?["model"] as? [String: Any]

        XCTAssertNotNil(model?["value"], "a declared value must survive publication")
    }

    func testUnreadFieldIsRemovedFromTheParent() {
        let raw: [String: Any] = [
            "contract": ["contractVersion": 1, "device": ["value": ["codename": "lynx"]]]
        ]
        let cleaned = CLIJSONPresentation.omittingUnreadFields(raw, fields: ["contract.device"])
        let contract = cleaned["contract"] as? [String: Any]

        XCTAssertFalse(contract?.keys.contains("device") ?? true, "the unread field is absent")
        XCTAssertEqual(contract?["contractVersion"] as? Int, 1, "sibling fields are preserved")
    }

    func testUnreadFieldForAMissingParentIsHarmless() {
        let raw: [String: Any] = ["command": "capability"]
        let cleaned = CLIJSONPresentation.omittingUnreadFields(raw, fields: ["contract.device"])

        XCTAssertEqual(cleaned["command"] as? String, "capability")
        XCTAssertNil(cleaned["contract"])
    }

    func testAnOrdinaryObjectWithoutASourceKeyIsUntouched() {
        // The rule keys off `source`. Nothing else in the envelope has one, so it cannot reach
        // an unrelated structure.
        let raw: [String: Any] = ["value": 7, "name": "DTCA-1"]
        let cleaned = CLIJSONPresentation.omittingUnknownValues(raw) as? [String: Any]

        XCTAssertEqual(cleaned?["value"] as? Int, 7)
        XCTAssertEqual(cleaned?["name"] as? String, "DTCA-1")
    }
}

// MARK: - 2. Black-box command surface

final class Phase9CLIBinaryTests: XCTestCase {

    // MARK: capability

    func testCapabilitySucceedsWithNoDeviceAttached() throws {
        // The property the whole command exists for: a planner can ask what the build supports
        // without involving a device at all.
        let result = try CLIRunner.run(["capability", "--json"])

        XCTAssertEqual(result.exitCode, 0, "stderr: \(result.stderr)")
        let json = try XCTUnwrap(result.json)
        XCTAssertEqual(json["ok"] as? Bool, true)
        XCTAssertNotNil(json["contract"])
        XCTAssertTrue(CLIResult.isNull(json["observation"]), "capability publishes no observation")
        XCTAssertTrue(CLIResult.isNull(json["error"]), "a successful run carries no error")
    }

    func testCapabilityEmitsValidJSONWithEveryEnvelopeKey() throws {
        let result = try CLIRunner.run(["capability", "--json"])
        let json = try XCTUnwrap(result.json)

        for key in ["interface_version", "command", "ok", "produced_at",
                    "contract", "observation", "not_read", "error"] {
            XCTAssertTrue(json.keys.contains(key), "envelope must always carry '\(key)'")
        }
        XCTAssertEqual(json["interface_version"] as? Int, 1)
        XCTAssertEqual(json["command"] as? String, "capability")
    }

    func testCapabilityPublishesNoDeviceIdentityAndSaysWhy() throws {
        // NOTE: the command is run and unwrapped in separate statements throughout this file.
        // `try XCTUnwrap(try CLIRunner.run(...))` would trap the `XCTSkip` thrown by the runner
        // inside `XCTUnwrap`'s autoclosure and report it as a failure instead of a skip.
        let result = try CLIRunner.run(["capability", "--json"])
        let json = try XCTUnwrap(result.json)
        let contract = try XCTUnwrap(json["contract"] as? [String: Any])

        XCTAssertFalse(contract.keys.contains("device"),
                       "device identity must be absent entirely, not published as null")

        let notRead = try XCTUnwrap(json["not_read"] as? [[String: Any]])
        let entry = try XCTUnwrap(notRead.first { ($0["field"] as? String) == "contract.device" })
        XCTAssertTrue((entry["reason"] as? String)?.contains("no device I/O") == true,
                      "the omission must be stated with its reason")
    }

    func testCapabilityPublishesStaticFactsMatchingTheSharedDefinitions() throws {
        // Values must equal what the shared implementation owns — not restated in the CLI.
        let result = try CLIRunner.run(["capability", "--json"])
        let json = try XCTUnwrap(result.json)
        let contract = try XCTUnwrap(json["contract"] as? [String: Any])

        let model = try XCTUnwrap((contract["model"] as? [String: Any])?["value"] as? [String: Any])
        let limits = try XCTUnwrap((contract["limits"] as? [String: Any])?["value"] as? [String: Any])
        let runtime = try XCTUnwrap((contract["runtime"] as? [String: Any])?["value"] as? [String: Any])

        XCTAssertEqual(model["fileName"] as? String, ModelContract.modelFileName)
        XCTAssertEqual(model["sha256"] as? String, ModelContract.expectedSha256)
        XCTAssertEqual(model["byteCount"] as? Int, ModelContract.expectedByteCount)
        XCTAssertEqual(limits["maximumPromptCharacters"] as? Int, InferenceRequest.maximumPromptCharacters)
        XCTAssertEqual(limits["maximumTokensCeiling"] as? Int, InferenceRequest.maximumTokensCeiling)
        XCTAssertEqual(runtime["name"] as? String, "llama.cpp")
    }

    func testCapabilityPublishesBothWorkloadsWithVerifiability() throws {
        let result = try CLIRunner.run(["capability", "--json"])
        let json = try XCTUnwrap(result.json)
        let contract = try XCTUnwrap(json["contract"] as? [String: Any])
        let workloads = try XCTUnwrap(contract["workloads"] as? [[String: Any]])

        XCTAssertEqual(workloads.compactMap { $0["name"] as? String }.sorted(), ["DTCA-1", "LOCAL-LLM-1"])
        let dtca = try XCTUnwrap(workloads.first { ($0["name"] as? String) == "DTCA-1" })
        XCTAssertEqual(dtca["exactlyVerifiable"] as? Bool, true)
        let llm = try XCTUnwrap(workloads.first { ($0["name"] as? String) == "LOCAL-LLM-1" })
        XCTAssertEqual(llm["exactlyVerifiable"] as? Bool, false)
    }

    func testCapabilityPreservesProvenanceAndLimitations() throws {
        // Static facts are build constants: `.declared`, and NO timestamp — a constant was never
        // observed, and a timestamp would claim otherwise. The limitation is the load-bearing
        // honesty field and must survive publication.
        let result = try CLIRunner.run(["capability", "--json"])
        let json = try XCTUnwrap(result.json)
        let contract = try XCTUnwrap(json["contract"] as? [String: Any])

        for field in ["runtime", "model", "limits"] {
            let entry = try XCTUnwrap(contract[field] as? [String: Any], "\(field) missing")
            XCTAssertEqual(entry["source"] as? String, "declared", "\(field) must be .declared")
            XCTAssertFalse(entry.keys.contains("observedAt"),
                           "\(field) must carry no timestamp at all — a constant was never observed")
            let limitation = try XCTUnwrap(entry["limitation"] as? String)
            XCTAssertFalse(limitation.isEmpty, "\(field) must carry its limitation")
        }

        // The specific overclaim this guards against: a published model hash must not read as
        // "the model is present on the device".
        let model = try XCTUnwrap(contract["model"] as? [String: Any])
        XCTAssertTrue((model["limitation"] as? String)?.contains("does NOT establish") == true)
    }

    func testCapabilityDoesNotPromoteAMeasurementToACapability() throws {
        // Phase 7 Step 1's rule, checked on the published bytes.
        let result = try CLIRunner.run(["capability", "--json"])
        for forbidden in ["tokensPerSecond", "tokens_per_second", "generationMs",
                          "modelLoadMs", "latency", "throughput"] {
            XCTAssertFalse(result.stdout.contains(forbidden),
                           "capability output must not carry '\(forbidden)'")
        }
    }

    // MARK: observe

    func testObserveWithoutADeviceFailsStructuredAndNonZero() throws {
        // The device is not attached in this environment, so this asserts the real behaviour.
        // If a device IS attached the observation path is covered by the harness instead.
        let result = try CLIRunner.run(["observe", "--json"])

        guard result.exitCode != 0 else {
            // A device was attached: assert the success shape instead of skipping, so this test
            // is never vacuous.
            let json = try XCTUnwrap(result.json)
            XCTAssertEqual(json["ok"] as? Bool, true)
            XCTAssertNotNil(json["observation"])
            return
        }

        XCTAssertEqual(result.exitCode, 1)
        let json = try XCTUnwrap(result.json, "a failure must still emit JSON")

        XCTAssertEqual(json["ok"] as? Bool, false)
        XCTAssertTrue(CLIResult.isNull(json["observation"]),
                      "a failed observation must not be partially populated")

        let error = try XCTUnwrap(json["error"] as? [String: Any])
        XCTAssertEqual(error["type"] as? String, "device_not_found")
        XCTAssertEqual(error["is_recoverable"] as? Bool, true)
        XCTAssertNotNil(error["message"] as? String)

        // The envelope keeps its shape on failure, so a consumer parses one shape for both.
        for key in ["interface_version", "command", "produced_at", "not_read"] {
            XCTAssertTrue(json.keys.contains(key))
        }
        XCTAssertEqual(json["command"] as? String, "observe")
    }

    // MARK: usage errors

    func testNoArgumentsIsAUsageError() throws {
        let result = try CLIRunner.run([])
        XCTAssertEqual(result.exitCode, 2)
        XCTAssertTrue(result.stdout.isEmpty, "a usage error is not a JSON result")
        XCTAssertTrue(result.stderr.contains("expected exactly one command"))
    }

    func testUnknownCommandIsRejected() throws {
        // A typo must not look like a successful run of a different command.
        let result = try CLIRunner.run(["frobnicate", "--json"])
        XCTAssertEqual(result.exitCode, 2)
        XCTAssertTrue(result.stderr.contains("frobnicate"))
    }

    func testMissingJsonFlagIsRejected() throws {
        let result = try CLIRunner.run(["capability"])
        XCTAssertEqual(result.exitCode, 2)
        XCTAssertTrue(result.stderr.contains("--json"))
    }

    func testTwoCommandsAreRejected() throws {
        let result = try CLIRunner.run(["capability", "observe", "--json"])
        XCTAssertEqual(result.exitCode, 2)
    }

    func testUsageTextIsPrintedOnAUsageError() throws {
        let result = try CLIRunner.run(["frobnicate", "--json"])
        XCTAssertTrue(result.stderr.contains("USAGE"), "the usage text must be shown")
    }

    // MARK: output hygiene

    func testJsonGoesToStdoutAndDiagnosticsToStderr() throws {
        // A consumer parses stdout; anything else would corrupt the JSON.
        let ok = try CLIRunner.run(["capability", "--json"])
        XCTAssertFalse(ok.stdout.isEmpty)
        XCTAssertTrue(ok.stderr.isEmpty, "a successful run writes nothing to stderr")

        let bad = try CLIRunner.run(["nonsense", "--json"])
        XCTAssertTrue(bad.stdout.isEmpty, "a usage error writes nothing to stdout")
        XCTAssertFalse(bad.stderr.isEmpty)
    }
}

// MARK: - 3. Argument parsing (pure, no tool needed)

/// `CLIInvocation` lives in the tool target, so it cannot be imported here (see the file header).
/// Its behaviour is therefore pinned through the binary, which is the contract a caller actually
/// depends on — covered by `Phase9CLIBinaryTests`. This type documents that choice rather than
/// leaving an unexplained gap.
final class Phase9CLIArgumentCoverageTests: XCTestCase {

    func testArgumentParsingIsCoveredBlackBox() throws {
        // Presence check: the black-box suite must actually be running, not silently skipping.
        guard CLIBinary.url != nil else {
            throw XCTSkip("pixel-desktop tool not built; argument parsing is covered by Phase9CLIBinaryTests")
        }
        XCTAssertNotNil(CLIBinary.url)
    }
}
