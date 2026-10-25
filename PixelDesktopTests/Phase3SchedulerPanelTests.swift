import XCTest
@testable import PixelDesktop

/// Phase 3.4 (C4) — the Schedules tab's state machine.
///
/// Every test here runs against a temporary store and a temporary `LaunchAgents` directory, so the
/// suite never writes to `~/Library` and never asks launchd for anything: `launchctl` is replaced by a
/// recorder. That matters because the thing being tested is *what the app claims*, and "installed"
/// must mean "launchd accepted it", not "a file appeared".
@MainActor
final class Phase3SchedulerPanelTests: XCTestCase {
    private var directory: URL!
    private let fixedNow = Date(timeIntervalSince1970: 1_700_000_000)

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("PixelDesktopPanel-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let directory, FileManager.default.fileExists(atPath: directory.path) {
            try FileManager.default.removeItem(at: directory)
        }
    }

    // MARK: - Fixtures

    private final class LaunchctlRecorder: @unchecked Sendable {
        private let lock = NSLock()
        private var storage: [[String]] = []

        var calls: [[String]] {
            lock.lock()
            defer { lock.unlock() }
            return storage
        }

        func runner(status: Int32 = 0) -> LaunchctlRunner {
            { [self] arguments in
                record(arguments, status: status)
            }
        }

        func record(_ arguments: [String], status: Int32) -> Int32 {
            lock.lock()
            storage.append(arguments)
            lock.unlock()
            return status
        }
    }

    private func storeURL(_ name: String = "jobs.json") -> URL {
        directory.appendingPathComponent(name)
    }

    private func makeModel(
        helperPath: String? = "/usr/local/bin/pixel-desktop",
        recorder: LaunchctlRecorder = LaunchctlRecorder(),
        unavailableReason: String? = nil
    ) -> SchedulerPanelModel {
        SchedulerPanelModel(
            store: ScheduledJobStore(fileURL: storeURL(), now: { [fixedNow] in fixedNow }),
            installer: LaunchAgentInstaller(runLaunchctl: recorder.runner()),
            now: { [fixedNow] in fixedNow },
            helperPath: helperPath,
            unavailableReason: unavailableReason,
            launchAgentsDirectory: directory.appendingPathComponent("LaunchAgents").path,
            logDirectory: directory.appendingPathComponent("Logs").path
        )
    }

    private func plistURL(for job: ScheduledJob) -> URL {
        directory
            .appendingPathComponent("LaunchAgents")
            .appendingPathComponent("\(LaunchAgent.label(for: job.id)).plist")
    }

    // MARK: - Creating jobs

    func testAddPersistsJobAndListsIt() throws {
        let model = makeModel()
        XCTAssertTrue(model.jobs.isEmpty)

        model.add(name: "Hourly telemetry", cadence: .interval(seconds: 3600), action: .telemetrySample)

        XCTAssertNil(model.errorMessage)
        XCTAssertEqual(model.jobs.count, 1)
        XCTAssertEqual(model.jobs.first?.name, "Hourly telemetry")
        XCTAssertEqual(model.jobs.first?.enabled, true)
        XCTAssertNotNil(model.status)

        // The job has to be on disk, not only in the model: the process launchd starts reads the file.
        let onDisk = try ScheduledJobStore(fileURL: storeURL())
        XCTAssertEqual(onDisk.jobs.count, 1)
    }

    func testAddRejectsDuplicateNameAndKeepsOneJob() throws {
        let model = makeModel()
        model.add(name: "Nightly", cadence: .daily(hour: 3, minute: 0), action: .workerHealth)
        model.add(name: "nightly", cadence: .daily(hour: 4, minute: 0), action: .workerHealth)

        XCTAssertNotNil(model.errorMessage)
        XCTAssertEqual(model.jobs.count, 1)
    }

    func testAddRejectsBlankName() throws {
        let model = makeModel()
        model.add(name: "   ", cadence: .interval(seconds: 600), action: .workerHealth)

        XCTAssertNotNil(model.errorMessage)
        XCTAssertTrue(model.jobs.isEmpty)
    }

    func testCorruptStoreIsReportedAndRefusesWrites() throws {
        try Data("{".utf8).write(to: storeURL())

        let model = makeModel()
        XCTAssertNotNil(model.corruption)
        XCTAssertFalse(model.isWritable)

        model.add(name: "Would vanish", cadence: .interval(seconds: 600), action: .workerHealth)
        XCTAssertTrue(model.jobs.isEmpty)

        // The unreadable file is left on disk byte-for-byte: a corrupt store is the operator's data,
        // and silently rewriting it would destroy whatever was recoverable.
        XCTAssertEqual(try String(contentsOf: storeURL(), encoding: .utf8), "{")
    }

    func testUnavailableStoreIsReadOnly() throws {
        let model = makeModel(unavailableReason: "no store path")
        XCTAssertFalse(model.isWritable)
        XCTAssertNotNil(model.corruption)

        model.add(name: "Nope", cadence: .interval(seconds: 600), action: .workerHealth)
        XCTAssertTrue(model.jobs.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: storeURL().path))
    }

    // MARK: - Install / uninstall

    func testInstallWritesPlistAndReportsLaunchdAcceptance() async throws {
        let recorder = LaunchctlRecorder()
        let model = makeModel(recorder: recorder)
        model.add(name: "Quarter hourly", cadence: .interval(seconds: 900), action: .telemetrySample)
        let job = try XCTUnwrap(model.jobs.first)

        await model.install(job)

        XCTAssertNil(model.errorMessage)
        XCTAssertTrue(FileManager.default.fileExists(atPath: plistURL(for: job).path))
        XCTAssertTrue(model.isInstalled(job))

        // Bootout-then-bootstrap: bootstrap refuses a label that is already loaded, and pressing
        // Install twice must not be an error the operator has to understand.
        let calls = recorder.calls
        XCTAssertEqual(calls.count, 2)
        XCTAssertTrue(calls[0].contains("bootout"))
        XCTAssertTrue(calls[1].contains("bootstrap"))

        // The plist names the helper and the job the run process must act on.
        let plist = try String(contentsOf: plistURL(for: job), encoding: .utf8)
        XCTAssertTrue(plist.contains("/usr/local/bin/pixel-desktop"))
        XCTAssertTrue(plist.contains(job.id.uuidString))
    }

    func testInstallWithoutHelperRefusesAndWritesNothing() async throws {
        let recorder = LaunchctlRecorder()
        let model = makeModel(helperPath: nil, recorder: recorder)
        model.add(name: "No helper", cadence: .interval(seconds: 900), action: .telemetrySample)
        let job = try XCTUnwrap(model.jobs.first)

        await model.install(job)

        XCTAssertNotNil(model.errorMessage)
        XCTAssertFalse(model.isInstalled(job))
        XCTAssertTrue(recorder.calls.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: plistURL(for: job).path))
    }

    func testFailedBootstrapReportsErrorAndIsNotInstalled() async throws {
        let recorder = LaunchctlRecorder()
        // bootout succeeds, bootstrap fails — the shape of a plist launchd refuses.
        let installer = LaunchAgentInstaller { arguments in
            recorder.record(arguments, status: arguments.contains("bootstrap") ? 1 : 0)
        }
        let rejecting = SchedulerPanelModel(
            store: ScheduledJobStore(fileURL: storeURL(), now: { [fixedNow] in fixedNow }),
            installer: installer,
            now: { [fixedNow] in fixedNow },
            helperPath: "/usr/local/bin/pixel-desktop",
            launchAgentsDirectory: directory.appendingPathComponent("LaunchAgents").path,
            logDirectory: directory.appendingPathComponent("Logs").path
        )
        rejecting.add(name: "Rejected", cadence: .interval(seconds: 900), action: .telemetrySample)
        let job = try XCTUnwrap(rejecting.jobs.first)

        await rejecting.install(job)

        XCTAssertNotNil(rejecting.errorMessage)
        XCTAssertFalse(rejecting.isInstalled(job))
        // A refused bootstrap must not leave a plist behind: the badge, the file on disk and launchd
        // have to agree that this job is not loaded.
        XCTAssertFalse(FileManager.default.fileExists(atPath: plistURL(for: job).path))
        XCTAssertEqual(recorder.calls.count, 2)
    }

    func testDisablingJobRemovesItsAgent() async throws {
        let model = makeModel()
        model.add(name: "Toggle me", cadence: .interval(seconds: 900), action: .telemetrySample)
        let job = try XCTUnwrap(model.jobs.first)
        await model.install(job)
        XCTAssertTrue(FileManager.default.fileExists(atPath: plistURL(for: job).path))

        await model.setEnabled(false, job: job)

        let updated = try XCTUnwrap(model.jobs.first)
        XCTAssertFalse(updated.enabled)
        XCTAssertFalse(model.isInstalled(updated))
        // A disabled job must not keep an agent that ticks and skips forever.
        XCTAssertFalse(FileManager.default.fileExists(atPath: plistURL(for: job).path))
    }

    func testDeleteRemovesJobAndAgent() async throws {
        let model = makeModel()
        model.add(name: "Temporary", cadence: .interval(seconds: 900), action: .workerHealth)
        let job = try XCTUnwrap(model.jobs.first)
        await model.install(job)

        await model.delete(job)

        XCTAssertTrue(model.jobs.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: plistURL(for: job).path))
        XCTAssertEqual(try ScheduledJobStore(fileURL: storeURL()).jobs.count, 0)
    }

    // MARK: - Copy shown to the operator

    func testNextRunTextStatesFactsAboutTheStore() throws {
        let model = makeModel()
        model.add(name: "Copy", cadence: .interval(seconds: 3600), action: .telemetrySample)
        var job = try XCTUnwrap(model.jobs.first)

        XCTAssertEqual(model.nextRunText(for: job), "Due at the next tick")
        XCTAssertEqual(model.lastRunText(for: job), "Never ran")

        job.enabled = false
        XCTAssertEqual(model.nextRunText(for: job), "Disabled — no agent runs")
    }

    func testNextRunTextAfterARecordedRun() throws {
        let store = ScheduledJobStore(fileURL: storeURL(), now: { [fixedNow] in fixedNow })
        let job = try store.add(name: "Ran", cadence: .interval(seconds: 3600), action: .workerHealth)
        try store.recordRun(id: job.id, at: fixedNow, outcome: .succeeded)

        let model = SchedulerPanelModel(
            store: store,
            installer: LaunchAgentInstaller { _ in 0 },
            now: { [fixedNow] in fixedNow },
            helperPath: nil,
            launchAgentsDirectory: directory.appendingPathComponent("LaunchAgents").path,
            logDirectory: directory.appendingPathComponent("Logs").path
        )
        let updated = try XCTUnwrap(model.jobs.first)

        XCTAssertTrue(model.nextRunText(for: updated).hasPrefix("Next tick after"))
        XCTAssertTrue(model.lastRunText(for: updated).hasPrefix("Succeeded"))
    }

    // MARK: - Helper discovery

    func testLocateFindsHelperInsideTheBundle() throws {
        let helper = directory
            .appendingPathComponent("PixelDesktop.app/Contents/MacOS")
            .appendingPathComponent(SchedulerHelper.executableName)
        try FileManager.default.createDirectory(
            at: helper.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data().write(to: helper)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: helper.path)

        let found = SchedulerHelper.locate(
            bundleURL: directory.appendingPathComponent("PixelDesktop.app")
        )
        XCTAssertEqual(found, helper.path)
    }

    func testLocateFallsBackToTheSiblingProduct() throws {
        let app = directory.appendingPathComponent("PixelDesktop.app")
        try FileManager.default.createDirectory(at: app, withIntermediateDirectories: true)
        let sibling = directory.appendingPathComponent(SchedulerHelper.executableName)
        try Data().write(to: sibling)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: sibling.path)

        XCTAssertEqual(SchedulerHelper.locate(bundleURL: app), sibling.path)
    }

    func testLocateReturnsNilWhenTheHelperIsAbsent() throws {
        let app = directory.appendingPathComponent("PixelDesktop.app")
        try FileManager.default.createDirectory(at: app, withIntermediateDirectories: true)

        XCTAssertNil(SchedulerHelper.locate(bundleURL: app))
    }
}
