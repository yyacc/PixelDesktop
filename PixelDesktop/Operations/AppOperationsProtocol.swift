import Foundation

/// Named application/process operations on a device.
///
/// This is the seam between "what we want to do to an application" and "how it is done
/// over ADB". It depends on nothing but device identity and explicit arguments.
///
/// **Every method takes explicit, typed arguments. None accepts a shell string.** Raw
/// `shell()` stays below this layer on `TransportProtocol` and is never surfaced here, so
/// a caller cannot compose an arbitrary command through the operations layer.
///
/// Master prompt §16 requires device discovery, device representation and device
/// operations to be separate concerns. This protocol is the operations concern; it
/// contains no discovery and no representation logic.
///
/// Master prompt §22 constrains what may be implemented: no APK modification, no code
/// injection, no security or anti-cheat bypass, no destructive operations beyond the
/// explicitly scoped application stop.
protocol AppOperationsProtocol: Sendable {
    /// Lists installed applications.
    ///
    /// - Parameter includeSystem: when `false` (the default), only third-party packages are
    ///   returned. The device has 364 packages total but only 41 third-party ones, so the
    ///   default scope is both smaller and more useful.
    func installedApplications(
        deviceSerial: String,
        includeSystem: Bool,
        timeout: TimeInterval
    ) async throws -> [InstalledApp]

    /// Lists applications that expose a launcher activity.
    ///
    /// Returns the subset of installed applications the user can actually start, keyed by
    /// package name. Resolved in a single device call rather than one call per package.
    func launchableApplications(
        deviceSerial: String,
        timeout: TimeInterval
    ) async throws -> [InstalledApp]

    /// Starts an application's launcher activity.
    ///
    /// - Throws: `PixelDesktopError.invalidInput` if the package has no launcher activity,
    ///   because there is nothing to start. This is checked before any command is issued.
    func launchApplication(
        deviceSerial: String,
        packageName: String,
        timeout: TimeInterval
    ) async throws -> TransportResult

    /// Reports whether an application currently has a running process.
    ///
    /// "Not running" is a **valid answer, not an error** — the underlying `pidof` exits
    /// non-zero for a package with no process, and that is translated to `false` here.
    func isApplicationRunning(
        deviceSerial: String,
        packageName: String,
        timeout: TimeInterval
    ) async throws -> Bool

    /// Stops an application.
    ///
    /// This is the only operation in the project that can destroy in-flight work: it
    /// terminates the process and discards unsaved state. Containment is applied inside the
    /// implementation, not at the call site — see `ADBAppOperations.stopApplication` and
    /// ADR-009 for the protection model **and its limitations**.
    ///
    /// - Throws: `PixelDesktopError.invalidInput` when the package is rejected by the
    ///   containment rules, before any command is issued.
    func stopApplication(
        deviceSerial: String,
        packageName: String,
        timeout: TimeInterval
    ) async throws -> TransportResult
}
