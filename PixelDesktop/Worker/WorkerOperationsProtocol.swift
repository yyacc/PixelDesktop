import Foundation

/// The only surface the rest of the application uses to move worker payloads.
///
/// **No method takes a path.** Remote and local locations are fixed by
/// `WorkerTransferContract`; the caller supplies *content*, never a location. That is what
/// makes every path-traversal case unreachable by construction rather than merely blocked.
///
/// Responsibilities follow ADR-009's split: this layer decides, the transport executes.
/// `push()`/`pull()` on `TransportProtocol` take validated absolute paths and hold no worker
/// semantics; this layer owns the paths, the validation, and the policy.
protocol WorkerOperationsProtocol: Sendable {
    /// Creates the device-side workspace directory.
    ///
    /// Must run before a submission. `/data/local/tmp` is cleared on reboot, so this is not
    /// assumed to persist.
    func prepareRemoteWorkspace(deviceSerial: String, timeout: TimeInterval) async throws

    /// Validates and submits the input payload, returning the transfer outcome.
    ///
    /// - Parameter text: the DTCA-1 input. Validated against the workload's own limits
    ///   (10,000 characters, no null bytes) before anything touches the device.
    /// - Returns: the size verification for the transfer.
    func submitInput(
        deviceSerial: String,
        text: String,
        timeout: TimeInterval
    ) async throws -> WorkerTransferContract.SizeVerification

    /// Retrieves the result payload and decodes it.
    ///
    /// - Returns: the decoded result plus the size verification.
    /// - Throws: `workerError` when the worker produced no result, `verificationFailed` when
    ///   the result is not valid JSON.
    func retrieveResult(
        deviceSerial: String,
        timeout: TimeInterval
    ) async throws -> WorkerResultRetrieval
}

/// A retrieved and decoded worker result, with its transfer evidence.
struct WorkerResultRetrieval: Equatable {
    let result: DTCA1Result
    let sizeVerification: WorkerTransferContract.SizeVerification
}

/// Worker operations implemented over ADB.
struct ADBWorkerOperations: WorkerOperationsProtocol {
    private let transport: TransportProtocol

    /// `FileManager` is not `Sendable`, so it is not stored on this `Sendable` struct. The
    /// shared instance is documented as safe for concurrent use and is referenced inline.
    private var fileManager: FileManager { .default }

    init(transport: TransportProtocol) {
        self.transport = transport
    }

    // MARK: - Workspace

    /// Checks that the worker's exchange directory exists.
    ///
    /// **This deliberately does not create the directory.** adb creating it would make it owned by
    /// `shell:ext_data_rw`, which the worker (its own UID, not in `ext_data_rw`) cannot write —
    /// measured on the real device. The worker creates its own directory via
    /// `getExternalFilesDir(null)`; the correct way to ensure it exists is to launch the worker,
    /// which `WorkerComputeProof.ensureWorkspaceExists` does.
    ///
    /// - Throws: `workerError` when the directory is absent, because that means the worker has
    ///   never run and the caller must warm it up first.
    func prepareRemoteWorkspace(deviceSerial: String, timeout: TimeInterval) async throws {
        let result = try await transport.shell(
            deviceSerial: deviceSerial,
            command: WorkerTransferContract.remoteWorkspaceExistsCommand,
            timeout: timeout
        )

        guard result.stdout.contains("EXISTS") else {
            throw PixelDesktopError.workerError(
                "Worker exchange directory does not exist at \(WorkerTransferContract.remoteRoot); "
                + "the worker must be launched once to create it"
            )
        }
    }

    // MARK: - Input

    func submitInput(
        deviceSerial: String,
        text: String,
        timeout: TimeInterval
    ) async throws -> WorkerTransferContract.SizeVerification {
        // Workload limits first — cheapest check, and it keeps oversized input off the device.
        try DTCA1Worker.validateInput(text)

        try WorkerTransferContract.prepareStagingDirectory()

        let inputURL = WorkerTransferContract.localInputPath
        do {
            try text.write(to: inputURL, atomically: true, encoding: .utf8)
        } catch {
            throw PixelDesktopError.invalidInput(
                "Could not write staged job payload: \(error.localizedDescription)"
            )
        }

        // Validates that staging holds a regular, non-symlink file within the size cap.
        let validated = try WorkerTransferContract.validateRegularFile(at: inputURL)

        let result = try await transport.push(
            deviceSerial: deviceSerial,
            localPath: validated.url.path,
            remotePath: WorkerTransferContract.remoteInputPath,
            timeout: timeout
        )

        guard result.isSuccess else {
            throw PixelDesktopError.adbCommandFailed(
                command: "push \(WorkerTransferContract.remoteInputPath)",
                exitCode: Int(result.exitCode),
                stderr: result.stderr
            )
        }

        // D3: confirm what actually landed on the device matches what we sent.
        let remoteSize = try await remoteByteCount(
            deviceSerial: deviceSerial,
            remotePath: WorkerTransferContract.remoteInputPath,
            timeout: timeout
        )

        return WorkerTransferContract.verifySize(expected: validated.byteCount, actual: remoteSize)
    }

    // MARK: - Result

    func retrieveResult(
        deviceSerial: String,
        timeout: TimeInterval
    ) async throws -> WorkerResultRetrieval {
        try WorkerTransferContract.prepareStagingDirectory()

        let resultURL = WorkerTransferContract.localResultPath

        // A stale result from a previous run would be indistinguishable from a fresh one, so
        // remove it first. This deletes only the fixed staging file, never a caller's path.
        if fileManager.fileExists(atPath: resultURL.path) {
            try? fileManager.removeItem(at: resultURL)
        }

        let remoteSize = try await remoteByteCount(
            deviceSerial: deviceSerial,
            remotePath: WorkerTransferContract.remoteResultPath,
            timeout: timeout
        )

        let pull = try await transport.pull(
            deviceSerial: deviceSerial,
            remotePath: WorkerTransferContract.remoteResultPath,
            localPath: resultURL.path,
            timeout: timeout
        )

        guard pull.isSuccess else {
            // `adb pull` exits non-zero and reports `failed to stat remote object` when the
            // worker produced nothing. That is a worker failure, not a transport failure.
            throw PixelDesktopError.workerError(
                "Worker produced no result at \(WorkerTransferContract.remoteResultPath): "
                + pull.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            )
        }

        // The pulled file must itself be a regular file — the same rule as the input side.
        let validated = try WorkerTransferContract.validateRegularFile(at: resultURL)

        let verification = WorkerTransferContract.verifySize(
            expected: remoteSize,
            actual: validated.byteCount
        )

        guard verification.isVerified else {
            throw PixelDesktopError.workerError(
                "Partial result transfer: device reported \(remoteSize) bytes, "
                + "local file is \(validated.byteCount) bytes"
            )
        }

        let data: Data
        do {
            data = try Data(contentsOf: resultURL)
        } catch {
            throw PixelDesktopError.workerError(
                "Could not read retrieved result: \(error.localizedDescription)"
            )
        }

        do {
            let decoded = try JSONDecoder().decode(DTCA1Result.self, from: data)
            return WorkerResultRetrieval(result: decoded, sizeVerification: verification)
        } catch {
            // ADR-004: a result that cannot be parsed is never trusted.
            throw PixelDesktopError.verificationFailed(
                reason: "Result is not valid DTCA-1 JSON: \(error.localizedDescription)"
            )
        }
    }

    // MARK: - Helpers

    /// Reads a remote file's byte count via `stat -c %s`.
    ///
    /// - Throws: `workerError` when the remote path does not exist.
    private func remoteByteCount(
        deviceSerial: String,
        remotePath: String,
        timeout: TimeInterval
    ) async throws -> Int {
        let stat = try await transport.shell(
            deviceSerial: deviceSerial,
            command: "stat -c %s \(remotePath)",
            timeout: timeout
        )

        guard let size = WorkerTransferContract.parseRemoteSize(stat.stdout) else {
            throw PixelDesktopError.workerError(
                "Could not determine size of \(remotePath) on the device"
            )
        }

        return size
    }
}
