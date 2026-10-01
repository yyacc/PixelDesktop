import Foundation

/// An application installed on an Android device.
///
/// Pure representation, like `AndroidDevice`: it holds facts and performs no device I/O.
///
/// **Running state is deliberately not a field.** It is dynamic and would make a static
/// representation hold a live value that goes stale the moment it is read. Ask
/// `AppOperationsProtocol.isApplicationRunning(packageName:)` instead.
///
/// Deliberately minimal: no icons, version strings, install sizes or permissions. None of
/// those has a consumer in this phase, and each would need its own acquisition mechanism.
struct InstalledApp: Identifiable, Equatable {
    /// The application's package identifier, e.g. `com.android.settings`.
    let packageName: String

    /// The component to start, e.g. `com.android.settings/.Settings`.
    ///
    /// `nil` when the package exposes no launcher activity — many system and library
    /// packages do not. A `nil` here is not an error; it means "not launchable".
    let launchActivity: String?

    var id: String { packageName }

    /// Whether this application can be started by the user.
    var isLaunchable: Bool {
        launchActivity != nil
    }

    /// The last path segment of the package, used as a fallback display label.
    ///
    /// This is a package-name fragment, **not** the application's real label. Reading the
    /// real label requires `dumpsys package` (49 KB per app) or an APK inspection, neither
    /// of which is justified in this phase. Named `displayLabel` only to make the
    /// fallback obvious at call sites.
    var displayLabel: String {
        packageName.split(separator: ".").last.map(String.init) ?? packageName
    }

    /// Whether this looks like a system package.
    ///
    /// A **heuristic based on package naming only**. It is not authoritative: a third-party
    /// app can be named `com.android.*`, and vendor system packages use other prefixes.
    /// Used as one defence-in-depth signal, never as a security boundary.
    var isLikelySystemPackage: Bool {
        Self.systemPrefixes.contains { packageName.hasPrefix($0) }
    }

    /// Prefixes used by the `isLikelySystemPackage` heuristic.
    static let systemPrefixes = [
        "com.android.",
        "com.google.android.",
        "android.",
        "com.qualcomm.",
        "com.google.android.apps."
    ]
}
