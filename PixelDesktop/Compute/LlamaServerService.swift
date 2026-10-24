//
//  LlamaServerService.swift
//  PixelDesktop
//
//  Phase 1 (C1) — lifecycle for the on-device llama-server (Termux).
//
//  ## Channel status — verified on real hardware 2026-10-24
//
//  `start`/`stop` are **not reachable on the current device**, and the reason is a property
//  of Termux 0.118 on Android 16, not of this code:
//
//  | Attempt | Result |
//  |---|---|
//  | `am start … -e com.termux.execute "<cmd>"` | **Not executed.** Termux 0.118 dropped the extra. Verified: intent delivered, no command ran, no side effect. |
//  | `am startservice … RunCommandService` | `Requires permission com.termux.permission.RUN_COMMAND` |
//  | `pm grant com.android.shell com.termux.permission.RUN_COMMAND` | exits 0 and **silently does nothing** — the permission is not in the shell's manifest |
//  | `adb shell pkill -f llama-server` | `Operation not permitted` — shell cannot signal a Termux-UID process |
//
//  The unblock is a **user action on the device**: Settings → Termux → "Allow external apps
//  to run commands", or root. Neither is available to this host, so `start`/`stop` are kept
//  as the correct *request* rather than deleted — the unblock is not a code change.
//
//  `status` and `healthCheck` **do** work, and the inference path (C2) works end to end.
//  See `docs/handoffs/handoff-pixeldesktop-phase1-device-verification.md`.
//

import Foundation

enum LlamaServerStatus: Equatable, Sendable {
    case unknown
    case stopped
    case starting
    case running(port: Int, pid: Int?)
    case failed(String)
}

protocol LlamaServerServiceProtocol: Sendable {
    func start(deviceSerial: String, port: Int, modelPath: String, timeout: TimeInterval) async throws -> TransportResult
    func stop(deviceSerial: String, timeout: TimeInterval) async throws -> TransportResult
    func status(deviceSerial: String, port: Int, timeout: TimeInterval) async throws -> LlamaServerStatus
    func healthCheck(localPort: Int, timeout: TimeInterval) async -> Bool
}

struct ADBLlamaServerService: LlamaServerServiceProtocol {
    private let transport: TransportProtocol

    init(transport: TransportProtocol) {
        self.transport = transport
    }

    func start(deviceSerial: String, port: Int, modelPath: String, timeout: TimeInterval) async throws -> TransportResult {
        // 127.0.0.1, not 0.0.0.0. `adb forward` reaches the device's loopback, and binding all
        // interfaces would publish an unauthenticated inference endpoint on the LAN.
        let cmd = "am start -n com.termux/.app.TermuxActivity -e com.termux.execute \"llama-server -m \(modelPath) --host 127.0.0.1 --port \(port)\""
        return try await transport.shell(deviceSerial: deviceSerial, command: cmd, timeout: timeout)
    }

    func stop(deviceSerial: String, timeout: TimeInterval) async throws -> TransportResult {
        try await transport.shell(deviceSerial: deviceSerial, command: "pkill -f llama-server", timeout: timeout)
    }

    func status(deviceSerial: String, port: Int, timeout: TimeInterval) async throws -> LlamaServerStatus {
        // `pidof`, not `pgrep`.
        //
        // `pgrep -f llama-server` matches the **adb shell wrapper's own command line** — the
        // wrapper is `sh -c "pgrep -f llama-server"`, which contains the string, so pgrep
        // reported the wrapper's PID alongside the server's. Measured on device: `8329` (the
        // server) and `8540` (the wrapper), and a later run returned the wrapper's PID first.
        //
        // `pgrep -x` looks like the fix and is **not**: procps-ng 4.0.7 on this device returns
        // nothing for `pgrep -x llama-server` even while `/proc/8329/comm` reads `llama-server`.
        // Verified on device:
        //
        //     cat /proc/8329/comm          → llama-server
        //     pgrep -x llama-server        → (nothing)
        //     pgrep -a -x llama-server     → (nothing)
        //     pgrep llama-server           → 8329
        //     pidof llama-server           → 8329
        //
        // `pidof` matches the exact process name and cannot match a shell, so it is both
        // self-match-free and working on this build.
        let result = try await transport.shell(
            deviceSerial: deviceSerial,
            command: "pidof llama-server || echo NONE",
            timeout: timeout
        )
        let out = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        if out == "NONE" || out.isEmpty { return .stopped }
        if let pid = Int(out.split(separator: "\n").first ?? "") {
            return .running(port: port, pid: pid)
        }
        return .running(port: port, pid: nil)
    }

    func healthCheck(localPort: Int, timeout: TimeInterval) async -> Bool {
        guard let url = URL(string: "http://127.0.0.1:\(localPort)/health") else { return false }
        var req = URLRequest(url: url)
        req.timeoutInterval = timeout
        do {
            let (_, resp) = try await URLSession.shared.data(for: req)
            return (resp as? HTTPURLResponse)?.statusCode == 200
        } catch {
            return false
        }
    }
}
