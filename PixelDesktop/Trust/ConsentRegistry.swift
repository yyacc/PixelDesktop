import Foundation

// MARK: - Data classes

/// The unit of consent (Phase 3 proposal D1, §5.1).
///
/// Four classes, matching the master proposal's P4. Consent is **per class, not per package**
/// (decision Q4a): what the owner is granting is "the phone's messages may be read", not "this
/// one app's messages may be read", and a per-package model would silently re-grant whenever a new
/// package appeared.
enum ConsentDataClass: String, Codable, Sendable, CaseIterable {
    case notifications
    case sms
    case contacts
    case clipboard

    var displayName: String {
        switch self {
        case .notifications: return "Notifications"
        case .sms: return "Messages (SMS)"
        case .contacts: return "Contacts"
        case .clipboard: return "Clipboard"
        }
    }

    /// What granting this actually exposes. Shown beside the toggle, because consent given
    /// without knowing the exposure is not consent.
    var exposure: String {
        switch self {
        case .notifications:
            return "Reads notification titles, bodies and text lines, including message previews "
                + "from messaging apps. `dumpsys notification --noredact` is not a metadata feed."
        case .sms:
            return "Reads the SMS store: senders, timestamps and message bodies."
        case .contacts:
            return "Reads the contact list: names, numbers and account associations."
        case .clipboard:
            return "Reads whatever was last copied, which may be a password or a token."
        }
    }
}

// MARK: - Grant

/// One persisted decision about one data class.
///
/// `granted` and `revokedAt` are both stored rather than collapsed into a single boolean so the
/// history survives: the record says *when* consent was given, *why*, and *when it was withdrawn*.
struct ConsentGrant: Equatable, Sendable, Codable, Identifiable {
    var id: ConsentDataClass { dataClass }
    let dataClass: ConsentDataClass
    var granted: Bool
    var grantedAt: Date
    var revokedAt: Date?
    /// Required at grant time. Free text, stored verbatim.
    let reason: String

    /// **Revocation is sticky.** A non-nil `revokedAt` wins over `granted == true`, so a stale
    /// write that flips the boolean back cannot re-open a withdrawn class. This is the single
    /// predicate every read consults.
    var isActive: Bool { granted && revokedAt == nil }

    var statusDescription: String {
        if revokedAt != nil { return "Revoked" }
        return granted ? "Granted" : "Not granted"
    }
}

// MARK: - Errors

/// Why a consent-gated read did not happen.
///
/// A dedicated vocabulary rather than prose inside `PixelDesktopError.invalidInput`: the proposal
/// requires that a read without a grant throws and issues **zero** commands, and a refusal that
/// collapses into a string cannot be asserted on.
enum ConsentError: Error, Equatable, CustomStringConvertible {
    /// No active grant exists for this class.
    case consentRequired(dataClass: ConsentDataClass)

    /// A grant was attempted with no reason, so the record would not say why it exists.
    case reasonRequired(dataClass: ConsentDataClass)

    var description: String {
        switch self {
        case .consentRequired(let dataClass):
            return "Refused: reading \(dataClass.displayName.lowercased()) requires an explicit "
                + "consent grant, and none is active"
        case .reasonRequired(let dataClass):
            return "Refused: granting \(dataClass.displayName.lowercased()) requires a reason"
        }
    }
}

/// Evidence that the gate was passed, and when.
///
/// Returned by `ConsentRegistry.permit(for:)`. A caller that has one of these has proven the grant
/// was active at that moment; a caller that does not cannot reach the device.
struct ConsentPermit: Equatable, Sendable {
    let dataClass: ConsentDataClass
    let grantedAt: Date
    let reason: String
}

// MARK: - Registry

/// The persisted, per-data-class consent store.
///
/// **Default deny.** A class with no record is denied. A record with `granted == false` is denied.
/// A record with a `revokedAt` is denied regardless of `granted`. There is no "unknown means
/// allowed" path in this type.
///
/// A `final class` with a lock: it is mutated from the UI and read from async operation paths.
final class ConsentRegistry: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [ConsentDataClass: ConsentGrant] = [:]
    private let fileURL: URL?
    private let now: @Sendable () -> Date

    init(fileURL: URL? = nil, now: @escaping @Sendable () -> Date = Date.init) {
        self.fileURL = fileURL
        self.now = now
        if let fileURL, let existing = try? Self.read(fileURL) {
            for grant in existing {
                storage[grant.dataClass] = grant
            }
        }
    }

    // MARK: Reading

    /// Every class in declaration order, whether or not a decision has been recorded.
    var grants: [ConsentGrant] {
        lock.lock()
        defer { lock.unlock() }
        return ConsentDataClass.allCases.compactMap { storage[$0] }
    }

    func grant(for dataClass: ConsentDataClass) -> ConsentGrant? {
        lock.lock()
        defer { lock.unlock() }
        return storage[dataClass]
    }

    /// Whether the class may be read right now. Consults `isActive`, never the raw boolean.
    func isGranted(_ dataClass: ConsentDataClass) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return storage[dataClass]?.isActive ?? false
    }

    /// **The gate.** Any read of a P4 data class calls this *before* issuing a device command.
    ///
    /// - Throws: `ConsentError.consentRequired` when no active grant exists. Throwing is the whole
    ///   mechanism: callers that do not hold a permit have no path to a transport call.
    func permit(for dataClass: ConsentDataClass) throws -> ConsentPermit {
        lock.lock()
        let grant = storage[dataClass]
        lock.unlock()

        guard let grant, grant.isActive else {
            throw ConsentError.consentRequired(dataClass: dataClass)
        }
        return ConsentPermit(
            dataClass: dataClass,
            grantedAt: grant.grantedAt,
            reason: grant.reason
        )
    }

    // MARK: Writing

    /// Grants a class. Requires a reason, because the persisted record must say why it exists.
    ///
    /// Re-granting a revoked class clears the revocation — that is a new, explicit decision by the
    /// owner, not an undo of the earlier one (the earlier `revokedAt` is replaced, and the grant
    /// timestamp moves).
    @discardableResult
    func grant(_ dataClass: ConsentDataClass, reason: String, at date: Date? = nil) throws -> ConsentGrant {
        let trimmed = reason.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw ConsentError.reasonRequired(dataClass: dataClass)
        }

        let grant = ConsentGrant(
            dataClass: dataClass,
            granted: true,
            grantedAt: date ?? now(),
            revokedAt: nil,
            reason: trimmed
        )

        lock.lock()
        storage[dataClass] = grant
        let snapshot = orderedSnapshot()
        lock.unlock()
        persist(snapshot)
        return grant
    }

    /// Withdraws a class. Immediate, and sticky.
    ///
    /// - Returns: the revoked grant, or `nil` when the class was never granted — revoking an
    ///   undecided class is a no-op rather than the creation of a misleading "revoked" record.
    @discardableResult
    func revoke(_ dataClass: ConsentDataClass, at date: Date? = nil) -> ConsentGrant? {
        lock.lock()
        guard var existing = storage[dataClass] else {
            lock.unlock()
            return nil
        }
        if existing.revokedAt == nil {
            existing.revokedAt = date ?? now()
        }
        // Both fields are set: `isActive` already honours `revokedAt`, and `granted = false` means
        // a reader that inspects the boolean alone still sees a withdrawn class.
        existing.granted = false
        storage[dataClass] = existing
        let snapshot = orderedSnapshot()
        lock.unlock()
        persist(snapshot)
        return existing
    }

    /// Drops every decision. Used by tests and by a future kill switch (D4).
    func removeAll() {
        lock.lock()
        storage.removeAll()
        let fileURL = self.fileURL
        lock.unlock()
        if let fileURL { try? FileManager.default.removeItem(at: fileURL) }
    }

    /// Stable, declaration-ordered snapshot — so the on-disk file does not churn on every write.
    private func orderedSnapshot() -> [ConsentGrant] {
        ConsentDataClass.allCases.compactMap { storage[$0] }
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

    /// Atomic (temp file, then rename). A torn write here could lose a revocation, which is the
    /// one direction this file must never fail in.
    static func write(_ grants: [ConsentGrant], to url: URL) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try encoder.encode(grants).write(to: url, options: .atomic)
    }

    static func read(_ url: URL) throws -> [ConsentGrant] {
        guard FileManager.default.fileExists(atPath: url.path) else { return [] }
        return try decoder.decode([ConsentGrant].self, from: Data(contentsOf: url))
    }

    /// `~/Library/Application Support/PixelDesktop/consent.json`.
    static func applicationDefaultURL() throws -> URL {
        let base = try FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        return base.appendingPathComponent("PixelDesktop/consent.json")
    }

    private func persist(_ snapshot: [ConsentGrant]) {
        if let fileURL {
            try? Self.write(snapshot, to: fileURL)
        }
    }
}

// MARK: - Gate

/// Binds the consent check to the operation it guards, and audits a refusal.
///
/// `permit(for:)` alone is a check a caller could forget to make. This type makes the check and
/// the read a single expression: the body is only reachable after the permit is obtained, so a
/// refused read performs **zero** device work — which is the property Phase 3 success criterion 1
/// measures.
struct ConsentGate: Sendable {
    let registry: ConsentRegistry
    let auditLog: DeviceAuditLog

    init(registry: ConsentRegistry, auditLog: DeviceAuditLog) {
        self.registry = registry
        self.auditLog = auditLog
    }

    /// Runs `body` only if `dataClass` has an active grant.
    ///
    /// A refusal is recorded with `outcome == .refused` before anything is issued — ADR-019's rule
    /// that a refusal is an event, not an absence, carried into the generalised trail.
    func performing<T>(
        _ dataClass: ConsentDataClass,
        target: String?,
        operation: DeviceOperationKind = .notificationRead,
        _ body: () async throws -> T
    ) async throws -> T {
        do {
            _ = try registry.permit(for: dataClass)
        } catch {
            auditLog.append(
                operation: operation,
                target: target,
                outcome: .refused,
                detail: (error as? ConsentError)?.description ?? "\(error)"
            )
            throw error
        }
        return try await body()
    }
}
