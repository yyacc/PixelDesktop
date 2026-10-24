//
//  LlamaServerService.swift
//  PixelDesktop
//
//  Phase 1 (C1) — lifecycle for the on-device llama-server (Termux).
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
        let cmd = "am start -n com.termux/.app.TermuxActivity -e com.termux.execute \"llama-server -m \(modelPath) --host 0.0.0.0 --port \(port)\""
        return try await transport.shell(deviceSerial: deviceSerial, command: cmd, timeout: timeout)
    }

    func stop(deviceSerial: String, timeout: TimeInterval) async throws -> TransportResult {
        try await transport.shell(deviceSerial: deviceSerial, command: "pkill -f llama-server", timeout: timeout)
    }

    func status(deviceSerial: String, port: Int, timeout: TimeInterval) async throws -> LlamaServerStatus {
        let result = try await transport.shell(
            deviceSerial: deviceSerial,
            command: "pgrep -f llama-server || echo NONE",
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
