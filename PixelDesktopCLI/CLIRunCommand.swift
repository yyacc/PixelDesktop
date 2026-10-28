//
//  CLIRunCommand.swift
//  PixelDesktopCLI
//
//  Phase 9 Step 4 — one bounded execution command.
//
//  WHAT THIS IS
//  A thin invocation boundary. It resolves a workload, reads and validates an input file, builds
//  the existing job, and hands it to the **existing** E1 execution machinery
//  (`WorkerStreamRunner`). It adds no execution architecture of its own.
//
//  WHAT IT IS NOT
//  Not a scheduler, queue, retry policy, resource manager, or router. It runs exactly one job,
//  once, and reports what happened. It chooses nothing: the transport, the device, the job-file
//  path, and the Activity are PixelDesktop's business and are not caller-visible.
//
//  WHY THE CALLER CANNOT NAME A DEVICE OR A PATH
//  `shell()`, `push`, `pull`, `install`, and `am start` are transport primitives. Exposing any of
//  them would let a caller construct an arbitrary device operation, which is the containment
//  failure ADR-009 and ADR-007 §A1.12 exist to prevent. The caller supplies a workload and input,
//  and nothing else.
//

import Foundation

// This file is compiled into two different modules: the `pixel-desktop` tool (where the shared
// PixelDesktop sources are in the *same* module, so no import is needed) and the test bundle
// (where they are a separate module). The conditional keeps both compiling from one source file
// rather than forking a test-only copy that could drift.
#if canImport(PixelDesktop) && !PIXELDESKTOP_CLI_TOOL
// `@testable` rather than a plain import: the shared types are `internal`, so a plain import
// would find the module but not the types. In the tool target this branch is not compiled at all
// (the shared sources are in the same module there).
@testable import PixelDesktop
#endif

enum CLIRunCommand {

    /// The workloads this command exposes.
    ///
    /// Deliberately a fixed set rather than a registry. `LOCAL-LLM-1` requires a provisioned
    /// model and is not exactly verifiable, so it is gated behind the same preflight checks
    /// as DTCA-1. A workload that is not in this set is a usage error, not an unimplemented
    /// feature.
    static let supportedWorkloads: Set<String> = [DTCA1Job.workloadName, LlmJob.workloadName]

    // MARK: - Input

    /// Reads and validates the input file.
    ///
    /// Validation is delegated to the workload's **own** validator. Restating DTCA-1's rules here
    /// would create a second definition that can drift from the one the worker enforces — the
    /// same failure Phase 7 Amendment 2 corrected in the contract.
    ///
    /// The input is read verbatim. It is not trimmed, truncated, normalised, or otherwise
    /// modified: a caller's input is what the workload receives, and silent alteration would make
    /// the result unverifiable against what was actually submitted.
    ///
    /// - Throws: `invalidInput` when the file cannot be read or the workload rejects its contents.
    static func loadInput(from path: String, workload: String) throws -> String {
        let text = try readText(from: path)

        // The workload owns its own limits. Nothing is duplicated here.
        if workload == DTCA1Job.workloadName {
            try DTCA1Worker.validateInput(text)
        }
        // LOCAL-LLM-1 is not resolved here: its input may be a request envelope rather than a bare
        // prompt, so `run` goes through `loadInferenceInput`, which applies the InferenceRequest's
        // own validator to the prompt it resolves.
        return text
    }

    /// Reads a UTF-8 input file verbatim. Shared by both workloads so the failure modes are
    /// described in exactly one place.
    static func readText(from path: String) throws -> String {
        let url = URL(fileURLWithPath: (path as NSString).expandingTildeInPath)

        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            throw PixelDesktopError.invalidInput(
                "Could not read input file '\(path)': \(error.localizedDescription)")
        }

        guard let text = String(data: data, encoding: .utf8) else {
            throw PixelDesktopError.invalidInput(
                "Input file '\(path)' is not valid UTF-8 text")
        }
        return text
    }

    // MARK: - LOCAL-LLM-1 input

    /// The generated-token budget used when a caller does not ask for one.
    ///
    /// 128, not the 32 this boundary used to hardcode: 32 cut ordinary answers off mid-sentence,
    /// which is indistinguishable from a broken model. It is a *generation* budget and nothing
    /// else — it never touches the server's `-c` context size — and
    /// `InferenceRequest.maximumTokensCeiling` still caps what any caller may request.
    static let defaultMaxTokens = 128

    /// A resolved LOCAL-LLM-1 input: the text the model receives and the budget it may spend.
    struct ResolvedInferenceInput: Equatable {
        let prompt: String
        let maxTokens: Int
    }

    /// Reads a LOCAL-LLM-1 input file and resolves it into a prompt plus an output-length budget.
    ///
    /// Two accepted forms, one field location — the envelope is the **top level** of the file:
    ///
    ///   - `{"prompt": "...", "max_tokens": 256}` — a request envelope. `prompt` must be a string
    ///     for the file to be treated as one; `max_tokens` is optional and defaults to
    ///     `defaultMaxTokens`.
    ///   - anything else — the file is the prompt, verbatim, exactly as before. A file that is
    ///     JSON but has no string `prompt` key stays a prompt, so existing inputs, and prompts
    ///     that happen to be JSON, are unaffected.
    ///
    /// Bounds are the request's own (`InferenceRequest.validate()`), never a second copy, and they
    /// run here so an invalid value is rejected before any device I/O or job id is minted.
    static func loadInferenceInput(from path: String) throws -> ResolvedInferenceInput {
        let text = try readText(from: path)
        let resolved = try resolveInferenceInput(text: text, path: path)
        do {
            try InferenceRequest(
                jobId: LlmJob.newJobId(),
                prompt: resolved.prompt,
                maxTokens: resolved.maxTokens,
                temperature: 0.0,
                seed: 0
            ).validate()
        } catch let rejection as InferenceRequestError {
            throw PixelDesktopError.invalidInput("Input file '\(path)': \(rejection.description)")
        }
        return resolved
    }

    /// The envelope rules, separated from file I/O so they are testable without a temporary file.
    static func resolveInferenceInput(text: String, path: String) throws -> ResolvedInferenceInput {
        guard text.drop(while: { $0.isWhitespace }).first == "{" else {
            return ResolvedInferenceInput(prompt: text, maxTokens: defaultMaxTokens)
        }

        do {
            let envelope = try JSONDecoder().decode(RequestEnvelope.self, from: Data(text.utf8))
            return ResolvedInferenceInput(
                prompt: envelope.prompt,
                maxTokens: envelope.max_tokens ?? defaultMaxTokens)
        } catch DecodingError.keyNotFound {
            // A JSON object with no `prompt` key is a prompt that happens to be JSON, not a
            // malformed envelope: keep the pre-existing behaviour rather than rejecting it.
            return ResolvedInferenceInput(prompt: text, maxTokens: defaultMaxTokens)
        } catch let DecodingError.typeMismatch(_, context) {
            let field = context.codingPath.last?.stringValue ?? "prompt"
            throw PixelDesktopError.invalidInput(
                "Input file '\(path)': '\(field)' has the wrong type — 'prompt' must be a string "
                + "and 'max_tokens' a whole number")
        } catch {
            throw PixelDesktopError.invalidInput(
                "Input file '\(path)': could not read the request envelope "
                + "(\(error.localizedDescription))")
        }
    }

    /// The envelope's shape. Typed decoding is what rejects `"max_tokens": true` and `64.5`
    /// instead of letting them coerce.
    private struct RequestEnvelope: Decodable {
        let prompt: String
        let max_tokens: Int?
    }

    // MARK: - Execution

    /// Runs one DTCA-1 job through the existing E1 machinery.
    ///
    /// The sequence is deliberately the same one `WorkerStreamRunner`'s own callers use, with no
    /// additional layer:
    ///
    /// ```
    /// resolve workload → read+validate input → preflight → build job → WorkerStreamRunner.run
    ///   → durable result → ownership check → decode → structured outcome
    /// ```
    ///
    /// - Throws: only for conditions that prevent *starting* or that make the device unusable.
    ///   A worker refusal is **not** thrown — it is returned as a structured outcome, because a
    ///   refusal is a result the caller must be able to reason about, not an exception.
    static func run(
        workload: String,
        inputPath: String,
        transport: TransportProtocol,
        eligibility: any ExecutionEligibilityEvaluating,
        overrideRequested: Bool = false,
        backend: InferenceRequest.InferenceBackend = .inProcess
    ) async throws -> (result: CLIRunResult, error: PixelDesktopError?) {

        guard supportedWorkloads.contains(workload) else {
            throw PixelDesktopError.invalidInput(
                "Unsupported workload '\(workload)'. This interface exposes: \(supportedWorkloads.sorted().joined(separator: ", ")).")
        }

        // The prompt and the output-length budget, resolved once and used by every path below.
        // LOCAL-LLM-1's input may be a request envelope; every other workload's input is the
        // document itself.
        let input: String
        let maxTokens: Int
        if workload == LlmJob.workloadName {
            let resolved = try loadInferenceInput(from: inputPath)
            input = resolved.prompt
            maxTokens = resolved.maxTokens
        } else {
            input = try loadInput(from: inputPath, workload: workload)
            maxTokens = defaultMaxTokens  // not part of this workload's contract; unused below
        }

        // Device selection is PixelDesktop's, not the caller's. This reuses the same rule the
        // application applies (device → unauthorized → offline → not found).
        let serial = try await CLIDeviceSelection.connectedSerial(transport: transport)

        // Preflight. These produce typed errors the caller can act on, rather than being
        // discovered as an opaque stream failure. `installedState` reports absence as a state
        // rather than an error, so it is translated here into the error that describes it.
        let installed = try await WorkerInstaller(transport: transport)
            .installedState(deviceSerial: serial)
        guard installed.isInstalled else {
            throw PixelDesktopError.workerError(
                "Worker package \(WorkerTransferContract.workerPackageName) is not installed on the device")
        }

        // The E1 device script fails with NO_WORKSPACE if this directory is absent, and adb must
        // not create it (ADR-010 — ownership). Surfacing it here names the cause instead of
        // leaving the caller to interpret a stream error.
        let workspace = try await transport.shell(
            deviceSerial: serial,
            command: WorkerTransferContract.remoteWorkspaceExistsCommand,
            timeout: 30
        )
        guard workspace.stdout.contains("EXISTS") else {
            throw PixelDesktopError.workerError(
                "Worker exchange directory does not exist at \(WorkerTransferContract.remoteRoot); "
                + "the worker must be launched once to create it")
        }

        // The routing gate. It runs after device selection and preflight — a "worker not
        // installed" is more actionable than a routing verdict — and before any job id is minted
        // or any file is staged: a blocked run never reaches the worker.
        let requirement: ExecutionRequirement =
            workload == LlmJob.workloadName ? .inference : .deviceRead
        let decision = await eligibility.decide(
            deviceSerial: serial,
            requirement: requirement,
            context: .interactive
        )

        let routingDecision: RoutingDecision
        if decision.isPermitted {
            routingDecision = decision
        } else if decision.outcome == .requiresOverride, overrideRequested,
                  let overridden = decision.overridden(by: .interactive) {
            routingDecision = overridden
        } else {
            // `.rejected` and `.deferred` are never overridable — hard failures and an unhealthy
            // backend block even when an override is requested. A `.requiresOverride` without an
            // explicit request blocks too.
            throw PixelDesktopError.routingBlocked(decision)
        }

        // The existing job representation and the existing id rules. No second format.
        let jobId: String
        let payload: String
        let expectedSuccessToken: String

        if workload == DTCA1Job.workloadName {
            jobId = DTCA1Job.newJobId()
            let job = DTCA1Job(jobId: jobId, input: input)
            payload = try job.encoded()
            expectedSuccessToken = DTCA1Job.successResultToken
        } else {
            jobId = LlmJob.newJobId()
            let request = InferenceRequest(
                jobId: jobId,
                prompt: input,
                maxTokens: maxTokens,
                temperature: 0.0,
                seed: 0,
                backend: backend
            )
            let job = LlmJob(request: request)
            payload = try job.encoded()
            expectedSuccessToken = LlmJob.successResultToken
        }

        // The proven E1 path, unchanged.
        let runner = WorkerStreamRunner(transport: transport)
        let run = try await runner.run(deviceSerial: serial, jobId: jobId, payload: payload)

        // The durable result is authoritative. Decode it and confirm it belongs to this job
        // before reporting anything: a result file from a previous run is indistinguishable by
        // name alone, so the id echo is the ownership check (D9).
        let decoded = try decodeResult(from: run.outcome, jobId: jobId,
                                      expectedSuccessToken: expectedSuccessToken)

        let result = CLIRunResult(
            workload: workload,
            jobId: jobId,
            outcome: run.outcome,
            run: run,
            output: decoded.output,
            inferenceOutput: decoded.inferenceOutput,
            workerRefusal: decoded.refusal,
            routing: routingDecision
        )

        // A worker-reported refusal takes precedence over the stream outcome: the stream may have
        // completed cleanly while the *job* failed. The reducer does not inspect the payload, so
        // without this the refusal would be reported as a success — which is exactly what the
        // first version of this did, and what the tests caught.
        return (result, decoded.refusal ?? CLIRunResult.error(for: run.outcome))
    }

    /// What a decoded result payload yielded: a completed output, a refusal, or neither.
    struct DecodedResult {
        let output: DTCA1Result?
        let inferenceOutput: InferenceResult?
        let refusal: PixelDesktopError?
    }

    /// Decodes the result payload from the outcome, verifying ownership.
    ///
    /// - Throws: `verificationFailed` when a payload exists but does not belong to this job, or
    ///   cannot be decoded. A payload that cannot be parsed is never trusted (ADR-004).
    /// The published success token for the workload being run, read from the caller-supplied
    /// token rather than looked up by name.
    ///
    /// The CLI resolves DTCA-1 only (the `run` command rejects any other workload up front), so the
    /// token is the one DTCA-1 owns. The lookup is therefore passed through by the caller rather
    /// than performed here: this keeps the *decode* boundary free of workload-name knowledge.
    ///
    /// - Parameter expectedSuccessToken: supplied by `run`, sourced from the workload's own
    ///   constant (`DTCA1Job.successResultToken`) rather than restated here.
    static func decodeResult(
        from outcome: WorkerStreamOutcome,
        jobId: String,
        expectedSuccessToken: String
    ) throws -> DecodedResult {
        let json: String
        switch outcome {
        case .completed(let payload, _), .recoveredFromDevice(let payload, _):
            json = payload
        case .completedButDurabilityUnverified(let payload, _):
            // A payload exists, so decode it for the report — but the outcome is not treated as
            // success, and the durability caveat travels in the error.
            json = payload
        default:
            return DecodedResult(output: nil, inferenceOutput: nil, refusal: nil)
        }

        guard WorkerStreamRunner.resultBelongsToJob(json, jobId: jobId) else {
            throw PixelDesktopError.verificationFailed(
                reason: "Result does not belong to job \(jobId); refusing a stale or foreign result")
        }

        guard let data = json.data(using: .utf8) else {
            throw PixelDesktopError.verificationFailed(reason: "Result payload is not valid UTF-8")
        }

        let envelope: WorkerResultEnvelope
        do {
            envelope = try JSONDecoder().decode(WorkerResultEnvelope.self, from: data)
        } catch {
            throw PixelDesktopError.verificationFailed(
                reason: "Result is not a valid worker envelope: \(error.localizedDescription)")
        }

        // Phase 9 Step 6: when the expected success token is LOCAL-LLM-1's ("OK"), attempt to
        // decode as InferenceResult. This routes the LLM result shape through the CLI boundary
        // without executing LOCAL-LLM-1. The WorkerResultEnvelope decode above succeeds because
        // both shapes share the same wire keys for status and job_id; the InferenceResult decode
        // is what distinguishes the LLM payload (text, token_ids, generated_tokens, etc.).
        if expectedSuccessToken == InferenceResult.successResultToken,
           let inferenceResult = try? JSONDecoder().decode(InferenceResult.self, from: data),
           inferenceResult.status == .ok {
            return DecodedResult(output: nil, inferenceOutput: inferenceResult, refusal: nil)
        }

        // A FAILED envelope is a reported refusal carrying the worker's own structured category.
        // It is not a completed payload, and it is not a generic error: the category must survive
        // so a caller can tell MODEL_MISSING from INVALID_INPUT.
        //
        // The success token is supplied by the caller from the workload's own constant
        // (Phase 7 Amendment 3) — this boundary compares, it does not decide.
        guard envelope.isCompleted(expectedSuccessToken: expectedSuccessToken) else {
            return DecodedResult(output: nil, inferenceOutput: nil, refusal: envelope.refusal)
        }

        return DecodedResult(
            output: try envelope.asDTCA1Result(expectedSuccessToken: expectedSuccessToken),
            inferenceOutput: nil,
            refusal: nil)
    }
}
