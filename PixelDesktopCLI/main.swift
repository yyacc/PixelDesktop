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
//  There is no HTTP, no socket, no daemon, no queue, no router, no resource manager, no retry
//  policy, and no cancellation. It is a process that runs, prints, and exits.
//
//  ONE AMENDMENT (Phase 3.4 / C4): `schedule run <job-id>` exists, and the clock still does not.
//  launchd owns the schedule and decides when to fire; it invokes this process with a job id that
//  was stored by the app. The command cannot choose a cadence, describe an action, or ask to be
//  re-run later — a caller that could do any of those would be the scheduler, which this process
//  is not. `--scheduler` stays in `forbiddenFlags` for exactly that reason.
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
            let transport = ADBTransport()
            // Absent means the in-process backend, which is what an omitted wire key means on
            // the device too. The eligibility gate is wired to the same backend so the probe and
            // the model-presence policy cannot disagree with the request: the on-device server
            // probes its loopback port and skips the contract-model check; the in-process backend
            // has no endpoint to probe and must find the contract model present.
            let backend = invocation.backend ?? .inProcess
            let (result, failure) = try await CLIRunCommand.run(
                workload: invocation.workload ?? "",
                inputPath: invocation.inputFile ?? "",
                transport: transport,
                eligibility: DeviceExecutionEligibility(
                    transport: transport,
                    // Swift cannot address a static member on a protocol metatype, so the port
                    // constant — declared on `InferenceRuntime` — is reached via its concrete
                    // conformer rather than `InferenceRuntime.onDeviceServerPort`.
                    backendPort: backend == .onDeviceServer
                        ? LlamaCppInferenceRuntime.onDeviceServerPort : nil,
                    contractModelRequired: backend == .inProcess
                ),
                overrideRequested: invocation.overrideRouting,
                backend: backend
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

        case .schedule:
            // `jobID` is guaranteed non-nil by the parser for `schedule`.
            let report = try await CLIScheduleCommand.run(
                jobID: invocation.jobID ?? UUID(),
                transport: ADBTransport()
            )

            // A refused or failed attempt is a *result*, not an exception: the runner reached a
            // decision and recorded it. It is published with `ok: false` and the report's own exit
            // status, so launchd's log carries the reason instead of a bare non-zero code.
            envelope = CLIEnvelope(
                command: CLICommand.schedule.rawValue,
                ok: report.isSuccess,
                scheduledRun: report
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
