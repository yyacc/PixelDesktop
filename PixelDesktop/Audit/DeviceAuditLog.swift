import Foundation

// MARK: - Vocabulary

/// The kinds of device operation the audit trail records (Phase 3 proposal D2, §5.2).
///
/// Phase 2 shipped an input-only trail (`InputAuditLog`). Phase 3 generalises it: every
/// operation that touches the phone — reading notifications, installing, rebooting, running a
/// scheduled task — appends to the **same** log, so one file answers "what has this system done
/// to this device, and was it allowed to".
enum DeviceOperationKind: String, Codable, Sendable, CaseIterable {
    case inputInject
    case appInstall
    case appUninstall
    case reboot
    case notificationRead
    case shellCommand
    case scheduledTaskRun

    var displayName: String {
        switch self {
        case .inputInject: return "Input"
        case .appInstall: return "Install"
        case .appUninstall: return "Uninstall"
        case .reboot: return "Reboot"
        case .notificationRead: return "Notifications"
        case .shellCommand: return "Shell"
        case .scheduledTaskRun: return "Scheduled task"
        }
    }
}

/// How an attempt ended.
///
/// `.pending` is **not** in the proposal's three-case list, and that is a deliberate correction
/// rather than an omission. §5.2 requires each record to be written *before* the command is
/// issued, and a record written at that instant cannot know its outcome. `.pending` is the
/// truthful value for that moment, and a record that is *still* `.pending` after the call
/// returned is exactly the crash evidence append-before-execute exists to produce. Every
/// completed call resolves its own record, so `pending` in a normal run is never observable.
enum DeviceAuditOutcome: String, Codable, Sendable, CaseIterable {
    case pending
    case executed
    case refused
    case failed
    case deferred
}

/// The input-specific context ADR-019 requires, carried inside a general device record.
///
/// A blind tap is only reviewable if the record says *what was tapped* — label, resource id and
/// the centre derived from the device's own bounds. Generalising the log must not lose that, so
/// the input fields ride along as an optional projection instead of being dropped.
struct InputAuditContext: Equatable, Sendable, Codable {
    let kind: String
    let targetLabel: String?
    let targetResourceID: String?
    let centerX: Int?
    let centerY: Int?
    let payload: String?

    init(plan: InputActionPlan) {
        self.kind = plan.kind.rawValue
        self.targetLabel = plan.target?.label
        self.targetResourceID = plan.target?.resourceID
        self.centerX = plan.target?.centerX
        self.centerY = plan.target?.centerY
        self.payload = plan.payload
    }

    /// The one-line description of what was addressed.
    var summary: String {
        [kind, targetLabel ?? payload ?? ""].filter { !$0.isEmpty }.joined(separator: " ")
    }
}

// MARK: - Record

/// One line of the device audit trail.
///
/// Records are **immutable**. An attempt is appended as `.pending` before the command is issued
/// and later replaced by a resolved copy (`resolved(outcome:detail:)`), so a reader never holds
/// a record that quietly changed underneath it.
struct DeviceAuditRecord: Equatable, Sendable, Codable, Identifiable {
    let id: UUID
    /// Millisecond precision is required: the proposal's rule is that second precision would make
    /// the ordering of two adjacent operations ambiguous. Encoded with fractional seconds.
    let at: Date
    let operation: DeviceOperationKind
    /// Package, element label, or device serial — whatever the operation addresses.
    let target: String?
    let outcome: DeviceAuditOutcome
    /// The command that ran (on success) or the reason it did not.
    let detail: String?
    /// Present for `.inputInject` records only.
    let input: InputAuditContext?

    init(
        id: UUID = UUID(),
        at: Date = Date(),
        operation: DeviceOperationKind,
        target: String? = nil,
        outcome: DeviceAuditOutcome,
        detail: String? = nil,
        input: InputAuditContext? = nil
    ) {
        self.id = id
        self.at = at
        self.operation = operation
        self.target = target
        self.outcome = outcome
        self.detail = detail
        self.input = input
    }

    /// A copy with the outcome settled. `id` and `at` are preserved, so resolving never
    /// reorders the trail.
    func resolved(outcome: DeviceAuditOutcome, detail: String?) -> DeviceAuditRecord {
        DeviceAuditRecord(
            id: id,
            at: at,
            operation: operation,
            target: target,
            outcome: outcome,
            detail: detail,
            input: input
        )
    }

    /// What the audit view renders as the record's subject.
    var summary: String {
        if let input { return input.summary }
        if let target, !target.isEmpty {
            return "\(operation.displayName) \(target)"
        }
        return operation.displayName
    }

    // Test and view ergonomics: outcome literals that read as outcomes, not as enum paths.
    static let executed = DeviceAuditOutcome.executed
    static let refused = DeviceAuditOutcome.refused
    static let failed = DeviceAuditOutcome.failed
    static let pending = DeviceAuditOutcome.pending
    static let deferred = DeviceAuditOutcome.deferred
}

// MARK: - Input records

extension DeviceAuditRecord {
    /// An `.inputInject` record built from a plan.
    ///
    /// The input projection is filled from the plan so a tap stays reconstructable — label,
    /// resource id, and the centre derived from the device's own bounds — while the record itself
    /// is the general device record.
    init(
        plan: InputActionPlan,
        outcome: DeviceAuditOutcome,
        detail: String? = nil,
        at: Date = Date()
    ) {
        self.init(
            at: at,
            operation: .inputInject,
            target: plan.target?.label,
            outcome: outcome,
            detail: detail,
            input: InputAuditContext(plan: plan)
        )
    }
}

// MARK: - Log

/// The bounded, persisted, thread-safe device audit trail.
///
/// A `final class` with a lock rather than a value type because it is written from async transport
/// contexts and read from the UI: appending must not race with rendering.
///
/// **Bounded at 5,000 records.** The proposal's rationale: at one record per notification poll the
/// log would otherwise grow without limit. 5,000 is ten times the input-only cap, because the
/// generalised log now carries every operation class rather than taps alone.
///
/// **Persistence is caller-supplied.** There is no hardcoded path — `AppState` passes Application
/// Support, tests pass a temporary directory, and a caller that never persists gets an in-memory
/// log.
final class DeviceAuditLog: @unchecked Sendable {
    /// How many records are retained. Oldest are dropped first.
    static let defaultCapacity = 5_000

    private let lock = NSLock()
    private var storage: [DeviceAuditRecord] = []
    private let capacity: Int
    private let fileURL: URL?

    init(capacity: Int = DeviceAuditLog.defaultCapacity, fileURL: URL? = nil) {
        self.capacity = max(1, capacity)
        self.fileURL = fileURL
        if let fileURL, let existing = try? Self.read(fileURL) {
            storage = Array(existing.suffix(self.capacity))
        }
    }

    var records: [DeviceAuditRecord] {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }

    var isEmpty: Bool {
        lock.lock()
        defer { lock.unlock() }
        return storage.isEmpty
    }

    /// The most recent record, or `nil` when nothing has been attempted.
    var latest: DeviceAuditRecord? {
        lock.lock()
        defer { lock.unlock() }
        return storage.last
    }

    /// Records for one operation class, oldest first.
    func records(for operation: DeviceOperationKind) -> [DeviceAuditRecord] {
        records.filter { $0.operation == operation }
    }

    // MARK: Appending

    @discardableResult
    func append(_ record: DeviceAuditRecord) -> UUID {
        lock.lock()
        storage.append(record)
        if storage.count > capacity {
            storage.removeFirst(storage.count - capacity)
        }
        let snapshot = storage
        lock.unlock()
        persist(snapshot)
        return record.id
    }

    @discardableResult
    func append(
        operation: DeviceOperationKind,
        target: String?,
        outcome: DeviceAuditOutcome,
        detail: String? = nil,
        input: InputAuditContext? = nil,
        at: Date = Date()
    ) -> UUID {
        append(
            DeviceAuditRecord(
                at: at,
                operation: operation,
                target: target,
                outcome: outcome,
                detail: detail,
                input: input
            )
        )
    }

    /// Appends an unresolved attempt and returns its id.
    ///
    /// **This is the append-before-execute primitive.** The caller issues the device command only
    /// after this returns, so a crash mid-command leaves a `.pending` record — proof the attempt
    /// happened, which an append-after-success log cannot provide.
    @discardableResult
    func begin(
        operation: DeviceOperationKind,
        target: String?,
        detail: String? = nil,
        input: InputAuditContext? = nil,
        at: Date = Date()
    ) -> UUID {
        append(
            operation: operation,
            target: target,
            outcome: .pending,
            detail: detail,
            input: input,
            at: at
        )
    }

    /// Settles an attempt previously written by `begin`.
    ///
    /// A no-op when `id` is unknown — which happens only when the record was already evicted by
    /// the bound, and evicting a record is not a reason to fail the operation that produced it.
    func resolve(_ id: UUID, outcome: DeviceAuditOutcome, detail: String?) {
        lock.lock()
        if let index = storage.lastIndex(where: { $0.id == id }) {
            storage[index] = storage[index].resolved(outcome: outcome, detail: detail)
        }
        let snapshot = storage
        lock.unlock()
        persist(snapshot)
    }

    func removeAll() {
        lock.lock()
        storage.removeAll()
        let fileURL = self.fileURL
        lock.unlock()
        if let fileURL { try? FileManager.default.removeItem(at: fileURL) }
    }

    // MARK: - Persistence

    /// Encodes dates with **fractional seconds**.
    ///
    /// The `.iso8601` strategy truncates to whole seconds, which would collapse two operations in
    /// the same second into an ambiguous order — the exact defect §5.2 calls out. The plain
    /// formatter is retained as a decode fallback so a file written by another tool still loads.
    private static let fractionalFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    private static let plainFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()

    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .custom { date, encoder in
            var container = encoder.singleValueContainer()
            try container.encode(fractionalFormatter.string(from: date))
        }
        return encoder
    }()

    private static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()
            let text = try container.decode(String.self)
            if let date = fractionalFormatter.date(from: text) { return date }
            if let date = plainFormatter.date(from: text) { return date }
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "Not an ISO-8601 timestamp: \(text)"
            )
        }
        return decoder
    }()

    /// Writes the trail atomically (temp file, then rename), so a crash cannot leave a half
    /// written log that decodes as a shorter history than actually happened.
    static func write(_ records: [DeviceAuditRecord], to url: URL) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try encoder.encode(records).write(to: url, options: .atomic)
    }

    static func read(_ url: URL) throws -> [DeviceAuditRecord] {
        guard FileManager.default.fileExists(atPath: url.path) else { return [] }
        return try decoder.decode([DeviceAuditRecord].self, from: Data(contentsOf: url))
    }

    /// The app's default audit file: `~/Library/Application Support/PixelDesktop/device-audit.json`.
    ///
    /// Renamed from `input-audit.json` when the trail was generalised: the file's *shape* changed
    /// (records carry an operation class and an id), so continuing to read the old path would
    /// either fail to decode or silently load a narrower history than the log now claims to hold.
    static func applicationDefaultURL() throws -> URL {
        let base = try FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        return base.appendingPathComponent("PixelDesktop/device-audit.json")
    }

    private func persist(_ snapshot: [DeviceAuditRecord]) {
        // Written outside the lock: a disk write must not block a reader.
        if let fileURL {
            try? Self.write(snapshot, to: fileURL)
        }
    }
}
