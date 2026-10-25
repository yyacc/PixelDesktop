//
//  InferenceRuntime.swift
//  PixelDesktop
//
//  Phase 6 — Local AI Worker.
//
//  The runtime adapter boundary. ADR-012 requires the rest of PixelDesktop to be able to
//  replace llama.cpp with LiteRT-LM, ExecuTorch, or ONNX Runtime without touching anything
//  outside this file and its one concrete implementation.
//
//  Deliberately NOT a plugin system and NOT a runtime registry. One protocol, one concrete
//  type, one job shape. ADR-012 forbids building an inference framework here.
//

import Foundation

/// The identity of an inference runtime, recorded in evidence so a result can be attributed to
/// a specific runtime rather than to "inference" in the abstract.
///
/// The Android worker (`LlamaBridge.nativeRuntimeInfo`) returns runtime identity as a single
/// string: `"llama.cpp a868c3e backend=cpu"`. This type decodes both that legacy string form
/// and the structured object form, so a result from either worker shape is accepted without
/// requiring an Android-side change.
struct InferenceRuntimeIdentity: Equatable, Codable, Sendable {
    /// Short stable name, e.g. `llama.cpp`.
    let name: String
    /// The runtime's own version or the commit it was built from.
    let version: String
    /// The compute backend actually used. Phase 6 is CPU-only by decision (ADR-012 §11).
    let backend: String

    /// Memberwise initializer. Required because the presence of a custom `init(from:)`
    /// suppresses Swift's automatic memberwise initializer synthesis.
    init(name: String, version: String, backend: String) {
        self.name = name
        self.version = version
        self.backend = backend
    }

    static let llamaCppCPU = InferenceRuntimeIdentity(
        name: "llama.cpp",
        version: LlamaCppRuntime.pinnedVersion,
        backend: "cpu"
    )

    /// Decodes from either a legacy string (`"llama.cpp a868c3e backend=cpu"`) or a
    /// structured object (`{"name":..., "version":..., "backend":...}`).
    ///
    /// The string form is the one the current worker emits; the object form is the one
    /// this type's `Codable` synthesis would normally expect. Supporting both keeps the
    /// decode boundary tolerant of worker versions without requiring the worker to change.
    init(from decoder: Decoder) throws {
        if let container = try? decoder.singleValueContainer(),
           let stringValue = try? container.decode(String.self) {
            // Legacy string form: "llama.cpp a868c3e backend=cpu"
            // Split into [name, version, key=value]
            let parts = stringValue.split(separator: " ", maxSplits: 2, omittingEmptySubsequences: true)
            if parts.count == 3, String(parts[2]).starts(with: "backend=") {
                self.name = String(parts[0])
                self.version = String(parts[1])
                self.backend = String(String(parts[2]).dropFirst("backend=".count))
            } else {
                // Fall back: everything is the name, version/backend unknown
                self.name = stringValue
                self.version = "unknown"
                self.backend = "unknown"
            }
            return
        }

        // Structured object form
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.name = try container.decode(String.self, forKey: .name)
        self.version = try container.decode(String.self, forKey: .version)
        self.backend = try container.decode(String.self, forKey: .backend)
    }

    /// Encodes as a structured object. The worker only sends the string form, so this
    /// direction is used only if the type is ever re-encoded on the Mac side (not currently).
    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(name, forKey: .name)
        try container.encode(version, forKey: .version)
        try container.encode(backend, forKey: .backend)
    }

    private enum CodingKeys: String, CodingKey {
        case name, version, backend
    }
}

/// A single bounded generation request.
///
/// This is intentionally tiny. ADR-012 §6: no conversation, no tools, no memory, no RAG, no
/// network. One prompt in, a bounded number of tokens out.
struct InferenceRequest: Equatable, Codable, Sendable {
    /// Echoed back in the result so a stale result cannot be mistaken for a fresh one.
    let jobId: String
    let prompt: String
    /// Hard ceiling on generated tokens. The worker must not become unbounded.
    let maxTokens: Int
    /// Greedy decoding is requested with `temperature == 0`. Recorded explicitly so the
    /// result can be read as "greedy was requested" rather than "greedy was achieved" —
    /// ADR-012 R4 requires that distinction to be measured, not assumed.
    let temperature: Double
    let seed: Int

    /// Which backend the worker must use to produce the generation.
    ///
    /// `LOCAL-LLM-1` is one workload with two ways to compute it: the worker's in-process
    /// llama.cpp with its fixed Qwen artifact, or the on-device llama-server, which serves whatever
    /// model it was started with. The choice is a *request* property rather than a worker build
    /// property, so a caller can ask for a specific model without a second APK.
    ///
    /// Defaults to `.inProcess`, and the default is omitted from the wire, so a request written
    /// before this field existed is byte-identical to one written after. The worker's own default
    /// is the same value, which is what makes that safe rather than merely convenient.
    let backend: InferenceBackend

    /// Backend ids as the worker spells them. Raw values are the wire values.
    enum InferenceBackend: String, Codable, Sendable, Equatable, CaseIterable {
        /// In-process llama.cpp in the worker APK; model is the fixed Qwen artifact.
        case inProcess = "llama-jni"
        /// Delegates generation to the already-running on-device llama-server over loopback.
        case onDeviceServer = "llama-server-http"
    }

    init(
        jobId: String,
        prompt: String,
        maxTokens: Int,
        temperature: Double,
        seed: Int,
        backend: InferenceBackend = .inProcess
    ) {
        self.jobId = jobId
        self.prompt = prompt
        self.maxTokens = maxTokens
        self.temperature = temperature
        self.seed = seed
        self.backend = backend
    }

    /// Explicit wire keys. **Not** decorative — the synthesized encoding would emit `jobId` and
    /// `maxTokens`, and the Android worker reads `job_id` and `max_tokens`
    /// (`LlmWorkload.execute`). A missing `max_tokens` is not an error on the device: the worker
    /// falls back to its own default of 32 and reports no complaint, so the Mac would silently
    /// receive a different request than the one it validated. Stating the keys here is what makes
    /// the request self-describing rather than accidentally correct.
    ///
    /// The Swift property names are unchanged: this maps the wire spelling onto the semantic API,
    /// not the other way round.
    enum CodingKeys: String, CodingKey {
        case jobId = "job_id"
        case prompt
        case maxTokens = "max_tokens"
        case temperature
        case seed
        case backend
    }

    /// Decoded with the default when the key is absent. This is what lets a job document written
    /// before the backend field existed decode to the same request it always meant.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        jobId = try container.decode(String.self, forKey: .jobId)
        prompt = try container.decode(String.self, forKey: .prompt)
        maxTokens = try container.decode(Int.self, forKey: .maxTokens)
        temperature = try container.decode(Double.self, forKey: .temperature)
        seed = try container.decode(Int.self, forKey: .seed)
        backend = try container.decodeIfPresent(InferenceBackend.self, forKey: .backend)
            ?? .inProcess
    }

    /// Encoded with `backend` omitted while it is the default, so the wire form of an
    /// in-process request does not change. A non-default backend is always stated explicitly —
    /// an omitted key must never be able to mean "the other one".
    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(jobId, forKey: .jobId)
        try container.encode(prompt, forKey: .prompt)
        try container.encode(maxTokens, forKey: .maxTokens)
        try container.encode(temperature, forKey: .temperature)
        try container.encode(seed, forKey: .seed)
        if backend != .inProcess {
            try container.encode(backend, forKey: .backend)
        }
    }

    static let maximumPromptCharacters = 4096
    static let maximumTokensCeiling = 256

    /// Validates the request before any device work happens.
    ///
    /// Mirrors the D8 lesson: reject locally what can be rejected locally, rather than
    /// discovering the problem on the device.
    func validate() throws {
        if jobId.isEmpty {
            throw InferenceRequestError.emptyJobId
        }
        if prompt.isEmpty {
            throw InferenceRequestError.emptyPrompt
        }
        if prompt.count > Self.maximumPromptCharacters {
            throw InferenceRequestError.promptTooLong(
                actual: prompt.count, maximum: Self.maximumPromptCharacters)
        }
        if maxTokens <= 0 {
            throw InferenceRequestError.invalidMaxTokens(maxTokens)
        }
        if maxTokens > Self.maximumTokensCeiling {
            throw InferenceRequestError.maxTokensTooLarge(
                actual: maxTokens, maximum: Self.maximumTokensCeiling)
        }
        if temperature != 0.0 {
            throw InferenceRequestError.nonGreedyRequested(temperature)
        }
    }
}

enum InferenceRequestError: Error, Equatable, CustomStringConvertible {
    case emptyJobId
    case emptyPrompt
    case promptTooLong(actual: Int, maximum: Int)
    case invalidMaxTokens(Int)
    case maxTokensTooLarge(actual: Int, maximum: Int)
    case nonGreedyRequested(Double)

    var description: String {
        switch self {
        case .emptyJobId:
            return "job_id is empty"
        case .emptyPrompt:
            return "prompt is empty"
        case .promptTooLong(let actual, let maximum):
            return "prompt is \(actual) characters, maximum is \(maximum)"
        case .invalidMaxTokens(let value):
            return "max_tokens must be positive, got \(value)"
        case .maxTokensTooLarge(let actual, let maximum):
            return "max_tokens is \(actual), ceiling is \(maximum)"
        case .nonGreedyRequested(let value):
            return "Phase 6 requires greedy decoding (temperature 0), got \(value)"
        }
    }
}

/// What the worker reports back. Every field is evidence, not decoration.
struct InferenceResult: Equatable, Codable, Sendable {
    let jobId: String
    let status: Status
    /// Generated text. **Not** a correctness claim — see ADR-012 §P7.
    let text: String
    /// The token ids actually emitted, so a repeated run can be compared token-for-token
    /// rather than string-for-string. Greedy stability is measured (R4), not assumed.
    let tokenIds: [Int]
    let generatedTokens: Int
    let promptTokens: Int

    // Timings, in milliseconds, as measured on the device.
    let modelLoadMs: Int
    let promptEvalMs: Int
    let generationMs: Int
    let totalMs: Int

    let runtime: InferenceRuntimeIdentity
    let modelFile: String
    let modelSha256: String

    /// Context window the runtime actually allocated, reported back from the live context.
    ///
    /// Optional because it is a Phase 7 addition to the envelope: an older worker build omits it,
    /// and an absent value must not be read as zero. The capability contract falls back to a
    /// `.declared` value when this is nil, and says so.
    let contextSizeTokens: Int?

    /// The model's own maximum trained context. A property of the model, not of our
    /// configuration — the two differ (2048 allocated vs 32768 trained) and both are useful.
    let trainedContextSizeTokens: Int?

    /// The status token `LlmWorkload.java` writes for a **successful** inference (`"OK"`).
    ///
    /// Published by the capability contract for `LOCAL-LLM-1`, so the success token is owned by the
    /// workload that produces it rather than assumed by the boundary that decodes it.
    ///
    /// Failure is deliberately **not** modelled this way: every workload's failure is written by
    /// `WorkerActivity` as `"FAILED"` with `error_type` / `error_message`. The failure token is
    /// genuinely worker-wide and stays generic.
    static let successResultToken = "OK"

    enum Status: String, Codable, Sendable {
        case ok = "OK"
        case failed = "FAILED"
    }

    enum CodingKeys: String, CodingKey {
        case jobId = "job_id"
        case status
        case text
        case tokenIds = "token_ids"
        case generatedTokens = "generated_tokens"
        case promptTokens = "prompt_tokens"
        case modelLoadMs = "model_load_ms"
        case promptEvalMs = "prompt_eval_ms"
        case generationMs = "generation_ms"
        case totalMs = "total_ms"
        case runtime
        case modelFile = "model_file"
        case modelSha256 = "model_sha256"
        case contextSizeTokens = "context_size_tokens"
        case trainedContextSizeTokens = "trained_context_size_tokens"
    }

    /// Tokens per second, derived from generation time only.
    ///
    /// Returns nil rather than a misleading number when generation was too fast to measure
    /// meaningfully — the same discipline applied to D8's CPU-tick claim.
    var tokensPerSecond: Double? {
        guard generationMs > 0, generatedTokens > 0 else { return nil }
        return Double(generatedTokens) / (Double(generationMs) / 1000.0)
    }

    /// True when this result carries no generation at all, which a stale or default result
    /// would exhibit.
    var isUsableGeneration: Bool {
        status == .ok && !text.isEmpty
    }
}

/// The runtime adapter boundary.
///
/// Two operations only. ADR-012 §2: expose the minimum needed for this proof, nothing more.
protocol InferenceRuntime: Sendable {
    var identity: InferenceRuntimeIdentity { get }

    /// The workload name this runtime answers to, so a job cannot be silently routed to the
    /// wrong executor.
    var workloadName: String { get }

    /// Validates a request without touching the device.
    func validate(_ request: InferenceRequest) throws

    /// The device-local loopback port the on-device `llama-server` listens on.
    ///
    /// A protocol requirement (rather than an extension-only member) so it is reachable as
    /// `InferenceRuntime.onDeviceServerPort` from the CLI, which names the protocol rather than
    /// a concrete runtime.
    static var onDeviceServerPort: Int { get }
}

extension InferenceRuntime {
    /// The device-local loopback port the on-device `llama-server` listens on.
    ///
    /// Named once here so the routing gate's backend-health probe and the CLI wiring agree with
    /// the worker's own endpoint (`HttpInferenceBackend.ENDPOINT`,
    /// `http://127.0.0.1:8080/v1/chat/completions`). The literal must not be scattered through
    /// code that has to match it. `AppState.llamaServerPort` keeps its own name for the app's
    /// server lifecycle and is deliberately not referenced here.
    static var onDeviceServerPort: Int { 8080 }
}

/// llama.cpp, pinned. The version string is part of the evidence chain: a result is only
/// meaningful alongside the runtime that produced it.
enum LlamaCppRuntime {
    /// The exact upstream commit this build was taken from.
    static let pinnedVersion = "a868c3e"

    /// ADR-012 §11: CPU only for the first proof. Vulkan is available on this device and is
    /// deliberately NOT enabled here, so the chain
    /// `Pixel -> APK native runtime -> GGUF -> CPU inference` stays independently
    /// understandable. This is a decision, not a limitation of the device.
    static let backend = "cpu"
}

/// Concrete CPU-only llama.cpp adapter.
///
/// The macOS side does not link llama.cpp at all: inference happens on the Pixel, and this
/// type's job is to describe the contract, not to compute. That is deliberate — it keeps the
/// Mac incapable of accidentally producing the result it is meant to verify.
struct LlamaCppInferenceRuntime: InferenceRuntime {
    let identity = InferenceRuntimeIdentity.llamaCppCPU
    let workloadName = "LOCAL-LLM-1"

    func validate(_ request: InferenceRequest) throws {
        try request.validate()
    }
}
