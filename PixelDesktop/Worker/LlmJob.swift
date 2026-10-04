import Foundation

/// The LOCAL-LLM-1 job document sent to the Pixel worker.
///
/// Wraps the existing `InferenceRequest` (Phase 6) in the same job-envelope pattern as
/// `DTCA1Job`: a stable workload name, a workload-owned success token, and a deterministic
/// encoding. The `InferenceRequest` owns its own wire keys (`job_id`, `prompt`, `max_tokens`,
/// `temperature`, `seed`) and its own validation; this type adds only the job-envelope
/// concerns that are common to every workload.
///
/// `jobId` is the **anti-staleness** mechanism (D9), identical in purpose to `DTCA1Job.jobId`.
/// The contract uses fixed filenames, so a result file from a previous run is
/// indistinguishable from a fresh one by name alone. The worker echoes `job_id` into its
/// result; a mismatch means the file is stale and must be rejected.
struct LlmJob {
    /// The inference request this job carries. Owns its own validation and wire keys.
    let request: InferenceRequest

    /// The only workload the worker accepts for this job type. The worker rejects anything
    /// else by name, rather than attempting it — an allowlist, not a dispatcher.
    static let workloadName = "LOCAL-LLM-1"

    /// The status token this workload's worker emits for a **successful** result.
    ///
    /// Owned here because it is a property of this workload's own worker (`LlmWorkload.java`
    /// writes `status: "OK"`), not of the result boundary that decodes it. The capability
    /// contract publishes it from this constant, so the published value and the worker's
    /// behaviour cannot silently diverge.
    static let successResultToken = "OK"

    init(request: InferenceRequest) {
        self.request = request
    }

    /// The job id from the underlying request. Echoed by the worker and used for the
    /// ownership check.
    var jobId: String { request.jobId }

    /// Encodes the job to the fixed job file (`job.json`).
    ///
    /// The `InferenceRequest` owns its own `CodingKeys` and validation. This method
    /// encodes the request and then adds the `workload` field, which the Android
    /// worker's `WorkerActivity` uses to route to the correct executor. The encoding
    /// uses sorted keys so the job file is reproducible for a given input.
    func encoded() throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let requestData = try encoder.encode(request)
        var dict = try JSONSerialization.jsonObject(with: requestData) as! [String: Any]
        dict["workload"] = Self.workloadName
        let data = try JSONSerialization.data(withJSONObject: dict, options: [.sortedKeys])
        return String(decoding: data, as: UTF8.self)
    }

    /// Generates a job identifier.
    ///
    /// Uses a UUID rather than a timestamp: it needs only to differ between runs, and a
    /// UUID does not depend on clock agreement between the Mac and the device.
    static func newJobId() -> String {
        UUID().uuidString
    }
}
