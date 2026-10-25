import Foundation

/// The install/uninstall surface (Phase 3 proposal §5.5, B4).
///
/// Declared as a protocol so the Swift acceptance test and the UI both talk to the same seam, and
/// so the guard can be exercised with a mock transport and no device attached.
protocol AppPackageOperationsProtocol: Sendable {
    /// The set of installed **third-party** packages. Used to tell "an app the user installed"
    /// from "a system component", which is the only distinction that makes an uninstall safe.
    func installedThirdPartyPackages(deviceSerial: String, timeout: TimeInterval) async throws -> [String]

    func planInstall(deviceSerial: String, apkLocalPath: String) throws -> DestructiveActionPlan

    func planUninstall(
        deviceSerial: String,
        packageId: String,
        timeout: TimeInterval
    ) async throws -> DestructiveActionPlan

    func dryRunReport(for plan: DestructiveActionPlan) -> DryRunReport

    func execute(
        _ plan: DestructiveActionPlan,
        deviceSerial: String,
        timeout: TimeInterval
    ) async throws -> PackageOperationResult
}

/// What a package operation did. Only produced after the device actually answered.
struct PackageOperationResult: Equatable, Sendable {
    let planID: UUID
    let operation: DestructiveOperation
    let target: String
    let command: String
    let executedAt: Date
    let exitCode: Int32
    let stdout: String
    let stderr: String
}

/// Install and uninstall implemented over ADB, behind the confirmed-dry-run gate (D3).
///
/// ## Why this is not part of `ADBAppOperations`
///
/// `ADBAppOperations` observes and stops applications: its worst mistake is killing a process that
/// restarts. This type *removes bytes from the device*. It carries the audit log because every
/// command it issues must be recorded before it runs, and it keeps the two concerns apart so the
/// containment rules for one cannot be loosened by a change to the other.
///
/// ## Containment
///
/// The uninstall guard is layered, and all of it runs **before** any command is built:
///
/// 1. the identifier must be a bare package id (`ADBAppOperations.validatePackageName`), so no
///    shell fragment can reach the transport;
/// 2. the PixelDesktop worker package is refused outright — B4 must not be able to remove the
///    binary the product depends on;
/// 3. system packages and protected system prefixes are refused (reusing the stop-containment
///    lists, because uninstalling a provider is strictly worse than stopping it);
/// 4. the package must be installed **and** third-party, so the operation cannot be a no-op
///    dressed up as evidence, and cannot reach a component the user never installed.
///
/// Install is contained differently: the APK path must be an absolute, existing `.apk` file with no
/// control characters. **The package an APK contains is not inspected** — reading a binary
/// `AndroidManifest.xml` is not something this layer does — so `install -r` of the worker's own APK
/// would replace the worker. Every install preview says so in its notes. That is a stated limit,
/// not a guarantee.
struct ADBPackageOperations: AppPackageOperationsProtocol {
    private let transport: TransportProtocol
    private let auditLog: DeviceAuditLog

    /// Refusals specific to package mutation.
    enum Refusal: Error, Equatable, CustomStringConvertible {
        case uninstallWorkerPackage(packageName: String)
        case uninstallProtectedPackage(packageName: String)
        case notInstalled(packageName: String)
        case notThirdParty(packageName: String)
        case invalidAPKPath(String)
        case planDoesNotMatchOperation(expected: DestructiveOperation, actual: DestructiveOperation)

        var description: String {
            switch self {
            case .uninstallWorkerPackage(let name):
                return "Refusing to uninstall '\(name)': it is the PixelDesktop worker package"
            case .uninstallProtectedPackage(let name):
                return "Refusing to uninstall '\(name)': it is a protected system package"
            case .notInstalled(let name):
                return "Refusing to uninstall '\(name)': it is not installed on this device"
            case .notThirdParty(let name):
                return "Refusing to uninstall '\(name)': it is not a third-party package"
            case .invalidAPKPath(let reason):
                return "Refusing to install: \(reason)"
            case .planDoesNotMatchOperation(let expected, let actual):
                return "Plan is for \(actual.displayName.lowercased()), not \(expected.displayName.lowercased())"
            }
        }
    }

    init(transport: TransportProtocol, auditLog: DeviceAuditLog) {
        self.transport = transport
        self.auditLog = auditLog
    }

    // MARK: - Observation

    func installedThirdPartyPackages(
        deviceSerial: String,
        timeout: TimeInterval
    ) async throws -> [String] {
        let serial = try Self.validateSerial(deviceSerial)

        let result = try await transport.shell(
            deviceSerial: serial,
            command: "pm list packages -3",
            timeout: timeout
        )

        guard result.isSuccess else {
            throw PixelDesktopError.adbCommandFailed(
                command: "pm list packages -3",
                exitCode: Int(result.exitCode),
                stderr: result.stderr
            )
        }

        return ADBAppOperations.parsePackageList(result.stdout)
    }

    // MARK: - Planning

    func planInstall(deviceSerial: String, apkLocalPath: String) throws -> DestructiveActionPlan {
        let serial = try Self.validateSerial(deviceSerial)
        let apk = try Self.validateAPKPath(apkLocalPath)

        return DestructiveActionPlan(
            operation: .appInstall,
            target: apk,
            command: Self.renderInstallCommand(deviceSerial: serial, apkPath: apk),
            notes: [
                "installs with -r (replace): a package of the same id already on the device is overwritten",
                "the APK's manifest is not inspected before the command runs — the package id it "
                    + "contains is unknown to this layer, so the APK for the PixelDesktop worker must "
                    + "never be handed to this call",
                "the destination is the device's user data partition; removing it needs a confirmed uninstall"
            ]
        )
    }

    func planUninstall(
        deviceSerial: String,
        packageId: String,
        timeout: TimeInterval
    ) async throws -> DestructiveActionPlan {
        let serial = try Self.validateSerial(deviceSerial)
        let packageName = try ADBAppOperations.validatePackageName(packageId)
        try Self.assertUninstallable(packageName)

        // Presence and provenance are read from the device, not assumed. A refusal here is the
        // difference between "nothing to do" and evidence that would be a lie.
        let thirdParty = try await installedThirdPartyPackages(
            deviceSerial: serial,
            timeout: timeout
        )

        guard thirdParty.contains(packageName) else {
            // Distinguish "installed, but not third-party" from "not installed at all".
            let all = try await transport.shell(
                deviceSerial: serial,
                command: "pm list packages",
                timeout: timeout
            )
            let installed = all.isSuccess ? ADBAppOperations.parsePackageList(all.stdout) : []
            if installed.contains(packageName) {
                throw Refusal.notThirdParty(packageName: packageName)
            }
            throw Refusal.notInstalled(packageName: packageName)
        }

        return DestructiveActionPlan(
            operation: .appUninstall,
            target: packageName,
            command: Self.renderUninstallCommand(deviceSerial: serial, packageName: packageName),
            notes: [
                "removes the package and its private data directory",
                "reinstall requires an APK; the bytes are not kept by this operation",
                "leaves \(Self.protectedPackageCount) protected packages and the PixelDesktop worker untouched"
            ]
        )
    }

    func dryRunReport(for plan: DestructiveActionPlan) -> DryRunReport {
        plan.report
    }

    /// Convenience for the UI: the preview a user approves, with the plan's own notes.
    func preview(for plan: DestructiveActionPlan) -> String {
        plan.report.preview
    }

    // MARK: - Execution

    func execute(
        _ plan: DestructiveActionPlan,
        deviceSerial: String,
        timeout: TimeInterval
    ) async throws -> PackageOperationResult {
        let serial = try Self.validateSerial(deviceSerial)

        guard plan.operation == .appInstall || plan.operation == .appUninstall else {
            throw Refusal.planDoesNotMatchOperation(
                expected: .appUninstall,
                actual: plan.operation
            )
        }

        guard let operand = plan.target, !operand.isEmpty else {
            throw PixelDesktopError.invalidInput("Plan has no target to act on")
        }

        // Re-validate the operand at execution time. The plan is a value: it can be constructed by
        // hand, so the guard must not trust that planning ran.
        switch plan.operation {
        case .appInstall:
            _ = try Self.validateAPKPath(operand)
        case .appUninstall:
            let packageName = try ADBAppOperations.validatePackageName(operand)
            try Self.assertUninstallable(packageName)
        default:
            break
        }

        // The gate. Nothing is built or sent for an unconfirmed plan.
        guard plan.confirmed else {
            auditLog.append(
                operation: plan.operation == .appInstall ? .appInstall : .appUninstall,
                target: operand,
                outcome: .refused,
                detail: DryRunError.dryRunNotConfirmed(operation: plan.operation).description
            )
            throw DryRunError.dryRunNotConfirmed(operation: plan.operation)
        }

        // Append-before-execute: the attempt is durable before the device is touched.
        let attempt = auditLog.begin(
            operation: plan.operation == .appInstall ? .appInstall : .appUninstall,
            target: operand,
            detail: plan.command
        )

        let result: TransportResult
        do {
            result = try await plan.execute { _ in
                switch plan.operation {
                case .appInstall:
                    return try await transport.install(
                        deviceSerial: serial,
                        apkPath: operand,
                        replace: true,
                        timeout: timeout
                    )
                default:
                    return try await transport.execute(
                        command: "-s",
                        arguments: [serial, "uninstall", operand],
                        timeout: timeout
                    )
                }
            }
        } catch {
            auditLog.resolve(
                attempt,
                outcome: .failed,
                detail: "transport error: \(error.localizedDescription)"
            )
            throw PixelDesktopError.adbTransportError(error.localizedDescription)
        }

        guard result.isSuccess, Self.isSuccessOutput(result.stdout) else {
            auditLog.resolve(
                attempt,
                outcome: .failed,
                detail: "\(plan.command) exited \(result.exitCode): \(Self.failureDetail(result))"
            )
            throw PixelDesktopError.adbCommandFailed(
                command: plan.command,
                exitCode: Int(result.exitCode),
                stderr: Self.failureDetail(result)
            )
        }

        auditLog.resolve(attempt, outcome: .executed, detail: plan.command)

        return PackageOperationResult(
            planID: plan.id,
            operation: plan.operation,
            target: operand,
            command: plan.command,
            executedAt: Date(),
            exitCode: result.exitCode,
            stdout: result.stdout,
            stderr: result.stderr
        )
    }

    // MARK: - Validation and containment

    /// Uninstall containment that needs no device read.
    ///
    /// Runs at planning **and** at execution, so a hand-built confirmed plan cannot skip it.
    static func assertUninstallable(_ packageName: String) throws {
        guard packageName != ADBAppOperations.workerPackageName else {
            throw Refusal.uninstallWorkerPackage(packageName: packageName)
        }

        if ADBAppOperations.protectedPackages.contains(packageName) {
            throw Refusal.uninstallProtectedPackage(packageName: packageName)
        }

        for prefix in ADBAppOperations.protectedPrefixes where packageName.hasPrefix(prefix) {
            throw Refusal.uninstallProtectedPackage(packageName: packageName)
        }
    }

    /// Validates a local APK path and returns it unchanged.
    ///
    /// The path is passed to `adb` as a single argv element, never through a shell, but it is still
    /// shape-checked: a relative path, a directory, a non-APK file or a name containing a newline
    /// is a caller mistake that would otherwise surface as an opaque adb error.
    static func validateAPKPath(_ path: String) throws -> String {
        let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)

        guard !trimmed.isEmpty else {
            throw Refusal.invalidAPKPath("path must not be empty")
        }

        guard trimmed.hasPrefix("/") else {
            throw Refusal.invalidAPKPath("path must be absolute: '\(path)'")
        }

        guard !trimmed.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else {
            throw Refusal.invalidAPKPath("path must not contain control characters")
        }

        guard trimmed.lowercased().hasSuffix(".apk") else {
            throw Refusal.invalidAPKPath("not an .apk file: '\(path)'")
        }

        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: trimmed, isDirectory: &isDirectory),
              !isDirectory.boolValue else {
            throw Refusal.invalidAPKPath("no such file: '\(path)'")
        }

        return trimmed
    }

    static func validateSerial(_ deviceSerial: String) throws -> String {
        let trimmed = deviceSerial.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw PixelDesktopError.invalidInput("Device serial must not be empty")
        }
        guard !trimmed.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else {
            throw PixelDesktopError.invalidInput("Device serial must not contain control characters")
        }
        return trimmed
    }

    // MARK: - Command rendering

    /// `adb -s <serial> install -r <apk>` — the exact command `execute` issues.
    static func renderInstallCommand(deviceSerial: String, apkPath: String) -> String {
        render(["adb", "-s", deviceSerial, "install", "-r", apkPath])
    }

    /// `adb -s <serial> uninstall <package>` — the exact command `execute` issues.
    static func renderUninstallCommand(deviceSerial: String, packageName: String) -> String {
        render(["adb", "-s", deviceSerial, "uninstall", packageName])
    }

    /// Renders argv the way a shell would receive it, quoting only when it must.
    ///
    /// The preview's job is to be the command, not a summary of it: an unquoted path with a space
    /// in it would display a *different* command from the one executed.
    static func render(_ arguments: [String]) -> String {
        arguments.map { argument -> String in
            let safe = CharacterSet(charactersIn:
                "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789@%_+=:,./-")
            if !argument.isEmpty, argument.unicodeScalars.allSatisfy({ safe.contains($0) }) {
                return argument
            }
            return "'" + argument.replacingOccurrences(of: "'", with: "'\\''") + "'"
        }.joined(separator: " ")
    }

    // MARK: - Output interpretation

    /// `adb install` and `adb uninstall` report failure on **stdout** and still exit 0.
    ///
    /// Treating exit code alone as success would record a refused install as an executed one, so
    /// the platform's own words are checked too.
    static func isSuccessOutput(_ stdout: String) -> Bool {
        let text = stdout.lowercased()
        if text.contains("failure") { return false }
        if text.contains("error") { return false }
        if text.contains("success") { return true }
        // No verdict word: fall back to the exit code, which the caller has already checked.
        return true
    }

    static func failureDetail(_ result: TransportResult) -> String {
        let stderr = result.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
        if !stderr.isEmpty { return stderr }
        let stdout = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        return stdout.isEmpty ? "exit \(result.exitCode) with no output" : stdout
    }

    /// Number of protected packages, quoted in the uninstall preview so the promise is concrete.
    static var protectedPackageCount: Int { ADBAppOperations.protectedPackages.count }
}
