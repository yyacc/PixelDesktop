//
//  NotificationsView.swift
//  PixelDesktop
//
//  Phase 3.2 — A5, the notification stream.
//
//  ## Why this is a section of Perception, not its own tab
//
//  The phase proposal's capability table lists A5 in **Group A — Perception**, next to the UI
//  hierarchy, screenshot and logcat, and the tab bar is already at ten tabs with ⌘1–⌘9 / ⌘0 mapped
//  by index. An eleventh tab would need a second shortcut scheme for no navigational gain: the
//  question this view answers ("what is the phone showing right now") is the same question the rest
//  of Perception answers.
//
//  ## What the view must make visible
//
//  Three properties of the design are invisible unless the UI shows them, so each gets a readout:
//
//  1. **The gate is a gate.** With no `.notifications` grant the read throws before a command is
//     issued, and the refusal is rendered here rather than swallowed — including the fact that the
//     refusal is in the audit trail.
//  2. **The read is two-tier.** `didFetchPayload` says whether this poll paid for the 780 KB dump or
//     only for the 1.7 KB key list. A reader who cannot see that cannot tell polling from polling.
//  3. **Contentless records are records.** They are listed, badged, never filtered out.
//
//  There is deliberately **no consent button here.** Consent is granted in the Trust tab, where the
//  grant is a decision with a written reason (D1). Putting a one-click grant beside the messages it
//  unlocks would turn a deliberate act into a reflex.
//

import SwiftUI

struct NotificationsSection: View {
    @EnvironmentObject var appState: AppState

    @State private var stream: NotificationStream?
    @State private var keys: [NotificationKey] = []
    @State private var records: [NotificationRecord] = []
    @State private var errorText: String?
    @State private var lastRefresh: Date?
    @State private var didFetchPayload = false
    @State private var isBusy = false
    @State private var autoPoll = false

    /// The poll cadence the proposal specifies (§5.4). Tier 1 only, unless the key set changes.
    private static let pollInterval: UInt64 = 30_000_000_000

    private var serial: String? {
        appState.selectedSerial ?? appState.devices.first(where: { $0.state == .device })?.serialNumber
    }

    private var hasConsent: Bool {
        appState.isConsentGranted(.notifications)
    }

    private var contentlessCount: Int {
        records.filter(\.isContentless).count
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            header
            consentBanner
            if let errorText {
                Text(errorText)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .textSelection(.enabled)
            }
            readout
            recordList
        }
        .task(id: autoPoll) {
            guard autoPoll else { return }
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: Self.pollInterval)
                guard !Task.isCancelled else { break }
                await refresh()
            }
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack {
            Text("Notifications").font(.headline)
            Spacer()
            if let lastRefresh {
                Text("read \(lastRefresh.formatted(date: .omitted, time: .standard))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Toggle("Poll 30 s", isOn: $autoPoll)
                .toggleStyle(.switch)
                .font(.caption)
                .disabled(!hasConsent || serial == nil)
            Button("Force full read") {
                Task { await refresh(force: true) }
            }
            .disabled(isBusy || serial == nil)
            Button(isBusy ? "Reading…" : "Refresh") {
                Task { await refresh() }
            }
            .disabled(isBusy || serial == nil)
        }
    }

    // MARK: - Consent

    @ViewBuilder
    private var consentBanner: some View {
        if !hasConsent {
            VStack(alignment: .leading, spacing: 2) {
                Text("Notifications consent is not granted.")
                    .font(.caption)
                    .foregroundStyle(.orange)
                Text("A5 reads message bodies, so the read is refused before any command is issued "
                     + "and the refusal is written to the device audit trail. Grant it in the Trust "
                     + "tab (⌘0) with a written reason.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        } else {
            Text("Reads message content. Consent: Notifications — granted.")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - Readout

    @ViewBuilder
    private var readout: some View {
        if !records.isEmpty || !keys.isEmpty {
            HStack(spacing: 16) {
                Text("keys: \(keys.count)")
                Text("records: \(records.count)")
                Text("contentless: \(contentlessCount)")
                Text(didFetchPayload ? "last poll: full dump fetched" : "last poll: key list only")
                    .foregroundStyle(didFetchPayload ? .primary : .secondary)
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        } else if hasConsent && !isBusy && errorText == nil && lastRefresh == nil {
            Text("No read yet. Tier 1 is ~1.7 KB; tier 2 is only fetched when the key set changes.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - Records

    @ViewBuilder
    private var recordList: some View {
        if records.isEmpty {
            if lastRefresh != nil && errorText == nil {
                Text("No notifications on the device.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        } else {
            VStack(alignment: .leading, spacing: 6) {
                ForEach(records) { record in
                    recordRow(record)
                }
            }
        }
    }

    private func recordRow(_ record: NotificationRecord) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(record.displayTitle)
                    .font(.system(.caption, design: .rounded).weight(.semibold))
                    .lineLimit(2)
                    .textSelection(.enabled)
                Spacer()
                if record.isContentless {
                    Text("contentless")
                        .font(.system(.caption2, design: .monospaced))
                        .padding(.horizontal, 4)
                        .background(Color.secondary.opacity(0.15))
                        .clipShape(RoundedRectangle(cornerRadius: 3))
                }
                Text(record.importance.displayName)
                    .font(.system(.caption2, design: .monospaced))
                    .foregroundStyle(.secondary)
                Text(record.visibility.displayName)
                    .font(.system(.caption2, design: .monospaced))
                    .foregroundStyle(record.visibility == .publicVisibility ? Color.secondary : Color.orange)
            }

            if let body = record.displayBody {
                Text(body)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(3)
                    .textSelection(.enabled)
            }

            Text(meta(record))
                .font(.system(.caption2, design: .monospaced))
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .padding(.vertical, 2)
    }

    private func meta(_ record: NotificationRecord) -> String {
        var parts = [record.packageID, "id=\(record.notificationID)"]
        if let tag = record.tag { parts.append("tag=\(tag)") }
        if record.key.isAggregate { parts.append("aggregate") }
        return parts.joined(separator: " · ")
    }

    // MARK: - Read

    /// One poll. Tier 2 is paid for only when the key set changed, or on an explicit force.
    private func refresh(force: Bool = false) async {
        guard let serial else {
            errorText = "No device selected."
            return
        }
        isBusy = true
        defer { isBusy = false }

        let stream = self.stream ?? NotificationStream(reader: appState.notificationReader)
        self.stream = stream
        if force { stream.reset() }

        do {
            let refresh = try await stream.refresh(deviceSerial: serial, timeout: 30)
            keys = refresh.keys
            records = refresh.records
            didFetchPayload = refresh.didFetchPayload
            lastRefresh = Date()
            errorText = nil
        } catch let refusal as ConsentError {
            // A refusal is an event: show it, keep the previous records off the screen, and let the
            // audit trail carry the proof.
            errorText = refusal.description
            keys = []
            records = []
            didFetchPayload = false
            lastRefresh = Date()
        } catch {
            errorText = "\(error)"
            lastRefresh = Date()
        }

        // The Trust tab renders a published copy of the trail, which cannot observe an append.
        appState.refreshAuditSnapshots()
    }
}
