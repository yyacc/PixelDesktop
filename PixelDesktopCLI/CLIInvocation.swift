//
//  CLIInvocation.swift
//  PixelDesktopCLI
//
//  Phase 9 Step 1 / Step 4 — argument parsing.
//
//  Kept out of `main.swift` so it can be compiled into the test bundle: Swift forbids
//  top-level expressions outside an executable's main file, so anything living in `main.swift`
//  is unreachable from tests.
//

import Foundation

/// The commands, and nothing else.
///
/// An unknown argument is a usage error rather than a silently ignored one — a typo must not
/// look like a successful run of a different command.
enum CLICommand: String, CaseIterable {
    case capability
    case observe
    case run

    static let usage = """
    pixel-desktop — read-only publication, and one bounded execution

    USAGE
      pixel-desktop capability --json
      pixel-desktop observe --json
      pixel-desktop run --workload DTCA-1 --input-file <path> --json

    COMMANDS
      capability   Publish the static capability contract. No device required, no device I/O.
      observe      Publish a point-in-time observation of the connected device.
      run          Execute one bounded workload on the connected device and report the result.

    OPTIONS
      --json                  Emit JSON on stdout. Required.
      --workload <name>       (run) The workload to execute. Currently exactly one is supported.
      --input-file <path>     (run) Path to the UTF-8 input file. Read verbatim, never modified.

    EXIT STATUS
      0 success · 1 structured failure · 2 usage error
    """
}

struct CLIInvocation: Equatable {
    let command: CLICommand
    let json: Bool
    let workload: String?
    let inputFile: String?

    /// A usage failure. A dedicated type rather than `String`, because `Result`'s failure type
    /// must conform to `Error`.
    struct UsageError: Error, Equatable {
        let message: String
    }

    /// Flags that would let a caller name a transport primitive, a device, or an execution
    /// policy. None of these is part of the interface, and rejecting them **by name** is
    /// deliberate: silently ignoring `--device` would leave a caller believing it had selected a
    /// device, which is a worse outcome than a refusal.
    static let forbiddenFlags: Set<String> = [
        "--device", "--serial", "--shell", "--activity", "--path",
        "--timeout", "--retry", "--queue", "--scheduler", "--cancel",
        "--push", "--pull", "--install", "--stop", "--adb",
    ]

    /// Parses argv, returning a reason on failure rather than printing directly, so the
    /// behaviour is testable.
    static func parse(_ arguments: [String]) -> Result<CLIInvocation, UsageError> {
        var positionals: [String] = []
        var flags: [String] = []
        var workload: String?
        var inputFile: String?

        var index = 0
        while index < arguments.count {
            let argument = arguments[index]

            if argument.hasPrefix("--") {
                if forbiddenFlags.contains(argument) {
                    return .failure(UsageError(
                        message: "'\(argument)' is not part of this interface; PixelDesktop chooses "
                            + "the device, transport, and execution mechanism"))
                }

                switch argument {
                case "--workload", "--input-file":
                    guard index + 1 < arguments.count, !arguments[index + 1].hasPrefix("--") else {
                        return .failure(UsageError(message: "\(argument) requires a value"))
                    }
                    if argument == "--workload" { workload = arguments[index + 1] }
                    else { inputFile = arguments[index + 1] }
                    index += 2
                    continue

                default:
                    flags.append(argument)
                }
            } else {
                positionals.append(argument)
            }

            index += 1
        }

        guard positionals.count == 1, let command = CLICommand(rawValue: positionals[0]) else {
            let given = positionals.joined(separator: " ")
            return .failure(UsageError(
                message: "expected exactly one command (capability|observe|run), got '\(given)'"))
        }

        guard flags == ["--json"] else {
            let given = flags.joined(separator: " ")
            return .failure(UsageError(message: "expected --json, got '\(given)'"))
        }

        // `--workload` and `--input-file` are required by `run` and meaningless elsewhere. A
        // caller passing them to another command has misunderstood the interface, so it is a
        // usage error rather than a silent no-op.
        if command == .run {
            guard let workload else {
                return .failure(UsageError(message: "run requires --workload"))
            }
            guard let inputFile else {
                return .failure(UsageError(message: "run requires --input-file"))
            }
            return .success(CLIInvocation(
                command: command, json: true, workload: workload, inputFile: inputFile))
        }

        if workload != nil || inputFile != nil {
            return .failure(UsageError(message: "--workload and --input-file apply only to 'run'"))
        }

        return .success(CLIInvocation(command: command, json: true, workload: nil, inputFile: nil))
    }
}
