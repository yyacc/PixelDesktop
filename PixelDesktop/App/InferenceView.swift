//
//  InferenceView.swift
//  PixelDesktop
//
//  Phase 1 (C1 + C2) — the on-device compute node.
//
//  ## What this view is allowed to do
//
//  It renders `AppState`'s published values and calls the methods that produce them. It computes
//  nothing and invents no state. Every value shown is either read from the device by
//  `LlamaServerService` or returned by an inference job run against the forwarded port.
//
//  ## The one control that is deliberately inert
//
//  `start` and `stop` are rendered, because the service exposes them and hiding a control is its
//  own kind of lie. They are labelled with what actually happens on the current device: Termux
//  0.118 dropped the `com.termux.execute` intent extra and its `RunCommandService` requires a
//  permission the adb shell cannot hold, so the request is issued and fails. That is a property
//  of the device, not of this code — the unblock is a user action on the device, and the view says
//  so rather than presenting a button that silently does nothing.
//
//  `status`, `health` and the inference path all work; the evidence is in
//  `docs/handoffs/handoff-pixeldesktop-phase1-device-verification.md`.
//

import SwiftUI

struct InferenceView: View {
    @EnvironmentObject var appState: AppState

    /// The model path passed to `start`. A placeholder by default because the model lives on the
    /// device and the host does not know its path until it has been pushed.
    @State private var modelPath = "~/models/Qwen3.5-4B-Q4_K_S.gguf"

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                serverSection
                Divider()
                inferenceSection
                Spacer()
            }
            .padding()
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .onAppear {
            Task { await appState.refreshLlamaStatus() }
        }
    }

    // MARK: - Server

    private var serverSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("llama-server")
                .font(.headline)

            HStack {
                Button {
                    Task { await appState.refreshLlamaStatus() }
                } label: {
                    Label("Read Status", systemImage: "arrow.clockwise")
                }
                .disabled(appState.selectedSerial == nil)

                Button {
                    Task { await appState.checkLlamaHealth() }
                } label: {
                    Label("Check Health", systemImage: "heart.text.square")
                }
                .disabled(appState.selectedSerial == nil)

                if appState.llamaIsBusy {
                    ProgressView().controlSize(.small)
                }
                Spacer()
            }

            LabeledContent("Process status", value: Self.statusText(appState.llamaStatus))
                .monospacedDigit()

            LabeledContent("Health probe", value: Self.healthText(appState.llamaHealthy))
                .monospacedDigit()

            Text(
                "Start and Stop issue the request but cannot complete on this device: Termux 0.118 "
                + "dropped the command intent extra, and its RunCommandService needs a permission "
                + "the adb shell cannot hold. Unblock it in Settings → Termux → “Allow external "
                + "apps to run commands”, or with root."
            )
            .font(.caption)
            .foregroundStyle(.secondary)

            HStack {
                TextField("Model path on device", text: $modelPath)
                    .textFieldStyle(.roundedBorder)

                Button("Start") {
                    Task { await appState.startLlamaServer(modelPath: modelPath) }
                }
                .disabled(appState.selectedSerial == nil || appState.llamaIsBusy)

                Button("Stop") {
                    Task { await appState.stopLlamaServer() }
                }
                .disabled(appState.selectedSerial == nil || appState.llamaIsBusy)
            }
        }
    }

    // MARK: - Inference

    private var inferenceSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Inference")
                .font(.headline)

            TextField("Prompt", text: $appState.inferencePrompt, axis: .vertical)
                .textFieldStyle(.roundedBorder)
                .lineLimit(2...4)

            Stepper(
                "Max tokens: \(appState.inferenceMaxTokens)",
                value: $appState.inferenceMaxTokens,
                in: 1...512
            )
            .monospacedDigit()

            Button {
                Task { await appState.runInferenceJob() }
            } label: {
                Label("Run Inference Job", systemImage: "cpu")
            }
            .disabled(appState.inferenceIsRunning || appState.inferencePrompt.isEmpty)

            if appState.inferenceIsRunning {
                ProgressView().controlSize(.small)
            }

            if let result = appState.inferenceResult {
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text("Result")
                            .font(.subheadline.bold())
                        Spacer()
                        if let tokens = result.tokensGenerated {
                            Text("\(tokens) tokens")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .monospacedDigit()
                        }
                        Text(String(format: "%.1fs", result.durationSeconds))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                    }
                    Text(result.text.isEmpty ? "(empty completion)" : result.text)
                        .font(.system(.body, design: .monospaced))
                        .textSelection(.enabled)
                }
                .padding()
                .background(.quaternary, in: RoundedRectangle(cornerRadius: 6))
            } else {
                Text("No inference job has run yet.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    // MARK: - Rendering

    /// Renders a status without inventing one.
    ///
    /// `.unknown` is the state before the first read, and it renders as "not read" rather than as
    /// "stopped" — the two differ, and collapsing them would let an unread server read as a dead
    /// one.
    static func statusText(_ status: LlamaServerStatus) -> String {
        switch status {
        case .unknown: return "not read"
        case .stopped: return "stopped"
        case .starting: return "starting"
        case .running(let port, let pid):
            if let pid { return "running (pid \(pid), port \(port))" }
            return "running (port \(port))"
        case .failed(let message): return "failed: \(message)"
        }
    }

    /// Tri-state on purpose: `nil` means no probe has run, which is not the same as a failed one.
    static func healthText(_ healthy: Bool?) -> String {
        switch healthy {
        case nil: return "not probed"
        case .some(true): return "healthy"
        case .some(false): return "unreachable"
        }
    }
}
