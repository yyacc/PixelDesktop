import Foundation

/// The DTCA-1 job document sent to the Pixel worker.
///
/// Encodes to the fixed job file (`job.json`). Field names are the wire contract between the Mac
/// and the worker's Java `Dtca1.execute`; changing one requires changing the other.
///
/// `jobId` is the **anti-staleness** mechanism (D9). The contract uses fixed filenames, so a
/// result file from a previous run is indistinguishable from a fresh one by name alone. The
/// worker echoes `job_id` into its result; a mismatch means the file is stale and must be
/// rejected.
///
/// > This is a **staleness** check, not an **authenticity** check. It does not prevent a
/// > malicious writer from forging a matching id. The channel is not authenticated — ADB access
/// > is the boundary. See ADR-010.
struct DTCA1Job: Codable, Equatable {
    let jobId: String
    let workload: String
    let input: String

    enum CodingKeys: String, CodingKey {
        case jobId = "job_id"
        case workload
        case input
    }

    /// The only workload the worker accepts. The worker rejects anything else by name, rather
    /// than attempting it — an allowlist, not a dispatcher.
    static let workloadName = "DTCA-1"

    /// The status token this workload's worker emits for a **successful** result.
    ///
    /// Owned here because it is a property of this workload's own worker (`Dtca1.java` writes
    /// `status: "COMPLETED"`), not of the result boundary that decodes it. The capability contract
    /// publishes it from this constant, so the published value and the worker's behaviour cannot
    /// silently diverge. A different workload uses a different token — `LOCAL-LLM-1` emits `"OK"` —
    /// which is why the generic boundary must never assume this one.
    static let successResultToken = "COMPLETED"

    init(jobId: String, input: String) {
        self.jobId = jobId
        self.workload = Self.workloadName
        self.input = input
    }

    func encoded() throws -> String {
        let encoder = JSONEncoder()
        // Deterministic key order so the job file is reproducible for a given input.
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(self)
        return String(decoding: data, as: UTF8.self)
    }

    /// Generates a job identifier.
    ///
    /// Uses a UUID rather than a timestamp: it needs only to differ between runs, and a UUID does
    /// not depend on clock agreement between the Mac and the device.
    static func newJobId() -> String {
        UUID().uuidString
    }
}

/// The result document returned by the worker.
///
/// This is the Mac's `DTCA1Result` plus the `job_id` echo. It is a **superset** of what
/// `ResultVerifier` needs: the verifier compares the DTCA-1 fields, and `jobId` is checked
/// separately for staleness.
///
/// A `FAILED` result carries `error_type` and `error_message` instead of the DTCA-1 fields, so
/// those are optional here. A failed run is a *reported* failure, not a missing file.
struct WorkerResultEnvelope: Codable, Equatable {
    let status: String
    let jobId: String?
    let errorType: String?
    let errorMessage: String?

    // DTCA-1 payload — present only on success, whose token is the workload's own
    // (`Workload.successResultToken`); this type does not assume which token that is.
    let inputCharacters: Int?
    let totalWords: Int?
    let uniqueWords: Int?
    let topWords: [WordCount]?
    let classification: String?
    let confidence: Double?
    let executionTimestampMs: Int64?
    let executionDurationMs: Int64?

    enum CodingKeys: String, CodingKey {
        case status
        case jobId = "job_id"
        case errorType = "error_type"
        case errorMessage = "error_message"
        case inputCharacters = "input_characters"
        case totalWords = "total_words"
        case uniqueWords = "unique_words"
        case topWords = "top_words"
        case classification
        case confidence
        case executionTimestampMs = "execution_timestamp_ms"
        case executionDurationMs = "execution_duration_ms"
    }

    /// The status token `WorkerActivity` writes for a **failed** run, for every workload.
    ///
    /// Deliberately generic. Success is workload-owned (see `Workload.successResultToken`), but
    /// failure is written once by the shared `WorkerActivity` — `{"status": "FAILED",
    /// "error_type": ..., "error_message": ...}` — for DTCA-1 and LOCAL-LLM-1 alike. Modelling it
    /// per workload would invent a distinction the worker does not make.
    static let failureStatusToken = "FAILED"

    /// Whether this envelope reports the success its caller's workload defines.
    ///
    /// - Parameter expectedSuccessToken: the token the requested workload's worker emits on
    ///   success — supplied by the caller from the capability contract. There is deliberately no
    ///   default and no stored token: this type must not know any workload, and a default would
    ///   reintroduce exactly the coupling this replaced.
    func isCompleted(expectedSuccessToken: String) -> Bool {
        status == expectedSuccessToken
    }

    /// Converts a completed envelope into the `DTCA1Result` the verifier consumes.
    ///
    /// - Parameter expectedSuccessToken: as `isCompleted(expectedSuccessToken:)`.
    /// - Throws: `verificationFailed` when required fields are absent, rather than substituting
    ///   defaults — a result missing fields must not be silently coerced into a plausible one.
    func asDTCA1Result(expectedSuccessToken: String) throws -> DTCA1Result {
        guard isCompleted(expectedSuccessToken: expectedSuccessToken) else {
            throw refusal
        }
        guard let inputCharacters,
              let totalWords,
              let uniqueWords,
              let topWords,
              let classification,
              let confidence,
              let executionTimestampMs,
              let executionDurationMs else {
            throw PixelDesktopError.verificationFailed(
                reason: "Worker result is missing required DTCA-1 fields"
            )
        }

        return DTCA1Result(
            status: status,
            inputCharacters: inputCharacters,
            totalWords: totalWords,
            uniqueWords: uniqueWords,
            topWords: topWords,
            classification: classification,
            confidence: confidence,
            executionTimestampMs: executionTimestampMs,
            executionDurationMs: executionDurationMs
        )
    }

    /// The typed refusal this envelope represents.
    ///
    /// The worker emits a structured `error_type`; this preserves it as
    /// `PixelDesktopError.workerRefused(category:message:)` rather than interpolating it into
    /// prose. A caller can then branch on the category — `MODEL_MISSING` and `INVALID_INPUT`
    /// need different responses and one is retryable while the other is not.
    ///
    /// If the worker reported no category at all (a malformed envelope that never yielded one),
    /// this falls back to `workerError`, which is what that case is for. The category is never
    /// invented.
    ///
    /// This is a **presentation-preserving accessor**, not a new state machine: it reads the
    /// fields already decoded above and chooses the matching error case.
    var refusal: PixelDesktopError {
        let message = errorMessage ?? "no message"
        guard let errorType, !errorType.isEmpty else {
            // No structured category was supplied — do not fabricate one.
            return .workerError("Worker reported status \(status): \(message)")
        }
        return .workerRefused(category: errorType, message: message)
    }
}
