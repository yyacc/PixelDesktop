import SwiftUI

/// The PixelDesktop window.
///
/// ## What this view is allowed to do
///
/// Every value rendered here comes from a backend type that already existed and was already
/// verified on real hardware: `AndroidDevice` (Phase 3), `PixelStateObservation` (Phase 7 Step 2),
/// `InstalledApp` and the app-operations layer (Phase 4), and `LogEntry` (Core). This view
/// computes nothing, infers nothing, and invents no state.
///
/// Where the backend has no capability, the UI has no control. That is why there is no
/// workload-submission button: execution is the CLI's boundary, and a second execution path in the
/// UI would duplicate the architecture rather than expose it. Workloads are run with
/// `pixel-desktop run`.
///
/// ## Absence is rendered as absence
///
/// `PixelStateObservation` carries provenance for every field, and a field that could not be read
/// is reported with source `.unknown` rather than fabricated. The view preserves that: an unread
/// field renders as "not read", never as a zero or a plausible default. This is the same rule
/// `pixel-desktop observe` follows, applied to the same values.
struct ContentView: View {
    @EnvironmentObject var appState: AppState
    @State private var selection: DeviceTab = .device

    var body: some View {
        NavigationSplitView {
            sidebar
        } detail: {
            detailView
        }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    Task { await appState.refreshDevices() }
                } label: {
                    Label("Refresh", systemImage: "arrow.clockwise")
                }
                .disabled(appState.isDiscovering)
                .keyboardShortcut("r", modifiers: .command)
            }
        }
        .background(
            ForEach(DeviceTab.allCases.indices, id: \.self) { index in
                Button("") { selection = DeviceTab.allCases[index] }
                    .keyboardShortcut(Self.shortcut(for: index), modifiers: .command)
                    .opacity(0)
                    .allowsHitTesting(false)
            }
        )
    }

    /// ⌘1–⌘9 for the first nine tabs, ⌘0 for the tenth.
    ///
    /// A bare `Character("\(index + 1)")` traps at runtime for a two-digit index, so adding a
    /// tenth tab without this mapping would have crashed the view on first render.
    private static func shortcut(for index: Int) -> KeyEquivalent {
        index < 9 ? KeyEquivalent(Character("\(index + 1)")) : KeyEquivalent("0")
    }

    // MARK: - Sidebar

    private var sidebar: some View {
        List {
            Section("Devices") {
                if appState.devices.isEmpty {
                    Text("No devices found")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(appState.devices) { device in
                        DeviceRow(device: device)
                    }
                }
            }

            Section("Status") {
                HStack {
                    Text("Discovery:")
                    Spacer()
                    Text(appState.isDiscovering ? "Running" : "Stopped")
                        .foregroundStyle(appState.isDiscovering ? .green : .secondary)
                }

                if let error = appState.lastError {
                    HStack(alignment: .top) {
                        Text("Error:")
                        Spacer()
                        Text(error.description)
                            .foregroundStyle(.red)
                            .multilineTextAlignment(.trailing)
                    }
                }
            }
        }
        .navigationTitle("PixelDesktop")
    }

    // MARK: - Detail

    /// Every tab, in one place, so the two presentations below can never drift apart.
    @ViewBuilder
    private var tabChoices: some View {
        ForEach(DeviceTab.allCases) { tab in
            Text(tab.title).tag(tab)
        }
    }

    /// The segmented bar is only honest when it fits: a segmented picker does not scroll or
    /// ellipsise, it clips, and the tab that falls off the right edge is unreachable rather than
    /// merely off-screen. At 900 pt eleven segments overflow, so asking for the bar at its ideal
    /// width makes ViewThatFits reject it and fall through to the pop-up button below.
    private var segmentedTabBar: some View {
        Picker("", selection: $selection) { tabChoices }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
    }

    /// Carries the same eleven choices in a menu, with the current tab named in the button. No tab
    /// can hide off the edge, and the chevron makes the control's purpose visible without a scroll
    /// indicator that this design has nowhere to put.
    private var compactTabBar: some View {
        Picker("Tab", selection: $selection) { tabChoices }
            .pickerStyle(.menu)
            .labelsHidden()
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private var detailView: some View {
        VStack(spacing: 0) {
            ViewThatFits(in: .horizontal) {
                segmentedTabBar
                compactTabBar
            }
            .padding()

            Divider()

            // Schedules is deliberately outside the "a device is attached" gate the other tabs sit
            // behind: a job matters most while the phone is unplugged, and a tab that only opens with
            // the phone in hand would hide the feature exactly when the operator wants to check it.
            if selection == .schedules {
                SchedulesView()
            } else if let device = appState.devices.first(where: { $0.state == .device }) {
                deviceTab(for: device)
            } else if appState.devices.isEmpty {
                ContentUnavailableView(
                    "No Device Connected",
                    systemImage: "iphone.slash",
                    description: Text("Connect an Android device via USB and enable USB debugging.")
                )
            } else {
                // A device is attached but not usable. Naming the actual state is the point: an
                // unauthorized device needs a tap on its screen, an offline one needs a cable check,
                // and collapsing both into "no device" hides the one action the user can take.
                ContentUnavailableView(
                    "Device Not Ready",
                    systemImage: "exclamationmark.triangle",
                    description: Text(appState.devices.first?.state.description ?? "Unknown state")
                )
            }
        }
        // Without this the detail column centres the whole stack vertically, which parks the tab
        // picker in the middle of an empty window whenever no device is attached.
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    @ViewBuilder
    private func deviceTab(for device: AndroidDevice) -> some View {
        switch selection {
        case .device:
            DeviceDetailView(device: device)
        case .state:
            DeviceStateView()
        case .applications:
            ApplicationsView()
        case .log:
            LogView()
        case .storage:
            StorageBrowserView()
        case .perception:
            PerceptionView()
        case .inference:
            InferenceView()
        case .telemetry:
            TelemetryView()
        case .input:
            InputView()
        case .trust:
            TrustView()
        case .schedules:
            // Unreachable: `detailView` renders the Schedules tab before it reaches here.
            EmptyView()
        }
    }
}

enum DeviceTab: String, CaseIterable, Identifiable {
    case device, state, applications, log, storage, perception, inference, telemetry, input, trust
    case schedules

    var id: String { rawValue }

    var title: String {
        switch self {
        case .device: return "Device"
        case .state: return "State"
        case .applications: return "Applications"
        case .log: return "Log"
        case .storage: return "Storage"
        case .perception: return "Perception"
        case .inference: return "Inference"
        case .telemetry: return "Telemetry"
        case .input: return "Input"
        case .trust: return "Trust"
        case .schedules: return "Schedules"
        }
    }
}

// MARK: - Device row

struct DeviceRow: View {
    let device: AndroidDevice

    var body: some View {
        HStack {
            Image(systemName: "iphone")
                .foregroundStyle(device.state.isConnected ? .green : .secondary)

            VStack(alignment: .leading) {
                Text(device.displayName)
                    .font(.headline)
                Text(device.serialNumber)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            Text(device.state.description)
                .font(.caption)
                .foregroundStyle(device.state.isConnected ? .green : .orange)
        }
        .padding(.vertical, 4)
    }
}

// MARK: - Device identity

struct DeviceDetailView: View {
    let device: AndroidDevice

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text(device.displayName)
                    .font(.largeTitle)

                LabeledContent("Serial", value: device.serialNumber)
                LabeledContent("Model", value: device.marketingName.pdOrUnknown)
                LabeledContent("Codename", value: device.deviceCodename.pdOrUnknown)
                LabeledContent("Manufacturer", value: device.manufacturer.pdOrUnknown)
                LabeledContent("Android Version", value: device.androidVersion.pdOrUnknown)
                LabeledContent("API Level", value: device.apiLevel > 0 ? "\(device.apiLevel)" : "Unknown")
                LabeledContent("Architecture", value: device.architecture.pdOrUnknown)
                LabeledContent(
                    "Supported ABIs",
                    value: device.supportedABIs.isEmpty
                        ? "Unknown"
                        : device.supportedABIs.joined(separator: ", ")
                )
                LabeledContent("State", value: device.state.description)

                if device.marketingName.isEmpty {
                    Text(
                        "Identity fields are empty until the device is enriched. "
                        + "Use Refresh to read them."
                    )
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
            }
            .padding()
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

// MARK: - Device state (observation)

/// Renders `PixelStateObservation`.
///
/// The observation is a **snapshot, not a reservation** — the type says so, and the UI repeats it
/// rather than implying the numbers are durable.
struct DeviceStateView: View {
    @EnvironmentObject var appState: AppState

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                HStack {
                    Button {
                        Task { await appState.observeDevice() }
                    } label: {
                        Label("Observe Device", systemImage: "gauge.with.dots.needle.50percent")
                    }
                    .disabled(appState.isObserving || appState.selectedSerial == nil)

                    if appState.isObserving {
                        ProgressView().controlSize(.small)
                    }
                    Spacer()
                }

                if let observation = appState.observation {
                    VStack(alignment: .leading, spacing: 12) {
                        Text("Observed \(observation.observedAt.formatted(date: .omitted, time: .standard))")
                            .font(.caption)
                            .foregroundStyle(.secondary)

                        ObservationRow(
                            label: "Device reachable",
                            provenance: observation.deviceReachable,
                            format: { $0 ? "Yes" : "No" }
                        )
                        ObservationRow(
                            label: "Available memory",
                            provenance: observation.availableMemoryBytes,
                            format: { Self.byteCount($0) }
                        )
                        ObservationRow(
                            label: "Free storage",
                            provenance: observation.freeStorageBytes,
                            format: { Self.byteCount($0) }
                        )
                        ObservationRow(
                            label: "Worker installed",
                            provenance: observation.workerInstalled,
                            format: {
                                switch $0 {
                                case .notInstalled: return "Not installed"
                                case .installed(let versionCode): return "v\(versionCode)"
                                }
                            }
                        )
                        ObservationRow(
                            label: "Worker running",
                            provenance: observation.workerRunning,
                            format: { $0 ? "Yes" : "No" }
                        )
                        ObservationRow(
                            label: "Model present",
                            provenance: observation.modelPresent,
                            format: {
                                switch $0 {
                                case .absent: return "Absent"
                                case .present(let byteCount): return Self.byteCount(byteCount)
                                }
                            }
                        )
                        ObservationRow(
                            label: "Thermal status",
                            provenance: observation.thermalStatus,
                            format: { "\($0)" }
                        )

                        Text(
                            "This is a snapshot, not a reservation. A worker process being alive "
                            + "does not mean a model is loaded. Thermal status is device-wide and "
                            + "is not attributable to this worker."
                        )
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    }
                } else {
                    Text("No observation taken yet. Use Observe Device to read the current state.")
                        .foregroundStyle(.secondary)
                }

                Spacer()
            }
            .padding()
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    /// Formats a byte count for display.
    ///
    /// Uses `ByteCountFormatter` rather than hand-rolled division so the rendering cannot drift
    /// from platform behaviour.
    static func byteCount(_ bytes: Int) -> String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .binary
        formatter.allowsNonnumericFormatting = false
        return formatter.string(fromByteCount: Int64(bytes))
    }
}

/// One observation field: its value, its provenance, and its stated limitation.
///
/// The provenance is shown because the contract carries it, and hiding it would let a `.declared`
/// constant read as a device measurement — the exact confusion the provenance model exists to
/// prevent. A field whose source is `.unknown` renders as "not read", never as a value.
struct ObservationRow<Value: Codable & Equatable & Sendable>: View {
    let label: String
    let provenance: CapabilityValue<Value>
    let format: (Value) -> String

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(label)
                Spacer()
                Text(provenance.source == .unknown ? "not read" : format(provenance.value))
                    .foregroundStyle(provenance.source == .unknown ? .secondary : .primary)
                    .monospacedDigit()
            }
            HStack(spacing: 6) {
                Text(provenance.source.rawValue)
                    .font(.caption2)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1)
                    .background(.quaternary, in: Capsule())
                if let limitation = provenance.limitation {
                    Text(limitation)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
            }
        }
    }
}

// MARK: - Applications

struct ApplicationsView: View {
    @EnvironmentObject var appState: AppState
    @State private var includeSystem = false
    @State private var searchText = ""
    @State private var autoRefresh = false
    @State private var refreshTimer: Timer?

    var filteredApplications: [InstalledApp] {
        if searchText.isEmpty {
            return appState.installedApplications
        }
        return appState.installedApplications.filter {
            $0.displayLabel.localizedCaseInsensitiveContains(searchText) ||
            $0.packageName.localizedCaseInsensitiveContains(searchText)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Button {
                    Task { await appState.loadInstalledApplications(includeSystem: includeSystem) }
                } label: {
                    Label("List Applications", systemImage: "square.grid.2x2")
                }
                .disabled(appState.isListingApplications || appState.selectedSerial == nil)
                .keyboardShortcut("l", modifiers: .command)

                Toggle("Include system apps", isOn: $includeSystem)
                    .toggleStyle(.checkbox)

                if appState.isListingApplications {
                    ProgressView().controlSize(.small)
                }

                TextField("Search", text: $searchText)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 200)
                    .help("Filter by app name or package")

                Toggle("Auto-refresh", isOn: Binding(
                    get: { autoRefresh },
                    set: { newValue in
                        autoRefresh = newValue
                        if newValue { startAutoRefresh() } else { stopAutoRefresh() }
                    }
                ))
                .toggleStyle(.checkbox)
                .help("Reload applications every 30 seconds")

                Spacer()
                if !appState.installedApplications.isEmpty {
                    Text("\(filteredApplications.count) of \(appState.installedApplications.count) packages")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .padding()

            Divider()

            if appState.installedApplications.isEmpty {
                Text("No applications listed yet.")
                    .foregroundStyle(.secondary)
                    .padding()
                Spacer()
            } else if filteredApplications.isEmpty {
                Text("No applications match '\(searchText)'.")
                    .foregroundStyle(.secondary)
                    .padding()
                Spacer()
            } else {
                List(filteredApplications) { app in
                    HStack {
                        VStack(alignment: .leading) {
                            Text(app.displayLabel)
                                .font(.body)
                            Text(app.packageName)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        if app.isLaunchable {
                            Button("Launch") {
                                Task {
                                    await appState.launchApplicationReportingFailure(
                                        packageName: app.packageName)
                                }
                            }
                            .buttonStyle(.borderless)
                        } else {
                            Text("no launcher")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }
        .onDisappear {
            stopAutoRefresh()
        }
    }

    private func startAutoRefresh() {
        refreshTimer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { _ in
            Task { await appState.loadInstalledApplications(includeSystem: includeSystem) }
        }
    }

    private func stopAutoRefresh() {
        refreshTimer?.invalidate()
        refreshTimer = nil
    }
}

// MARK: - Log

struct LogView: View {
    @EnvironmentObject var appState: AppState
    @State private var levelFilter: LogLevel?

    var filteredLogs: [LogEntry] {
        if let level = levelFilter {
            return appState.logMessages.filter { $0.level == level }
        }
        return appState.logMessages
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Picker("Level", selection: $levelFilter) {
                    Text("All").tag(LogLevel?.none)
                    ForEach(LogLevel.allCases, id: \.self) { level in
                        Text(level.rawValue).tag(LogLevel?.some(level))
                    }
                }
                .pickerStyle(.segmented)
                .frame(width: 350)

                Spacer()

                Button("Clear") {
                    appState.logMessages.removeAll()
                }
                .disabled(appState.logMessages.isEmpty)
                .help("Clear all log entries")
            }
            .padding()

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 2) {
                    if filteredLogs.isEmpty {
                        Text(appState.logMessages.isEmpty ? "No log entries." : "No entries match the selected filter.")
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(filteredLogs) { entry in
                            HStack(alignment: .top, spacing: 8) {
                                Text(entry.formattedTimestamp)
                                    .font(.system(.caption, design: .monospaced))
                                    .foregroundStyle(.secondary)
                                Text(entry.level.rawValue)
                                    .font(.system(.caption2, design: .monospaced))
                                    .foregroundStyle(color(for: entry.level))
                                    .frame(width: 60, alignment: .leading)
                                Text(entry.message)
                                    .font(.system(.caption, design: .monospaced))
                                    .textSelection(.enabled)
                                Spacer()
                            }
                        }
                    }
                }
                .padding()
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private func color(for level: LogLevel) -> Color {
        switch level {
        case .debug: return .secondary
        case .info: return .primary
        case .warning: return .orange
        case .error: return .red
        }
    }
}

// MARK: - Helpers

private extension String {
    /// Renders an empty identity field as "Unknown" rather than a blank cell.
    ///
    /// The backend uses `""` for "not read". For these particular fields an empty string is never
    /// a real value, so mapping it to "Unknown" here is honest. Fields where empty *is* meaningful
    /// keep their own rendering.
    var pdOrUnknown: String { isEmpty ? "Unknown" : self }
}
