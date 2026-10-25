//
//  LaunchAgent.swift
//  PixelDesktop
//
//  Phase 3.4 (C4) — the launchd side, as a pure function plus an explicit installer.
//
//  WHAT IT IS
//  `LaunchAgent.plist(for:)` is a pure function of a job and a CLI path: same job, same bytes. That
//  is what makes "the plist is generated from the store" a property a test can assert instead of a
//  claim a reviewer has to trust. `LaunchAgentInstaller` writes that plist to `~/Library/LaunchAgents`
//  and bootstraps it — only when the operator presses the button, because a file appearing in
//  LaunchAgents without the operator seeing it is the wrong kind of convenience.
//
//  WHAT IT IS NOT
//  Not a daemon, not a timer, not a scheduler. launchd is the scheduler; this type hands it one
//  small, inspectable job description and nothing else.
//

import Foundation

struct LaunchAgentDescriptor: Equatable, Sendable {
    let label: String
    let jobID: UUID
    let cliPath: String
    let logDirectory: String
    let cadence: ScheduledCadence
    /// The directory the plist is written into. Injected rather than read from `NSHomeDirectory` at
    /// use time, so a test can install into a temporary directory instead of the operator's real
    /// `~/Library/LaunchAgents`.
    var directory: String = LaunchAgent.userLaunchAgentsDirectory

    var standardOutPath: String { "\(logDirectory)/\(label).out.log" }
    var standardErrorPath: String { "\(logDirectory)/\(label).err.log" }

    /// `<directory>/<label>.plist`
    var installedPath: String { "\(directory)/\(label).plist" }
}

enum LaunchAgent {
    static let labelPrefix = "com.pixeldesktop.scheduler."

    /// `~/Library/LaunchAgents`, unexpanded.
    static var userLaunchAgentsDirectory: String {
        (NSHomeDirectory() as NSString).appendingPathComponent("Library/LaunchAgents")
    }

    static func label(for jobID: UUID) -> String {
        labelPrefix + jobID.uuidString.lowercased()
    }

    static func descriptor(
        for job: ScheduledJob,
        cliPath: String,
        logDirectory: String = defaultLogDirectory,
        directory: String = LaunchAgent.userLaunchAgentsDirectory
    ) -> LaunchAgentDescriptor {
        LaunchAgentDescriptor(
            label: label(for: job.id),
            jobID: job.id,
            cliPath: cliPath,
            logDirectory: logDirectory,
            cadence: job.cadence,
            directory: directory
        )
    }

    /// `~/Library/Logs/PixelDesktop/scheduler`.
    static var defaultLogDirectory: String {
        (NSHomeDirectory() as NSString).appendingPathComponent("Library/Logs/PixelDesktop/scheduler")
    }

    /// The plist text. Deterministic: keys in a fixed order, no dates, no randomness.
    static func plist(for descriptor: LaunchAgentDescriptor) -> String {
        var lines: [String] = [
            #"<?xml version="1.0" encoding="UTF-8"?>"#,
            #"<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">"#,
            #"<plist version="1.0">"#,
            "<dict>",
            "\t<key>Label</key>",
            "\t<string>\(escape(descriptor.label))</string>",
            "\t<key>ProgramArguments</key>",
            "\t<array>",
            "\t\t<string>\(escape(descriptor.cliPath))</string>",
            "\t\t<string>schedule</string>",
            "\t\t<string>run</string>",
            "\t\t<string>\(escape(descriptor.jobID.uuidString))</string>",
            // launchd redirects this process's stdout to the job's log file, and every command
            // emits one JSON document; the scheduler's own report is what a human reads there.
            "\t\t<string>--json</string>",
            "\t</array>",
        ]

        switch descriptor.cadence {
        case .interval(let seconds):
            lines.append("\t<key>StartInterval</key>")
            lines.append("\t<integer>\(seconds)</integer>")
        case .daily(let hour, let minute):
            lines.append("\t<key>StartCalendarInterval</key>")
            lines.append("\t<dict>")
            lines.append("\t\t<key>Hour</key>")
            lines.append("\t\t<integer>\(hour)</integer>")
            lines.append("\t\t<key>Minute</key>")
            lines.append("\t\t<integer>\(minute)</integer>")
            lines.append("\t</dict>")
        }

        lines.append(contentsOf: [
            // A tick at login would run every job once per login for no reason: the store already
            // knows whether the job is due, and a "catch up on wake" tick is what `RunAtLoad` would
            // fake badly.
            "\t<key>RunAtLoad</key>",
            "\t<false/>",
            "\t<key>ProcessType</key>",
            "\t<string>Background</string>",
            "\t<key>StandardOutPath</key>",
            "\t<string>\(escape(descriptor.standardOutPath))</string>",
            "\t<key>StandardErrorPath</key>",
            "\t<string>\(escape(descriptor.standardErrorPath))</string>",
            "</dict>",
            "</plist>",
            "",
        ])

        return lines.joined(separator: "\n")
    }

    /// The exact command that loads the plist into the operator's GUI session, shown in the UI so
    /// what will run is never a mystery.
    static func bootstrapCommand(for descriptor: LaunchAgentDescriptor, userID: uid_t) -> [String] {
        ["launchctl", "bootstrap", "gui/\(userID)", descriptor.installedPath]
    }

    static func bootoutCommand(for descriptor: LaunchAgentDescriptor, userID: uid_t) -> [String] {
        ["launchctl", "bootout", "gui/\(userID)/\(descriptor.label)"]
    }

    private static func escape(_ value: String) -> String {
        value
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
    }
}

// MARK: - Installer

/// Runs one program with its arguments. Injected so the installer's behaviour is testable without
/// touching the machine's launchd.
typealias LaunchctlRunner = @Sendable (_ arguments: [String]) async -> Int32

struct LaunchAgentInstaller: Sendable {
    let fileManager: FileManager
    let runLaunchctl: LaunchctlRunner
    let userID: uid_t

    init(
        fileManager: FileManager = .default,
        userID: uid_t = getuid(),
        runLaunchctl: @escaping LaunchctlRunner = LaunchAgentInstaller.systemLaunchctl
    ) {
        self.fileManager = fileManager
        self.userID = userID
        self.runLaunchctl = runLaunchctl
    }

    struct InstallResult: Equatable, Sendable {
        let plistPath: String
        let command: [String]
        let exitStatus: Int32
    }

    enum InstallError: Error, Equatable, CustomStringConvertible {
        case writeFailed(String)
        case launchctlFailed(command: [String], status: Int32)

        var description: String {
            switch self {
            case .writeFailed(let reason):
                return "The launch agent could not be written: \(reason)"
            case .launchctlFailed(let command, let status):
                return "`\(command.joined(separator: " "))` exited \(status)."
            }
        }
    }

    /// Writes the plist, then bootstraps it. A failed bootstrap leaves the file on disk and reports
    /// the exact command, because "installed" must mean "launchd accepted it".
    func install(_ descriptor: LaunchAgentDescriptor) async throws -> InstallResult {
        let text = LaunchAgent.plist(for: descriptor)
        do {
            try fileManager.createDirectory(
                atPath: descriptor.directory,
                withIntermediateDirectories: true
            )
            try fileManager.createDirectory(
                atPath: descriptor.logDirectory,
                withIntermediateDirectories: true
            )
            try Data(text.utf8).write(to: URL(fileURLWithPath: descriptor.installedPath), options: .atomic)
        } catch {
            throw InstallError.writeFailed(String(describing: error))
        }

        let command = LaunchAgent.bootstrapCommand(for: descriptor, userID: userID)
        // Bootstrap refuses a label that is already loaded; that is not a failure for the operator
        // who just pressed Install twice. Bootout first, then bootstrap, so the installed plist wins.
        _ = await runLaunchctl(LaunchAgent.bootoutCommand(for: descriptor, userID: userID))
        let status = await runLaunchctl(command)
        guard status == 0 else {
            throw InstallError.launchctlFailed(command: command, status: status)
        }
        return InstallResult(plistPath: descriptor.installedPath, command: command, exitStatus: status)
    }

    func uninstall(_ descriptor: LaunchAgentDescriptor) async throws {
        let command = LaunchAgent.bootoutCommand(for: descriptor, userID: userID)
        let status = await runLaunchctl(command)
        if fileManager.fileExists(atPath: descriptor.installedPath) {
            try? fileManager.removeItem(atPath: descriptor.installedPath)
        }
        // Bootout reports non-zero when the label was not loaded, which is the desired end state.
        _ = status
    }

    /// The real thing: one `launchctl` invocation, no shell, no string interpolation into a command.
    static let systemLaunchctl: LaunchctlRunner = { arguments in
        guard !arguments.isEmpty else { return 2 }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        process.arguments = Array(arguments.dropFirst())
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            process.waitUntilExit()
            return process.terminationStatus
        } catch {
            return 1
        }
    }
}
