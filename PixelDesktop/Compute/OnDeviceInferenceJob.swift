//
//  OnDeviceInferenceJob.swift
//  PixelDesktop
//
//  Phase 1 (C2) — inference jobs against the on-device llama-server.
//

import Foundation

struct InferenceJobRequest: Sendable {
    let prompt: String
    let maxTokens: Int
    let temperature: Double
}

struct InferenceJobResult: Sendable, Equatable {
    let text: String
    let tokensGenerated: Int?
    let durationSeconds: Double
}

protocol OnDeviceInferenceJobRunnerProtocol: Sendable {
    func run(localPort: Int, request: InferenceJobRequest, timeout: TimeInterval) async throws -> InferenceJobResult
}

struct URLSessionOnDeviceInferenceJobRunner: OnDeviceInferenceJobRunnerProtocol {
    func run(localPort: Int, request: InferenceJobRequest, timeout: TimeInterval) async throws -> InferenceJobResult {
        guard let url = URL(string: "http://127.0.0.1:\(localPort)/completion") else {
            throw URLError(.badURL)
        }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.timeoutInterval = timeout
        let body: [String: Any] = [
            "prompt": request.prompt,
            "n_predict": request.maxTokens,
            "temperature": request.temperature,
            "stream": false
        ]
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        let start = Date()
        let (data, resp) = try await URLSession.shared.data(for: req)
        let elapsed = Date().timeIntervalSince(start)
        guard let http = resp as? HTTPURLResponse, http.statusCode == 200 else {
            throw URLError(.badServerResponse)
        }
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        let text = (json?["content"] as? String) ?? (json?["text"] as? String) ?? ""
        let tokens = json?["tokens_predicted"] as? Int
        return InferenceJobResult(text: text, tokensGenerated: tokens, durationSeconds: elapsed)
    }
}
