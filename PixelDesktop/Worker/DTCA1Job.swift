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

    // DTCA-1 payload — present only when status == "COMPLETED".
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

    var isCompleted: Bool { status == "COMPLETED" }

    /// Converts a completed envelope into the `DTCA1Result` the verifier consumes.
    ///
    /// - Throws: `verificationFailed` when required fields are absent, rather than substituting
    ///   defaults — a result missing fields must not be silently coerced into a plausible one.
    func asDTCA1Result() throws -> DTCA1Result {
        guard isCompleted else {
            throw PixelDesktopError.workerError(
                "Worker reported status \(status): \(errorType ?? "?") \(errorMessage ?? "")"
            )
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
}
