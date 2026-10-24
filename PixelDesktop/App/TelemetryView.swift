import SwiftUI

/// Phase 2 (A7) — device telemetry and thermal history.
///
/// ## What this view renders, and what it refuses to render
///
/// Every number here comes from `DeviceTelemetry`, which came from the device. A sub-read that
/// failed renders as "not read", never as a zero — the same rule `PerceptionView` follows. The
/// distinction matters most for thermal: a missing thermal reading must not look like a cool
/// phone.
///
/// ## The alert
///
/// ADR-018 fixes the threshold at `ThermalStatus >= .critical`, and the banner is driven by
/// `TelemetryHistory.latestAlert` — so the contract is enforced, not merely declared. Below the
/// threshold the history still records every sample; it just does not shout.
struct TelemetryView: View {
    @EnvironmentObject var appState: AppState

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                if let alert = appState.thermalAlert {
                    alertBanner(alert)
                }
                controlsSection
                Divider()
                batterySection
                Divider()
                thermalSection
                Divider()
                memorySection
                Divider()
                historySection
            }
            .padding()
        }
        .onAppear {
            // A single read on appearance, then the poll loop only if the user starts it.
            // Polling by default would issue four ADB calls every 10 s whether or not anyone
            // is looking at this tab.
            Task { await appState.readTelemetry() }
        }
        .onDisappear {
            appState.stopTelemetryPolling()
        }
    }

    // MARK: - Alert

    private func alertBanner(_ sample: TelemetrySample) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "thermometer.high")
                .foregroundStyle(.red)
            VStack(alignment: .leading, spacing: 4) {
                Text("Thermal alert — \(sample.thermalStatus?.label.uppercased() ?? "unknown")")
                    .font(.headline)
                    .foregroundStyle(.red)
                Text(
                    "ADR-018 threshold is CRITICAL (4). "
                    + "Peak zone \(sample.hottestZoneCelsius.map { String(format: "%.1f °C", $0) } ?? "not read")."
                )
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(10)
        .background(Color.red.opacity(0.1), in: RoundedRectangle(cornerRadius: 8))
    }

    // MARK: - Controls

    private var controlsSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Telemetry").font(.title2)

            HStack(spacing: 12) {
                Button {
                    Task { await appState.readTelemetry() }
                } label: {
                    Label("Read now", systemImage: "arrow.clockwise")
                }
                .disabled(appState.isReadingTelemetry)

                Button {
                    if appState.telemetryPolling {
                        appState.stopTelemetryPolling()
                    } else {
                        appState.startTelemetryPolling()
                    }
                } label: {
                    Label(
                        appState.telemetryPolling ? "Stop polling" : "Poll every 10 s",
                        systemImage: appState.telemetryPolling ? "stop.circle" : "play.circle"
                    )
                }

                if appState.isReadingTelemetry {
                    ProgressView().controlSize(.small)
                }

                Spacer()

                if let captured = appState.telemetry?.capturedAt {
                    Text("read \(captured.formatted(date: .omitted, time: .standard))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            if let error = appState.telemetryError {
                Text(error.description)
                    .font(.caption)
                    .foregroundStyle(.red)
            }
        }
    }

    // MARK: - Battery

    private var batterySection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Battery").font(.headline)

            if let battery = appState.telemetry?.battery {
                LabeledContent("Level", value: battery.levelPercent.map { "\($0) %" } ?? "not read")
                LabeledContent("Status", value: battery.statusLabel ?? "not read")
                LabeledContent(
                    "Temperature",
                    value: battery.temperatureCelsius.map { String(format: "%.1f °C", $0) } ?? "not read"
                )
                LabeledContent(
                    "Voltage",
                    value: battery.voltageMillivolts.map { "\($0) mV" } ?? "not read"
                )
            } else {
                notRead("dumpsys battery")
            }
        }
    }

    // MARK: - Thermal

    private var thermalSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Thermal").font(.headline)

            if let telemetry = appState.telemetry {
                LabeledContent(
                    "Status",
                    value: telemetry.thermalStatus.map { "\($0.label) (\($0.rawValue))" } ?? "not read"
                )
                LabeledContent(
                    "Hottest zone",
                    value: telemetry.hottestZoneCelsius.map { String(format: "%.1f °C", $0) } ?? "not read"
                )

                if telemetry.thermalZones.isEmpty {
                    Text("No thermal zones reported by the HAL.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(telemetry.thermalZones, id: \.name) { zone in
                        HStack {
                            Text(zone.name)
                                .font(.caption)
                                .frame(width: 120, alignment: .leading)
                            Text(String(format: "%.1f °C", zone.temperatureCelsius))
                                .font(.caption.monospacedDigit())
                            Spacer()
                        }
                    }
                }
            } else {
                notRead("dumpsys thermalservice")
            }
        }
    }

    // MARK: - Memory

    private var memorySection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Memory & storage").font(.headline)

            if let memory = appState.telemetry?.memory {
                LabeledContent(
                    "Memory used",
                    value: String(
                        format: "%.0f %% of %.1f GB",
                        memory.usedFraction * 100,
                        Double(memory.totalBytes) / 1_073_741_824
                    )
                )
                ProgressView(value: memory.usedFraction)
            } else {
                notRead("/proc/meminfo")
            }

            if let storage = appState.telemetry?.storage {
                LabeledContent(
                    "Storage used",
                    value: String(
                        format: "%.0f %% of %.1f GB",
                        storage.usedFraction * 100,
                        Double(storage.totalBytes) / 1_073_741_824
                    )
                )
                ProgressView(value: storage.usedFraction)
            } else {
                notRead("df -k /data")
            }
        }
    }

    // MARK: - History

    private var historySection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Thermal history").font(.headline)

            if appState.telemetryHistory.isEmpty {
                Text("No samples yet.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                LabeledContent("Samples retained", value: "\(appState.telemetryHistory.samples.count)")
                LabeledContent(
                    "Peak status",
                    value: appState.telemetryHistory.peakThermalStatus.map { "\($0.label) (\($0.rawValue))" }
                        ?? "not read"
                )
                LabeledContent(
                    "Peak zone",
                    value: appState.telemetryHistory.peakZoneCelsius.map { String(format: "%.1f °C", $0) }
                        ?? "not read"
                )
                LabeledContent("Alerts", value: "\(appState.telemetryHistory.thermalAlerts.count)")

                // A compact trend of the hottest zone. Sparkline rather than a chart library:
                // the values are already in the history and a dependency would be the only
                // reason to add one.
                if appState.telemetryHistory.samples.count > 1 {
                    sparkline
                }
            }
        }
    }

    private var sparkline: some View {
        let values = appState.telemetryHistory.samples.compactMap(\.hottestZoneCelsius)
        let low = values.min() ?? 0
        let high = values.max() ?? 1
        let span = max(high - low, 0.1)

        return GeometryReader { geometry in
            Path { path in
                for (index, value) in values.enumerated() {
                    let x = geometry.size.width * CGFloat(index) / CGFloat(max(1, values.count - 1))
                    let y = geometry.size.height * (1 - CGFloat((value - low) / span))
                    if index == 0 {
                        path.move(to: CGPoint(x: x, y: y))
                    } else {
                        path.addLine(to: CGPoint(x: x, y: y))
                    }
                }
            }
            .stroke(Color.accentColor, lineWidth: 1.5)
        }
        .frame(height: 60)
        .overlay(alignment: .topLeading) {
            Text(String(format: "%.1f °C", high))
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .overlay(alignment: .bottomLeading) {
            Text(String(format: "%.1f °C", low))
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - Helpers

    private func notRead(_ source: String) -> some View {
        Text("Not read — \(source) did not answer.")
            .font(.caption)
            .foregroundStyle(.secondary)
    }
}
