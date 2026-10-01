import Foundation

/// Application/process operations implemented over ADB.
///
/// Depends on `TransportProtocol`, not `ADBTransport`, so it is unit-testable against a
/// mock with no device attached — the same pattern `DeviceEnricher` uses.
///
/// ## Command construction
///
/// Every command string is assembled here from a **fixed template** plus a single
/// validated argument. No method accepts a caller-supplied command, and no command is ever
/// composed by concatenating arbitrary caller input.
///
/// ## Protection model
///
/// See ADR-009. In short: package naming is **not** a security boundary. The containment
/// in `stopApplication` is defence-in-depth against accidental misuse, not a sandbox. The
/// real boundary is that this device is not rooted and not debuggable, so ADB cannot
/// escalate privilege; and that raw `shell()` is not reachable from this layer, the UI, or
/// Hermes.
struct ADBAppOperations: AppOperationsProtocol {
    private let transport: TransportProtocol

    init(transport: TransportProtocol) {
        self.transport = transport
    }

    /// Packages that must never be stopped.
    ///
    /// The criterion is **"stopping this disrupts the device itself, not merely an
    /// application"**. SystemUI is the status bar and navigation; the launcher is the home
    /// screen; telephony and the settings provider back system services. Killing any of them
    /// leaves the device in a broken state, which is not acceptable even though a reboot
    /// recovers it.
    ///
    /// `com.android.settings` is deliberately **not** on this list. It was initially included
    /// by reflex because of its package name, but it fails the criterion: it is an ordinary
    /// user-facing application that can be swiped away and reopened, with no system service
    /// depending on it. Real-device verification surfaced the over-broad entry, because the
    /// approved verification sequence launches and stops Settings.
    ///
    /// This list is a **denylist of known-critical packages**, not an allowlist. It cannot be
    /// complete — a vendor system package with an unexpected name will not match. It is
    /// defence-in-depth against accidental misuse, **not a security boundary**. See ADR-009
    /// for the protection model and its limitations.
    static let protectedPackages: Set<String> = [
        "android",
        "com.android.systemui",
        "com.android.phone",
        "com.android.shell",
        "com.android.providers.settings",
        "com.google.android.apps.nexuslauncher",
        "com.google.android.gms",
        "com.google.android.gsf"
    ]

    /// Prefixes of packages that must never be stopped.
    static let protectedPrefixes = [
        "com.android.systemui",
        "com.android.providers.",
        "com.android.server.",
        "com.google.android.gms"
    ]

    // MARK: - Discovery

    func installedApplications(
        deviceSerial: String,
        includeSystem: Bool,
        timeout: TimeInterval
    ) async throws -> [InstalledApp] {
        let command = includeSystem ? "pm list packages" : "pm list packages -3"
        let result = try await transport.shell(
            deviceSerial: deviceSerial,
            command: command,
            timeout: timeout
        )

        guard result.isSuccess else {
            throw PixelDesktopError.adbCommandFailed(
                command: command,
                exitCode: Int(result.exitCode),
                stderr: result.stderr
            )
        }

        return Self.parsePackageList(result.stdout).map {
            InstalledApp(packageName: $0, launchActivity: nil)
        }
    }

    func launchableApplications(
        deviceSerial: String,
        timeout: TimeInterval
    ) async throws -> [InstalledApp] {
        // One call returns the whole launchable set. Resolving launch activities per
        // package via `dumpsys package` would cost ~49 KB per app (measured); with 41
        // third-party packages that is ~2 MB for the same information.
        let command = "cmd package query-activities --brief -a android.intent.action.MAIN -c android.intent.category.LAUNCHER"
        let result = try await transport.shell(
            deviceSerial: deviceSerial,
            command: command,
            timeout: timeout
        )

        guard result.isSuccess else {
            throw PixelDesktopError.adbCommandFailed(
                command: command,
                exitCode: Int(result.exitCode),
                stderr: result.stderr
            )
        }

        return Self.parseLaunchableActivities(result.stdout)
            .map { InstalledApp(packageName: $0.key, launchActivity: $0.value) }
            .sorted { $0.packageName < $1.packageName }
    }

    // MARK: - Lifecycle

    func launchApplication(
        deviceSerial: String,
        packageName: String,
        timeout: TimeInterval
    ) async throws -> TransportResult {
        let validated = try Self.validatePackageName(packageName)

        // Resolve the launcher activity first. Launching a package that has none would fail
        // on the device; failing here keeps the device untouched and gives a clear reason.
        let launchable = try await launchableApplications(deviceSerial: deviceSerial, timeout: timeout)
        guard let app = launchable.first(where: { $0.packageName == validated }),
              let activity = app.launchActivity else {
            throw PixelDesktopError.invalidInput(
                "Package '\(validated)' has no launcher activity, so there is nothing to start"
            )
        }

        let command = "am start -n \(validated)/\(Self.componentActivity(from: activity, packageName: validated))"
        let result = try await transport.shell(
            deviceSerial: deviceSerial,
            command: command,
            timeout: timeout
        )

        guard result.isSuccess else {
            throw PixelDesktopError.adbCommandFailed(
                command: command,
                exitCode: Int(result.exitCode),
                stderr: result.stderr
            )
        }

        return result
    }

    func isApplicationRunning(
        deviceSerial: String,
        packageName: String,
        timeout: TimeInterval
    ) async throws -> Bool {
        let validated = try Self.validatePackageName(packageName)

        let result = try await transport.shell(
            deviceSerial: deviceSerial,
            command: "pidof \(validated)",
            timeout: timeout
        )

        // `pidof` exits 1 when no process matches. That is a valid answer ("not running"),
        // not a failure. Note this differs from `getprop`, which exits 0 for an unset key —
        // the two must not share error handling.
        return Self.parsePID(result.stdout) != nil
    }

    func stopApplication(
        deviceSerial: String,
        packageName: String,
        timeout: TimeInterval
    ) async throws -> TransportResult {
        let validated = try Self.validatePackageName(packageName)
        try Self.assertStoppable(validated)

        let command = "am force-stop \(validated)"
        let result = try await transport.shell(
            deviceSerial: deviceSerial,
            command: command,
            timeout: timeout
        )

        guard result.isSuccess else {
            throw PixelDesktopError.adbCommandFailed(
                command: command,
                exitCode: Int(result.exitCode),
                stderr: result.stderr
            )
        }

        return result
    }

    // MARK: - Validation and containment

    /// Validates a package identifier and returns it unchanged.
    ///
    /// Rejects anything that is not a bare package identifier, which is what keeps a caller
    /// from smuggling a shell fragment (spaces, `;`, `|`, `&&`, quotes, redirects) into a
    /// command template. This is an **input-shape check**, and it is the mechanism that
    /// prevents command injection through the operations layer.
    static func validatePackageName(_ packageName: String) throws -> String {
        let trimmed = packageName.trimmingCharacters(in: .whitespacesAndNewlines)

        guard !trimmed.isEmpty else {
            throw PixelDesktopError.invalidInput("Package name must not be empty")
        }

        // A package identifier is dot-separated segments of letters, digits and underscore,
        // each starting with a letter. Anything else is rejected outright.
        let pattern = "^[A-Za-z][A-Za-z0-9_]*(\\.[A-Za-z0-9_]+)+$"
        guard trimmed.range(of: pattern, options: .regularExpression) != nil else {
            throw PixelDesktopError.invalidInput(
                "Not a valid package identifier: '\(packageName)'"
            )
        }

        return trimmed
    }

    /// Applies the stop-containment rules. Throws before any command is issued.
    static func assertStoppable(_ packageName: String) throws {
        guard !protectedPackages.contains(packageName) else {
            throw PixelDesktopError.invalidInput(
                "Refusing to stop protected package '\(packageName)': stopping it disrupts the device itself"
            )
        }

        for prefix in protectedPrefixes where packageName.hasPrefix(prefix) {
            throw PixelDesktopError.invalidInput(
                "Refusing to stop '\(packageName)': matches protected prefix '\(prefix)'"
            )
        }

        guard packageName != workerPackageName else {
            throw PixelDesktopError.invalidInput(
                "Refusing to stop '\(packageName)': it is the PixelDesktop worker package"
            )
        }
    }

    /// The Phase 5 worker package. Stopping it would kill our own worker mid-task.
    ///
    /// Declared here as a constant so the containment rule is explicit and testable before
    /// the worker exists.
    static let workerPackageName = "com.pixeldesktop.worker"

    /// Converts a `query-activities` component into the form `am start -n` expects.
    ///
    /// The device returns either a fully-qualified activity
    /// (`com.android.settings/com.android.settings.Settings`) or an abbreviated one
    /// (`com.android.settings/.Settings`). `am start -n` accepts both, so the value is
    /// passed through with its separator normalised.
    static func componentActivity(from activity: String, packageName: String) -> String {
        guard let separatorIndex = activity.firstIndex(of: "/") else {
            return activity
        }
        return String(activity[activity.index(after: separatorIndex)...])
    }

    // MARK: - Parsers

    /// Parses `pm list packages` output: one `package:<name>` per line.
    static func parsePackageList(_ output: String) -> [String] {
        var packages: [String] = []

        for line in output.components(separatedBy: .newlines) {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard trimmed.hasPrefix("package:") else { continue }

            let name = String(trimmed.dropFirst("package:".count))
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty else { continue }

            packages.append(name)
        }

        return packages
    }

    /// Parses `cmd package query-activities --brief` output into package → component.
    ///
    /// The output interleaves header lines (`58 activities found:`), `Activity #N:` markers
    /// and `priority=...` attribute lines with the component lines. Components are the only
    /// lines containing `/`, so that is the discriminator. Attributes contain `=` and are
    /// excluded explicitly.
    static func parseLaunchableActivities(_ output: String) -> [String: String] {
        var activities: [String: String] = [:]

        for line in output.components(separatedBy: .newlines) {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard trimmed.contains("/"),
                  !trimmed.contains("="),
                  !trimmed.hasSuffix(":") else {
                continue
            }

            let parts = trimmed.split(separator: "/", maxSplits: 1)
            guard parts.count == 2 else { continue }

            let packageName = String(parts[0]).trimmingCharacters(in: .whitespaces)
            guard !packageName.isEmpty,
                  packageName.range(of: "^[A-Za-z][A-Za-z0-9_]*(\\.[A-Za-z0-9_]+)+$",
                                    options: .regularExpression) != nil else {
                continue
            }

            // First occurrence wins: the device lists default handlers first.
            if activities[packageName] == nil {
                activities[packageName] = trimmed
            }
        }

        return activities
    }

    /// Parses `pidof` output. Returns `nil` when no process matched.
    ///
    /// `pidof` prints one or more space-separated PIDs. The first is used.
    static func parsePID(_ output: String) -> Int? {
        let trimmed = output.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return trimmed.split(separator: " ").first.flatMap { Int($0) }
    }
}
