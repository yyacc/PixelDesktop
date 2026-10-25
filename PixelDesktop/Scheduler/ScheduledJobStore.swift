//
//  ScheduledJobStore.swift
//  PixelDesktop
//
//  Phase 3.4 (C4) — the job store.
//
//  WHAT IT IS
//  One JSON file (`~/Library/Application Support/PixelDesktop/schedules.json`) holding every
//  scheduled job, written atomically and versioned. It is the single source of truth: the launchd
//  plists are generated from it, the Schedules tab renders it, and the CLI's `schedule run` reads
//  it. A job exists in exactly one place.
//
//  WHAT IT IS NOT
//  Not a database, not a queue, not a lock. A corrupt file is reported and left on disk — silently
//  replacing it would delete the operator's schedules and call that recovery.
//

import Foundation

final class ScheduledJobStore: @unchecked Sendable {
    /// Versioned so a future field can be added without guessing at the shape of an old file.
    struct Document: Codable, Equatable, Sendable {
        var schemaVersion: Int
        var jobs: [ScheduledJob]
    }

    static let schemaVersion = 1
    static let maximumNameLength = 64

    private let lock = NSLock()
    private let fileURL: URL?
    private let now: @Sendable () -> Date
    private var storage: [ScheduledJob] = []
    private var corruptReason: String?

    init(fileURL: URL?, now: @escaping @Sendable () -> Date = Date.init) {
        self.fileURL = fileURL
        self.now = now
        guard let fileURL, FileManager.default.fileExists(atPath: fileURL.path) else { return }

        do {
            let document = try Self.decode(contentsOf: fileURL)
            storage = document.jobs
        } catch {
            // Left on disk, unmodified. Every mutation below refuses while this is set.
            corruptReason = String(describing: error)
        }
    }

    // MARK: Reading

    /// Non-nil when the file exists but could not be read. The UI shows this instead of an empty list,
    /// because an empty list is a lie that looks like success.
    var corruption: String? {
        lock.lock()
        defer { lock.unlock() }
        return corruptReason
    }

    /// In creation order.
    var jobs: [ScheduledJob] {
        lock.lock()
        defer { lock.unlock() }
        return storage.sorted { $0.createdAt < $1.createdAt }
    }

    var enabledJobs: [ScheduledJob] { jobs.filter(\.enabled) }

    func job(id: UUID) -> ScheduledJob? {
        lock.lock()
        defer { lock.unlock() }
        return storage.first { $0.id == id }
    }

    func job(id: String) -> ScheduledJob? {
        guard let uuid = UUID(uuidString: id) else { return nil }
        return job(id: uuid)
    }

    func job(named name: String) -> ScheduledJob? {
        let needle = name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        lock.lock()
        defer { lock.unlock() }
        return storage.first { $0.name.lowercased() == needle }
    }

    // MARK: Writing

    @discardableResult
    func add(
        name: String,
        cadence: ScheduledCadence,
        action: ScheduledAction
    ) throws -> ScheduledJob {
        let trimmed = try Self.validateName(name)
        try cadence.validate()

        lock.lock()
        if let corruptReason {
            lock.unlock()
            throw ScheduledJobError.storeCorrupt(corruptReason)
        }
        let collides = storage.contains { $0.name.lowercased() == trimmed.lowercased() }
        lock.unlock()
        guard !collides else { throw ScheduledJobError.duplicateName(trimmed) }

        let job = ScheduledJob(
            name: trimmed,
            cadence: cadence,
            action: action,
            enabled: true,
            createdAt: now()
        )
        try mutate { $0.append(job) }
        return job
    }

    func update(_ job: ScheduledJob) throws {
        let trimmed = try Self.validateName(job.name)
        try job.cadence.validate()
        try mutate { jobs in
            guard let index = jobs.firstIndex(where: { $0.id == job.id }) else {
                throw ScheduledJobError.unknownJob(job.id.uuidString)
            }
            let collides = jobs.contains {
                $0.id != job.id && $0.name.lowercased() == trimmed.lowercased()
            }
            guard !collides else { throw ScheduledJobError.duplicateName(trimmed) }
            var updated = job
            updated.name = trimmed
            jobs[index] = updated
        }
    }

    func remove(id: UUID) throws {
        try mutate { jobs in
            guard let index = jobs.firstIndex(where: { $0.id == id }) else {
                throw ScheduledJobError.unknownJob(id.uuidString)
            }
            jobs.remove(at: index)
        }
    }

    @discardableResult
    func setEnabled(_ enabled: Bool, id: UUID) throws -> ScheduledJob {
        var result: ScheduledJob?
        try mutate { jobs in
            guard let index = jobs.firstIndex(where: { $0.id == id }) else {
                throw ScheduledJobError.unknownJob(id.uuidString)
            }
            jobs[index].enabled = enabled
            if enabled { jobs[index].disabledReason = nil }
            result = jobs[index]
        }
        guard let result else { throw ScheduledJobError.unknownJob(id.uuidString) }
        return result
    }

    /// Disables every enabled job and records why. The D4 kill switch's scheduler hook.
    ///
    /// Returns how many jobs it actually changed, so the caller can report a number rather than a
    /// claim. Throws if the store cannot be written — a kill switch that says "stopped" while the
    /// jobs are still enabled is worse than one that reports its failure.
    @discardableResult
    func disableAll(reason: String) throws -> Int {
        let trimmed = reason.trimmingCharacters(in: .whitespacesAndNewlines)
        let targets = enabledJobs.map(\.id)
        guard !targets.isEmpty else { return 0 }
        try mutate { jobs in
            for index in jobs.indices where jobs[index].enabled {
                jobs[index].enabled = false
                jobs[index].disabledReason = trimmed
            }
        }
        return targets.count
    }

    func recordRun(id: UUID, at date: Date, outcome: ScheduledRunOutcome) throws {
        try mutate { jobs in
            guard let index = jobs.firstIndex(where: { $0.id == id }) else {
                throw ScheduledJobError.unknownJob(id.uuidString)
            }
            jobs[index].lastRunAt = date
            jobs[index].lastOutcome = outcome
        }
    }

    /// Records a deferred attempt: the outcome is stored, but `lastRunAt` is left unchanged so the
    /// job stays due and retries on the next tick. Deferred is not a run that happened.
    func recordDeferral(id: UUID, at date: Date, outcome: ScheduledRunOutcome) throws {
        try mutate { jobs in
            guard let index = jobs.firstIndex(where: { $0.id == id }) else {
                throw ScheduledJobError.unknownJob(id.uuidString)
            }
            jobs[index].lastOutcome = outcome
        }
    }

    // MARK: Persistence

    private func mutate(_ body: (inout [ScheduledJob]) throws -> Void) throws {
        lock.lock()
        if let corruptReason {
            lock.unlock()
            throw ScheduledJobError.storeCorrupt(corruptReason)
        }
        var copy = storage
        do {
            try body(&copy)
        } catch {
            lock.unlock()
            throw error
        }
        try persist(copy)
        storage = copy
        lock.unlock()
    }

    private func persist(_ jobs: [ScheduledJob]) throws {
        guard let fileURL else { return }
        let document = Document(schemaVersion: Self.schemaVersion, jobs: jobs)
        do {
            try FileManager.default.createDirectory(
                at: fileURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            encoder.dateEncodingStrategy = .iso8601
            try encoder.encode(document).write(to: fileURL, options: .atomic)
        } catch {
            throw ScheduledJobError.storeUnwritable(String(describing: error))
        }
    }

    private static func decode(contentsOf url: URL) throws -> Document {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let document = try decoder.decode(Document.self, from: Data(contentsOf: url))
        // A file written by a different build is not read as this build's shape. `JSONDecoder`
        // ignores unknown keys, so without this check a future version's document would decode as
        // long as its v1-compatible subset lined up — and the next mutation would re-encode the
        // whole document at the version this build writes, silently dropping every field it does
        // not know about. Refusing keeps the file byte-for-byte intact and makes the mismatch
        // visible instead of destructive.
        //
        // There is deliberately no migration path: exactly one on-disk format has ever existed, so
        // there is nothing older to migrate from, and "supporting" an unknown future version would
        // mean inventing a shape. The operator is told which version they have and which one this
        // build reads.
        guard document.schemaVersion == Self.schemaVersion else {
            throw ScheduledJobError.storeCorrupt(
                "schedules.json was written by a different version (schemaVersion "
                    + "\(document.schemaVersion); this build reads \(Self.schemaVersion)). "
                    + "The file has been left unmodified."
            )
        }
        return document
    }

    private static func validateName(_ name: String) throws -> String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw ScheduledJobError.invalidName("A job needs a name.")
        }
        guard trimmed.count <= maximumNameLength else {
            throw ScheduledJobError.invalidName(
                "A job name must be \(maximumNameLength) characters or fewer."
            )
        }
        return trimmed
    }

    /// `~/Library/Application Support/PixelDesktop/schedules.json`.
    static func applicationDefaultURL() throws -> URL {
        let base = try FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        return base.appendingPathComponent("PixelDesktop/schedules.json")
    }
}
