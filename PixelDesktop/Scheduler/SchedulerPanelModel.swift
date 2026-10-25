//
//  SchedulerPanelModel.swift
//  PixelDesktop
//
//  Phase 3.4 (C4) — the state behind the Schedules tab.
//
//  WHAT IT IS
//  The operator's half of the scheduler: it lists the stored jobs, edits them, and installs or removes
//  the launch agent for one job. Every device-facing decision still happens in `ScheduledJobRunner`
//  inside a launchd-run process — the model never reads the device, never chooses a time, and never
//  claims a run happened.
//
//  WHAT IT IS NOT
//  Not a timer. Nothing here holds a schedule in memory: the store holds the job, launchd holds the
//  clock, and this file holds the buttons.
//

import Foundation

/// Where the helper executable lives.
///
/// The CLI is the process launchd runs, and the app is what installs it, so the app has to name it —
/// but naming an absolute path would pin the app to one machine. These are the two places the binary
/// can legitimately be.
enum SchedulerHelper {
    static let executableName = "pixel-desktop"

    static func locate(
        bundleURL: URL = Bundle.main.bundleURL,
        fileManager: FileManager = .default
    ) -> String? {
        // A shipped app carries the helper inside its own bundle.
        let bundled = bundleURL
            .appendingPathComponent("Contents/MacOS")
            .appendingPathComponent(executableName)
        if fileManager.isExecutableFile(atPath: bundled.path) { return bundled.path }

        // A development build puts `PixelDesktop.app` and `pixel-desktop` side by side in the same
        // products directory, so a dev build works without a hardcoded path.
        let sibling = bundleURL
            .deletingLastPathComponent()
            .appendingPathComponent(executableName)
        if fileManager.isExecutableFile(atPath: sibling.path) { return sibling.path }

        return nil
    }
}

@MainActor
final class SchedulerPanelModel: ObservableObject {
    @Published private(set) var jobs: [ScheduledJob] = []
    /// Set when the store file exists but cannot be read. Shown instead of an empty list, because an
    /// empty list looks exactly like "no jobs" and would invite the operator to create duplicates.
    @Published private(set) var corruption: String?
    @Published private(set) var status: String?
    @Published private(set) var errorMessage: String?
    @Published private(set) var busyJobIDs: Set<UUID> = []
    @Published private(set) var installedJobIDs: Set<UUID> = []
    @Published private(set) var helperPath: String?

    /// Set when the store could not be opened at all. Mutations are refused rather than silently
    /// applied to an in-memory store that would vanish on quit.
    private let unavailableReason: String?

    private let store: ScheduledJobStore
    private let installer: LaunchAgentInstaller
    private let now: @Sendable () -> Date
    private let fileManager: FileManager
    /// Where a job's plist goes, and where its process writes its logs. Defaults are the real
    /// per-user locations; tests pass a temporary directory so installing never touches the
    /// operator's `~/Library`.
    private let launchAgentsDirectory: String
    private let logDirectory: String

    init(
        store: ScheduledJobStore,
        installer: LaunchAgentInstaller = LaunchAgentInstaller(),
        now: @escaping @Sendable () -> Date = { Date() },
        fileManager: FileManager = .default,
        helperPath: String? = SchedulerHelper.locate(),
        unavailableReason: String? = nil,
        launchAgentsDirectory: String = LaunchAgent.userLaunchAgentsDirectory,
        logDirectory: String = LaunchAgent.defaultLogDirectory
    ) {
        self.store = store
        self.installer = installer
        self.now = now
        self.fileManager = fileManager
        self.helperPath = helperPath
        self.unavailableReason = unavailableReason
        self.launchAgentsDirectory = launchAgentsDirectory
        self.logDirectory = logDirectory
        reload()
    }

    /// The app's own store, at the path the launch agent's process reads.
    static func live(
        fileManager: FileManager = .default,
        helperPath: String? = SchedulerHelper.locate()
    ) -> SchedulerPanelModel {
        do {
            let url = try ScheduledJobStore.applicationDefaultURL()
            return SchedulerPanelModel(
                store: ScheduledJobStore(fileURL: url),
                fileManager: fileManager,
                helperPath: helperPath
            )
        } catch {
            return SchedulerPanelModel(
                store: ScheduledJobStore(fileURL: nil),
                fileManager: fileManager,
                helperPath: helperPath,
                unavailableReason: "The scheduler store is unavailable: \(String(describing: error))"
            )
        }
    }

    // MARK: - Reading

    var isWritable: Bool { unavailableReason == nil && store.corruption == nil }

    var helperIsAvailable: Bool { helperPath != nil }

    func reload() {
        jobs = store.jobs.sorted { $0.createdAt < $1.createdAt }
        corruption = unavailableReason ?? store.corruption
        installedJobIDs = Set(jobs.filter { fileManager.fileExists(atPath: installedPath(for: $0)) }
            .map(\.id))
    }

    func isInstalled(_ job: ScheduledJob) -> Bool { installedJobIDs.contains(job.id) }

    /// What the operator needs to know about the next firing. Stated as a fact about the store, not a
    /// promise: launchd decides when a tick arrives, and a Mac asleep at that moment fires late.
    func nextRunText(for job: ScheduledJob) -> String {
        guard job.enabled else { return "Disabled — no agent runs" }
        guard let lastRun = job.lastRunAt else { return "Due at the next tick" }
        let next = CadenceResolver.nextRun(after: lastRun, cadence: job.cadence)
        guard next > now() else { return "Overdue — due at the next tick" }
        return "Next tick after \(next.formatted(date: .abbreviated, time: .shortened))"
    }

    func lastRunText(for job: ScheduledJob) -> String {
        guard let last = job.lastRunAt else { return "Never ran" }
        let outcome = job.lastOutcome?.displayName ?? "Unknown"
        return "\(outcome) · \(last.formatted(date: .abbreviated, time: .shortened))"
    }

    // MARK: - Writing

    func add(name: String, cadence: ScheduledCadence, action: ScheduledAction) {
        guard isWritable else { return }
        do {
            let job = try store.add(name: name, cadence: cadence, action: action)
            status = "Added “\(job.name)”. Press Install to let launchd run it."
            errorMessage = nil
            reload()
        } catch {
            errorMessage = Self.describe(error)
        }
    }

    func setEnabled(_ enabled: Bool, job: ScheduledJob) async {
        guard isWritable else { return }
        do {
            _ = try store.setEnabled(enabled, id: job.id)
            errorMessage = nil
            reload()
            // A disabled job must not keep an agent that ticks and skips forever; the store says the
            // job is off, so the thing that would run it is removed rather than left to no-op.
            if !enabled, let updated = store.job(id: job.id) { await uninstall(updated) }
        } catch {
            errorMessage = Self.describe(error)
        }
    }

    func delete(_ job: ScheduledJob) async {
        guard isWritable else { return }
        await uninstall(job)
        do {
            try store.remove(id: job.id)
            status = "Removed “\(job.name)”."
            errorMessage = nil
            reload()
        } catch {
            errorMessage = Self.describe(error)
        }
    }

    func install(_ job: ScheduledJob) async {
        guard isWritable else { return }
        guard let cliPath = helperPath else {
            errorMessage = "The scheduler helper (\(SchedulerHelper.executableName)) was not found "
                + "inside the app bundle or beside it. Build the CLI target, then try again."
            return
        }

        busyJobIDs.insert(job.id)
        defer { busyJobIDs.remove(job.id) }

        let descriptor = LaunchAgent.descriptor(
            for: job,
            cliPath: cliPath,
            logDirectory: logDirectory,
            directory: launchAgentsDirectory
        )
        do {
            let result = try await installer.install(descriptor)
            status = "launchd accepted \(descriptor.label). Plist: \(result.plistPath)"
            errorMessage = nil
        } catch {
            // A refused bootstrap means launchd did not load this job. Leaving the plist behind would
            // make `isInstalled` (a file check) show a green "installed" badge for an agent that is
            // not loaded — and would also fail again at next login. Take the file back and report the
            // command's own error.
            try? fileManager.removeItem(atPath: descriptor.installedPath)
            errorMessage = "Install failed: \(String(describing: error))"
        }
        reload()
    }

    func uninstall(_ job: ScheduledJob) async {
        busyJobIDs.insert(job.id)
        defer { busyJobIDs.remove(job.id) }

        let descriptor = LaunchAgent.descriptor(
            for: job,
            cliPath: helperPath ?? SchedulerHelper.executableName,
            logDirectory: logDirectory,
            directory: launchAgentsDirectory
        )
        do {
            try await installer.uninstall(descriptor)
            status = "Removed \(descriptor.label)."
            errorMessage = nil
        } catch {
            errorMessage = "Removing the agent failed: \(String(describing: error))"
        }
        reload()
    }

    // MARK: - Paths

    private func installedPath(for job: ScheduledJob) -> String {
        "\(launchAgentsDirectory)/\(LaunchAgent.label(for: job.id)).plist"
    }

    private static func describe(_ error: Error) -> String {
        // Every `Error` bridges to `CustomStringConvertible`, so `String(describing:)` is the one
        // conversion that works for both a described domain error and a bare `NSError`.
        String(describing: error)
    }
}
