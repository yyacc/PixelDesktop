//
//  PixelCapabilityContract.swift
//  PixelDesktop
//
//  Phase 7 Step 1 — the Pixel capability contract.
//
//  WHAT THIS IS
//  A small, versioned, machine-readable description of what the Pixel compute node can actually
//  support. It exists so Hermes can plan against the Pixel without hardcoding facts like
//  "the Pixel has X GB" or "the Pixel runs at Z tokens/sec".
//
//  WHAT THIS IS NOT
//  It is NOT a security boundary, NOT a router, and NOT a planner.
//
//  Hermes decides. PixelDesktop enforces. This contract is the informational input to Hermes's
//  decision; PixelDesktop independently validates every actual request before execution
//  regardless of what this contract said. A stale or wrong value here costs a rejected request
//  and an extra round trip — never unsafe execution.
//  (ADR-007 Amendment 1 §A1.5, §A1.6.)
//
//  SOURCES OF TRUTH
//  Every field is DERIVED from an existing authoritative definition, never restated:
//
//    device identity / ABI  ->  AndroidDevice, DeviceCapabilities
//    runtime + backend      ->  InferenceRuntimeIdentity, LlamaCppRuntime
//    model name / hash / size ->  ModelContract
//    request limits         ->  InferenceRequest
//    workload names         ->  LlamaCppInferenceRuntime.workloadName, DTCA1Job.workloadName
//    context size           ->  the native runtime (kContextSize), reported back over JNI
//
//  Adding a value here that is also defined elsewhere would create a second source of truth.
//  The type is deliberately constructed *from* those sources instead.
//

import Foundation

// MARK: - Provenance

/// Where a value came from, and how much it can be trusted.
///
/// The distinction is the point: a value read from the device is stronger evidence than a value
/// declared in source, and the contract must not present them as equivalent.
enum CapabilitySource: String, Codable, Equatable, Sendable {
    /// A compile-time constant in this project. Authoritative for what we *intend* to run, but
    /// it describes our build, not the device's current reality.
    case declared

    /// Read from the connected device at observation time. Stronger than `.declared`.
    case deviceReported

    /// Reported by the inference runtime itself. Strongest for runtime behaviour: it describes
    /// what is actually in use, not what we configured.
    case runtimeReported

    /// Not established. Present so an unknown is visible rather than absent.
    case unknown
}

/// A value together with where it came from.
///
/// Wrapping rather than embedding keeps provenance impossible to drop accidentally: a consumer
/// cannot read the value without also having access to its source.
struct CapabilityValue<Value: Codable & Equatable & Sendable>: Codable, Equatable, Sendable {
    let value: Value
    let source: CapabilitySource

    /// When the value was observed. `nil` for `.declared` values, which are not observations.
    let observedAt: Date?

    /// What this value does NOT establish. Every non-trivial field states one.
    let limitation: String?

    init(value: Value, source: CapabilitySource, observedAt: Date? = nil, limitation: String? = nil) {
        self.value = value
        self.source = source
        self.observedAt = observedAt
        self.limitation = limitation
    }

    /// A compile-time constant from this project.
    static func declared(_ value: Value, limitation: String? = nil) -> Self {
        Self(value: value, source: .declared, observedAt: nil, limitation: limitation)
    }

    /// A value read from the device.
    static func deviceReported(_ value: Value, at date: Date = Date(), limitation: String? = nil) -> Self {
        Self(value: value, source: .deviceReported, observedAt: date, limitation: limitation)
    }

    /// A value reported by the runtime.
    static func runtimeReported(_ value: Value, at date: Date = Date(), limitation: String? = nil) -> Self {
        Self(value: value, source: .runtimeReported, observedAt: date, limitation: limitation)
    }
}

// MARK: - Availability

/// Whether something can actually be executed right now.
///
/// Four states, not two. "We do not know" is a distinct and honest answer, and collapsing it into
/// either supported or unsupported would be a false claim in one direction or the other.
enum CapabilityAvailability: String, Codable, Equatable, Sendable {
    /// Established as executable, and the prerequisites are present.
    case supported

    /// Established as NOT executable. This is a fact, not a guess — e.g. a workload whose runtime
    /// or model is absent by design, or a model class measured to exceed available memory.
    case unsupported

    /// Supported in principle, but a prerequisite is currently missing: device disconnected,
    /// worker not installed, model not provisioned.
    ///
    /// Distinct from `.unsupported`: this can become `.supported` without any code change.
    case unavailable

    /// Not established. Used where no measurement or documentation exists.
    case unknown

    /// True only when execution is actually possible right now.
    var isExecutable: Bool { self == .supported }
}

// MARK: - The contract

/// The static half: what this build of PixelDesktop can execute on a Pixel, and with what.
///
/// "Static" means it changes only when the worker, runtime, or model is redeployed — not per
/// invocation. Dynamic state (is the device connected? is the model present?) is deliberately
/// NOT here; it belongs in an observation, not in a contract.
struct PixelCapabilityContract: Codable, Equatable, Sendable {

    /// Version of the contract SHAPE, not of its contents.
    ///
    /// Bumped when a field is added, removed, or changes meaning, so a consumer can detect a
    /// contract it does not understand rather than silently misreading it.
    ///
    /// - 1 → initial shape (Phase 7 Step 1).
    /// - 2 → `Workload.maximumInputCharacters` added (Phase 7 Amendment 2). A consumer that reads
    ///   workload input bounds must check for version 2; under version 1 those bounds are not
    ///   published, and the contract-wide `limits.maximumPromptCharacters` is the LLM's limit
    ///   rather than a bound that applies to every workload.
    static let currentVersion = 2

    let contractVersion: Int

    // MARK: Device

    /// Stable device properties, from `AndroidDevice` (Phases 2–3).
    struct DeviceIdentity: Codable, Equatable, Sendable {
        let codename: String
        let marketingName: String
        let manufacturer: String
        let androidVersion: String
        let apiLevel: Int
        let architecture: String
        let supportedABIs: [String]
    }

    // MARK: Runtime

    /// The inference runtime, from `InferenceRuntimeIdentity` + `LlamaCppRuntime`.
    struct RuntimeIdentity: Codable, Equatable, Sendable {
        let name: String
        let version: String
        /// The compute backend in use. Phase 6 chose CPU deliberately (ADR-012 §11) — this is a
        /// decision, not a hardware limitation, and the contract says so via `limitation`.
        let backend: String
        /// The model format the runtime consumes. Recorded so a consumer knows what a swap
        /// would involve, without the contract naming a specific model file.
        let modelFormat: String
    }

    // MARK: Model

    /// The provisioned model, from `ModelContract`.
    struct ModelIdentity: Codable, Equatable, Sendable {
        let fileName: String
        let sha256: String
        let byteCount: Int
        /// Total context window the runtime is configured with, in tokens.
        ///
        /// Sourced from the native runtime, which owns `kContextSize`. It is reported back over
        /// JNI rather than duplicated as a Swift constant — a second definition would be a second
        /// source of truth and could drift from what the runtime actually allocates.
        let contextSizeTokens: CapabilityValue<Int>
        /// The model's own maximum trained context, when the runtime reports it. This is a
        /// property of the model, NOT of our configuration; the two differ and both are useful.
        let trainedContextSizeTokens: CapabilityValue<Int>?
    }

    // MARK: Limits

    /// Hard request limits that already exist in the request path.
    ///
    /// These are not new policy — they are the existing `InferenceRequest` validation limits,
    /// published so a planner can respect them instead of discovering them by refusal.
    struct RequestLimits: Codable, Equatable, Sendable {
        let maximumPromptCharacters: Int
        let maximumTokensCeiling: Int
        let maximumModelBytes: Int
    }

    // MARK: Workloads

    /// A workload this build can execute, and the availability of its prerequisites.
    struct Workload: Codable, Equatable, Sendable {
        /// Stable workload name, as it appears in a job envelope.
        let name: String
        /// Whether this workload requires a provisioned model.
        let requiresModel: Bool
        /// Whether the runtime needs to load a model to run it.
        let requiresRuntime: Bool
        /// Whether the output can be verified exactly by re-computation on the Mac.
        ///
        /// `DTCA-1` is deterministic, so it can. `LOCAL-LLM-1` cannot — generative output is not
        /// bit-reproducible across implementations, and Phase 6 replaced re-computation with an
        /// evidence chain (ADR-012 §P7). A consumer that assumed exact verification for every
        /// workload would be wrong, so the contract states it per workload.
        let exactlyVerifiable: Bool

        /// The maximum input characters **this workload's own validator** accepts.
        ///
        /// ## Why this is per workload and not a contract-wide field
        ///
        /// The workloads do not share an input bound. `DTCA-1` is a deterministic text workload
        /// whose specification caps input at 10,000 characters; `LOCAL-LLM-1` is a bounded
        /// generation request capped at 4,096. Those are different components' constraints, and
        /// neither is derived from the other.
        ///
        /// `RequestLimits.maximumPromptCharacters` is the **LLM runtime's** request limit
        /// (`InferenceRequest`). Reading it as a bound that applies to every workload would
        /// understate DTCA-1's real capacity by more than half — a planner would be needlessly
        /// restrictive for no reason. That is why the bound lives here, on the workload that owns
        /// it, and why the two must not be conflated.
        ///
        /// Optional: a workload whose validator does not expose a bound publishes `.unknown`, and
        /// the value key is then absent rather than zero (see the absence rule). A workload that
        /// genuinely accepts unbounded input would be a different and more serious statement than
        /// "the bound is not published", so the two are kept distinct.
        let maximumInputCharacters: CapabilityValue<Int>?
    }

    let device: CapabilityValue<DeviceIdentity>
    let runtime: CapabilityValue<RuntimeIdentity>
    let model: CapabilityValue<ModelIdentity>
    let limits: CapabilityValue<RequestLimits>
    let workloads: [Workload]

    // MARK: Construction

    /// Builds the contract from the existing authoritative definitions.
    ///
    /// Every argument is a value the project already owns. Nothing is invented here.
    ///
    /// - Parameters:
    ///   - device: the connected device, from `AndroidDevice`.
    ///   - contextSize: reported by the runtime where available; otherwise the declared constant
    ///     is used and marked `.declared` so its weaker provenance is visible.
    static func build(
        device: AndroidDevice,
        contextSize: CapabilityValue<Int>,
        trainedContextSize: CapabilityValue<Int>? = nil,
        observedAt date: Date = Date()
    ) -> PixelCapabilityContract {

        let identity = DeviceIdentity(
            codename: device.deviceCodename,
            marketingName: device.marketingName,
            manufacturer: device.manufacturer,
            androidVersion: device.androidVersion,
            apiLevel: device.apiLevel,
            architecture: device.architecture,
            supportedABIs: device.supportedABIs
        )

        // Runtime identity comes from the existing adapter, not from a new constant.
        let runtimeAdapter = LlamaCppInferenceRuntime()
        let runtimeIdentity = RuntimeIdentity(
            name: runtimeAdapter.identity.name,
            version: runtimeAdapter.identity.version,
            backend: runtimeAdapter.identity.backend,
            modelFormat: "GGUF"
        )

        let modelIdentity = ModelIdentity(
            fileName: ModelContract.modelFileName,
            sha256: ModelContract.expectedSha256,
            byteCount: ModelContract.expectedByteCount,
            contextSizeTokens: contextSize,
            trainedContextSizeTokens: trainedContextSize
        )

        let requestLimits = RequestLimits(
            maximumPromptCharacters: InferenceRequest.maximumPromptCharacters,
            maximumTokensCeiling: InferenceRequest.maximumTokensCeiling,
            maximumModelBytes: ModelContract.maximumModelBytes
        )

        return PixelCapabilityContract(
            contractVersion: Self.currentVersion,
            device: .deviceReported(identity, at: date, limitation:
                "Stable properties only. Not a statement of current load, thermal state, or "
                + "available memory — those are dynamic and belong to an observation."),
            runtime: .declared(runtimeIdentity, limitation:
                "Describes what this build ships, not what is installed on the device. "
                + "Backend is CPU by decision (ADR-012 §11), not by hardware limitation: Vulkan "
                + "compute is available on this device and deliberately unused."),
            model: .declared(modelIdentity, limitation:
                "Describes the artifact this build expects. It does NOT establish that the model "
                + "is present on the device — provisioning is verified separately."),
            limits: .declared(requestLimits, limitation:
                "The LLM runtime's own request limits (InferenceRequest). They apply to "
                + "LOCAL-LLM-1, NOT to every workload — each workload's input bound is published "
                + "on that workload as maximumInputCharacters. Reading this as a bound that "
                + "applies to DTCA-1 would understate its real capacity."),
            workloads: [
                Workload(name: DTCA1Job.workloadName, requiresModel: false,
                         requiresRuntime: false, exactlyVerifiable: true,
                         maximumInputCharacters: .declared(
                            DTCA1Worker.maximumInputCharacters,
                            limitation: "Owned by the DTCA-1 validator that enforces it "
                                + "(DTCA1Worker.validateInput), not restated here. DTCA-1 also "
                                + "rejects null bytes, which this bound does not express.")),
                Workload(name: LlamaCppInferenceRuntime().workloadName, requiresModel: true,
                         requiresRuntime: true, exactlyVerifiable: false,
                         maximumInputCharacters: .declared(
                            InferenceRequest.maximumPromptCharacters,
                            limitation: "Owned by InferenceRequest.validate(), which also caps "
                                + "generated tokens separately (see limits.maximumTokensCeiling).")),
            ]
        )
    }

    /// The context size this build declares when the runtime cannot be asked.
    ///
    /// Marked `.declared` at the call site so a consumer can tell it apart from a runtime-reported
    /// value. It is the fallback, not the preferred answer.
    static let declaredContextSizeTokens = 2048

    /// Builds the context-size field, preferring a value the runtime actually reported.
    ///
    /// `kContextSize` in `llama_jni.cpp` is the single definition of this limit. Asking the
    /// runtime what it allocated is how that definition is observed from outside the native
    /// layer, so the contract describes what is in use rather than restating a constant.
    ///
    /// - Parameter runtimeReported: the `n_ctx_in_use` value from the native model report, or
    ///   `nil`/`0` when no context was established.
    static func contextSize(
        runtimeReported: Int?,
        at date: Date = Date()
    ) -> CapabilityValue<Int> {
        if let reported = runtimeReported, reported > 0 {
            return .runtimeReported(reported, at: date, limitation:
                "The context window the runtime allocated. A prompt plus max_tokens exceeding "
                + "this is refused with a bounded error. NOTE: the runtime also has a much "
                + "smaller per-call batch bound whose violation was measured to abort the "
                + "process rather than return an error (FAIL-005); that bound is not published "
                + "here because the worker now chunks internally to respect it.")
        }
        return .declared(declaredContextSizeTokens, limitation:
            "DECLARED, not observed: the runtime was not asked, so this is what this build "
            + "intends to allocate. Treat as provisional until confirmed by a runtime report. "
            + "This is a fallback, NOT the authoritative value — the native kContextSize is.")
    }

    /// Parses the runtime's model report.
    ///
    /// The report shape already existed for `nativeModelInfo`; this reads the context fields from
    /// it. Parsing is kept here, next to the contract, so the contract's provenance claims can be
    /// tested without a device.
    struct RuntimeModelReport: Equatable, Sendable {
        let description: String?
        let parameterCount: Int?
        let sizeBytes: Int?
        /// The model's own maximum trained context — a property of the model, not our config.
        let trainedContextSize: Int?
        /// The context window actually allocated. `nil` when the runtime did not report one.
        let contextSizeInUse: Int?
    }

    /// Decodes the native model report.
    ///
    /// Returns `nil` for a report carrying an `error` key, rather than fabricating a partial
    /// result: a failed report is not evidence of anything.
    static func parseRuntimeModelReport(_ json: String) -> RuntimeModelReport? {
        guard let data = json.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }

        if object["error"] != nil { return nil }

        func int(_ key: String) -> Int? {
            // JSON numbers arrive as NSNumber; accept only genuine integers so a float or a
            // string cannot be silently coerced into a context size.
            guard let number = object[key] as? NSNumber else { return nil }
            return number.intValue
        }

        let inUse = int("n_ctx_in_use")
        return RuntimeModelReport(
            description: object["desc"] as? String,
            parameterCount: int("n_params"),
            sizeBytes: int("size_bytes"),
            trainedContextSize: int("n_ctx_train"),
            // 0 means "no context established", which is not a context size. Normalise to nil so
            // the caller falls back to `.declared` rather than publishing a zero.
            contextSizeInUse: (inUse ?? 0) > 0 ? inUse : nil
        )
    }
}
