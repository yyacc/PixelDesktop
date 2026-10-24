import Foundation

/// One line of the input audit trail (proposal D2).
///
/// Every plan, every execution, and every refusal is recorded with its resolved target, so a
/// blind action can always be reconstructed after the fact. This is the record that makes a
/// tap on a dead-screen phone reviewable — without it the only evidence of what was touched
/// is the effect on the device.
struct InputAuditRecord: Equatable, Sendable, Codable {
    let timestamp: Date
    let kind: String
    let targetLabel: String?
    let targetResourceID: String?
    let centerX: Int?
    let centerY: Int?
    let payload: String?
    /// `executed`, `refused`, or `failed`.
    let outcome: String
    /// The device command for `executed`, or the refusal reason otherwise.
    let detail: String

    init(plan: InputActionPlan, outcome: String, detail: String, timestamp: Date = Date()) {
        self.timestamp = timestamp
        self.kind = plan.kind.rawValue
        self.targetLabel = plan.target?.label
        self.targetResourceID = plan.target?.resourceID
        self.centerX = plan.target?.centerX
        self.centerY = plan.target?.centerY
        self.payload = plan.payload
        self.outcome = outcome
        self.detail = detail
    }

    static let executed = "executed"
    static let refused = "refused"
    static let failed = "failed"
}

/// A bounded, thread-safe audit log for injected input.
///
/// A `final class` with a lock rather than a value type because it is written from the
/// transport's async context and read from the UI: appending must not race with rendering.
///
/// Bounded for the same reason `TelemetryHistory` is: an unattended session that taps
/// periodically would otherwise grow this without limit. The cap is explicit and documented
/// in `defaultCapacity`.
///
/// **Persistence is opt-in and caller-supplied.** There is no hardcoded path — `AppState`
/// passes Application Support, tests pass a temporary directory, and a caller that never
/// persists gets an in-memory log.
final class InputAuditLog: @unchecked Sendable {
    /// How many records are retained in memory. 500 taps is far more than a maintenance
    /// session performs, and the on-disk file is written on every append.
    static let defaultCapacity = 500

    private let lock = NSLock()
    private var storage: [InputAuditRecord] = []
    private let capacity: Int
    private let fileURL: URL?

    init(capacity: Int = InputAuditLog.defaultCapacity, fileURL: URL? = nil) {
        self.capacity = max(1, capacity)
        self.fileURL = fileURL
        if let fileURL, let existing = try? Self.read(fileURL) {
            storage = Array(existing.suffix(self.capacity))
        }
    }

    var records: [InputAuditRecord] {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }

    var isEmpty: Bool { records.isEmpty }

    /// The most recent record, or `nil` when nothing has been attempted.
    var latest: InputAuditRecord? { records.last }

    func append(_ record: InputAuditRecord) {
        lock.lock()
        storage.append(record)
        if storage.count > capacity {
            storage.removeFirst(storage.count - capacity)
        }
        let snapshot = storage
        lock.unlock()

        // Written outside the lock: a disk write must not block a reader.
        if let fileURL {
            try? Self.write(snapshot, to: fileURL)
        }
    }

    func removeAll() {
        lock.lock()
        storage.removeAll()
        let fileURL = self.fileURL
        lock.unlock()
        if let fileURL { try? FileManager.default.removeItem(at: fileURL) }
    }

    // MARK: - Persistence

    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }()

    private static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()

    static func write(_ records: [InputAuditRecord], to url: URL) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try encoder.encode(records).write(to: url, options: .atomic)
    }

    static func read(_ url: URL) throws -> [InputAuditRecord] {
        guard FileManager.default.fileExists(atPath: url.path) else { return [] }
        return try decoder.decode([InputAuditRecord].self, from: Data(contentsOf: url))
    }

    /// The app's default audit file: `~/Library/Application Support/PixelDesktop/input-audit.json`.
    static func applicationDefaultURL() throws -> URL {
        let base = try FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        return base.appendingPathComponent("PixelDesktop/input-audit.json")
    }
}
