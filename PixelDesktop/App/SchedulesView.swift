import SwiftUI

/// Phase 3.4 (C4) — the Schedules tab.
///
/// ## Why this exists
///
/// `ScheduledJobRunner` and the launch agent were both finished and tested before this file, and an
/// operator still could not create a job: the store is a JSON file with no writer. A scheduler that
/// can only be reached through a test fixture is not a feature, it is a rehearsal.
///
/// ## What the screen refuses to promise
///
/// The app never claims a run happened. It shows what the store recorded (`Last: succeeded · …`) and
/// what the cadence implies (`Next tick after …`), and it labels the moment launchd accepts the agent
/// separately from the moment a run is recorded — because those are two different facts, and the
/// second one only exists after a process actually ran.
struct SchedulesView: View {
    @State private var panel: SchedulerPanelModel?

    var body: some View {
        Group {
            if let panel {
                SchedulerContent(panel: panel)
            } else {
                ProgressView("Opening the scheduler store…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .task {
            // Built on the main actor once per appearance. The store is the source of truth, so a
            // fresh model still shows the same jobs.
            if panel == nil { panel = SchedulerPanelModel.live() }
        }
    }
}

private struct SchedulerContent: View {
    @ObservedObject var panel: SchedulerPanelModel

    @State private var name = ""
    @State private var action: ScheduledAction = .telemetrySample
    @State private var kind: Kind = .interval
    @State private var intervalMinutes = 60
    @State private var hour = 7
    @State private var minute = 0

    private enum Kind: String, CaseIterable, Identifiable {
        case interval = "Every N minutes"
        case daily = "Daily at"

        var id: String { rawValue }
    }

    private var cadence: ScheduledCadence {
        switch kind {
        case .interval: return .interval(seconds: intervalMinutes * 60)
        case .daily: return .daily(hour: hour, minute: minute)
        }
    }

    private var trimmedName: String { name.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var canAdd: Bool { panel.isWritable && !trimmedName.isEmpty }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                header

                if let corruption = panel.corruption {
                    banner(corruption, systemImage: "exclamationmark.triangle", tint: .red)
                } else if let error = panel.errorMessage {
                    banner(error, systemImage: "xmark.octagon", tint: .red)
                } else if let status = panel.status {
                    banner(status, systemImage: "checkmark.circle", tint: .green)
                }

                Divider()
                jobsSection
                Divider()
                createSection
            }
            .padding()
        }
        .onAppear { panel.reload() }
    }

    // MARK: - Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Schedules")
                .font(.title2)
                .bold()
            Text(
                "A job is a stored definition. launchd owns the clock: installing a job writes a "
                    + "LaunchAgent that runs `pixel-desktop schedule run <id>`, and the run process "
                    + "decides what to do. Nothing ticks while this window is closed."
            )
            .font(.callout)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)

            Label(
                panel.helperIsAvailable
                    ? "Helper: \(panel.helperPath ?? "")"
                    : "Helper not found — install needs `pixel-desktop` inside the app bundle or beside it.",
                systemImage: panel.helperIsAvailable ? "terminal" : "exclamationmark.triangle"
            )
            .font(.caption)
            .foregroundStyle(panel.helperIsAvailable ? Color.secondary : Color.orange)
            .textSelection(.enabled)
        }
    }

    // MARK: - Jobs

    @ViewBuilder
    private var jobsSection: some View {
        Text("Jobs")
            .font(.headline)

        if panel.jobs.isEmpty {
            Text(
                panel.corruption == nil
                    ? "No jobs yet. A job created here stays defined until you delete it."
                    : "Jobs cannot be listed while the store is unreadable — delete or repair the "
                        + "store file first. Creating a job now would only look like it worked."
            )
            .font(.callout)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
        } else {
            ForEach(panel.jobs, id: \.id) { job in
                jobRow(job)
            }
        }
    }

    private func jobRow(_ job: ScheduledJob) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(job.name)
                    .font(.body.weight(.medium))
                Spacer()
                Toggle(
                    "Enabled",
                    isOn: Binding(
                        get: { job.enabled },
                        set: { newValue in
                            Task { await panel.setEnabled(newValue, job: job) }
                        }
                    )
                )
                .labelsHidden()
                .disabled(!panel.isWritable)
            }

            Text("\(job.action.displayName) · \(cadenceText(job.cadence))")
                .font(.caption)
                .foregroundStyle(.secondary)

            Text(panel.nextRunText(for: job))
                .font(.caption)

            Text("Last: \(panel.lastRunText(for: job))")
                .font(.caption)
                .foregroundStyle(.secondary)

            HStack(spacing: 12) {
                if panel.isInstalled(job) {
                    Label("Installed with launchd", systemImage: "checkmark.seal")
                        .font(.caption)
                        .foregroundStyle(.green)
                    Button("Remove agent") {
                        Task { await panel.uninstall(job) }
                    }
                } else {
                    Button("Install agent") {
                        Task { await panel.install(job) }
                    }
                    .disabled(!panel.helperIsAvailable || !panel.isWritable)
                }

                Spacer()

                Button("Delete", role: .destructive) {
                    Task { await panel.delete(job) }
                }
                .disabled(!panel.isWritable)

                if panel.busyJobIDs.contains(job.id) {
                    ProgressView()
                        .controlSize(.small)
                }
            }
            .font(.callout)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .stroke(.quaternary, lineWidth: 1)
        )
    }

    // MARK: - Create

    private var createSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("New job")
                .font(.headline)

            TextField("Name (e.g. Hourly telemetry)", text: $name)
                .textFieldStyle(.roundedBorder)
                .frame(maxWidth: 320)

            Picker("Action", selection: $action) {
                ForEach(ScheduledAction.allCases, id: \.self) { candidate in
                    Text(candidate.displayName).tag(candidate)
                }
            }
            .frame(maxWidth: 360)

            Picker("Cadence", selection: $kind) {
                ForEach(Kind.allCases) { candidate in
                    Text(candidate.rawValue).tag(candidate)
                }
            }
            .pickerStyle(.segmented)
            .frame(maxWidth: 340)

            switch kind {
            case .interval:
                Stepper("Every \(intervalMinutes) minutes", value: $intervalMinutes, in: 5...1440, step: 5)
            case .daily:
                HStack(spacing: 16) {
                    Stepper("Hour \(hour)", value: $hour, in: 0...23)
                    Stepper("Minute \(minute)", value: $minute, in: 0...55, step: 5)
                }
            }

            Button("Add job") {
                panel.add(name: trimmedName, cadence: cadence, action: action)
                name = ""
            }
            .disabled(!canAdd)

            if !panel.isWritable, let reason = panel.corruption {
                Text(reason)
                    .font(.caption)
                    .foregroundStyle(.red)
            }
        }
    }

    // MARK: - Pieces

    private func banner(_ text: String, systemImage: String, tint: Color) -> some View {
        Label {
            Text(text)
                .font(.callout)
                .fixedSize(horizontal: false, vertical: true)
        } icon: {
            Image(systemName: systemImage)
        }
        .foregroundStyle(tint)
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 8).stroke(tint.opacity(0.4)))
    }

    private func cadenceText(_ cadence: ScheduledCadence) -> String {
        switch cadence {
        case .interval(let seconds):
            if seconds % 3600 == 0 {
                let hours = seconds / 3600
                return hours == 1 ? "every hour" : "every \(hours) hours"
            }
            return "every \(seconds / 60) min"
        case .daily(let hour, let minute):
            return String(format: "daily at %02d:%02d", hour, minute)
        }
    }
}
