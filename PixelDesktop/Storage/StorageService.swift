import Foundation

/// File operations on the device, implemented over ADB.
///
/// ## Layering
///
/// Depends on `TransportProtocol`, never on `ADBTransport`, so it is unit-testable against
/// `MockTransport` with no device attached — the same seam `ADBAppOperations` and
/// `DeviceEnricher` use. All operations are bound to one `deviceSerial`, supplied at init.
///
/// ## Path model and containment
///
/// The device-visible storage root is `/sdcard/PixelDesktop/` (decision §7 of
/// `docs/PROPOSAL-REMOTE-STORAGE.md`). **Every** remote path crosses
/// `normalizeStoragePath(_:)` before a command is issued, which enforces three rules:
///
/// 1. the path is absolute,
/// 2. it contains no `..` component, and
/// 3. after normalisation it is the storage root or beneath it.
///
/// This is a real boundary, not a cosmetic one: `adb shell` runs its argument string through
/// the device shell, and `adb` itself resolves `..` on the device (ADR-010). Containment is
/// therefore enforced here, before anything reaches `adb`.
///
/// ## Command injection
///
/// Remote paths are additionally **single-quoted** into the shell command by `shellQuote(_:)`,
/// with embedded single quotes escaped as `'\''`. Even a path that survives containment (say a
/// file literally named `a; rm -rf /`) is passed to the device shell as one inert argument.
/// Containment bounds *where* a command may act; quoting bounds *what* it can do — the two are
/// independent layers and neither substitutes for the other.
struct StorageService: Sendable {

    /// The dedicated device folder this service is allowed to touch.
    static let storageRoot = "/sdcard/PixelDesktop"

    let deviceSerial: String
    let transport: TransportProtocol

    /// Cadence for transfer progress polling. Injectable so tests do not wait on a production
    /// interval.
    let progressPollInterval: TimeInterval

    /// Bounds every single `adb shell` command. Transfers use a longer, separate budget because
    /// a large `push`/`pull` is legitimately slow — see `transferTimeout`.
    let commandTimeout: TimeInterval

    /// Bounds a whole `push`/`pull`. Deliberately much larger than `commandTimeout`.
    let transferTimeout: TimeInterval

    init(
        deviceSerial: String,
        transport: TransportProtocol,
        progressPollInterval: TimeInterval = 0.25,
        commandTimeout: TimeInterval = 30,
        transferTimeout: TimeInterval = 3600
    ) {
        self.deviceSerial = deviceSerial
        self.transport = transport
        self.progressPollInterval = progressPollInterval
        self.commandTimeout = commandTimeout
        self.transferTimeout = transferTimeout
    }

    // MARK: - Listing

    /// Lists one directory on the device.
    ///
    /// - Parameter path: an absolute path at or beneath `storageRoot`.
    /// - Returns: the directory's entries, with `.`/`..` filtered out. Directory symbols are
    ///   reported on `StorageItem.isDirectory`.
    /// - Throws: `StorageError.fileNotFound` when the directory is absent,
    ///   `StorageError.permissionDenied` when it is not readable, and the other
    ///   `StorageError` cases otherwise.
    func list(path: String) async throws -> [StorageItem] {
        let normalized = try Self.normalizeStoragePath(path)
        let command = "ls -la \(Self.shellQuote(normalized))"
        let result = try await run(command: command, path: normalized)
        return StorageItem.parseListing(result.stdout, parentPath: normalized)
    }

    // MARK: - Transfers

    /// Uploads a local file to the device with `adb push`.
    ///
    /// - Parameters:
    ///   - localPath: an absolute Mac-side path to a regular file.
    ///   - remotePath: an absolute device path at or beneath `storageRoot`.
    ///   - onProgress: optional progress samples. Nil means "do not poll" — the transfer still
    ///     verifies its size, it simply reports nothing along the way.
    /// - Throws: `StorageError.fileNotFound` if the local source is missing,
    ///   `StorageError.invalidPath` if it is not a regular file, and
    ///   `StorageError.transferFailed` if the pushed size does not match the source size.
    func upload(
        localPath: String,
        remotePath: String,
        onProgress: StorageProgressHandler? = nil
    ) async throws {
        let remote = try Self.normalizeStoragePath(remotePath)
        let local = try Self.validateLocalSource(localPath)
        let totalBytes = Self.localFileSize(local) ?? 0

        let transfer = StorageTransfer(
            direction: .upload,
            localPath: local,
            remotePath: remote,
            totalBytes: totalBytes
        )

        let poller = makePoller(transfer: transfer, remote: remote, onProgress: onProgress)
        poller?.start()

        let result: TransportResult
        do {
            result = try await transport.push(
                deviceSerial: deviceSerial,
                localPath: local,
                remotePath: remote,
                timeout: transferTimeout
            )
        } catch {
            await poller?.abort()
            throw StorageError.from(error, path: remote)
        }

        guard result.isSuccess else {
            await poller?.abort()
            throw StorageError.classify(
                command: "push \(local) \(remote)",
                exitCode: Int(result.exitCode),
                stderr: result.stderr,
                path: remote
            )
        }

        let observed = await Self.remoteSize(
            transport: transport,
            deviceSerial: deviceSerial,
            path: remote
        )
        await poller?.stop(transferredBytes: observed ?? totalBytes)

        if let observed, observed != totalBytes {
            throw StorageError.transferFailed(
                path: remote,
                reason: "size mismatch after upload: local file is \(totalBytes) bytes, device has \(observed)"
            )
        }
    }

    /// Downloads a device file to a local path with `adb pull`.
    ///
    /// The remote size is read **before** the pull so the progress total is known; without it a
    /// progress bar could only ever be indeterminate.
    ///
    /// - Parameters:
    ///   - remotePath: an absolute device path at or beneath `storageRoot`.
    ///   - localPath: an absolute Mac-side destination. Its parent directory is created if
    ///     needed. An existing symlink destination is refused (it could redirect the write
    ///     outside the chosen folder).
    ///   - onProgress: optional progress samples.
    /// - Throws: `StorageError.fileNotFound` if the remote file is missing, and
    ///   `StorageError.transferFailed` if the local size does not match the remote size.
    func download(
        remotePath: String,
        localPath: String,
        onProgress: StorageProgressHandler? = nil
    ) async throws {
        let remote = try Self.normalizeStoragePath(remotePath)
        let destination = try Self.validateLocalDestination(localPath)

        guard let totalBytes = await Self.remoteSize(
            transport: transport,
            deviceSerial: deviceSerial,
            path: remote
        ) else {
            throw StorageError.fileNotFound(path: remote)
        }

        let transfer = StorageTransfer(
            direction: .download,
            localPath: destination.path,
            remotePath: remote,
            totalBytes: totalBytes
        )

        let poller = makePoller(transfer: transfer, remote: remote, onProgress: onProgress)
        poller?.start()

        let result: TransportResult
        do {
            result = try await transport.pull(
                deviceSerial: deviceSerial,
                remotePath: remote,
                localPath: destination.path,
                timeout: transferTimeout
            )
        } catch {
            await poller?.abort()
            throw StorageError.from(error, path: remote)
        }

        guard result.isSuccess else {
            await poller?.abort()
            throw StorageError.classify(
                command: "pull \(remote) \(destination.path)",
                exitCode: Int(result.exitCode),
                stderr: result.stderr,
                path: remote
            )
        }

        let observed = Self.localFileSize(destination.path)
        await poller?.stop(transferredBytes: observed ?? totalBytes)

        if let observed, observed != totalBytes {
            throw StorageError.transferFailed(
                path: remote,
                reason: "size mismatch after download: device has \(totalBytes) bytes, local file has \(observed)"
            )
        }
    }

    // MARK: - Mutations

    /// Deletes a file or folder on the device.
    ///
    /// Recursive and idempotent (`rm -rf`): the storage browser deletes whole folders, and a
    /// missing entry is not an error worth surfacing. The storage **root itself** cannot be
    /// deleted — that would take the whole feature offline from inside the feature.
    func delete(path: String) async throws {
        let normalized = try Self.normalizeStoragePath(path)
        guard normalized != Self.storageRoot else {
            throw StorageError.invalidPath("refusing to delete the storage root \(Self.storageRoot)")
        }
        _ = try await run(command: "rm -rf \(Self.shellQuote(normalized))", path: normalized)
    }

    /// Creates a directory (and any missing parents) on the device.
    ///
    /// Idempotent: creating an existing folder succeeds, matching the browser's "New Folder"
    /// action and making retries safe.
    func mkdir(path: String) async throws {
        let normalized = try Self.normalizeStoragePath(path)
        guard normalized != Self.storageRoot else { return }
        _ = try await run(command: "mkdir -p \(Self.shellQuote(normalized))", path: normalized)
    }

    /// Renames or moves an entry on the device.
    ///
    /// - Throws: `StorageError.invalidPath` if either operand is the storage root, which would
    ///   move or overwrite the whole feature.
    func rename(from: String, to: String) async throws {
        let source = try Self.normalizeStoragePath(from)
        let destination = try Self.normalizeStoragePath(to)

        guard source != Self.storageRoot else {
            throw StorageError.invalidPath("refusing to move the storage root \(Self.storageRoot)")
        }
        guard destination != Self.storageRoot else {
            throw StorageError.invalidPath("refusing to replace the storage root \(Self.storageRoot)")
        }

        _ = try await run(
            command: "mv \(Self.shellQuote(source)) \(Self.shellQuote(destination))",
            path: source
        )
    }

    // MARK: - Disk space

    /// Reports used and total bytes on the filesystem holding the storage root.
    ///
    /// Returns `nil` when the answer is unavailable or unparseable — disk space is an
    /// informational read and a failure here must not surface as an error on the browser.
    ///
    /// - Note: The proposal sketched `df -h`. This implementation issues `df -k <root>` instead,
    ///   because `-h` rounds to three significant figures (`1.1G`) and cannot populate an exact
    ///   `UInt64` byte count. `parseDiskSpace` still accepts `-h` output, so both formats work.
    func diskSpace() async -> (used: UInt64, total: UInt64)? {
        let command = "df -k \(Self.shellQuote(Self.storageRoot))"
        guard let result = try? await run(command: command, path: Self.storageRoot) else {
            return nil
        }
        return Self.parseDiskSpace(result.stdout)
    }

    /// Parses `df` output into `(used, total)` bytes.
    ///
    /// Handles both the `-k` layout (1 KiB blocks) and the `-h` layout (human suffixes). The
    /// first non-header data row is used; the header is recognised by its `Filesystem` label,
    /// which both Toybox and GNU `df` emit.
    static func parseDiskSpace(_ output: String) -> (used: UInt64, total: UInt64)? {
        for line in output.components(separatedBy: .newlines) {
            let columns = line.split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init)
            guard columns.count >= 3 else { continue }
            guard !columns[0].lowercased().hasPrefix("filesystem") else { continue }

            if let totalKB = UInt64(columns[1]), let usedKB = UInt64(columns[2]) {
                return (used: usedKB * 1024, total: totalKB * 1024)
            }

            if let total = parseHumanBytes(columns[1]), let used = parseHumanBytes(columns[2]) {
                return (used: used, total: total)
            }
        }
        return nil
    }

    /// Parses a human-readable size such as `110G`, `1.1G`, `512M`, `0`, or `1.5KiB`.
    ///
    /// Suffixes are **binary** (K = 1024), matching how `df -h` reports on Android. A bare
    /// number is treated as bytes.
    static func parseHumanBytes(_ raw: String) -> UInt64? {
        let trimmed = raw.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return nil }

        let digits = trimmed.prefix { $0.isNumber || $0 == "." }
        guard let value = Double(digits) else { return nil }

        let suffix = trimmed.dropFirst(digits.count).uppercased()
        let multiplier: Double
        switch suffix.first {
        case "K": multiplier = 1024
        case "M": multiplier = 1024 * 1024
        case "G": multiplier = 1024 * 1024 * 1024
        case "T": multiplier = 1024 * 1024 * 1024 * 1024
        case "B": multiplier = 1
        case nil: multiplier = 1
        default: return nil
        }

        return UInt64(value * multiplier)
    }

    // MARK: - Path validation

    /// Validates and normalises a remote path against the storage root.
    ///
    /// The returned value is the canonical form used to build commands, so callers never have to
    /// normalise separately. See the type doc comment for the three rules enforced.
    static func normalizeStoragePath(_ path: String) throws -> String {
        guard !path.isEmpty, !path.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw StorageError.invalidPath("path must not be empty")
        }

        guard path.hasPrefix("/") else {
            throw StorageError.invalidPath("path must be absolute: '\(path)'")
        }

        guard path.rangeOfCharacter(from: .controlCharacters) == nil else {
            throw StorageError.invalidPath("path must not contain control characters")
        }

        var components: [String] = []
        for rawComponent in path.split(separator: "/", omittingEmptySubsequences: true) {
            let component = String(rawComponent)
            switch component {
            case ".":
                continue
            case "..":
                throw StorageError.invalidPath("path must not contain '..': '\(path)'")
            default:
                components.append(component)
            }
        }

        let normalized = "/" + components.joined(separator: "/")

        guard normalized == storageRoot || normalized.hasPrefix(storageRoot + "/") else {
            throw StorageError.invalidPath(
                "path '\(path)' is outside the storage root '\(storageRoot)'"
            )
        }

        return normalized
    }

    /// Quotes a value for safe inclusion in a device shell command.
    ///
    /// Wraps in single quotes (in which the device shell expands nothing) and closes/reopens the
    /// quote around each embedded single quote as `'\''`. This is the standard POSIX-safe
    /// technique and makes arbitrary filenames inert.
    static func shellQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    /// Validates a Mac-side upload source.
    ///
    /// Rejects non-absolute paths, missing files, symlinks (a symlink source can point outside
    /// anywhere the user believed they picked) and directories (`adb push` would recurse).
    static func validateLocalSource(_ path: String) throws -> String {
        guard path.hasPrefix("/") else {
            throw StorageError.invalidPath("local source must be an absolute path: '\(path)'")
        }

        guard FileManager.default.fileExists(atPath: path) else {
            throw StorageError.fileNotFound(path: path)
        }

        let attributes = try? FileManager.default.attributesOfItem(atPath: path)
        if let type = attributes?[.type] as? FileAttributeType, type == .typeSymbolicLink {
            throw StorageError.invalidPath("refusing to upload a symbolic link: '\(path)'")
        }

        var isDirectory: ObjCBool = false
        FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory)
        guard !isDirectory.boolValue else {
            throw StorageError.invalidPath("only regular files can be uploaded: '\(path)'")
        }

        return path
    }

    /// Validates a Mac-side download destination, creating its parent directory if needed.
    static func validateLocalDestination(_ path: String) throws -> URL {
        guard path.hasPrefix("/") else {
            throw StorageError.invalidPath("local destination must be an absolute path: '\(path)'")
        }

        let url = URL(fileURLWithPath: path)

        // An existing symlink destination is refused: writing through it would land the file
        // wherever the link points, not where the save panel said.
        if let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
           let type = attributes[.type] as? FileAttributeType,
           type == .typeSymbolicLink {
            throw StorageError.invalidPath("refusing to overwrite a symbolic link: '\(path)'")
        }

        let parent = url.deletingLastPathComponent()
        if !FileManager.default.fileExists(atPath: parent.path) {
            do {
                try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
            } catch {
                throw StorageError.invalidPath(
                    "could not create destination folder '\(parent.path)': \(error.localizedDescription)"
                )
            }
        }

        return url
    }

    // MARK: - Probes and local helpers

    /// Reads a remote file's size via `stat -c %s`. Returns `nil` when absent or unparseable.
    static func remoteSize(
        transport: TransportProtocol,
        deviceSerial: String,
        path: String
    ) async -> UInt64? {
        let command = "stat -c %s \(shellQuote(path))"
        guard let result = try? await transport.shell(
            deviceSerial: deviceSerial,
            command: command,
            timeout: 15
        ), result.isSuccess else {
            return nil
        }

        // Reuse the worker contract's parser: it already tolerates Toybox noise and returns nil
        // for a non-numeric answer, so "missing" stays distinguishable from "zero bytes".
        guard let size = WorkerTransferContract.parseRemoteSize(result.stdout) else { return nil }
        return UInt64(max(0, size))
    }

    /// Reads a local file's size, or `nil` when it cannot be read.
    static func localFileSize(_ path: String) -> UInt64? {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: path),
              let size = attributes[.size] as? NSNumber else {
            return nil
        }
        return size.uint64Value
    }

    // MARK: - Command execution

    /// Runs a remote shell command, mapping any failure into the storage vocabulary.
    private func run(command: String, path: String) async throws -> TransportResult {
        do {
            let result = try await transport.shell(
                deviceSerial: deviceSerial,
                command: command,
                timeout: commandTimeout
            )

            guard result.isSuccess else {
                throw StorageError.classify(
                    command: command,
                    exitCode: Int(result.exitCode),
                    stderr: result.stderr,
                    path: path
                )
            }

            return result
        } catch {
            throw StorageError.from(error, path: path)
        }
    }

    /// Builds the progress poller for a transfer, or `nil` when no handler was supplied.
    private func makePoller(
        transfer: StorageTransfer,
        remote: String,
        onProgress: StorageProgressHandler?
    ) -> StorageTransferPoller? {
        guard let onProgress else { return nil }

        let transport = self.transport
        let deviceSerial = self.deviceSerial

        if transfer.direction == .upload {
            return StorageTransferPoller(
                transfer: transfer,
                interval: progressPollInterval,
                probe: { await Self.remoteSize(transport: transport, deviceSerial: deviceSerial, path: remote) ?? 0 },
                onProgress: onProgress
            )
        } else {
            let localPath = transfer.localPath
            return StorageTransferPoller(
                transfer: transfer,
                interval: progressPollInterval,
                probe: { Self.localFileSize(localPath) ?? 0 },
                onProgress: onProgress
            )
        }
    }
}
