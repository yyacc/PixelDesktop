//
//  main.swift
//  PixelDesktopCLI
//
//  Phase 9 Step 1 / Step 4 — `pixel-desktop`.
//
//  A publication and execution interface over the existing PixelDesktop implementation.
//
//  WHAT IT IS
//  A thin access/presentation layer. `capability` and `observe` read the existing contract and
//  evidence types; `run` hands one bounded job to the existing E1 execution machinery. It owns no
//  capability logic, chooses no transport, decides no placement, retries nothing.
//
//  WHAT IT IS NOT
//  Not a second capability implementation, not a service, not an orchestration layer.
//  There is no HTTP, no socket, no daemon, no queue, no scheduler, no router, no resource
//  manager, no retry policy, and no cancellation. It is a process that runs, prints, and exits.
//
//  AUTHORITY
//  PixelDesktop remains the authority on what the Pixel can do and on how work reaches it. This
//  process publishes what PixelDesktop concluded, and executes what PixelDesktop is willing to
//  execute. Hermes consumes it and does not own it.
//
//  EXIT STATUS
//    0  success — a result was produced (for `run`: the workload completed)
//    1  structured failure (JSON error is still printed)
//    2  usage error (unknown command, unknown flag, or missing required argument)
//

import Foundation

func emit(_ text: String, to handle: FileHandle = .standardOutput) {
    handle.write(Data((text + "\n").utf8))
}

/// Runs a command, prints its envelope, and returns the process exit status.
func run(_ invocation: CLIInvocation) async -> Int32 {
    do {
        let envelope: CLIEnvelope
        switch invocation.command {
        case .capability:
            envelope = try CLICommands.capability()

        case .observe:
            envelope = try await CLICommands.observe(transport: ADBTransport())

        case .run:
            // `workload` and `inputFile` are guaranteed non-nil by the parser for `run`.
            let (result, failure) = try await CLIRunCommand.run(
                workload: invocation.workload ?? "",
                inputPath: invocation.inputFile ?? "",
                transport: ADBTransport()
            )

            // A worker refusal is a *result*, not an exception: the execution machinery ran and
            // reported what happened. It is published with its structured error and a non-zero
            // exit status, so a caller can distinguish it from success without parsing prose.
            envelope = CLIEnvelope(
                command: "run",
                ok: failure == nil,
                result: result,
                error: failure.map(CLIErrorPayload.init)
            )
        }

        emit(try CLIEnvelopeRenderer.render(envelope))
        return envelope.ok ? 0 : 1

    } catch {
        // A structured failure: the error taxonomy is preserved, and JSON is still emitted so a
        // consumer parses one shape for both outcomes. A failed command never yields a partially
        // populated payload.
        let typed = (error as? PixelDesktopError) ?? .unknown(error.localizedDescription)
        let envelope = CLIEnvelope(
            command: invocation.command.rawValue,
            ok: false,
            error: CLIErrorPayload(typed)
        )

        if let text = try? CLIEnvelopeRenderer.render(envelope) {
            emit(text)
        } else {
            emit("pixel-desktop: could not encode error envelope", to: .standardError)
        }
        return 1
    }
}

// `main.swift` is the only file permitted top-level code, so the entry point lives here.
// `@main` cannot be used in a file named `main.swift`.
let arguments = Array(CommandLine.arguments.dropFirst())

switch CLIInvocation.parse(arguments) {
case .failure(let reason):
    emit("pixel-desktop: \(reason.message)", to: .standardError)
    emit(CLICommand.usage, to: .standardError)
    exit(2)
case .success(let invocation):
    let status = await run(invocation)
    exit(status)
}
