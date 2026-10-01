import Foundation

enum PixelDesktopError: Error, Equatable, CustomStringConvertible {
    case deviceNotFound
    case deviceUnauthorized
    case deviceOffline
    case adbCommandFailed(command: String, exitCode: Int, stderr: String)
    case adbTransportError(String)
    case invalidInput(String)
    case timeout(operation: String, duration: TimeInterval)
    case cancelled
    case verificationFailed(reason: String)
    case workerError(String)
    case unknown(String)

    var description: String {
        switch self {
        case .deviceNotFound:
            return "No authorized Android device found"
        case .deviceUnauthorized:
            return "Device is unauthorized. Please accept the ADB authorization prompt on the device."
        case .deviceOffline:
            return "Device is offline"
        case .adbCommandFailed(let command, let exitCode, let stderr):
            return "ADB command failed: \(command) (exit code \(exitCode)): \(stderr)"
        case .adbTransportError(let message):
            return "ADB transport error: \(message)"
        case .invalidInput(let reason):
            return "Invalid input: \(reason)"
        case .timeout(let operation, let duration):
            return "Operation timed out: \(operation) after \(String(format: "%.1f", duration))s"
        case .cancelled:
            return "Operation was cancelled"
        case .verificationFailed(let reason):
            return "Verification failed: \(reason)"
        case .workerError(let message):
            return "Worker error: \(message)"
        case .unknown(let message):
            return "Unknown error: \(message)"
        }
    }

    var isRecoverable: Bool {
        switch self {
        case .deviceNotFound, .deviceUnauthorized, .deviceOffline:
            return true
        case .adbCommandFailed, .adbTransportError:
            return true
        case .timeout, .cancelled:
            return true
        case .invalidInput, .verificationFailed, .workerError:
            return false
        case .unknown:
            return false
        }
    }
}
