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

// `CLIInvocation` names `InferenceRequest.InferenceBackend`, so it needs the same conditional
// import the other CLI files use: compiled into the tool target the shared sources are in the
// same module and this branch is skipped, while the test bundle compiles this file against the
// application module. Without it the test bundle cannot see `InferenceRequest` at all and the
// whole CLI suite stops compiling — which is how this was found.
#if canImport(PixelDesktop) && !PIXELDESKTOP_CLI_TOOL
@testable import PixelDesktop
#endif

/// The commands, and nothing else.
///
/// An unknown argument is a usage error rather than a silently ignored one — a typo must not
/// look like a successful run of a different command.
enum CLICommand: String, CaseIterable {
    case capability
    case observe
    case run
    case schedule

    static let usage = """
    pixel-desktop — read-only publication, one bounded execution, and one scheduled attempt

    USAGE
      pixel-desktop capability --json
      pixel-desktop observe --json
      pixel-desktop run --workload DTCA-1 --input-file <path> --json
      pixel-desktop run --workload LOCAL-LLM-1 --input-file <path> --json
      pixel-desktop schedule run <job-id> --json

    COMMANDS
      capability   Publish the static capability contract. No device required, no device I/O.
      observe      Publish a point-in-time observation of the connected device.
      run          Execute one bounded workload on the connected device and report the result,
      schedule     Make one attempt at one stored job. The clock belongs to launchd, not to this
                   command: it is invoked with a job id it did not choose, and it either runs the
                   job because it is due or reports that it is not.

    OPTIONS
      --json                  Emit JSON on stdout. Required.
      --workload <name>       (run) The workload to execute. Supported: DTCA-1, LOCAL-LLM-1.
      --input-file <path>     (run) Path to the UTF-8 input file. Read verbatim, never modified.
      --override-routing      (run) Request to proceed past soft routing conditions. A request,
                              never a force: the gate decides whether an override is available,
                              and hard failures stay blocked.
      --backend <id>          (run LOCAL-LLM-1) Which backend executes the tokens.
                              llama-jni (default) runs the worker's in-process llama.cpp with its
                              fixed Qwen artifact. llama-server-http delegates to the on-device
                              llama-server that is already running, which serves its own model.

    EXIT STATUS
      0 success · 1 structured failure · 2 usage error
    """
}

struct CLIInvocation: Equatable {
    let command: CLICommand
    let json: Bool
    let workload: String?
    let inputFile: String?
    /// Present only for `schedule run`. The job is named, never described: a caller cannot pass a
    /// cadence, an action, or a retry policy, because those are stored state the app owns.
    let jobID: UUID?
    /// Present only for `run --workload LOCAL-LLM-1`. Which backend the worker must use. Absent
    /// means the worker's in-process path, which is also what the wire form means.
    let backend: InferenceRequest.InferenceBackend?
    /// Present only for `run`. A *request* to proceed past soft routing conditions, never a force:
    /// the gate decides whether an override is even available, and hard failures stay blocked.
    let overrideRouting: Bool

    init(
        command: CLICommand,
        json: Bool,
        workload: String? = nil,
        inputFile: String? = nil,
        jobID: UUID? = nil,
        backend: InferenceRequest.InferenceBackend? = nil,
        overrideRouting: Bool = false
    ) {
        self.command = command
        self.json = json
        self.workload = workload
        self.inputFile = inputFile
        self.jobID = jobID
        self.backend = backend
        self.overrideRouting = overrideRouting
    }

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
        var backend: InferenceRequest.InferenceBackend?
        var overrideRouting = false

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
                case "--override-routing":
                    // A legitimate interactive affordance, deliberately not a forbidden flag. It
                    // requests an override; the gate still decides whether one is available.
                    overrideRouting = true
                    index += 1
                    continue

                case "--workload", "--input-file", "--backend":
                    guard index + 1 < arguments.count, !arguments[index + 1].hasPrefix("--") else {
                        return .failure(UsageError(message: "\(argument) requires a value"))
                    }
                    let value = arguments[index + 1]
                    if argument == "--workload" {
                        workload = value
                    } else if argument == "--input-file" {
                        inputFile = value
                    } else {
                        // Rejected by name, like the forbidden flags: a caller who types a
                        // backend this build does not implement must not be quietly given the
                        // default one, because the default runs a different model.
                        guard let parsed = InferenceRequest.InferenceBackend(rawValue: value) else {
                            let allowed = InferenceRequest.InferenceBackend.allCases
                                .map(\.rawValue).joined(separator: ", ")
                            return .failure(UsageError(
                                message: "'\(value)' is not a backend; expected one of: \(allowed)"))
                        }
                        backend = parsed
                    }
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

        // `schedule` is the one command with a sub-verb and an identifier. The identifier must be
        // the stored UUID: the job is looked up, never described, so a caller cannot name a cadence
        // or an action and cannot invent a job by describing one.
        if positionals.first == CLICommand.schedule.rawValue {
            guard positionals.count == 3, positionals[1] == "run" else {
                let given = positionals.joined(separator: " ")
                return .failure(UsageError(
                    message: "expected 'schedule run <job-id>', got '\(given)'"))
            }

            guard let jobID = UUID(uuidString: positionals[2]) else {
                return .failure(UsageError(
                    message: "'\(positionals[2])' is not a job id; pass the UUID the app shows "
                        + "for the job"))
            }

            guard flags == ["--json"] else {
                let given = flags.joined(separator: " ")
                return .failure(UsageError(message: "expected --json, got '\(given)'"))
            }

            if workload != nil || inputFile != nil || backend != nil || overrideRouting {
                return .failure(UsageError(
                    message: "--workload, --input-file, --backend and --override-routing apply only to 'run'"))
            }

            return .success(CLIInvocation(
                command: .schedule, json: true, workload: nil, inputFile: nil, jobID: jobID))
        }

        guard positionals.count == 1, let command = CLICommand(rawValue: positionals[0]) else {
            let given = positionals.joined(separator: " ")
            return .failure(UsageError(
                message: "expected exactly one command (capability|observe|run|schedule run), "
                    + "got '\(given)'"))
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
                command: command, json: true, workload: workload, inputFile: inputFile,
                jobID: nil, backend: backend, overrideRouting: overrideRouting))
        }

        if workload != nil || inputFile != nil || backend != nil || overrideRouting {
            return .failure(UsageError(
                message: "--workload, --input-file, --backend and --override-routing apply only to 'run'"))
        }

        return .success(CLIInvocation(
            command: command, json: true, workload: nil, inputFile: nil, jobID: nil))
    }
}
