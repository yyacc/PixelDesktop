import Foundation

/// The typed error vocabulary of the remote-storage layer.
///
/// ## Why a separate vocabulary from `PixelDesktopError`
///
/// `PixelDesktopError` describes the *transport* (did `adb` run? did it time out?). The storage
/// layer needs to describe the *file operation* (was the path denied? was the disk full? was the
/// file absent?). Those are different audiences: the storage UI shows "Permission denied" or
/// "Not enough space on the Pixel", not "ADB command failed: rm ... (exit code 1)".
///
/// The five cases named in the Phase 2 specification — `deviceOffline`, `permissionDenied`,
/// `diskFull`, `fileNotFound`, `transferFailed` — are all present and each is **reachable**:
/// every one is produced by `classify` from a real `adb` stderr signature. `invalidPath`,
/// `commandFailed` and `unknown` are the residual cases required so that an unrecognised
/// failure has somewhere truthful to land instead of being coerced into a plausible-but-wrong
/// category.
enum StorageError: Error, Equatable, CustomStringConvertible {

    /// No device is attached, or the attached device is offline/unauthorized.
    case deviceOffline

    /// The device filesystem refused the operation (mode, SELinux, or a read-only mount).
    case permissionDenied(path: String)

    /// The device has no free space for the operation.
    case diskFull(path: String)

    /// The named path does not exist on the device (or, for a download destination, the source).
    case fileNotFound(path: String)

    /// The transfer ran but could not be completed or verified.
    ///
    /// Carries a reason because the causes are genuinely different — a size mismatch after a
    /// truncated `adb push` and a dropped link mid-`pull` are both "transfer failed" but want
    /// different user-facing wording.
    case transferFailed(path: String, reason: String)

    /// The caller supplied a path the storage layer cannot accept.
    ///
    /// Its message always names the rule that failed (relative path, `..`, or outside the
    /// storage root) so a caller can tell the cases apart without parsing prose.
    case invalidPath(String)

    /// An `adb` command exited non-zero with a signature that matched no known category.
    case commandFailed(command: String, exitCode: Int, stderr: String)

    /// A failure with no further structure.
    case unknown(String)

    // MARK: - Presentation

    var description: String {
        switch self {
        case .deviceOffline:
            return "The Pixel 7a is offline or disconnected"
        case .permissionDenied(let path):
            return "Permission denied on the device: \(path)"
        case .diskFull(let path):
            return "Not enough space on the Pixel for \(path)"
        case .fileNotFound(let path):
            return "No such file or folder: \(path)"
        case .transferFailed(let path, let reason):
            return "Transfer failed for \(path): \(reason)"
        case .invalidPath(let reason):
            return "Invalid storage path: \(reason)"
        case .commandFailed(let command, let exitCode, let stderr):
            return "Storage command failed: \(command) (exit code \(exitCode)): \(stderr)"
        case .unknown(let message):
            return "Storage error: \(message)"
        }
    }

    // MARK: - Classification

    /// Maps a non-zero `adb` result onto a storage category from its stderr signature.
    ///
    /// The match is on lowercased stderr substrings. It is **best-effort classification, not a
    /// parser**: `adb`/Toybox does not emit stable error codes here, so an unrecognised message
    /// falls through to `commandFailed` with the raw stderr preserved rather than being forced
    /// into a category it may not belong to.
    static func classify(
        command: String,
        exitCode: Int,
        stderr: String,
        path: String
    ) -> StorageError {
        let lowered = stderr.lowercased()

        if lowered.contains("no space left") || lowered.contains("disk full") || lowered.contains("enospc") {
            return .diskFull(path: path)
        }

        if lowered.contains("permission denied")
            || lowered.contains("operation not permitted")
            || lowered.contains("eacces")
            || lowered.contains("read-only file system") {
            return .permissionDenied(path: path)
        }

        if lowered.contains("no such file")
            || lowered.contains("not found")
            || lowered.contains("does not exist") {
            return .fileNotFound(path: path)
        }

        if lowered.contains("device offline")
            || lowered.contains("device not found")
            || lowered.contains("no devices")
            || lowered.contains("device unauthorized") {
            return .deviceOffline
        }

        return .commandFailed(
            command: command,
            exitCode: exitCode,
            stderr: stderr.trimmingCharacters(in: .whitespacesAndNewlines)
        )
    }

    /// Translates any error surfaced by the transport or Foundation into the storage vocabulary.
    ///
    /// The device-state cases collapse onto `deviceOffline` on purpose: from the storage UI's
    /// point of view, "not found", "unauthorized" and "offline" are one actionable state —
    /// "the Pixel is not reachable right now". The transport keeps them distinct for its own
    /// callers; the storage layer does not need that granularity.
    static func from(_ error: Error, path: String) -> StorageError {
        if let storage = error as? StorageError {
            return storage
        }

        if let pixelError = error as? PixelDesktopError {
            switch pixelError {
            case .deviceNotFound, .deviceUnauthorized, .deviceOffline:
                return .deviceOffline
            case .adbCommandFailed(let command, let exitCode, let stderr):
                return classify(command: command, exitCode: exitCode, stderr: stderr, path: path)
            case .timeout(let operation, _):
                return .transferFailed(path: path, reason: "timed out during \(operation)")
            case .cancelled:
                return .transferFailed(path: path, reason: "the operation was cancelled")
            case .adbTransportError(let message):
                return .transferFailed(path: path, reason: message)
            case .invalidInput(let message):
                return .invalidPath(message)
            default:
                return .unknown(pixelError.description)
            }
        }

        return .unknown(error.localizedDescription)
    }
}
