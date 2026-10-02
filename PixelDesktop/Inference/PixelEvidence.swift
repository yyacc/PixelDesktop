//
//  PixelEvidence.swift
//  PixelDesktop
//
//  Phase 7 Step 2 — measured evidence, with provenance and freshness.
//
//  WHAT THIS ADDS OVER STEP 1
//  Step 1 published what the Pixel *can* support: static, declared facts that change only on
//  redeploy. This file publishes what has been *observed*: dynamic device state and the results
//  of real executions. The distinction the contract must let a consumer draw is:
//
//      "Pixel is capable of doing this"
//  vs.
//      "Pixel is capable of doing this AND this observed state is current enough to matter"
//
//  REUSE, NOT REINVENTION
//  `CapabilityValue` (Step 1) already IS the observation shape this step requires — it carries
//  value + source + observedAt + limitation. There is deliberately **no second observation type**.
//  Adding one would be the "duplicate information" failure the brief warns about.
//
//  A SNAPSHOT IS NOT A RESERVATION
//  This is the most important property of this file and it is stated in every relevant place:
//
//      availableMemory = X   does NOT guarantee X is still available at submission time.
//
//  PixelDesktop re-validates authoritative state immediately before execution. A stale
//  observation held by Hermes causes a **refused request and an extra round trip** — never unsafe
//  execution. (ADR-007 Amendment 1 §A1.5, §A1.6.)
//
//  WHAT THIS IS NOT
//  Not a ResourceMonitor, not a polling daemon, not a cache, not a scheduler, not a reservation
//  system. Observations are taken on request and are immutable values. Nothing here refreshes
//  itself, holds state between calls, or runs in the background.
//

import Foundation

// MARK: - Freshness

/// How much an observation's age matters, decided by the **consumer**, not by PixelDesktop.
///
/// Deliberately has NO default threshold.
///
/// PixelDesktop has no defensible basis for declaring "memory readings older than N seconds are
/// stale" — that depends entirely on what the consumer intends to do with the number. Baking in a
/// threshold would be inventing policy, and would risk becoming exactly the kind of hardcoded
/// constant this project forbids (ADR-013 P7, and the Step 2 brief's prohibition on hardcoded
/// thresholds).
///
/// So the caller supplies `maxAge`. PixelDesktop only does the arithmetic and reports the result.
enum Freshness: String, Codable, Equatable, Sendable {
    /// Observed within the caller's stated window.
    case current

    /// Older than the caller's stated window. Still a real observation — just an old one.
    case stale

    /// No timestamp exists, so age cannot be assessed. Distinct from `stale`: we do not know that
    /// it is old, we know that we cannot tell.
    case unknown

    /// Assesses age against a window the caller chooses.
    ///
    /// - Parameters:
    ///   - observedAt: when the value was observed; `nil` for declared values.
    ///   - now: the reference instant, injectable so this is testable without waiting.
    ///   - maxAge: the caller's tolerance. **No default is provided, deliberately.**
    static func assess(
        observedAt: Date?,
        now: Date = Date(),
        maxAge: TimeInterval
    ) -> Freshness {
        guard let observedAt else { return .unknown }
        // A timestamp in the future is not "current" — it means the clock is wrong, and pretending
        // otherwise would hide a real problem. Treated as unknown.
        guard observedAt <= now else { return .unknown }
        return now.timeIntervalSince(observedAt) <= maxAge ? .current : .stale
    }
}

// MARK: - Device-reported dynamic state

/// A point-in-time reading of the device's dynamic state.
///
/// Immutable. Taken on request. Never refreshed automatically, never cached by this type.
///
/// **Every field here is a snapshot, not a reservation.** Reading `availableMemoryBytes` does not
/// reserve that memory, and it may be gone by the time a workload is submitted. See the file
/// header.
struct PixelStateObservation: Codable, Equatable, Sendable {

    /// When the whole observation was taken.
    ///
    /// Per-field timestamps also exist on each `CapabilityValue`; this is the observation as a
    /// whole, which is what a consumer usually wants for a freshness decision.
    let observedAt: Date

    /// The serial this was read from, so an observation cannot be silently attributed to another
    /// device if a different Pixel is attached later.
    let deviceSerial: String

    /// `/proc/meminfo` `MemAvailable`, in bytes.
    ///
    /// `MemAvailable` rather than `MemFree`: it includes reclaimable page cache and is the number
    /// that actually predicts whether a ~1.3 GB allocation will succeed.
    let availableMemoryBytes: CapabilityValue<Int>

    /// Free bytes on the volume holding the worker's exchange directory.
    let freeStorageBytes: CapabilityValue<Int>

    /// Whether the worker package is installed, and at what version code.
    let workerInstalled: CapabilityValue<WorkerInstallation>

    /// Whether a worker process is currently alive.
    ///
    /// Note: a live process does NOT imply a loaded model. Phase 7 reconnaissance measured that
    /// Android keeps the process cached after `finish()` while the one-shot Activity frees the
    /// model on every run. The limitation field states this.
    let workerRunning: CapabilityValue<Bool>

    /// Whether the provisioned model is present at its fixed path, and its size.
    let modelPresent: CapabilityValue<ModelPresence>

    /// The device's system-wide thermal status.
    ///
    /// **Deliberately `.deviceReported` and explicitly NOT worker-attributable.** `dumpsys
    /// thermalservice` reports the whole device. It must never be presented as this worker's
    /// thermal consumption.
    let thermalStatus: CapabilityValue<Int>

    /// Whether the device is reachable over ADB right now.
    let deviceReachable: CapabilityValue<Bool>

    /// Worker installation state, as read from the device.
    enum WorkerInstallation: Codable, Equatable, Sendable {
        case notInstalled
        case installed(versionCode: Int)
    }

    /// Model presence at the fixed contract path.
    enum ModelPresence: Codable, Equatable, Sendable {
        case absent
        /// Present with the given byte count. Compared against `ModelContract.expectedByteCount`
        /// by the consumer — this type does not assert correctness, only presence and size.
        case present(byteCount: Int)

        var byteCount: Int? {
            if case .present(let count) = self { return count }
            return nil
        }
    }

    /// Freshness of the observation as a whole, assessed against a caller-supplied window.
    ///
    /// No default: see `Freshness`.
    func freshness(now: Date = Date(), maxAge: TimeInterval) -> Freshness {
        Freshness.assess(observedAt: observedAt, now: now, maxAge: maxAge)
    }
}

// MARK: - Execution evidence

/// What a single real execution reported about itself.
///
/// Runtime-reported, so it is stronger evidence than anything PixelDesktop declares. It is an
/// **observation of one run**, not a capability and not a promise about the next run.
///
/// Every field comes from `InferenceResult`, which the worker already returns. Nothing new is
/// measured here — Step 2 publishes what Phase 6 was already producing.
struct PixelExecutionEvidence: Codable, Equatable, Sendable {

    let observedAt: Date
    let deviceSerial: String
    let jobId: String
    let status: InferenceResult.Status

    /// The runtime that actually produced this result, as it reported itself.
    let runtime: CapabilityValue<InferenceRuntimeIdentity>

    /// The model file the runtime actually opened, and its device-computed SHA-256.
    ///
    /// The hash is computed **on the device, over the bytes the runtime read** — which is what
    /// makes it evidence about this execution rather than about our intent.
    let model: CapabilityValue<ExecutedModel>

    /// Context window the runtime actually allocated for this run.
    let contextSizeTokens: CapabilityValue<Int>

    /// The timing breakdown for this run.
    let timings: CapabilityValue<ExecutionTimings>

    /// The model file and hash as observed during this execution.
    struct ExecutedModel: Codable, Equatable, Sendable {
        let fileName: String
        let sha256: String
    }

    /// Timings, in milliseconds, exactly as the worker reported them.
    struct ExecutionTimings: Codable, Equatable, Sendable {
        let modelLoadMs: Int
        let promptEvalMs: Int
        let generationMs: Int
        let totalMs: Int
        let promptTokens: Int
        let generatedTokens: Int
    }
}

// MARK: - Performance observations

/// A measured performance sample, **with the conditions it was taken under**.
///
/// This is deliberately NOT a capability and NOT a threshold.
///
/// Phase 7 reconnaissance measured a **2.4× generation-time variance** for identical work and a
/// **12× model-load variance** depending on page-cache state. A single number published as "the
/// Pixel's speed" would therefore be wrong roughly half the time. The honest representation of
/// such a measurement is a *sample with its conditions attached*, which is what this type is.
///
/// **It must not be used to rank executors or to build latency-based routing.** The variance is
/// the finding; a threshold derived from one sample would contradict it.
struct PerformanceObservation: Codable, Equatable, Sendable {

    let observedAt: Date

    /// What was being measured. Carried so a sample can never be compared against a sample taken
    /// under different conditions without that difference being visible.
    let conditions: MeasurementConditions

    /// The raw measurement.
    let timings: PixelExecutionEvidence.ExecutionTimings

    /// Tokens per second over generation time only.
    ///
    /// `nil` rather than a misleading number when generation was too short to measure — the same
    /// discipline applied to D8's CPU-tick claim.
    var generationTokensPerSecond: Double? {
        guard timings.generationMs > 0, timings.generatedTokens > 0 else { return nil }
        return Double(timings.generatedTokens) / (Double(timings.generationMs) / 1000.0)
    }

    /// Tokens per second over prompt processing only.
    ///
    /// This is the figure that dominates cost for large prompts: Step 1 measured an 820-token
    /// prompt taking 5.1 minutes of prefill.
    var promptTokensPerSecond: Double? {
        guard timings.promptEvalMs > 0, timings.promptTokens > 0 else { return nil }
        return Double(timings.promptTokens) / (Double(timings.promptEvalMs) / 1000.0)
    }
}

/// The conditions a performance sample was taken under.
///
/// Only fields with a **reliable source** are included. Notably absent is page-cache warm/cold
/// state: Phase 7 reconnaissance showed it materially affects model-load time (393 ms → 4,954 ms),
/// but there is **no non-root way to determine it**. Rather than invent a value, the field does not
/// exist and the absence is documented. (Step 2 brief: "If a proposed measurement cannot be
/// reliably obtained on the real device, mark it unknown/unavailable instead of inventing it.")
struct MeasurementConditions: Codable, Equatable, Sendable {
    let modelFileName: String
    let modelSha256: String
    let runtimeName: String
    let runtimeVersion: String
    let backend: String
    let contextSizeTokens: Int?
    let promptTokens: Int
    let generatedTokens: Int

    /// Memory available at the moment the run was submitted, when it was observed.
    ///
    /// Optional because observing it requires an extra device read that a caller may not have
    /// taken. Absent means "not recorded", not "zero".
    let availableMemoryBytes: Int?

    /// Page-cache state affecting model load.
    ///
    /// **Always `.unknown` in this implementation.** It is modelled explicitly so the gap is
    /// visible rather than silently missing — the reconnaissance proved it matters, and there is
    /// no reliable way to determine it without root. A consumer reading a load time must know this
    /// is uncontrolled.
    let pageCacheState: PageCacheState

    enum PageCacheState: String, Codable, Equatable, Sendable {
        case warm
        case cold
        case unknown
    }
}

// MARK: - Building evidence from existing components

/// Builds evidence from sources the project already has.
///
/// Reads through `TransportProtocol` and the existing worker types — it does not add a monitoring
/// layer, a cache, or a background loop. Every method performs its reads at call time and returns
/// an immutable value.
struct PixelEvidenceReader: Sendable {

    private let transport: TransportProtocol

    init(transport: TransportProtocol) {
        self.transport = transport
    }

    /// The fixed model path, derived from the contract rather than supplied.
    static var remoteModelPath: String { ModelContract.remoteModelPath }

    // MARK: State observation

    /// Takes one point-in-time reading of the device's dynamic state.
    ///
    /// Performs its reads in **one shell round trip** rather than one per field: an ADB round trip
    /// costs ~226 ms (measured), and three separate reads would triple that for no benefit. The
    /// reads are independent and read-only.
    ///
    /// Never throws for a partially-available device: a field that cannot be read is reported as
    /// unavailable rather than fabricated. A device that is entirely unreachable produces an
    /// observation whose every field says so, which is more useful to a consumer than an error
    /// that discards what *was* readable.
    func observeState(deviceSerial: String, timeout: TimeInterval = 20) async throws -> PixelStateObservation {
        let now = Date()

        // One round trip. Each line is `KEY=value`; a missing key means the read failed.
        let command = """
        echo MEM=$(grep MemAvailable /proc/meminfo | tr -dc 0-9); \
        echo FREE=$(df -k /sdcard | tail -1 | awk '{print $4}'); \
        echo MODEL=$(stat -c %s \(Self.remoteModelPath) 2>/dev/null || echo 0)
        """

        let result: TransportResult
        do {
            result = try await transport.shell(
                deviceSerial: deviceSerial, command: command, timeout: timeout)
        } catch {
            // Device unreachable. Report that fact as an observation rather than throwing away the
            // structure — every field explicitly unknown/unavailable.
            return Self.unreachableObservation(deviceSerial: deviceSerial, at: now)
        }

        let values = Self.parseKeyValueLines(result.stdout)
        let reachable = result.exitCode == 0

        // Worker installation and running state come from the EXISTING components, not from new
        // parsing here. Reuse over duplication.
        let installer = WorkerInstaller(transport: transport)
        let lifecycle = WorkerLifecycle(transport: transport)

        var installed: CapabilityValue<PixelStateObservation.WorkerInstallation> =
            .deviceReported(.notInstalled, at: now, limitation:
                "Read from `dumpsys package`. Absence means the package is not installed, not that "
                + "the read failed — a failed read reports separately as unknown.")
        if let state = try? await installer.installedState(deviceSerial: deviceSerial, timeout: timeout) {
            installed = .deviceReported(Self.map(state), at: now, limitation:
                "Installation is not availability: an installed worker can still refuse a workload.")
        }

        var running: CapabilityValue<Bool> = .deviceReported(false, at: now, limitation:
            "A live process does NOT imply a loaded model. Android caches the process after "
            + "finish() while the one-shot Activity frees the model on every run.")
        if let state = try? await lifecycle.state(deviceSerial: deviceSerial, timeout: timeout) {
            running = .deviceReported(state.isRunning, at: now, limitation:
                "A live process does NOT imply a loaded model. Android caches the process after "
                + "finish() while the one-shot Activity frees the model on every run.")
        }

        // Memory.
        let memory: CapabilityValue<Int>
        if let memKb = values["MEM"].flatMap(Int.init), memKb > 0 {
            memory = .deviceReported(memKb * 1024, at: now, limitation:
                Self.notAReservation + " MemAvailable includes reclaimable page cache, so it is "
                + "an estimate of what a new allocation could obtain, not a guarantee.")
        } else {
            memory = CapabilityValue(value: 0, source: .unknown, observedAt: nil, limitation:
                "Unreadable from /proc/meminfo on this attempt. Reported as unknown rather than 0.")
        }

        // Storage.
        let storage: CapabilityValue<Int>
        if let freeKb = values["FREE"].flatMap(Int.init), freeKb > 0 {
            storage = .deviceReported(freeKb * 1024, at: now, limitation:
                Self.notAReservation)
        } else {
            storage = CapabilityValue(value: 0, source: .unknown, observedAt: nil, limitation:
                "Unreadable from df on this attempt. Reported as unknown rather than 0.")
        }

        // Model presence.
        let model: CapabilityValue<PixelStateObservation.ModelPresence>
        if let modelBytes = values["MODEL"].flatMap(Int.init) {
            if modelBytes > 0 {
                model = .deviceReported(.present(byteCount: modelBytes), at: now, limitation:
                    "Presence and size only. This does NOT verify the artifact's hash — that is "
                    + "established during provisioning, and re-verified per run in execution evidence.")
            } else {
                model = .deviceReported(.absent, at: now, limitation:
                    "Absent at the fixed contract path. A model elsewhere on the device would not "
                    + "be found, because the path is fixed by design (ADR-010).")
            }
        } else {
            model = CapabilityValue(value: .absent, source: .unknown, observedAt: nil, limitation:
                "The model path could not be read on this attempt. Reported as unknown rather than "
                + "absent, because those are different facts.")
        }

        // Thermal — system-wide, never worker-attributable.
        let thermal: CapabilityValue<Int>
        if let raw = try? await transport.shell(
            deviceSerial: deviceSerial,
            command: "dumpsys thermalservice | grep -m1 'Thermal Status'",
            timeout: timeout
        ), let status = Self.parseThermalStatus(raw.stdout) {
            thermal = .deviceReported(status, at: now, limitation:
                Self.thermalLimitation)
        } else {
            thermal = CapabilityValue(value: -1, source: .unknown, observedAt: nil, limitation:
                Self.thermalLimitation)
        }

        return PixelStateObservation(
            observedAt: now,
            deviceSerial: deviceSerial,
            availableMemoryBytes: memory,
            freeStorageBytes: storage,
            workerInstalled: installed,
            workerRunning: running,
            modelPresent: model,
            thermalStatus: thermal,
            deviceReachable: .deviceReported(reachable, at: now, limitation:
                "A successful shell command means ADB reached the device at this instant. It does "
                + "not predict the connection surviving a workload.")
        )
    }

    // MARK: Parsing

    /// Parses `KEY=value` lines emitted by the combined read.
    ///
    /// A key that is absent from the result map means the read did not produce it; callers must
    /// treat that as unknown rather than as zero.
    static func parseKeyValueLines(_ output: String) -> [String: String] {
        var values: [String: String] = [:]
        for line in output.split(separator: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard let separator = trimmed.firstIndex(of: "=") else { continue }
            let key = String(trimmed[trimmed.startIndex..<separator])
            let value = String(trimmed[trimmed.index(after: separator)...])
                .trimmingCharacters(in: .whitespaces)
            guard !key.isEmpty else { continue }
            values[key] = value
        }
        return values
    }

    /// Parses `Thermal Status: N` from `dumpsys thermalservice`.
    ///
    /// Returns `nil` rather than a sentinel when the line is absent, so a caller cannot mistake a
    /// parse failure for a real thermal reading of 0.
    static func parseThermalStatus(_ output: String) -> Int? {
        for line in output.split(separator: "\n") {
            guard line.contains("Thermal Status") else { continue }
            let digits = line.filter { $0.isNumber }
            if let value = Int(digits) { return value }
        }
        return nil
    }

    static func map(_ state: WorkerInstaller.InstalledState)
        -> PixelStateObservation.WorkerInstallation {
        switch state {
        case .notInstalled:
            return .notInstalled
        case .installed(let versionCode):
            return .installed(versionCode: versionCode)
        }
    }

    /// An observation for a device that could not be reached at all.
    ///
    /// Every field is explicitly unknown. Returning this rather than throwing preserves the
    /// structure, so a consumer always receives an observation it can reason about.
    static func unreachableObservation(deviceSerial: String, at date: Date) -> PixelStateObservation {
        let unknown = "The device was not reachable when this observation was taken."
        func unreadable<T: Codable & Equatable & Sendable>(_ placeholder: T) -> CapabilityValue<T> {
            CapabilityValue(value: placeholder, source: .unknown, observedAt: nil, limitation: unknown)
        }
        return PixelStateObservation(
            observedAt: date,
            deviceSerial: deviceSerial,
            availableMemoryBytes: unreadable(0),
            freeStorageBytes: unreadable(0),
            workerInstalled: unreadable(.notInstalled),
            workerRunning: unreadable(false),
            modelPresent: unreadable(.absent),
            thermalStatus: unreadable(-1),
            deviceReachable: .deviceReported(false, at: date, limitation:
                "ADB did not reach the device at this instant.")
        )
    }

    // MARK: Shared limitation text

    /// The single most important sentence in this file, reused so it cannot be paraphrased away.
    static let notAReservation =
        "A SNAPSHOT, NOT A RESERVATION. This value may be different by the time a workload is "
        + "submitted. PixelDesktop re-validates authoritative state immediately before execution, "
        + "so a stale observation causes a refused request, never unsafe execution."

    static let thermalLimitation =
        "SYSTEM-WIDE, NOT WORKER-ATTRIBUTABLE. dumpsys thermalservice reports the whole device, "
        + "influenced by every process, by charging, and by ambient temperature. It must never be "
        + "presented as this worker's thermal consumption (ADR-011, ADR-012 section P9)."

    // MARK: Evidence from an execution

    /// Converts a real `InferenceResult` into execution evidence.
    ///
    /// Pure: takes what the worker already returned and attaches provenance. It measures nothing
    /// new, and it cannot invent a value the worker did not report.
    static func evidence(
        from result: InferenceResult,
        deviceSerial: String,
        at date: Date = Date()
    ) -> PixelExecutionEvidence {
        PixelExecutionEvidence(
            observedAt: date,
            deviceSerial: deviceSerial,
            jobId: result.jobId,
            status: result.status,
            runtime: .runtimeReported(result.runtime, at: date, limitation:
                "The runtime that produced THIS result, as it reported itself. Not a statement "
                + "that the same runtime will be used next time."),
            model: .runtimeReported(
                PixelExecutionEvidence.ExecutedModel(
                    fileName: result.modelFile, sha256: result.modelSha256),
                at: date,
                limitation:
                    "The model file the runtime actually opened, hashed ON THE DEVICE over the "
                    + "bytes it read. This is evidence about this execution, not about intent."),
            contextSizeTokens: .runtimeReported(
                result.contextSizeTokens ?? PixelCapabilityContract.declaredContextSizeTokens,
                at: date,
                limitation: result.contextSizeTokens == nil
                    ? "NOT reported by the runtime; the declared value is substituted and is "
                      + "therefore weaker evidence."
                    : "The context window the runtime actually allocated for this run."),
            timings: .runtimeReported(
                PixelExecutionEvidence.ExecutionTimings(
                    modelLoadMs: result.modelLoadMs,
                    promptEvalMs: result.promptEvalMs,
                    generationMs: result.generationMs,
                    totalMs: result.totalMs,
                    promptTokens: result.promptTokens,
                    generatedTokens: result.generatedTokens),
                at: date,
                limitation:
                    "ONE RUN under uncontrolled conditions. Phase 7 measured a 2.4x generation "
                    + "variance and a 12x model-load variance for identical work, so this is a "
                    + "sample, NOT a capability and NOT a threshold.")
        )
    }

    /// Builds a performance sample from execution evidence, attaching its conditions.
    static func performanceObservation(
        from evidence: PixelExecutionEvidence,
        availableMemoryBytes: Int? = nil
    ) -> PerformanceObservation {
        PerformanceObservation(
            observedAt: evidence.observedAt,
            conditions: MeasurementConditions(
                modelFileName: evidence.model.value.fileName,
                modelSha256: evidence.model.value.sha256,
                runtimeName: evidence.runtime.value.name,
                runtimeVersion: evidence.runtime.value.version,
                backend: evidence.runtime.value.backend,
                contextSizeTokens: evidence.contextSizeTokens.value,
                promptTokens: evidence.timings.value.promptTokens,
                generatedTokens: evidence.timings.value.generatedTokens,
                availableMemoryBytes: availableMemoryBytes,
                // No non-root way to determine this. The reconnaissance proved it matters
                // (393 ms -> 4,954 ms) but it cannot be measured, so it is declared unknown
                // rather than guessed.
                pageCacheState: .unknown),
            timings: evidence.timings.value)
    }
}
