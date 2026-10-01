import Foundation

/// The fixed transfer contract for the Pixel Compute Worker.
///
/// ## Why this is a fixed contract
///
/// `adb` does not sanitize paths. Reconnaissance on the real Pixel 7a (ADR-010) established:
///
/// - `../` is resolved by the **device filesystem**, not rejected by adb. A push to
///   `/data/local/tmp/pdsub/../file` succeeded and landed in `/data/local/tmp/`.
/// - Absolute remote paths escape any staging root without needing traversal at all.
/// - A local `pull` destination containing `../` escaped the staging directory and wrote
///   outside it (exit 0).
/// - **Symlinks are followed, not rejected.** Pushing a symlink to `/etc/hosts` pushed the
///   contents of `/etc/hosts`.
/// - Directory operands **recurse**.
///
/// The traversal attempts that *did* fail during probing failed on **permissions**, not on a
/// control. That distinction is why containment cannot be delegated to adb.
///
/// ## The mechanism: narrowness, not validation
///
/// There is **no path parameter anywhere in this contract**. Two fixed filenames in two fixed
/// directories, one file each way. Every traversal case above is therefore *unreachable by
/// construction* rather than merely blocked.
///
/// Validation still exists as a second layer (regular-file checks, symlink rejection, size
/// caps), but it is the fallback, not the mechanism.
///
/// ## Limits of this protection model
///
/// This contract is safe because it is **narrow**, not because paths are validated. It
/// provides **no** general path-safety mechanism. Before any future phase introduces a
/// variable path, ADR-010 must be revisited and a real path validator written.
enum WorkerTransferContract {

    // MARK: - Remote (device) paths — fixed

    /// The Android worker's package identifier.
    static let workerPackageName = "com.pixeldesktop.worker"

    /// The worker's launchable Activity component, in `am start -n` form.
    static let workerActivityComponent = "com.pixeldesktop.worker/.WorkerActivity"

    /// The only device directory this project exchanges worker payloads through.
    ///
    /// **This is the worker application's own external files directory** — see ADR-010
    /// Revision 1.
    ///
    /// It replaced `/data/local/tmp/pixeldesktop` because that path is **mode 771 owned by
    /// `shell`**: adb can write it, but the Android worker process cannot, because it runs
    /// under its own UID and is not in group `shell`. The two identities do not have
    /// equivalent filesystem privileges, and the transfer root must be reachable by **both**:
    ///
    /// | Stage | Identity | Access basis |
    /// |---|---|---|
    /// | write job  | `shell` (adb) | `ext_data_rw` group membership |
    /// | read job / write result | app UID | **ownership** of the directory |
    /// | read result | `shell` (adb) | `ext_data_rw` group membership |
    ///
    /// The directory is `drwxrws---` (owner + `ext_data_rw`), so it is **not readable by other
    /// applications**, and the worker needs **no permission** to use its own directory.
    static let remoteRoot = "/sdcard/Android/data/com.pixeldesktop.worker/files"

    /// The one job payload. Filename is fixed; no caller may influence it.
    static let remoteInputPath = "/sdcard/Android/data/com.pixeldesktop.worker/files/job.json"

    /// The one result payload. Filename is fixed; no caller may influence it.
    static let remoteResultPath = "/sdcard/Android/data/com.pixeldesktop.worker/files/result.json"

    // MARK: - Local paths — fixed

    /// Staging directory inside the app's own container.
    ///
    /// Under `Application Support`, which is container-controlled and outside user-visible
    /// storage. The caller cannot substitute a different staging path — it is computed here
    /// and never accepted as an argument.
    static var stagingDirectory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return base
            .appendingPathComponent("PixelDesktop", isDirectory: true)
            .appendingPathComponent("Staging", isDirectory: true)
    }

    /// The staged job file. Filename fixed.
    static var localInputPath: URL {
        stagingDirectory.appendingPathComponent("job.json", isDirectory: false)
    }

    /// The retrieved result file. Filename fixed.
    static var localResultPath: URL {
        stagingDirectory.appendingPathComponent("result.json", isDirectory: false)
    }

    // MARK: - Limits

    /// Maximum payload size accepted in either direction.
    ///
    /// The DTCA-1 specification caps input at 10,000 characters, so the real payload is a few
    /// KB. This cap is a guard against a wrong file being handed in, not a transfer limit.
    static let maximumPayloadBytes = 1_048_576 // 1 MB

    // MARK: - Local operand validation

    /// A local file that has passed validation.
    ///
    /// Its existence as a value is the proof that validation ran — the operations layer
    /// cannot construct one without going through `validateRegularFile`.
    struct ValidatedLocalFile: Equatable {
        let url: URL
        let byteCount: Int
    }

    /// Validates that a local URL is a regular, non-symlink file within the size cap.
    ///
    /// Rejects, in order:
    /// - a missing path
    /// - a **symlink** (reported by `attributesOfItem` without following it) — a symlink in
    ///   staging is a full escape from it
    /// - a **directory** — `adb` would transfer it recursively
    /// - anything that is not a regular file (socket, device, fifo)
    /// - a file over `maximumPayloadBytes`
    static func validateRegularFile(at url: URL) throws -> ValidatedLocalFile {
        let attributes: [FileAttributeKey: Any]
        do {
            attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        } catch {
            throw PixelDesktopError.invalidInput(
                "Local payload not found or unreadable: \(url.lastPathComponent)"
            )
        }

        // `attributesOfItem` reports a symlink as `.typeSymbolicLink` WITHOUT following it,
        // so this check cannot be bypassed by a link pointing at a regular file.
        guard let type = attributes[.type] as? FileAttributeType else {
            throw PixelDesktopError.invalidInput(
                "Local payload has no file type: \(url.lastPathComponent)"
            )
        }

        guard type == .typeRegular else {
            let kind: String
            switch type {
            case .typeSymbolicLink: kind = "a symbolic link (refused: it could point outside staging)"
            case .typeDirectory: kind = "a directory (refused: adb would transfer it recursively)"
            default: kind = "not a regular file (\(type.rawValue))"
            }
            throw PixelDesktopError.invalidInput(
                "Local payload '\(url.lastPathComponent)' is \(kind)"
            )
        }

        let byteCount = (attributes[.size] as? NSNumber)?.intValue ?? 0
        guard byteCount <= maximumPayloadBytes else {
            throw PixelDesktopError.invalidInput(
                "Local payload is \(byteCount) bytes, over the \(maximumPayloadBytes)-byte limit"
            )
        }

        return ValidatedLocalFile(url: url, byteCount: byteCount)
    }

    /// Reports whether the exchange directory exists on the device.
    ///
    /// **The directory must be created by the worker application, not by adb.**
    ///
    /// Measured on the real device: if adb creates it with `mkdir -p`, the directory is owned by
    /// `shell:ext_data_rw` with mode `drwxrws---`. The worker runs under its own UID, is not in
    /// `ext_data_rw`, and is therefore **unable to write its own output directory**. An adb-created
    /// workspace silently breaks the worker.
    ///
    /// The worker calls `getExternalFilesDir(null)` on launch, which creates the directory owned by
    /// the app — the only correct owner. So the correct sequence is:
    ///
    /// 1. launch the worker once so it creates its directory (it exits immediately, having found no job)
    /// 2. push the job
    /// 3. launch the worker again to compute
    ///
    /// This is an existence check only. `chmod` is deliberately never applied: the directory is
    /// already owner-scoped by the platform, and changing its mode would break the worker's access.
    static var remoteWorkspaceExistsCommand: String {
        "test -d \(remoteRoot) && echo EXISTS"
    }

    /// Ensures the staging directory exists. Creates it if needed.
    ///
    /// The path is computed from the container, never supplied by a caller.
    static func prepareStagingDirectory() throws {
        let directory = stagingDirectory
        if !FileManager.default.fileExists(atPath: directory.path) {
            do {
                try FileManager.default.createDirectory(
                    at: directory,
                    withIntermediateDirectories: true
                )
            } catch {
                throw PixelDesktopError.invalidInput(
                    "Could not create staging directory: \(error.localizedDescription)"
                )
            }
        }
    }

    // MARK: - Device-side size verification

    /// Parses the output of `stat -c %s <path>` into a byte count.
    ///
    /// Returns `nil` when the value is absent or not a number, so a missing remote file is
    /// distinguishable from a zero-byte one.
    static func parseRemoteSize(_ output: String) -> Int? {
        let trimmed = output.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        // Toybox may emit the value with surrounding noise; take the last numeric token.
        let numeric = trimmed.split(whereSeparator: { !$0.isNumber }).last
        guard let token = numeric, let value = Int(token) else { return nil }
        return value
    }

    // MARK: - Integrity

    /// Outcome of the post-transfer size check.
    ///
    /// - Important: This detects a **size mismatch**. It is **not** cryptographic integrity
    ///   verification — it cannot detect same-length corruption. Per ADR-010, integrity of
    ///   the *result content* is established by ADR-004's independent re-computation, not by
    ///   this check.
    enum SizeVerification: Equatable {
        case match(expected: Int, actual: Int)
        case mismatch(expected: Int, actual: Int)

        var isVerified: Bool {
            if case .match = self { return true }
            return false
        }
    }

    static func verifySize(expected: Int, actual: Int) -> SizeVerification {
        expected == actual ? .match(expected: expected, actual: actual)
                           : .mismatch(expected: expected, actual: actual)
    }
}
