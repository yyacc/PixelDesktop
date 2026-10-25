import XCTest
@testable import PixelDesktop

/// Phase 3.4 (C4) — the Mac scheduler, tested hermetically.
///
/// No wall clock, no launchd, no device: a `TestClock` supplies time, a counting executor stands in
/// for the phone, and every store is either in-memory or a temporary file. The one exception is the
/// deadline test, which uses a real 200 ms deadline on purpose — a bounded failure that only works
/// when time never advances is not bounded at all.
final class Phase3SchedulerTests: XCTestCase {
    private let serial = "TEST-SERIAL"
    private let fixedID = UUID(uuidString: "11111111-2222-3333-4444-555555555555")!

    // MARK: - Clock

    final class TestClock: Clock, @unchecked Sendable {
        var current: Date
        private(set) var sleepRequests: [Date] = []

        init(_ date: Date) { self.current = date }

        func now() -> Date { current }

        func sleep(until date: Date) async throws {
            sleepRequests.append(date)
            // Never fires on its own: the executor under test completes first and cancels this.
            // If a test ever needs the deadline to win, it uses `SystemClock`.
            try await Task.sleep(nanoseconds: 60_000_000_000)
        }
    }

    // MARK: - Executor mock

    final class CountingExecutor: ScheduledActionExecuting, @unchecked Sendable {
        let auditLog: DeviceAuditLog?
        var calls: [(action: ScheduledAction, serial: String)] = []
        var auditAtCallTime: [DeviceAuditRecord] = []
        var error: Error?
        var summary = "ok"

        init(auditLog: DeviceAuditLog? = nil) { self.auditLog = auditLog }

        func perform(action: ScheduledAction, deviceSerial: String, deadline: Date) async throws -> String {
            calls.append((action, deviceSerial))
            auditAtCallTime = auditLog?.records ?? []
            if let error { throw error }
            return summary
        }
    }

    // MARK: - Helpers

    private func makeStore(now: Date = Date(timeIntervalSince1970: 1_000_000)) -> ScheduledJobStore {
        ScheduledJobStore(fileURL: nil, now: { now })
    }

    private func makeJob(
        action: ScheduledAction = .telemetrySample,
        cadence: ScheduledCadence = .interval(seconds: 900),
        enabled: Bool = true,
        lastRunAt: Date? = nil
    ) -> ScheduledJob {
        ScheduledJob(
            name: "Job",
            cadence: cadence,
            action: action,
            enabled: enabled,
            createdAt: Date(timeIntervalSince1970: 0),
            lastRunAt: lastRunAt
        )
    }

    private func makeRunner(
        store: ScheduledJobStore,
        clock: Clock,
        executor: CountingExecutor,
        consent: ConsentRegistry = ConsentRegistry(),
        auditLog: DeviceAuditLog,
        serial: String? = "TEST-SERIAL",
        timeout: TimeInterval = 60
    ) -> ScheduledJobRunner {
        ScheduledJobRunner(
            store: store,
            consent: consent,
            auditLog: auditLog,
            clock: clock,
            deviceSerial: { serial },
            executor: executor,
            eligibility: AlwaysEligibleEligibility(),
            timeout: timeout
        )
    }

    private var gmt: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return calendar
    }

    // MARK: - Cadence

    func testCadenceRejectsSubMinuteInterval() {
        XCTAssertThrowsError(try ScheduledCadence.interval(seconds: 5).validate()) { error in
            guard case ScheduledJobError.invalidCadence = error else {
                return XCTFail("expected invalidCadence, got \(error)")
            }
        }
        XCTAssertNoThrow(try ScheduledCadence.interval(seconds: 60).validate())
    }

    func testCadenceRejectsOutOfRangeDailyTime() {
        XCTAssertThrowsError(try ScheduledCadence.daily(hour: 24, minute: 0).validate())
        XCTAssertThrowsError(try ScheduledCadence.daily(hour: 12, minute: 60).validate())
        XCTAssertNoThrow(try ScheduledCadence.daily(hour: 23, minute: 59).validate())
    }

    func testNextRunForIntervalIsExactlyOneCadenceAhead() {
        let base = Date(timeIntervalSince1970: 1_000_000)
        let next = CadenceResolver.nextRun(after: base, cadence: .interval(seconds: 900))
        XCTAssertEqual(next.timeIntervalSince(base), 900, accuracy: 0.001)
    }

    func testNextRunForDailyIsTheNextOccurrence() throws {
        let base = try XCTUnwrap(
            gmt.date(from: DateComponents(year: 2026, month: 10, day: 25, hour: 6, minute: 30))
        )
        let sameDay = CadenceResolver.nextRun(
            after: base,
            cadence: .daily(hour: 9, minute: 0),
            calendar: gmt
        )
        XCTAssertEqual(
            gmt.dateComponents([.day, .hour, .minute], from: sameDay),
            DateComponents(day: 25, hour: 9, minute: 0)
        )

        let afterTheTime = try XCTUnwrap(
            gmt.date(from: DateComponents(year: 2026, month: 10, day: 25, hour: 9, minute: 30))
        )
        let tomorrow = CadenceResolver.nextRun(
            after: afterTheTime,
            cadence: .daily(hour: 9, minute: 0),
            calendar: gmt
        )
        XCTAssertEqual(
            gmt.dateComponents([.day, .hour, .minute], from: tomorrow),
            DateComponents(day: 26, hour: 9, minute: 0)
        )
    }

    func testMissedTicksForDailyCountsSkippedDays() throws {
        let lastRun = try XCTUnwrap(
            gmt.date(from: DateComponents(year: 2026, month: 10, day: 20, hour: 9, minute: 0))
        )
        let now = try XCTUnwrap(
            gmt.date(from: DateComponents(year: 2026, month: 10, day: 23, hour: 10, minute: 0))
        )
        // Ran on the 20th; ticks on the 21st, 22nd and 23rd elapsed, one of which is "this run".
        XCTAssertEqual(
            CadenceResolver.missedTicks(
                lastRun: lastRun,
                now: now,
                cadence: .daily(hour: 9, minute: 0),
                calendar: gmt
            ),
            2
        )
    }

    func testMissedTicksCoalesceForInterval() {
        let lastRun = Date(timeIntervalSince1970: 1_000_000)
        let now = lastRun.addingTimeInterval(900 * 4 + 10)
        XCTAssertEqual(
            CadenceResolver.missedTicks(lastRun: lastRun, now: now, cadence: .interval(seconds: 900)),
            3
        )
        XCTAssertEqual(
            CadenceResolver.missedTicks(
                lastRun: lastRun,
                now: lastRun.addingTimeInterval(10),
                cadence: .interval(seconds: 900)
            ),
            0
        )
    }

    func testIsDueRespectsInterval() {
        let lastRun = Date(timeIntervalSince1970: 1_000_000)
        XCTAssertFalse(
            CadenceResolver.isDue(
                lastRun: lastRun,
                now: lastRun.addingTimeInterval(60),
                cadence: .interval(seconds: 900)
            )
        )
        XCTAssertTrue(
            CadenceResolver.isDue(
                lastRun: lastRun,
                now: lastRun.addingTimeInterval(901),
                cadence: .interval(seconds: 900)
            )
        )
        XCTAssertTrue(CadenceResolver.isDue(lastRun: nil, now: lastRun, cadence: .interval(seconds: 900)))
    }

    // MARK: - Store

    func testStoreRoundTripsThroughJSON() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("pd-schedules-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }

        let store = ScheduledJobStore(fileURL: url)
        let added = try store.add(name: "Telemetry", cadence: .interval(seconds: 1800), action: .telemetrySample)

        let reopened = ScheduledJobStore(fileURL: url)
        XCTAssertNil(reopened.corruption)
        XCTAssertEqual(reopened.jobs.count, 1)
        XCTAssertEqual(reopened.jobs.first?.id, added.id)
        XCTAssertEqual(reopened.jobs.first?.action, .telemetrySample)
        XCTAssertEqual(reopened.jobs.first?.cadence, .interval(seconds: 1800))
    }

    func testStoreReportsCorruptFileAndRefusesMutation() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("pd-schedules-corrupt-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        try Data("{ not json".utf8).write(to: url)

        let store = ScheduledJobStore(fileURL: url)
        XCTAssertNotNil(store.corruption)
        XCTAssertTrue(store.jobs.isEmpty)
        XCTAssertThrowsError(
            try store.add(name: "Nope", cadence: .interval(seconds: 60), action: .workerHealth)
        ) { error in
            guard case ScheduledJobError.storeCorrupt = error else {
                return XCTFail("expected storeCorrupt, got \(error)")
            }
        }
        // The corrupt file is still there, unmodified.
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), "{ not json")
    }

    // MARK: Schema version

    /// A document written by a different build must not be adopted and re-written as this build's
    /// shape. `JSONDecoder` ignores unknown keys, so the failure would otherwise be silent: the
    /// v1-compatible subset decodes, and the next mutation drops every field this build cannot model.
    func testStoreRefusesAFileFromANewerSchemaVersion() throws {
        let (url, text) = try seedStoreDocument(rewritingVersionTo: 2, injectingFutureField: true)
        defer { try? FileManager.default.removeItem(at: url) }
        XCTAssertTrue(text.contains("retryPolicy"), "the fixture must carry a field this build does not model")

        let store = ScheduledJobStore(fileURL: url)
        let reason = try XCTUnwrap(store.corruption, "a newer document must not load silently")
        XCTAssertTrue(reason.contains("schemaVersion 2"), "the reason must name what it found: \(reason)")
        XCTAssertTrue(reason.contains("reads 1"), "the reason must name what it supports: \(reason)")
        XCTAssertTrue(store.jobs.isEmpty, "nothing from an unreadable version is adopted")

        XCTAssertThrowsError(
            try store.add(name: "Nope", cadence: .interval(seconds: 60), action: .workerHealth)
        ) { error in
            guard case ScheduledJobError.storeCorrupt = error else {
                return XCTFail("expected storeCorrupt, got \(error)")
            }
        }
        // Byte-for-byte identical, including the field this build does not know about.
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), text)
    }

    /// Version 0 is not a version this build ever wrote, so it is refused on the same terms rather
    /// than treated as "older but close enough".
    func testStoreRefusesSchemaVersionZero() throws {
        let (url, text) = try seedStoreDocument(rewritingVersionTo: 0, injectingFutureField: false)
        defer { try? FileManager.default.removeItem(at: url) }

        let store = ScheduledJobStore(fileURL: url)
        XCTAssertNotNil(store.corruption, "schedules.json at version 0 must be reported, not adopted")
        XCTAssertTrue(store.jobs.isEmpty)
        XCTAssertThrowsError(
            try store.add(name: "Nope", cadence: .interval(seconds: 60), action: .telemetrySample)
        ) { error in
            guard case ScheduledJobError.storeCorrupt = error else {
                return XCTFail("expected storeCorrupt, got \(error)")
            }
        }
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), text,
                       "the refused file is left exactly as it was found")
    }

    func testThisBuildWritesSchemaVersionOne() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("pd-schedules-v1-\\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }

        let store = ScheduledJobStore(fileURL: url)
        try store.add(name: "Telemetry", cadence: .interval(seconds: 600), action: .telemetrySample)

        let text = try String(contentsOf: url, encoding: .utf8)
        XCTAssertTrue(text.contains("\"schemaVersion\" : 1"), "written document: \(text)")
        XCTAssertNil(ScheduledJobStore(fileURL: url).corruption, "this build reads what it writes")
    }

    /// Writes a real store, then rewrites the document the way a different build would have left it.
    private func seedStoreDocument(
        rewritingVersionTo version: Int,
        injectingFutureField: Bool
    ) throws -> (url: URL, text: String) {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("pd-schedules-v\(version)-\\(UUID().uuidString).json")
        let store = ScheduledJobStore(fileURL: url)
        try store.add(name: "Telemetry", cadence: .interval(seconds: 600), action: .telemetrySample)

        var text = try String(contentsOf: url, encoding: .utf8)
        text = text.replacingOccurrences(
            of: "\"schemaVersion\" : 1",
            with: "\"schemaVersion\" : \(version)"
        )
        if injectingFutureField {
            text = text.replacingOccurrences(
                of: "  \"schemaVersion\"",
                with: "  \"retryPolicy\" : { \"max\" : 3 },\n  \"schemaVersion\""
            )
        }
        try Data(text.utf8).write(to: url)
        return (url, text)
    }

    func testStoreRejectsDuplicateNamesCaseInsensitively() throws {
        let store = makeStore()
        try store.add(name: "Telemetry", cadence: .interval(seconds: 600), action: .telemetrySample)
        XCTAssertThrowsError(
            try store.add(name: " telemetry ", cadence: .interval(seconds: 600), action: .workerHealth)
        ) { error in
            guard case ScheduledJobError.duplicateName = error else {
                return XCTFail("expected duplicateName, got \(error)")
            }
        }
    }

    func testStoreDisableAllRecordsReasonAndCount() throws {
        let store = makeStore()
        try store.add(name: "A", cadence: .interval(seconds: 600), action: .telemetrySample)
        let b = try store.add(name: "B", cadence: .interval(seconds: 600), action: .workerHealth)
        try store.setEnabled(false, id: b.id)

        let changed = try store.disableAll(reason: "D4 kill switch")
        XCTAssertEqual(changed, 1)
        XCTAssertTrue(store.enabledJobs.isEmpty)
        XCTAssertEqual(store.job(id: b.id)?.disabledReason, nil)
        XCTAssertEqual(store.jobs.first { $0.name == "A" }?.disabledReason, "D4 kill switch")
        XCTAssertEqual(try store.disableAll(reason: "again"), 0)
    }

    // MARK: - Launch agent

    func testPlistIsByteForByteDeterministicForInterval() {
        let job = ScheduledJob(
            id: fixedID,
            name: "Telemetry",
            cadence: .interval(seconds: 900),
            action: .telemetrySample,
            createdAt: Date(timeIntervalSince1970: 0)
        )
        let descriptor = LaunchAgent.descriptor(
            for: job,
            cliPath: "/opt/pixel-desktop",
            logDirectory: "/tmp/logs"
        )
        let text = LaunchAgent.plist(for: descriptor)

        let expected = [
            #"<?xml version="1.0" encoding="UTF-8"?>"#,
            #"<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">"#,
            #"<plist version="1.0">"#,
            "<dict>",
            "\t<key>Label</key>",
            "\t<string>com.pixeldesktop.scheduler.11111111-2222-3333-4444-555555555555</string>",
            "\t<key>ProgramArguments</key>",
            "\t<array>",
            "\t\t<string>/opt/pixel-desktop</string>",
            "\t\t<string>schedule</string>",
            "\t\t<string>run</string>",
            "\t\t<string>11111111-2222-3333-4444-555555555555</string>",
            "\t\t<string>--json</string>",
            "\t</array>",
            "\t<key>StartInterval</key>",
            "\t<integer>900</integer>",
            "\t<key>RunAtLoad</key>",
            "\t<false/>",
            "\t<key>ProcessType</key>",
            "\t<string>Background</string>",
            "\t<key>StandardOutPath</key>",
            "\t<string>/tmp/logs/com.pixeldesktop.scheduler.11111111-2222-3333-4444-555555555555.out.log</string>",
            "\t<key>StandardErrorPath</key>",
            "\t<string>/tmp/logs/com.pixeldesktop.scheduler.11111111-2222-3333-4444-555555555555.err.log</string>",
            "</dict>",
            "</plist>",
            "",
        ].joined(separator: "\n")

        XCTAssertEqual(text, expected)
        XCTAssertEqual(text, LaunchAgent.plist(for: descriptor))
    }

    func testPlistDailyCadenceUsesCalendarInterval() {
        let job = ScheduledJob(
            id: fixedID,
            name: "Daily",
            cadence: .daily(hour: 7, minute: 5),
            action: .workerHealth,
            createdAt: Date(timeIntervalSince1970: 0)
        )
        let text = LaunchAgent.plist(
            for: LaunchAgent.descriptor(for: job, cliPath: "/bin/echo", logDirectory: "/tmp/logs")
        )
        XCTAssertTrue(text.contains("<key>StartCalendarInterval</key>"))
        XCTAssertTrue(text.contains("\t\t<key>Hour</key>\n\t\t<integer>7</integer>"))
        XCTAssertTrue(text.contains("\t\t<key>Minute</key>\n\t\t<integer>5</integer>"))
        XCTAssertFalse(text.contains("StartInterval"))
    }

    func testPlistEscapesXMLSignificantCharacters() {
        let job = ScheduledJob(
            id: fixedID,
            name: "Escaped",
            cadence: .interval(seconds: 60),
            action: .workerHealth,
            createdAt: Date(timeIntervalSince1970: 0)
        )
        let text = LaunchAgent.plist(
            for: LaunchAgent.descriptor(
                for: job,
                cliPath: "/tmp/a&b<c>d/pixel-desktop",
                logDirectory: "/tmp/logs"
            )
        )
        XCTAssertTrue(text.contains("/tmp/a&amp;b&lt;c&gt;d/pixel-desktop"))
        XCTAssertFalse(text.contains("a&b<c>d"))
    }

    func testBootstrapCommandNamesTheInstalledPlist() {
        let job = ScheduledJob(
            id: fixedID,
            name: "Any",
            cadence: .interval(seconds: 60),
            action: .workerHealth,
            createdAt: Date(timeIntervalSince1970: 0)
        )
        let descriptor = LaunchAgent.descriptor(for: job, cliPath: "/bin/echo")
        let command = LaunchAgent.bootstrapCommand(for: descriptor, userID: 501)
        XCTAssertEqual(command.prefix(3), ["launchctl", "bootstrap", "gui/501"])
        XCTAssertTrue(command.last?.hasSuffix("com.pixeldesktop.scheduler.11111111-2222-3333-4444-555555555555.plist") == true)
        XCTAssertTrue(descriptor.installedPath.contains("/Library/LaunchAgents/"))
    }

    // MARK: - Safety boundary

    func testDestructiveOperationsAreUnrepresentable() {
        XCTAssertEqual(ScheduledAction.allCases.count, 3)
        let names = Set(ScheduledAction.allCases.map(\.rawValue).map { $0.lowercased() })
        for forbidden in ["install", "uninstall", "reboot", "delete", "input", "shell"] {
            XCTAssertFalse(
                names.contains { $0.contains(forbidden) },
                "ScheduledAction must not contain a \(forbidden) action"
            )
        }
    }

    func testOnlyNotificationActionRequiresConsent() {
        XCTAssertEqual(ScheduledAction.notificationTier1.requiredConsent, .notifications)
        XCTAssertNil(ScheduledAction.telemetrySample.requiredConsent)
        XCTAssertNil(ScheduledAction.workerHealth.requiredConsent)
    }

    // MARK: - Runner

    func testUnknownJobReturnsNil() async {
        let store = makeStore()
        let executor = CountingExecutor()
        let runner = makeRunner(
            store: store,
            clock: TestClock(Date(timeIntervalSince1970: 1_000_000)),
            executor: executor,
            auditLog: DeviceAuditLog()
        )
        let report = await runner.run(jobID: fixedID)
        XCTAssertNil(report)
        XCTAssertTrue(executor.calls.isEmpty)
    }

    func testRunnerSkipsDisabledJobWithoutDeviceCall() async throws {
        let store = makeStore()
        let job = try store.add(name: "Off", cadence: .interval(seconds: 600), action: .telemetrySample)
        try store.setEnabled(false, id: job.id)

        let executor = CountingExecutor()
        let audit = DeviceAuditLog()
        let runner = makeRunner(
            store: store,
            clock: TestClock(Date(timeIntervalSince1970: 1_000_000)),
            executor: executor,
            auditLog: audit
        )

        let result = await runner.run(jobID: job.id)
        let report = try XCTUnwrap(result)
        XCTAssertEqual(report.outcome, .skipped)
        XCTAssertEqual(report.exitStatus, 0)
        XCTAssertTrue(executor.calls.isEmpty)
        XCTAssertTrue(audit.records.isEmpty)
    }

    func testRunnerSkipsEarlyTick() async throws {
        let now = Date(timeIntervalSince1970: 1_000_000)
        let store = makeStore(now: now)
        let job = try store.add(name: "Soon", cadence: .interval(seconds: 900), action: .workerHealth)
        try store.recordRun(id: job.id, at: now.addingTimeInterval(-60), outcome: .succeeded)

        let executor = CountingExecutor()
        let audit = DeviceAuditLog()
        let runner = makeRunner(store: store, clock: TestClock(now), executor: executor, auditLog: audit)

        let result = await runner.run(jobID: job.id)
        let report = try XCTUnwrap(result)
        XCTAssertEqual(report.outcome, .skipped)
        XCTAssertTrue(report.detail.contains("Not due"))
        XCTAssertTrue(executor.calls.isEmpty)
        XCTAssertTrue(audit.records.isEmpty)
    }

    func testRunnerRefusesWithoutConsentAndMakesZeroDeviceCalls() async throws {
        let now = Date(timeIntervalSince1970: 1_000_000)
        let store = makeStore(now: now)
        let job = try store.add(
            name: "Notifications",
            cadence: .interval(seconds: 900),
            action: .notificationTier1
        )

        let executor = CountingExecutor()
        let audit = DeviceAuditLog()
        let runner = makeRunner(store: store, clock: TestClock(now), executor: executor, auditLog: audit)

        let result = await runner.run(jobID: job.id)
        let report = try XCTUnwrap(result)
        XCTAssertEqual(report.outcome, .refused)
        XCTAssertEqual(report.exitStatus, 1)
        XCTAssertTrue(executor.calls.isEmpty, "a refusal must issue zero device calls")
        XCTAssertEqual(audit.records.count, 1)
        XCTAssertEqual(audit.records.first?.outcome, .refused)
        XCTAssertEqual(audit.records.first?.operation, .scheduledTaskRun)
    }

    func testRunnerSucceedsWithConsentAndWritesPendingAuditBeforeExecuting() async throws {
        let now = Date(timeIntervalSince1970: 1_000_000)
        let store = makeStore(now: now)
        let job = try store.add(
            name: "Notifications",
            cadence: .interval(seconds: 900),
            action: .notificationTier1
        )
        let consent = ConsentRegistry(now: { now })
        try consent.grant(.notifications, reason: "test")

        let audit = DeviceAuditLog()
        let executor = CountingExecutor(auditLog: audit)
        executor.summary = "2 notification keys"
        let runner = makeRunner(
            store: store,
            clock: TestClock(now),
            executor: executor,
            consent: consent,
            auditLog: audit
        )

        let result = await runner.run(jobID: job.id)
        let report = try XCTUnwrap(result)
        XCTAssertEqual(report.outcome, .succeeded)
        XCTAssertEqual(report.detail, "2 notification keys")
        XCTAssertEqual(report.skippedTicks, 0)
        XCTAssertEqual(executor.calls.count, 1)
        XCTAssertEqual(executor.calls.first?.serial, serial)
        XCTAssertEqual(executor.auditAtCallTime.first?.outcome, .pending, "the audit record must exist before the command runs")
        XCTAssertEqual(audit.records.last?.outcome, .executed)
        XCTAssertEqual(store.job(id: job.id)?.lastOutcome, .succeeded)
        XCTAssertNotNil(store.job(id: job.id)?.lastRunAt)
    }

    func testRunnerRecordsSkippedTicksAfterSleep() async throws {
        let now = Date(timeIntervalSince1970: 1_000_000)
        let store = makeStore(now: now)
        let job = try store.add(name: "Sleepy", cadence: .interval(seconds: 900), action: .workerHealth)
        try store.recordRun(id: job.id, at: now.addingTimeInterval(-900 * 3 - 5), outcome: .succeeded)

        let executor = CountingExecutor()
        let runner = makeRunner(
            store: store,
            clock: TestClock(now),
            executor: executor,
            auditLog: DeviceAuditLog()
        )

        let result = await runner.run(jobID: job.id)
        let report = try XCTUnwrap(result)
        XCTAssertEqual(report.outcome, .succeeded)
        XCTAssertEqual(report.skippedTicks, 2)
    }

    func testRunnerFailsLoudlyWhenExecutorThrows() async throws {
        let now = Date(timeIntervalSince1970: 1_000_000)
        let store = makeStore(now: now)
        let job = try store.add(name: "Boom", cadence: .interval(seconds: 900), action: .telemetrySample)

        let executor = CountingExecutor()
        executor.error = PixelDesktopError.verificationFailed(reason: "no source answered")
        let audit = DeviceAuditLog()
        let runner = makeRunner(store: store, clock: TestClock(now), executor: executor, auditLog: audit)

        let result = await runner.run(jobID: job.id)
        let report = try XCTUnwrap(result)
        XCTAssertEqual(report.outcome, .failed)
        XCTAssertEqual(report.exitStatus, 1)
        XCTAssertEqual(audit.records.last?.outcome, .failed)
        XCTAssertEqual(store.job(id: job.id)?.lastOutcome, .failed)
    }

    func testRunnerFailsWithinDeadlineWhenDeviceNeverReturns() async throws {
        let store = makeStore()
        let job = try store.add(name: "Hang", cadence: .interval(seconds: 900), action: .telemetrySample)

        final class SlowExecutor: ScheduledActionExecuting, @unchecked Sendable {
            func perform(action: ScheduledAction, deviceSerial: String, deadline: Date) async throws -> String {
                try await Task.sleep(nanoseconds: 5_000_000_000)
                return "never reached"
            }
        }

        let runner = ScheduledJobRunner(
            store: store,
            consent: ConsentRegistry(),
            auditLog: DeviceAuditLog(),
            clock: SystemClock(),
            deviceSerial: { "TEST-SERIAL" },
            executor: SlowExecutor(),
            eligibility: AlwaysEligibleEligibility(),
            timeout: 0.2
        )

        let started = Date()
        let result = await runner.run(jobID: job.id)
        let report = try XCTUnwrap(result)
        let elapsed = Date().timeIntervalSince(started)

        XCTAssertEqual(report.outcome, .failed)
        XCTAssertTrue(report.detail.contains("did not finish"), "detail was: \(report.detail)")
        XCTAssertLessThan(elapsed, 2, "the deadline must win, not the hung call")
    }

    func testRunnerFailsWhenNoDeviceSerial() async throws {
        let now = Date(timeIntervalSince1970: 1_000_000)
        let store = makeStore(now: now)
        let job = try store.add(name: "NoDevice", cadence: .interval(seconds: 900), action: .workerHealth)

        let executor = CountingExecutor()
        let audit = DeviceAuditLog()
        let runner = makeRunner(
            store: store,
            clock: TestClock(now),
            executor: executor,
            auditLog: audit,
            serial: nil
        )

        let result = await runner.run(jobID: job.id)
        let report = try XCTUnwrap(result)
        XCTAssertEqual(report.outcome, .failed)
        XCTAssertTrue(report.detail.contains("No device serial"))
        XCTAssertTrue(executor.calls.isEmpty)
        XCTAssertEqual(audit.records.first?.outcome, .failed)
        // Cadence governs *attempts*, not successes: a failed attempt still advances `lastRunAt`.
        // Otherwise a broken job stays permanently due and inflates `skippedTicks` on every later run.
        XCTAssertNotNil(store.job(id: job.id)?.lastRunAt)
        XCTAssertEqual(store.job(id: job.id)?.lastOutcome, .failed)
    }

    func testReportExitStatusMapping() {
        func make(_ outcome: ScheduledRunOutcome) -> ScheduledRunReport {
            ScheduledRunReport(
                jobID: fixedID,
                jobName: "x",
                action: .workerHealth,
                outcome: outcome,
                detail: "",
                startedAt: Date(),
                duration: 0,
                skippedTicks: 0,
                auditID: nil
            )
        }
        XCTAssertEqual(make(.succeeded).exitStatus, 0)
        XCTAssertEqual(make(.skipped).exitStatus, 0)
        XCTAssertEqual(make(.refused).exitStatus, 1)
        XCTAssertEqual(make(.failed).exitStatus, 1)
    }
}
