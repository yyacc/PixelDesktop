import SwiftUI

/// Phase 2 (B1) — input injection, behind the dry-run gate.
///
/// ## Why this view is shaped around a preview
///
/// A tap on this device is fired blind: the panel is dead, so there is no visual confirmation
/// that the right thing was touched, and a tap can confirm a factory-reset dialog or accept a
/// permission the user did not intend (proposal §6.2). The mitigation is not a confirmation
/// alert on the button — it is that the action is **planned, described, and only then
/// approved**.
///
/// So the flow is deliberately three steps and cannot be collapsed:
///
/// 1. **Propose** — a query resolves against a fresh hierarchy dump, or a key/text is proposed.
/// 2. **Preview** — the resolved element (label, resource-id, bounds, centre) is rendered.
/// 3. **Confirm** — the only call that promotes a plan to `confirmed`.
///
/// There is no coordinate entry anywhere, and no "tap here" control: the backend has no such
/// API, so neither does the UI.
struct InputView: View {
    @EnvironmentObject var appState: AppState

    @State private var query = ""
    @State private var text = ""
    @State private var key = "KEYCODE_BACK"

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                warningSection
                Divider()
                pendingSection
                Divider()
                tapSection
                Divider()
                keySection
                Divider()
                textSection
                Divider()
                auditSection
            }
            .padding()
        }
        .onAppear {
            appState.inputAuditRecords = appState.inputAuditLog.records
        }
    }

    // MARK: - Warning

    private var warningSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: "hand.tap")
                Text("Input injection").font(.title2)
            }
            Text(
                "Actions here are delivered blind — the panel does not display, so nothing "
                + "confirms the target visually. Every action must be previewed and confirmed, "
                + "and every execution is written to the audit trail below."
            )
            .font(.caption)
            .foregroundStyle(.secondary)
        }
    }

    // MARK: - Pending plan

    @ViewBuilder
    private var pendingSection: some View {
        if let plan = appState.pendingInputPlan {
            VStack(alignment: .leading, spacing: 10) {
                Text("Pending — review before executing").font(.headline)
                    .foregroundStyle(.orange)

                Text(plan.preview)
                    .font(.system(.body, design: .monospaced))
                    .textSelection(.enabled)
                    .padding(8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.orange.opacity(0.1), in: RoundedRectangle(cornerRadius: 6))

                HStack {
                    Button("Confirm and execute") {
                        Task { await appState.confirmAndExecuteInput() }
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(appState.inputIsBusy)

                    Button("Cancel") { appState.cancelInputPlan() }
                        .disabled(appState.inputIsBusy)

                    if appState.inputIsBusy { ProgressView().controlSize(.small) }
                    Spacer()
                }
            }
        } else {
            Text("No action pending. Propose one below to see its preview.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }

        if let refusal = appState.inputRefusal {
            Text(refusal.description)
                .font(.caption)
                .foregroundStyle(.red)
                .textSelection(.enabled)
        }

        if let result = appState.lastInputResult {
            Text("Executed: \(result.command) — exit \(result.exitCode)")
                .font(.caption)
                .foregroundStyle(.green)
                .textSelection(.enabled)
        }
    }

    // MARK: - Tap

    private var tapSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Tap an element").font(.headline)
            Text("Matched against a fresh UI hierarchy dump. Element-addressed — never a pixel.")
                .font(.caption)
                .foregroundStyle(.secondary)

            HStack {
                TextField("Element label, resource-id or class", text: $query)
                    .textFieldStyle(.roundedBorder)
                Button("Preview tap") {
                    Task { await appState.proposeTap(query: query) }
                }
                .disabled(query.trimmingCharacters(in: .whitespaces).isEmpty || appState.inputIsBusy)
            }

            if !appState.inputCandidates.isEmpty {
                Text("Ambiguous — pick one:").font(.caption)
                ForEach(appState.inputCandidates, id: \.self) { candidate in
                    Button(candidate) {
                        // Candidates are rendered as "#index label"; the index is the handle.
                        if let index = Self.index(from: candidate) {
                            Task { await appState.proposeTap(elementIndex: index) }
                        }
                    }
                    .buttonStyle(.link)
                    .font(.caption)
                }
            }
        }
    }

    // MARK: - Key

    private var keySection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Key event").font(.headline)
            HStack {
                Picker("Key", selection: $key) {
                    ForEach(InputContainment.supportedKeys, id: \.self) { name in
                        Text(name).tag(name)
                    }
                }
                .frame(maxWidth: 280)

                Button("Preview key") { appState.proposeKey(key) }
                    .disabled(appState.inputIsBusy)
                Spacer()
            }
        }
    }

    // MARK: - Text

    private var textSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Type text").font(.headline)
            Text("Delivered to whatever currently has focus. Single-quoted for the shell, so "
                 + "$ and backticks are literal rather than expanded.")
                .font(.caption)
                .foregroundStyle(.secondary)

            HStack {
                TextField("Text to type", text: $text)
                    .textFieldStyle(.roundedBorder)
                Button("Preview type") { appState.proposeText(text) }
                    .disabled(text.isEmpty || appState.inputIsBusy)
            }
        }
    }

    // MARK: - Audit

    private var auditSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Audit trail").font(.headline)
                Spacer()
                Text("\(appState.inputAuditRecords.count) records")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if appState.inputAuditRecords.isEmpty {
                Text("Nothing has been attempted yet.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(Array(appState.inputAuditRecords.suffix(25).reversed()), id: \.timestamp) { record in
                    HStack(alignment: .top, spacing: 8) {
                        Text(record.outcome)
                            .font(.caption2.monospaced())
                            .foregroundStyle(color(for: record.outcome))
                            .frame(width: 62, alignment: .leading)

                        VStack(alignment: .leading, spacing: 2) {
                            Text("\(record.kind) \(record.targetLabel ?? record.payload ?? "")")
                                .font(.caption)
                            if let x = record.centerX, let y = record.centerY {
                                Text("centre (\(x), \(y))")
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                            Text(record.detail)
                                .font(.caption2.monospaced())
                                .foregroundStyle(.secondary)
                                .textSelection(.enabled)
                        }
                        Spacer()
                        Text(record.timestamp.formatted(date: .omitted, time: .standard))
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    // MARK: - Helpers

    private func color(for outcome: String) -> Color {
        switch outcome {
        case InputAuditRecord.executed: return .green
        case InputAuditRecord.refused: return .orange
        default: return .red
        }
    }

    /// Extracts the leading `#index` from a rendered candidate string.
    private static func index(from candidate: String) -> Int? {
        guard candidate.hasPrefix("#") else { return nil }
        let digits = candidate.dropFirst().prefix { $0.isNumber }
        return Int(digits)
    }
}
