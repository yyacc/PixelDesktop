//
//  main.swift
//  PixelDesktopCLI
//
//  Phase 9 Step 1 — `pixel-desktop`.
//
//  A read-only publication interface over the existing PixelDesktop implementation.
//
//  WHAT IT IS
//  A thin access/presentation layer. It reads `PixelCapabilityContract` and
//  `PixelEvidenceReader` and prints JSON. It owns no capability logic, decides nothing,
//  retries nothing, and mutates nothing.
//
//  WHAT IT IS NOT
//  Not a second capability implementation, not an execution interface, not a service.
//  There is no HTTP, no socket, no daemon, no queue, no scheduler, no router, no resource
//  manager, and no retry loop. It is a process that runs, prints, and exits.
//
//  AUTHORITY
//  PixelDesktop remains the authority on what the Pixel can do. This process publishes what
//  PixelDesktop already concluded. Hermes consumes it and does not own it.
//
//  EXIT STATUS
//    0  success
//    1  structured failure (JSON error is still printed)
//    2  usage error (unknown command or flag)
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
        }
        emit(try CLIEnvelopeRenderer.render(envelope))
        return 0
    } catch {
        // A structured failure: the error taxonomy is preserved, and JSON is still emitted so a
        // consumer parses one shape for both outcomes. A failed observation never yields a
        // partially populated observation.
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
