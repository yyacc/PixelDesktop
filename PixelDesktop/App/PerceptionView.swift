import SwiftUI
import AppKit

/// Phase 0 control plane, in the app.
///
/// Three read-only capabilities and one reversible one:
///
/// - **UI hierarchy** (A4) — what is on screen, as the device's own accessibility tree.
/// - **Screenshot** (A2) — the framebuffer, written to Application Support as evidence.
/// - **Logcat** (A6) — a live device log stream with a priority floor.
/// - **Port forwards** (B3) — host→device forwards, listed and removable.
///
/// There is no tap, type or swipe control anywhere in this view, because the backend has none.
/// The screen is dead, so blind input is gated behind a dry-run preview in a later phase — a
/// button here that fired an unconfirmed tap would be the exact mistake that gate exists to
/// prevent.
///
/// Live mirroring is **not** here either: `scrcpy` is an external tool (proposal §6.4), and this
/// view only prints the command to run.
struct PerceptionView: View {
    @EnvironmentObject var appState: AppState

    @State private var hierarchy: UIHierarchy?
    @State private var hierarchyError: String?
    @State private var dumpDuration: TimeInterval?
    @State private var isDumping = false
    @State private var searchText = ""

    @State private var screenshotURL: URL?
    @State private var screenshotError: String?
    @State private var isCapturing = false

    @State private var logcat: LogcatStream?
    @State private var logLines: [LogcatLine] = []
    @State private var logError: String?
    @State private var logTag = ""
    @State private var logPriority: LogcatLine.Priority? = .info
    @State private var isStreaming = false

    @State private var forwards: [PortForward] = []
    @State private var forwardError: String?
    @State private var localPortText = "8080"
    @State private var remotePortText = "8080"

    /// Interaction is separated from structure on purpose: 60+ nodes is unreadable as a flat
    /// list, and the tap targets are the only nodes a later phase could act on.
    @State private var showAllNodes = false

    private var serial: String? {
        appState.devices.first(where: { $0.state == .device })?.serialNumber
    }

    private var visibleElements: [UIElement] {
        guard let hierarchy else { return [] }
        let base = showAllNodes ? hierarchy.elements : hierarchy.tapTargets
        guard !searchText.isEmpty else { return base }
        return base.filter { $0.matches(searchText) }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                hierarchySection
                Divider()
                screenshotSection
                Divider()
                logcatSection
                Divider()
                // A5 — the notification stream (Phase 3.2). Group A, so it lives here rather than in
                // an eleventh tab; see `NotificationsSection`'s header for the reasoning.
                NotificationsSection()
                Divider()
                forwardSection
                Divider()
                scrcpySection
            }
            .padding()
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .onDisappear {
            // A stream that outlives its view leaks a transport session and a dispatch thread.
            logcat?.stop()
            isStreaming = false
        }
    }

    // MARK: - A4 · UI hierarchy

    private var hierarchySection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("UI hierarchy").font(.headline)
                Spacer()
                if let dumpDuration {
                    Text(String(format: "%.2f s", dumpDuration))
                        .font(.caption).foregroundStyle(.secondary)
                }
                Button(isDumping ? "Dumping…" : "Dump") { dumpHierarchy() }
                    .disabled(serial == nil || isDumping)
            }

            if let hierarchyError {
                Text(hierarchyError).font(.caption).foregroundStyle(.red)
            }

            if let hierarchy {
                HStack(spacing: 16) {
                    Text("package: \(hierarchy.packageName ?? "unknown")")
                    Text("nodes: \(hierarchy.elements.count)")
                    Text("tap targets: \(hierarchy.tapTargets.count)")
                    Text("rotation: \(hierarchy.rotation.map(String.init) ?? "unknown")")
                }
                .font(.caption)
                .foregroundStyle(.secondary)

                HStack {
                    TextField("Filter by text, id, class…", text: $searchText)
                        .textFieldStyle(.roundedBorder)
                        .frame(maxWidth: 280)
                    Toggle("All nodes", isOn: $showAllNodes)
                        .toggleStyle(.switch)
                        .font(.caption)
                    Spacer()
                    Text("\(visibleElements.count) shown").font(.caption).foregroundStyle(.secondary)
                }

                VStack(alignment: .leading, spacing: 2) {
                    ForEach(visibleElements) { element in
                        HStack(alignment: .top, spacing: 8) {
                            Text(element.isClickable ? "▸" : " ")
                                .font(.system(.caption, design: .monospaced))
                                .foregroundStyle(.secondary)
                            Text(element.label)
                                .font(.system(.caption, design: .monospaced))
                                .lineLimit(1)
                                .textSelection(.enabled)
                            Spacer()
                            Text(element.className.split(separator: ".").last.map(String.init) ?? "")
                                .font(.system(.caption2, design: .monospaced))
                                .foregroundStyle(.secondary)
                            Text("[\(element.bounds.left),\(element.bounds.top)][\(element.bounds.right),\(element.bounds.bottom)]")
                                .font(.system(.caption2, design: .monospaced))
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            } else if !isDumping && hierarchyError == nil {
                Text("No hierarchy read yet. The dump takes ~1–4 s on the device.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    // MARK: - A2 · Screenshot

    private var screenshotSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Screenshot").font(.headline)
                Spacer()
                Button(isCapturing ? "Capturing…" : "Capture") { captureScreenshot() }
                    .disabled(serial == nil || isCapturing)
            }

            if let screenshotError {
                Text(screenshotError).font(.caption).foregroundStyle(.red)
            }

            if let screenshotURL {
                Text(screenshotURL.path)
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)

                if let image = NSImage(contentsOf: screenshotURL) {
                    Image(nsImage: image)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(maxHeight: 320)
                        .border(.quaternary)
                } else {
                    Text("Capture written but could not be decoded for preview.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            } else if !isCapturing && screenshotError == nil {
                Text("Captures are written to Application Support/PixelDesktop/captures.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    // MARK: - A6 · Logcat

    private var logcatSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Logcat").font(.headline)
                Spacer()

                TextField("tag", text: $logTag)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 140)
                    .disabled(isStreaming)

                Picker("", selection: $logPriority) {
                    Text("All").tag(LogcatLine.Priority?.none)
                    ForEach(LogcatLine.Priority.allCases, id: \.self) { priority in
                        Text(priority.rawValue).tag(LogcatLine.Priority?.some(priority))
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 240)
                .disabled(isStreaming)

                Button(isStreaming ? "Stop" : "Start") {
                    isStreaming ? stopLogcat() : startLogcat()
                }
                .disabled(serial == nil)

                Button("Clear") {
                    logcat?.clear()
                    logLines = []
                }
            }

            if let logError {
                Text(logError).font(.caption).foregroundStyle(.red)
            }

            Text(isStreaming
                 ? "Streaming · \(logLines.count) lines"
                 : "Stopped · \(logLines.count) lines retained")
                .font(.caption).foregroundStyle(.secondary)

            VStack(alignment: .leading, spacing: 1) {
                ForEach(logLines.suffix(200)) { line in
                    HStack(alignment: .top, spacing: 8) {
                        Text(line.timestamp).foregroundStyle(.secondary)
                        Text(line.priority.rawValue).foregroundStyle(color(for: line.priority))
                        Text(line.tag).foregroundStyle(.blue)
                        Text(line.message).lineLimit(2)
                    }
                    .font(.system(.caption2, design: .monospaced))
                }
            }
        }
    }

    // MARK: - B3 · Port forwards

    private var forwardSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Port forwards").font(.headline)
                Spacer()

                TextField("local", text: $localPortText)
                    .textFieldStyle(.roundedBorder).frame(width: 70)
                TextField("remote", text: $remotePortText)
                    .textFieldStyle(.roundedBorder).frame(width: 70)
                Button("Forward") { addForward() }
                    .disabled(serial == nil)

                Button("Refresh") { refreshForwards() }
                    .disabled(serial == nil)
            }

            if let forwardError {
                Text(forwardError).font(.caption).foregroundStyle(.red)
            }

            if forwards.isEmpty {
                Text("No forwards.")
                    .font(.caption).foregroundStyle(.secondary)
            } else {
                ForEach(forwards) { forward in
                    HStack {
                        Text("\(forward.local) → \(forward.remote)")
                            .font(.system(.caption, design: .monospaced))
                        Spacer()
                        Button("Remove") {
                            removeForward(forward)
                        }
                    }
                }
            }
        }
    }

    // MARK: - Mirroring, documented not implemented

    private var scrcpySection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Screen mirroring (external)").font(.headline)
            Text("Live mirroring is scrcpy, an external tool. PixelDesktop owns no video pipeline "
                 + "and speaks no part of the scrcpy protocol (proposal §6.4).")
                .font(.caption)
                .foregroundStyle(.secondary)

            ForEach(Self.scrcpyCommands, id: \.self) { command in
                HStack {
                    Text(command).font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                    Spacer()
                    Button("Copy") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(command, forType: .string)
                    }
                    .buttonStyle(.link)
                    .font(.caption)
                }
            }
        }
    }

    private static let scrcpyCommands = [
        "scrcpy                                              # live mirror over USB",
        "scrcpy --record=session.mkv                         # mirror + record",
        "scrcpy --no-playback --record=session.mkv           # record only, no window",
    ]

    // MARK: - Actions

    private func dumpHierarchy() {
        guard let serial else { return }
        isDumping = true
        hierarchyError = nil

        Task {
            let started = Date()
            do {
                let result = try await appState.perception.uiHierarchy(deviceSerial: serial, timeout: 25)
                hierarchy = result
                dumpDuration = Date().timeIntervalSince(started)
            } catch {
                hierarchyError = (error as? PixelDesktopError)?.description ?? error.localizedDescription
            }
            isDumping = false
        }
    }

    private func captureScreenshot() {
        guard let serial else { return }
        isCapturing = true
        screenshotError = nil

        Task {
            do {
                let png = try await appState.perception.screenshot(deviceSerial: serial, timeout: 30)
                let store = try ScreenshotStore.applicationDefault()
                screenshotURL = try store.write(png)
            } catch {
                screenshotError = (error as? PixelDesktopError)?.description ?? error.localizedDescription
            }
            isCapturing = false
        }
    }

    private func startLogcat() {
        guard let serial else { return }

        let stream = appState.makeLogcatStream()
        let filter = LogcatFilter(
            tag: logTag.isEmpty ? nil : logTag,
            minimumPriority: logPriority
        )

        do {
            try stream.start(deviceSerial: serial, filter: filter)
        } catch {
            logError = (error as? PixelDesktopError)?.description ?? error.localizedDescription
            return
        }

        logError = nil
        logcat = stream
        isStreaming = true

        // Poll rather than push: the stream delivers on a dispatch thread, and hopping every
        // line to the main actor would cost more than reading a bounded snapshot twice a second.
        Task {
            while isStreaming {
                try? await Task.sleep(nanoseconds: 500_000_000)
                guard isStreaming else { break }
                logLines = stream.lines
                logError = stream.errorDescription
                if !stream.isRunning {
                    isStreaming = false
                    break
                }
            }
        }
    }

    private func stopLogcat() {
        logcat?.stop()
        logLines = logcat?.lines ?? logLines
        isStreaming = false
    }

    private func refreshForwards() {
        guard let serial else { return }
        forwardError = nil

        Task {
            do {
                forwards = try await appState.portForwarding.forwards(deviceSerial: serial, timeout: 15)
            } catch {
                forwardError = (error as? PixelDesktopError)?.description ?? error.localizedDescription
            }
        }
    }

    private func addForward() {
        guard let serial, let local = Int(localPortText), let remote = Int(remotePortText) else {
            forwardError = "Local and remote ports must be integers"
            return
        }
        forwardError = nil

        Task {
            do {
                _ = try await appState.portForwarding.forward(
                    deviceSerial: serial,
                    localPort: local,
                    remotePort: remote,
                    timeout: 15
                )
                forwards = try await appState.portForwarding.forwards(deviceSerial: serial, timeout: 15)
            } catch {
                forwardError = (error as? PixelDesktopError)?.description ?? error.localizedDescription
            }
        }
    }

    private func removeForward(_ forward: PortForward) {
        guard let serial,
              let port = Int(forward.local.replacingOccurrences(of: "tcp:", with: "")) else { return }
        forwardError = nil

        Task {
            do {
                _ = try await appState.portForwarding.removeForward(
                    deviceSerial: serial,
                    localPort: port,
                    timeout: 15
                )
                forwards = try await appState.portForwarding.forwards(deviceSerial: serial, timeout: 15)
            } catch {
                forwardError = (error as? PixelDesktopError)?.description ?? error.localizedDescription
            }
        }
    }

    private func color(for priority: LogcatLine.Priority) -> Color {
        switch priority {
        case .verbose, .debug: return .secondary
        case .info: return .primary
        case .warn: return .orange
        case .error, .fatal, .assert: return .red
        }
    }
}
