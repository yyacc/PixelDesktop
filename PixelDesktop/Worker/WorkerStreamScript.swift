import Foundation

/// Builds the device-side script that drives one worker job inside a single persistent
/// `adb shell`.
///
/// ## Why the script exists at all
///
/// The Android worker emits **nothing** to stdout — verified: it writes to logcat only, and
/// `grep -rn "System.out\|System.err"` across its Java sources returns no matches. It is launched
/// by `am start`, so its stdout belongs to the Android app runtime, not to the ADB shell.
///
/// That means the stream's events cannot come from the worker. They come from **this script**,
/// which observes the job from the shell side: it writes the payload, launches the worker, watches
/// `pidof`, and reports what it sees.
///
/// This is a direct consequence of E1's limitation L6 and it bounds what the protocol can claim:
/// `HEARTBEAT` is **process liveness**, never model-generation progress. The worker has no progress
/// to report, so none is invented.
///
/// ## Single-line form
///
/// The script is emitted as **one line**. `adb shell` passes its argument through the device's own
/// shell, which treats embedded newlines as command separators in ways that vary with quoting; a
/// single line with explicit `;` removes that ambiguity entirely.
///
/// ## Fixed paths only
///
/// Every path comes from `WorkerTransferContract`. The only interpolated value is the job id,
/// which is validated as a UUID-shaped token before use so it cannot carry shell syntax.
enum WorkerStreamScript {

    /// Maximum length accepted for a job id before it is rejected.
    ///
    /// A UUID is 36 characters. This is a guard, not a format check.
    static let maximumJobIdLength = 64

    /// Validates a job id as a safe token for interpolation into the device script.
    ///
    /// Only letters, digits and hyphens are accepted. The job id is the **only** value this
    /// project interpolates into a device shell command, so it is constrained to a character set
    /// that cannot express shell syntax — no quotes, no `;`, no `$`, no spaces.
    static func validateJobId(_ jobId: String) throws -> String {
        guard !jobId.isEmpty else {
            throw PixelDesktopError.invalidInput("Job id is empty")
        }
        guard jobId.count <= maximumJobIdLength else {
            throw PixelDesktopError.invalidInput(
                "Job id is \(jobId.count) characters, over the \(maximumJobIdLength) limit"
            )
        }
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-"))
        guard jobId.unicodeScalars.allSatisfy({ allowed.contains($0) }) else {
            throw PixelDesktopError.invalidInput(
                "Job id contains characters outside [A-Za-z0-9-]"
            )
        }
        return jobId
    }

    /// Builds the one-line device script for a job.
    ///
    /// The sequence:
    /// 1. announce start, carrying the job id
    /// 2. remove any stale result so a previous run cannot be mistaken for this one
    /// 3. verify the workspace exists (it must be created by the worker, not by adb — ADR-010)
    /// 4. receive the payload on **stdin** (`cat > job.json`), replacing `adb push`
    /// 5. launch the worker
    /// 6. report liveness until a result appears, or declare the worker exited (E1 F4)
    /// 7. emit the result inline, then its byte count
    ///
    /// - Parameter jobId: validated by `validateJobId` before interpolation.
    static func deviceScript(jobId: String) throws -> String {
        let safeJobId = try validateJobId(jobId)

        let root = WorkerTransferContract.remoteRoot
        let result = WorkerTransferContract.remoteResultPath
        let job = WorkerTransferContract.remoteInputPath
        let component = WorkerTransferContract.workerActivityComponent
        let package = WorkerTransferContract.workerPackageName

        // Consecutive missed liveness checks before the script itself declares the worker gone.
        // This mirrors WorkerStreamReducer.livenessMissGrace so the script and the Mac agree;
        // the Mac still makes its own determination rather than trusting the script blindly.
        let missGrace = 5

        return [
            "set -u",
            "D=\(root)",
            "R=\(result)",
            "J=\(job)",
            "echo \"\(WorkerEventParser.prefix) START job_id=\(safeJobId)\"",
            "rm -f $R",
            "if ! test -d $D; then echo \"\(WorkerEventParser.prefix) ERROR code=NO_WORKSPACE "
                + "message=worker exchange directory is missing\"; exit 1; fi",
            "cat > $J",
            "echo \"\(WorkerEventParser.prefix) JOB_WRITTEN bytes=$(wc -c < $J | tr -d ' ')\"",
            "am start -n \(component) >/dev/null 2>&1",
            "echo \"\(WorkerEventParser.prefix) LAUNCHED\"",
            // NOTE: `joined(separator: "; ")` places a semicolon between every element, so no
            // element may end with `;` and none may be a bare `do`. An earlier revision emitted
            // `while ...; do; i=0; ...` — `do;` is a shell syntax error, and because the whole
            // script failed to parse the stream produced no output at all. The loop body is
            // therefore kept as one `if/else` chain with no trailing separator.
            "i=0",
            "miss=0",
            "while [ ! -f $R ]",
            "do i=$((i+1))",
            "P=$(pidof \(package) 2>/dev/null || true)",
            "if [ -n \"$P\" ]; then miss=0; echo \"\(WorkerEventParser.prefix) HEARTBEAT n=$i pid=$P\"",
            "else miss=$((miss+1)); echo \"\(WorkerEventParser.prefix) HEARTBEAT n=$i pid=none\"",
            "if [ $miss -ge \(missGrace) ]; then echo \"\(WorkerEventParser.prefix) "
                + "WORKER_EXITED n=$i\"; exit 0; fi; fi",
            "sleep 0.5",
            "done",
            "echo \"\(WorkerEventParser.prefix) RESULT_BEGIN\"",
            "cat $R",
            "printf '\\n'",
            "echo \"\(WorkerEventParser.prefix) RESULT_END bytes=$(wc -c < $R | tr -d ' ')\"",
        ].joined(separator: "; ")
    }
}
