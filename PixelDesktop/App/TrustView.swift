import SwiftUI

/// The trust surface: what PixelDesktop is allowed to read, and what it has done.
///
/// Phase 3 exists because the phone has no screen. Every capability in the rest of the app is
/// reachable from here in the sense that matters: **the gates that constrain it are visible and
/// operable.** Two panels, one per trust primitive:
///
/// - **Consent (D1)** — one row per data class, defaulting to *not granted*. A grant requires a
///   reason, because the registry refuses to record a decision that does not say why.
/// - **Audit (D2)** — the shared device trail, every operation class, including refusals. A
///   refusal is an event, so a read that was blocked appears here rather than leaving no trace.
///
/// Nothing on this view executes against the device. Granting consent does not read anything; it
/// only changes what a future read is permitted to do.
struct TrustView: View {
    @EnvironmentObject var appState: AppState

    /// Reasons typed but not yet submitted, keyed by class. Held in the view because an
    /// unsubmitted reason is not a consent decision.
    @State private var reasons: [ConsentDataClass: String] = [:]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                preamble
                consentSection
                auditSection
            }
            .padding()
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .onAppear {
            appState.refreshConsent()
            appState.refreshAuditSnapshots()
        }
    }

    // MARK: - Preamble

    private var preamble: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Trust")
                .font(.title2.bold())
            Text(
                "Consent is denied by default and is checked before any device command is issued, "
                + "so an ungranted read performs no work. Revoking is immediate."
            )
            .font(.caption)
            .foregroundStyle(.secondary)

            if let error = appState.consentError {
                Text(error.description)
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .textSelection(.enabled)
            }
        }
    }

    // MARK: - Consent

    private var consentSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Data classes (D1)").font(.headline)

            ForEach(ConsentDataClass.allCases, id: \.self) { dataClass in
                consentRow(for: dataClass)
                if dataClass != ConsentDataClass.allCases.last { Divider() }
            }
        }
    }

    private func consentRow(for dataClass: ConsentDataClass) -> some View {
        let grant = appState.consentGrants.first { $0.dataClass == dataClass }
        let granted = appState.isConsentGranted(dataClass)

        return VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Image(systemName: granted ? "checkmark.shield.fill" : "shield.slash")
                    .foregroundStyle(granted ? .green : .secondary)

                Text(dataClass.displayName).font(.subheadline.bold())

                Text(grant?.statusDescription ?? "Not granted")
                    .font(.caption2.monospaced())
                    .foregroundStyle(granted ? .green : .secondary)

                Spacer()

                if granted {
                    Button("Revoke") { appState.revokeConsent(dataClass) }
                        .buttonStyle(.bordered)
                } else {
                    Button("Grant") {
                        appState.grantConsent(dataClass, reason: reason(for: dataClass))
                    }
                    .buttonStyle(.borderedProminent)
                    // A grant with no reason is refused by the registry; disabling the button
                    // says so before the click rather than after it.
                    .disabled(reason(for: dataClass).trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }

            Text(dataClass.exposure)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if !granted {
                TextField(
                    "Why is this needed? (required, stored with the grant)",
                    text: Binding(
                        get: { reasons[dataClass] ?? "" },
                        set: { reasons[dataClass] = $0 }
                    )
                )
                .textFieldStyle(.roundedBorder)
                .font(.caption)
            } else if let grant {
                Text("Granted \(grant.grantedAt.formatted(date: .abbreviated, time: .shortened)) — \(grant.reason)")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
        }
        .padding(.vertical, 4)
    }

    private func reason(for dataClass: ConsentDataClass) -> String {
        reasons[dataClass] ?? ""
    }

    // MARK: - Audit

    private var auditSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Device audit trail (D2)").font(.headline)
                Spacer()
                Text("\(appState.deviceAuditRecords.count) records")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if appState.deviceAuditRecords.isEmpty {
                Text("Nothing has been attempted yet.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(Array(appState.deviceAuditRecords.suffix(40).reversed()), id: \.id) { record in
                    HStack(alignment: .top, spacing: 8) {
                        Text(record.at.formatted(date: .omitted, time: .standard))
                            .font(.caption2.monospaced())
                            .foregroundStyle(.secondary)
                            .frame(width: 74, alignment: .leading)

                        Text(record.outcome.rawValue)
                            .font(.caption2.monospaced())
                            .foregroundStyle(color(for: record.outcome))
                            .frame(width: 58, alignment: .leading)

                        VStack(alignment: .leading, spacing: 2) {
                            Text("\(record.operation.displayName) — \(record.summary)")
                                .font(.caption)
                            if let detail = record.detail, !detail.isEmpty {
                                Text(detail)
                                    .font(.caption2.monospaced())
                                    .foregroundStyle(.secondary)
                                    .textSelection(.enabled)
                            }
                        }
                        Spacer()
                    }
                }
            }
        }
    }

    private func color(for outcome: DeviceAuditOutcome) -> Color {
        switch outcome {
        case .executed: return .green
        case .refused: return .orange
        case .pending: return .secondary
        case .failed: return .red
        case .deferred: return .yellow
        }
    }
}
