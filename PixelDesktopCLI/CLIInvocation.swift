//
//  CLIInvocation.swift
//  PixelDesktopCLI
//
//  Phase 9 Step 1 — argument parsing.
//
//  Kept out of `main.swift` so it can be compiled into the test bundle: Swift forbids
//  top-level expressions outside an executable's main file, so anything living in `main.swift`
//  is unreachable from tests.
//

import Foundation

/// The two commands, and nothing else.
///
/// An unknown argument is a usage error rather than a silently ignored one — a typo must not
/// look like a successful run of a different command.
enum CLICommand: String, CaseIterable {
    case capability
    case observe

    static let usage = """
    pixel-desktop — read-only publication of PixelDesktop capability and evidence

    USAGE
      pixel-desktop capability --json
      pixel-desktop observe --json

    COMMANDS
      capability   Publish the static capability contract. No device required, no device I/O.
      observe      Publish a point-in-time observation of the connected device.

    OPTIONS
      --json       Emit JSON on stdout. Required.

    EXIT STATUS
      0 success · 1 structured failure · 2 usage error
    """
}

struct CLIInvocation: Equatable {
    let command: CLICommand
    let json: Bool

    /// A usage failure. A dedicated type rather than `String`, because `Result`'s failure type
    /// must conform to `Error`.
    struct UsageError: Error, Equatable {
        let message: String
    }

    /// Parses argv, returning a reason on failure rather than printing directly, so the
    /// behaviour is testable.
    static func parse(_ arguments: [String]) -> Result<CLIInvocation, UsageError> {
        let flags = arguments.filter { $0.hasPrefix("--") }
        let positionals = arguments.filter { !$0.hasPrefix("--") }

        guard positionals.count == 1, let command = CLICommand(rawValue: positionals[0]) else {
            let given = positionals.joined(separator: " ")
            return .failure(UsageError(message: "expected exactly one command (capability|observe), got '\(given)'"))
        }

        guard flags == ["--json"] else {
            let given = flags.joined(separator: " ")
            return .failure(UsageError(message: "expected --json, got '\(given)'"))
        }

        return .success(CLIInvocation(command: command, json: true))
    }
}
