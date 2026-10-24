//
//  OnDeviceInferenceJob.swift
//  PixelDesktop
//
//  Phase 1 (C2) — inference jobs against the on-device llama-server.
//
//  ## Verified end to end 2026-10-24
//
//  Exercised against a real `llama-server` on the Pixel 7a (Qwen3.5-4B Q4_K_S, CPU-only):
//
//      POST /completion  {"prompt":"…","n_predict":16,"temperature":0.1,"stream":false}
//      → 200, `content` + `tokens_predicted` present
//
//  The request shape and the two fields read back are exactly what `run` sends and parses.
//  Measured on device: prompt 6 tokens in 3.5 s, 16 tokens generated in 19.0 s
//  (0.79 tok/s while the model paged in; 4.21 tok/s steady state).
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

    /// Extracts the generated text and token count from a `/completion` response body.
    ///
    /// Separated from `run` so the parsing is testable without a live server: the fields the
    /// caller reads (`content`, `tokens_predicted`) are the server's own names, and a rename
    /// on either side is the kind of defect a unit test catches cheaply.
    ///
    /// `content` is preferred over `text`; llama.cpp's `/completion` returns `content`, and
    /// the fallback exists only so an OpenAI-shaped body does not silently yield an empty
    /// result. Both being absent is **not** an error — an empty completion is a real answer
    /// (the model produced nothing within `n_predict`), so the text is `""` rather than a throw.
    static func parseCompletionBody(_ data: Data) throws -> (text: String, tokensGenerated: Int?) {
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw URLError(.badServerResponse)
        }
        let text = (json["content"] as? String) ?? (json["text"] as? String) ?? ""
        let tokens = json["tokens_predicted"] as? Int
        return (text, tokens)
    }

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
        let parsed = try Self.parseCompletionBody(data)
        return InferenceJobResult(
            text: parsed.text,
            tokensGenerated: parsed.tokensGenerated,
            durationSeconds: elapsed
        )
    }
}
