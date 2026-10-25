import Foundation

// MARK: - Seam

/// The notification read, as two tiers.
///
/// Tier 1 is keys only and cheap; tier 2 is the full dump and expensive. They are separate methods
/// because the point of the design is that a caller can poll tier 1 without paying for tier 2.
protocol NotificationReading: Sendable {
    /// `cmd notification list` — about 1.7 KB, keys only.
    func keys(deviceSerial: String, timeout: TimeInterval) async throws -> [NotificationKey]

    /// `dumpsys notification --noredact` — about 780 KB, full content.
    func records(deviceSerial: String, timeout: TimeInterval) async throws -> [NotificationRecord]
}

// MARK: - ADB implementation

/// Both tiers are **P4 reads**, and both go through `ConsentGate` on `.notifications`.
///
/// A key list is not metadata: it carries package names and notification tags, which on this device
/// include a mail account (`gig:…:^sq_ig_i_personal`). Gating tier 1 as well as tier 2 is the reason
/// the registry is checked before *either* command runs.
struct ADBNotificationReader: NotificationReading {
    /// 1,731–2,487 B on this device. Keys only.
    static let listCommand = "cmd notification list"

    /// 777,677–840,239 B on this device. Message bodies.
    static let dumpCommand = "dumpsys notification --noredact"

    private let transport: TransportProtocol
    private let gate: ConsentGate

    init(transport: TransportProtocol, gate: ConsentGate) {
        self.transport = transport
        self.gate = gate
    }

    /// The trail both tiers write to. `ConsentGate` audits only *refusals*; a successful read has to
    /// record itself, and it does so through the same `begin`/`resolve` primitives the input path
    /// uses, so one file answers "what has this system done to this device".
    private var auditLog: DeviceAuditLog { gate.auditLog }

    func keys(deviceSerial: String, timeout: TimeInterval) async throws -> [NotificationKey] {
        try await gate.performing(.notifications, target: deviceSerial, operation: .notificationRead) {
            // Append-before-execute: the attempt is durable before the device is touched.
            let attempt = auditLog.begin(
                operation: .notificationRead,
                target: deviceSerial,
                detail: "tier 1 (keys): \(Self.listCommand)"
            )
            let result: TransportResult
            do {
                result = try await transport.shell(
                    deviceSerial: deviceSerial,
                    command: Self.listCommand,
                    timeout: timeout
                )
            } catch {
                auditLog.resolve(
                    attempt,
                    outcome: .failed,
                    detail: "tier 1 transport error: \(error.localizedDescription)"
                )
                throw PixelDesktopError.adbTransportError(error.localizedDescription)
            }
            guard result.isSuccess else {
                auditLog.resolve(
                    attempt,
                    outcome: .failed,
                    detail: "tier 1 exit \(result.exitCode)"
                )
                throw PixelDesktopError.adbCommandFailed(
                    command: Self.listCommand,
                    exitCode: Int(result.exitCode),
                    stderr: result.stderr
                )
            }
            // **Empty output is a valid answer here**, unlike every `dumpsys` read in A7: a phone
            // with no notifications prints nothing. The distinction matters because "no
            // notifications" and "the command did not run" would otherwise look the same.
            let keys = NotificationParser.keys(fromList: result.stdout)
            auditLog.resolve(attempt, outcome: .executed, detail: Self.keyDetail(count: keys.count, bytes: result.stdout.utf8.count))
            return keys
        }
    }

    func records(deviceSerial: String, timeout: TimeInterval) async throws -> [NotificationRecord] {
        try await gate.performing(.notifications, target: deviceSerial, operation: .notificationRead) {
            let attempt = auditLog.begin(
                operation: .notificationRead,
                target: deviceSerial,
                detail: "tier 2 (dump): \(Self.dumpCommand)"
            )
            let result: TransportResult
            do {
                result = try await transport.shell(
                    deviceSerial: deviceSerial,
                    command: Self.dumpCommand,
                    timeout: timeout
                )
            } catch {
                auditLog.resolve(
                    attempt,
                    outcome: .failed,
                    detail: "tier 2 transport error: \(error.localizedDescription)"
                )
                throw PixelDesktopError.adbTransportError(error.localizedDescription)
            }
            guard result.isSuccess else {
                auditLog.resolve(
                    attempt,
                    outcome: .failed,
                    detail: "tier 2 exit \(result.exitCode)"
                )
                throw PixelDesktopError.adbCommandFailed(
                    command: Self.dumpCommand,
                    exitCode: Int(result.exitCode),
                    stderr: result.stderr
                )
            }
            // Empty output here is *not* an answer: with no notifications the device still prints
            // its section headers, so a zero-length stdout means the read did not happen.
            guard !result.stdout.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                auditLog.resolve(attempt, outcome: .failed, detail: "tier 2 empty output")
                throw PixelDesktopError.verificationFailed(
                    reason: "\(Self.dumpCommand) returned no output"
                )
            }
            let records = NotificationParser.records(fromDump: result.stdout)
            let contentless = records.filter(\.isContentless).count
            auditLog.resolve(
                attempt,
                outcome: .executed,
                detail: Self.recordDetail(
                    total: records.count,
                    contentless: contentless,
                    bytes: result.stdout.utf8.count
                )
            )
            return records
        }
    }

    // MARK: - Audit detail

    /// Counts and sizes only.
    ///
    /// **The audit detail must never carry notification content.** The trail is the one surface
    /// that outlives the session, is rendered in the Trust tab, and is copied into issue reports —
    /// writing a message body into it would move personal data out of the consent-gated path it was
    /// just read under. `NotificationAuditDetailTests` asserts this against a dump whose values
    /// would be unmistakable if they leaked.
    static func keyDetail(count: Int, bytes: Int) -> String {
        "tier 1: \(count) keys, \(bytes) B"
    }

    static func recordDetail(total: Int, contentless: Int, bytes: Int) -> String {
        "tier 2: \(total) records (\(contentless) contentless), \(bytes) B"
    }
}

// MARK: - Two-tier stream

/// Polls tier 1 and pays for tier 2 only when the key set actually changed.
///
/// The measured sizes are why: tier 1 is ~1.7 KB and tier 2 is ~780 KB — **45× larger**. Polling
/// tier 2 every 30 s would move roughly 15 MB/min for content that changes rarely. With this
/// service the poll path moves ~3 KB/min and the dump is fetched only on a real change.
///
/// The change signal is the **key set**, not the content: a notification whose text changed keeps
/// its key, so the stream reports its own limitation — it detects appearances and dismissals, and a
/// same-key content update is only noticed on the next appearance. Reading the content on every poll
/// to catch that would defeat the design.
final class NotificationStream: @unchecked Sendable {
    /// The result of one poll.
    struct Refresh: Equatable, Sendable {
        let keys: [NotificationKey]
        /// The full records. On a poll with no change these are the previously read records, so the
        /// caller always has content without having paid for it again.
        let records: [NotificationRecord]
        /// Whether tier 2 was read during this poll.
        let didFetchPayload: Bool
    }

    private let reader: NotificationReading
    private let lock = NSLock()
    private var lastKeys: Set<String>?
    private var cachedRecords: [NotificationRecord] = []

    init(reader: NotificationReading) {
        self.reader = reader
    }

    /// Polls tier 1, and tier 2 only if the key set changed (or nothing has been read yet).
    func refresh(deviceSerial: String, timeout: TimeInterval = 20) async throws -> Refresh {
        let keys = try await reader.keys(deviceSerial: deviceSerial, timeout: timeout)
        let current = Set(keys.map(\.raw))

        lock.lock()
        let unchanged = (lastKeys == current)
        let cached = cachedRecords
        lock.unlock()

        if unchanged {
            return Refresh(keys: keys, records: cached, didFetchPayload: false)
        }

        // No notifications at all: there is nothing for tier 2 to describe, so skip it entirely.
        if keys.isEmpty {
            lock.lock()
            lastKeys = current
            cachedRecords = []
            lock.unlock()
            return Refresh(keys: [], records: [], didFetchPayload: false)
        }

        let records = try await reader.records(deviceSerial: deviceSerial, timeout: timeout)

        lock.lock()
        lastKeys = current
        cachedRecords = records
        lock.unlock()

        return Refresh(keys: keys, records: records, didFetchPayload: true)
    }

    /// Forgets the change tracker, so the next poll pays for tier 2 regardless. Used when consent is
    /// revoked and re-granted, where the previous read is no longer a valid cache.
    func reset() {
        lock.lock()
        lastKeys = nil
        cachedRecords = []
        lock.unlock()
    }

    /// Whether a full read has ever succeeded.
    var hasRead: Bool {
        lock.lock()
        defer { lock.unlock() }
        return lastKeys != nil
    }
}
