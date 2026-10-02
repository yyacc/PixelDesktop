//
//  ModelProvisioning.swift
//  PixelDesktop
//
//  Phase 6 — model artifact provisioning.
//
//  The model is DATA, not code. The reconnaissance established that /storage/emulated is
//  mounted `noexec`, which rules out executing a runtime from the exchange directory but does
//  not affect the model at all. That distinction is the reason the model can live in the
//  worker's own external files directory.
//
//  Ownership rule, learned the hard way in D8/FAIL-004 instance 3: the APP creates and owns
//  the model directory. An adb-created directory is owned by shell:ext_data_rw and the app
//  cannot write it. Model provisioning therefore never creates a directory.
//

import Foundation

/// The fixed model contract. No caller-supplied paths — the same narrowness principle as
/// ADR-010. The caller may not name a file or a directory.
struct ModelContract: Equatable, Sendable {
    /// Fixed remote directory, relative to the worker's app-owned external files root.
    /// The worker creates it; adb never does.
    static let remoteModelDirectoryName = "model"

    /// The single fixed model filename for the first proof.
    static let modelFileName = "qwen2.5-1.5b-instruct-q4_k_m.gguf"

    /// Fixed remote path, derived — never supplied.
    static var remoteModelPath: String {
        "\(WorkerTransferContract.remoteRoot)/\(remoteModelDirectoryName)/\(modelFileName)"
    }

    /// Fixed remote directory.
    static var remoteModelDirectory: String {
        "\(WorkerTransferContract.remoteRoot)/\(remoteModelDirectoryName)"
    }

    /// The expected SHA-256 of the exact artifact used for the first proof.
    ///
    /// Recorded from the downloaded artifact. This is what makes provisioning a *verified*
    /// operation rather than a hopeful push: the device re-hashes what it received and the
    /// two must agree.
    static let expectedSha256 =
        "6a1a2eb6d15622bf3c96857206351ba97e1af16c30d7a74ee38970e434e9407e"

    /// Exact byte size of the artifact.
    static let expectedByteCount = 1_117_320_736

    /// Ceiling for a model transfer. Raised deliberately from the D8 payload cap, which was
    /// sized for a JSON job. This is an extension of the contract, not a bypass of it: the
    /// path is still fixed, the file is still validated as a regular file, and the transfer is
    /// still size-verified.
    static let maximumModelBytes = 2_147_483_648 // 2 GiB
}

/// A model artifact on the Mac, validated before any transfer begins.
struct LocalModelArtifact: Equatable, Sendable {
    let url: URL
    let byteCount: Int
    let sha256: String

    var fileName: String { url.lastPathComponent }
}

enum ModelProvisioningError: Error, Equatable, CustomStringConvertible {
    case modelFileMissing(String)
    case modelIsNotARegularFile(String)
    case modelTooLarge(actual: Int, maximum: Int)
    case modelSizeMismatch(expected: Int, actual: Int)
    case modelHashMismatch(expected: String, actual: String)
    case modelDirectoryMissingOnDevice(String)
    case remoteSizeUnreadable(String)
    case deviceHashUnreadable(String)

    var description: String {
        switch self {
        case .modelFileMissing(let path):
            return "model artifact not found at \(path)"
        case .modelIsNotARegularFile(let path):
            return "model artifact at \(path) is not a regular file"
        case .modelTooLarge(let actual, let maximum):
            return "model is \(actual) bytes, ceiling is \(maximum)"
        case .modelSizeMismatch(let expected, let actual):
            return "model size mismatch: expected \(expected), got \(actual)"
        case .modelHashMismatch(let expected, let actual):
            return "model hash mismatch: expected \(expected), device reported \(actual)"
        case .modelDirectoryMissingOnDevice(let path):
            return "the worker has not created its model directory at \(path) yet"
        case .remoteSizeUnreadable(let detail):
            return "could not read the remote model size: \(detail)"
        case .deviceHashUnreadable(let detail):
            return "could not read the device-side model hash: \(detail)"
        }
    }
}

/// Provisioning logic. Deterministic and testable; the device work lives in the operations layer.
enum ModelProvisioning {

    /// Validates a local artifact before it is offered to the transfer layer.
    ///
    /// Mirrors `WorkerTransferContract.validateRegularFile` — same narrowness, applied to a
    /// much larger file. A directory or symlink is refused here for the same reason it is
    /// refused there: adb would follow or recurse, and the contract is one regular file.
    static func validateLocalArtifact(
        at url: URL,
        fileManager: FileManager = .default
    ) throws -> LocalModelArtifact {
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory) else {
            throw ModelProvisioningError.modelFileMissing(url.path)
        }
        guard !isDirectory.boolValue else {
            throw ModelProvisioningError.modelIsNotARegularFile(url.path)
        }

        let attributes = try fileManager.attributesOfItem(atPath: url.path)
        guard let type = attributes[.type] as? FileAttributeType, type == .typeRegular else {
            throw ModelProvisioningError.modelIsNotARegularFile(url.path)
        }
        guard let size = attributes[.size] as? Int else {
            throw ModelProvisioningError.modelFileMissing(url.path)
        }
        guard size <= ModelContract.maximumModelBytes else {
            throw ModelProvisioningError.modelTooLarge(
                actual: size, maximum: ModelContract.maximumModelBytes)
        }

        return LocalModelArtifact(url: url, byteCount: size, sha256: "")
    }

    /// Compares what the device reports against what we sent.
    ///
    /// Size first (cheap, catches truncation), then hash (catches corruption). Both are
    /// required: a truncated file and a corrupted file of the same length are different
    /// failures and should not be conflated.
    static func verifyTransfer(
        expectedBytes: Int,
        deviceBytes: Int,
        expectedSha256: String,
        deviceSha256: String
    ) throws {
        guard expectedBytes == deviceBytes else {
            throw ModelProvisioningError.modelSizeMismatch(
                expected: expectedBytes, actual: deviceBytes)
        }
        let normalized = deviceSha256.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard normalized == expectedSha256.lowercased() else {
            throw ModelProvisioningError.modelHashMismatch(
                expected: expectedSha256, actual: normalized)
        }
    }

    /// Parses `sha256sum` / `shasum -a 256` output from the device.
    ///
    /// Toybox's sha256sum prints `<hash>  <path>`. Anything else is refused rather than
    /// guessed at.
    static func parseSha256Output(_ output: String) -> String? {
        let trimmed = output.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        guard let firstToken = trimmed.split(separator: " ").first else { return nil }
        let candidate = String(firstToken).lowercased()
        guard candidate.count == 64,
              candidate.allSatisfy({ $0.isHexDigit })
        else { return nil }
        return candidate
    }
}
