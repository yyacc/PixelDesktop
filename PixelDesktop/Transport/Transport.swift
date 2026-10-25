import Foundation

protocol TransportProtocol: AnyObject, Sendable {
    func execute(command: String, arguments: [String], timeout: TimeInterval) async throws -> TransportResult
    func listDevices() async throws -> [AndroidDevice]

    /// Reads a single Android system property via `adb shell getprop <key>`.
    ///
    /// - Returns: the trimmed property value.
    /// - Throws: `PixelDesktopError.adbCommandFailed` when ADB itself reports a
    ///   failure, and `PixelDesktopError.invalidInput` when the property is unset
    ///   (getprop exits 0 with empty output for a missing key).
    func getprop(deviceSerial: String, key: String, timeout: TimeInterval) async throws -> String

    /// Runs a command in the device shell via `adb -s <serial> shell <command>`.
    ///
    /// **This is a transport primitive, not an application-facing capability.** It is a
    /// general-purpose escape hatch: any string handed to it runs on the device. It must
    /// stay below the operations layer, and must never be exposed to the UI or to Hermes.
    /// Higher layers call named operations with explicit arguments instead of composing
    /// shell strings.
    ///
    /// The device this project targets is not rooted and not debuggable (`su` absent,
    /// `ro.debuggable=0`), so no privilege escalation is reachable through ADB. That bounds
    /// the blast radius but is not a substitute for containment.
    ///
    /// - Returns: the raw `TransportResult`. A non-zero exit code is returned rather than
    ///   thrown, because some callers (e.g. `pidof`) treat non-zero as a valid answer.
    func shell(deviceSerial: String, command: String, timeout: TimeInterval) async throws -> TransportResult

    /// Runs a command in the device shell and delivers **stdout incrementally**, line by line.
    ///
    /// Unlike `shell`, which buffers until the process exits, this exposes each line as it is
    /// produced and keeps stderr separate. It exists because a worker job can run for minutes:
    /// E1 measured a 27.6 s job whose progress was observable only through a live stream, and a
    /// 256-token job still running past 90 s. A buffered call cannot report either.
    ///
    /// **Transport primitive**, with the same posture as `shell`: any string handed to it runs on
    /// the device. It stays below the operations layer and is never exposed to the UI or Hermes.
    ///
    /// The session persists for the life of the command. `stdin` is written and then closed before
    /// reading begins, which is what lets the device script receive its payload through `cat > file`
    /// instead of a separate `push`.
    ///
    /// - Parameters:
    ///   - stdin: written to the device process, then closed. `nil` sends nothing and closes
    ///     immediately.
    ///   - onLine: invoked for each stdout line, in order, as it arrives.
    ///   - onStderrLine: invoked for each stderr line. Kept separate so transport diagnostics can
    ///     never be mistaken for protocol events.
    /// - Returns: the process exit code. A non-zero code is returned rather than thrown, matching
    ///   `shell`'s convention that some callers treat non-zero as a valid answer.
    func shellStreaming(
        deviceSerial: String,
        command: String,
        stdin: String?,
        onLine: @Sendable @escaping (String) -> Void,
        onStderrLine: @Sendable @escaping (String) -> Void,
        cancellation: CancellationHandle
    ) async throws -> Int32

    /// Runs `adb -s <serial> exec-out <arguments...>` and returns **stdout as bytes**.
    ///
    /// `exec-out` is the binary-safe sibling of `shell`: it hands back raw device stdout with
    /// no CRLF translation and no terminal allocation. `execute` and `shell` both decode stdout
    /// as UTF-8, which silently destroys a PNG (`screencap`) or any other binary payload, so a
    /// byte-preserving primitive is required rather than convenient.
    ///
    /// **Transport primitive.** It takes structured arguments, never a caller-supplied command
    /// string, and performs no interpretation of the payload. Containment belongs to the
    /// operations layer: `exec-out` can read anything the device shell can read, and this
    /// device is neither rooted nor debuggable, which bounds but does not remove that reach.
    ///
    /// - Returns: exit code, stdout bytes and stderr text. A non-zero exit is returned rather
    ///   than thrown, matching `shell`'s convention.
    func execOut(
        deviceSerial: String,
        arguments: [String],
        timeout: TimeInterval
    ) async throws -> TransportBinaryResult

    /// Copies a local file to the device via `adb -s <serial> push`.
    ///
    /// **Transport primitive.** It takes already-validated absolute paths and performs no
    /// path policy of its own — no allowlists, no staging roots, no worker semantics. It
    /// must not be called with caller-supplied paths; the worker layer validates first.
    ///
    /// `adb` does not sanitize paths: `../` is resolved by the device filesystem, absolute
    /// paths write wherever the destination is writable, and symlinks are followed. Any
    /// containment therefore belongs to the caller, not to this method. See ADR-010.
    ///
    /// - Note: `adb` overwrites an existing destination **silently**, with exit code 0.
    ///   It provides no overwrite protection.
    func push(deviceSerial: String, localPath: String, remotePath: String, timeout: TimeInterval) async throws -> TransportResult

    /// Copies a file from the device to a local path via `adb -s <serial> pull`.
    ///
    /// **Transport primitive**, with the same posture as `push`: no path policy, no
    /// containment. Note that a local destination containing `../` will escape the intended
    /// directory, because `adb` does not sanitize it. See ADR-010.
    func pull(deviceSerial: String, remotePath: String, localPath: String, timeout: TimeInterval) async throws -> TransportResult

    /// Installs an APK via `adb -s <serial> install [-r] <apkPath>`.
    ///
    /// **Transport primitive.** It takes an already-validated absolute APK path and performs no
    /// policy of its own. Installation is **state-changing**, unlike `push`/`pull`, so this must be
    /// called only from two gated callers — `WorkerInstaller`, and `ADBPackageOperations` behind a
    /// confirmed `DestructiveActionPlan` (B4) — and must never be exposed to the UI or to Hermes
    /// directly.
    ///
    /// - Parameter replace: when `true`, passes `-r` so an existing install is replaced. This
    ///   makes install and reinstall the same operation.
    func install(deviceSerial: String, apkPath: String, replace: Bool, timeout: TimeInterval) async throws -> TransportResult

    /// Reads every system property in a single `adb shell getprop` invocation.
    ///
    /// Prefer this over repeated `getprop` calls when several properties are needed:
    /// each call spawns an `adb` process, so reading N properties one at a time costs
    /// N process spawns against one here.
    ///
    /// - Returns: a map of property key to trimmed value. Unset properties are absent
    ///   rather than present-with-empty-value.
    func getSystemProperties(deviceSerial: String, timeout: TimeInterval) async throws -> [String: String]
}

struct TransportResult: Equatable {
    let exitCode: Int32
    let stdout: String
    let stderr: String

    var isSuccess: Bool {
        exitCode == 0
    }
}

/// The result of a binary-safe device read (`exec-out`).
///
/// stdout is `Data` on purpose: the payload is a PNG or another opaque byte stream, and
/// decoding it as text is precisely the defect this type exists to avoid. stderr stays text
/// because ADB diagnostics are text and must never be mistaken for payload.
struct TransportBinaryResult: Equatable {
    let exitCode: Int32
    let stdout: Data
    let stderr: String

    var isSuccess: Bool {
        exitCode == 0
    }
}

/// A thread-safe cancellation signal passed from the execution boundary into the transport.
///
/// The transport layer owns process/pipe cleanup. The execution boundary owns the decision of
/// *when* to cancel. This type is the bridge: it carries the cancellation signal without
/// exposing any transport primitives upward.
///
/// Exactly-once handler semantics:
/// - `setCancellationHandler` stores the handler. If cancellation already occurred, the handler
///   is invoked immediately (synchronously, before `setCancellationHandler` returns).
/// - `cancel` sets the flag and invokes the handler if one is registered.
/// - The handler is invoked at most once: `cancel` clears the handler reference before invoking,
///   so a subsequent `setCancellationHandler` will not double-invoke.
final class CancellationHandle: @unchecked Sendable {
    private let lock = NSLock()
    private var _isCancelled = false
    private var _handler: (@Sendable () -> Void)?

    /// Whether cancellation has been requested.
    var isCancelled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return _isCancelled
    }

    /// Registers a cleanup handler. If cancellation already occurred, the handler is invoked
    /// immediately. The handler is guaranteed to execute at most once across the lifetime
    /// of this handle.
    func setCancellationHandler(_ handler: @escaping @Sendable () -> Void) {
        lock.lock()
        let wasCancelled = _isCancelled
        _handler = handler
        lock.unlock()
        if wasCancelled { handler() }
    }

    /// Requests cancellation. If a handler is registered, it is invoked exactly once.
    func cancel() {
        lock.lock()
        _isCancelled = true
        let handler = _handler
        _handler = nil
        lock.unlock()
        handler?()
    }
}

/// Guards a streaming read against being resumed twice.
///
/// The reader thread and the stall watchdog can both finish the continuation — the reader when the
/// pipe closes, the watchdog when it tears the session down. `CheckedContinuation` traps on a
/// double resume, so exactly one path is allowed to win.
final class StreamReadState: @unchecked Sendable {
    private let lock = NSLock()
    private var finished = false
    private var cancelledFlag = false

    var isCancelled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return cancelledFlag
    }

    /// Whether the continuation has already been resumed.
    ///
    /// The watchdog checks this before acting, so a session that completed normally is never torn
    /// down by a timer that fired late.
    var isFinished: Bool {
        lock.lock()
        defer { lock.unlock() }
        return finished
    }

    func cancel() {
        lock.lock()
        cancelledFlag = true
        lock.unlock()
    }

    func finish(_ continuation: CheckedContinuation<Void, Never>) {
        lock.lock()
        let alreadyFinished = finished
        finished = true
        lock.unlock()

        if !alreadyFinished {
            continuation.resume()
        }
    }
}

/// Stable, device-identifying system properties retrieved with `getprop`.
///
/// Only values that are fixed for the lifetime of a device boot belong here.
/// Dynamic runtime state (battery, screen, storage, network, process counts) is
/// deliberately excluded: it has a different acquisition mechanism and is outside
/// the current phase's scope.
struct DeviceProperties: Equatable {
    let androidVersion: String
    let apiLevel: Int
    let architecture: String
    let marketingName: String
    let manufacturer: String
    let supportedABIs: [String]

    /// Assembles properties from raw `getprop` output.
    ///
    /// `getprop` exits 0 with empty output when a key is unset, so missing or
    /// malformed values are rejected here rather than by the transport.
    static func make(
        androidVersion: String,
        apiLevelRaw: String,
        architecture: String,
        marketingName: String,
        manufacturer: String,
        abiListRaw: String
    ) throws -> DeviceProperties {
        let version = androidVersion.trimmingCharacters(in: .whitespacesAndNewlines)
        let level = apiLevelRaw.trimmingCharacters(in: .whitespacesAndNewlines)
        let abi = architecture.trimmingCharacters(in: .whitespacesAndNewlines)
        let name = marketingName.trimmingCharacters(in: .whitespacesAndNewlines)
        let maker = manufacturer.trimmingCharacters(in: .whitespacesAndNewlines)

        guard !version.isEmpty else {
            throw PixelDesktopError.invalidInput("Android version property is empty")
        }

        guard let apiLevel = Int(level), apiLevel > 0 else {
            throw PixelDesktopError.invalidInput(
                "API level property is not a positive integer: '\(apiLevelRaw)'"
            )
        }

        guard !abi.isEmpty else {
            throw PixelDesktopError.invalidInput("Architecture property is empty")
        }

        guard !name.isEmpty else {
            throw PixelDesktopError.invalidInput("Product model property is empty")
        }

        guard !maker.isEmpty else {
            throw PixelDesktopError.invalidInput("Manufacturer property is empty")
        }

        let abis = parseABIList(abiListRaw)

        guard !abis.isEmpty else {
            throw PixelDesktopError.invalidInput(
                "ABI list property contains no usable entries: '\(abiListRaw)'"
            )
        }

        return DeviceProperties(
            androidVersion: version,
            apiLevel: apiLevel,
            architecture: abi,
            marketingName: name,
            manufacturer: maker,
            supportedABIs: abis
        )
    }

    /// Parses a comma-separated ABI list such as `arm64-v8a,armeabi-v7a`.
    ///
    /// A single-entry list (`arm64-v8a`) is valid and is the common case: the Pixel 7a
    /// reports exactly one ABI. Blank entries are dropped so a trailing comma does not
    /// produce an empty element.
    static func parseABIList(_ raw: String) -> [String] {
        raw.split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }
}

/// The `getprop` keys that back `DeviceProperties`.
///
/// Keeping the keys beside the model stops the acquisition source from drifting away
/// from the fields it populates.
enum DevicePropertyKey {
    static let androidVersion = "ro.build.version.release"
    static let apiLevel = "ro.build.version.sdk"
    static let architecture = "ro.product.cpu.abi"
    static let marketingName = "ro.product.model"
    static let manufacturer = "ro.product.manufacturer"
    static let supportedABIs = "ro.product.cpu.abilist"

    /// Every key `DeviceProperties` is built from, in the order it is assembled.
    static let all: [String] = [
        androidVersion,
        apiLevel,
        architecture,
        marketingName,
        manufacturer,
        supportedABIs
    ]
}

/// Capabilities of an attached device that are verifiable from stable system properties.
///
/// Deliberately minimal. RAM, GPU, NPU, thermal headroom, storage and battery are
/// **not** modelled: they have no reliable static `getprop` source, and the project
/// roadmap assigns thermal and memory work to later phases. Adding them here would be
/// speculative.
struct DeviceCapabilities: Equatable {
    /// Every ABI the device can run, in the device's own preference order.
    let supportedABIs: [String]

    init(supportedABIs: [String]) {
        self.supportedABIs = supportedABIs
    }

    init(device: AndroidDevice) {
        self.supportedABIs = device.supportedABIs
    }

    /// Whether the device can run code built for the given ABI.
    func supports(abi: String) -> Bool {
        supportedABIs.contains(abi)
    }
}

/// Operations this build can actually perform on a device.
///
/// Only operations that are implemented appear here. Phase 4 (Android Application /
/// Process Control) extends this enum as it implements `shell()` and device lifecycle
/// handling; nothing is listed in advance of being real, so the model cannot advertise
/// functionality the backend does not have.
enum DeviceOperation: String, CaseIterable {
    /// Enumerate attached devices. Implemented in Phase 2.
    case discover = "discover"

    /// Read stable system properties. Implemented in Phase 2.
    case readSystemProperties = "readSystemProperties"

    /// Enumerate installed applications. Implemented in Phase 4.
    case listApplications = "listApplications"

    /// Start an application's launcher activity. Implemented in Phase 4.
    case launchApplication = "launchApplication"

    /// Query whether an application currently has a running process. Implemented in Phase 4.
    case queryApplicationState = "queryApplicationState"

    /// Stop an application. Implemented in Phase 4.
    case stopApplication = "stopApplication"

    var description: String {
        switch self {
        case .discover: return "Discover attached devices"
        case .readSystemProperties: return "Read system properties"
        case .listApplications: return "List installed applications"
        case .launchApplication: return "Launch an application"
        case .queryApplicationState: return "Query application running state"
        case .stopApplication: return "Stop an application"
        }
    }
}
