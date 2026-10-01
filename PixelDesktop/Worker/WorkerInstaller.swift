import Foundation

/// Installs and identifies the Pixel compute worker.
///
/// ## Scope — deliberately narrow
///
/// This type owns exactly three things:
///
/// 1. **package identity verification** — is the expected package installed, and at which version
/// 2. **install / reinstall semantics** — install, or replace an existing install
/// 3. **installed-version detection** — read the installed `versionCode`
///
/// It is **not** a generalized Android package manager. It does not list packages, uninstall
/// arbitrary packages, clear data, grant permissions, or install anything other than the worker.
/// There is no API here that takes an arbitrary package name to act on.
///
/// ## Why installation is separated from the rest
///
/// Installation is **state-changing**, unlike `push`/`pull`. It runs `adb install`, which
/// modifies the device. It therefore lives behind this narrow abstraction and its transport
/// primitive, and is never exposed to the UI or to Hermes as "install this file".
struct WorkerInstaller {
    private let transport: TransportProtocol

    init(transport: TransportProtocol) {
        self.transport = transport
    }

    /// What is currently installed for the worker package.
    enum InstalledState: Equatable {
        /// The package is not installed.
        case notInstalled

        /// The package is installed at the given version code.
        case installed(versionCode: Int)

        var versionCode: Int? {
            if case .installed(let code) = self { return code }
            return nil
        }

        var isInstalled: Bool {
            if case .installed = self { return true }
            return false
        }
    }

    /// Reads the installed worker version, or reports that it is absent.
    ///
    /// Uses `dumpsys package <pkg>` and looks for `versionCode`. A package that is not installed
    /// produces no match, which is reported as `.notInstalled` rather than as an error — absence
    /// is a valid, expected state.
    func installedState(deviceSerial: String, timeout: TimeInterval = 15) async throws -> InstalledState {
        let result = try await transport.shell(
            deviceSerial: deviceSerial,
            command: "dumpsys package \(WorkerTransferContract.workerPackageName)",
            timeout: timeout
        )

        // `dumpsys package <missing>` exits non-zero with "Unable to find package".
        guard result.isSuccess else {
            return .notInstalled
        }

        guard let versionCode = Self.parseVersionCode(result.stdout) else {
            return .notInstalled
        }

        return .installed(versionCode: versionCode)
    }

    /// Installs the worker APK, replacing any existing install.
    ///
    /// - Parameter apkPath: absolute path to a **regular** APK file. Validated here; a symlink or
    ///   directory is refused for the same reason the transfer contract refuses them.
    /// - Returns: the installed state observed **after** the install, read back from the device
    ///   rather than assumed from the install command's exit code.
    @discardableResult
    func installWorker(
        deviceSerial: String,
        apkPath: String,
        timeout: TimeInterval = 120
    ) async throws -> InstalledState {
        // Reuse the transfer contract's regular-file rule: symlinks and directories are refused.
        let validated = try WorkerTransferContract.validateRegularFile(
            at: URL(fileURLWithPath: apkPath)
        )

        let result = try await transport.install(
            deviceSerial: deviceSerial,
            apkPath: validated.url.path,
            replace: true,
            timeout: timeout
        )

        guard result.isSuccess, !result.stdout.contains("Failure") else {
            throw PixelDesktopError.adbCommandFailed(
                command: "install \(WorkerTransferContract.workerPackageName)",
                exitCode: Int(result.exitCode),
                stderr: result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
            )
        }

        // Read the state back from the device. Do not trust the install command's own report.
        let state = try await installedState(deviceSerial: deviceSerial, timeout: timeout)

        guard state.isInstalled else {
            throw PixelDesktopError.workerError(
                "Install reported success but \(WorkerTransferContract.workerPackageName) is not present afterwards"
            )
        }

        return state
    }

    /// Ensures the expected version is installed, installing only when necessary.
    ///
    /// Idempotent: if the device already has the expected `versionCode`, no install is performed.
    /// This keeps repeated runs cheap and avoids needless state changes.
    @discardableResult
    func ensureInstalled(
        deviceSerial: String,
        apkPath: String,
        expectedVersionCode: Int,
        timeout: TimeInterval = 120
    ) async throws -> InstalledState {
        let current = try await installedState(deviceSerial: deviceSerial, timeout: timeout)

        if current.versionCode == expectedVersionCode {
            return current
        }

        return try await installWorker(deviceSerial: deviceSerial, apkPath: apkPath, timeout: timeout)
    }

    // MARK: - Parsing

    /// Extracts `versionCode` from `dumpsys package` output.
    ///
    /// The line looks like `    versionCode=1 minSdk=31 targetSdk=36`.
    static func parseVersionCode(_ output: String) -> Int? {
        for line in output.components(separatedBy: .newlines) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix("versionCode=") else { continue }

            let afterEquals = trimmed.dropFirst("versionCode=".count)
            let token = afterEquals.prefix { $0.isNumber }
            if let value = Int(token) {
                return value
            }
        }
        return nil
    }
}
