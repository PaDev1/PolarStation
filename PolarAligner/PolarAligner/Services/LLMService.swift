import Foundation

/// Supported LLM API providers.
enum LLMProvider: String, CaseIterable, Identifiable {
    case claude = "Claude (Anthropic)"
    case openai = "OpenAI Compatible"

    var id: String { rawValue }

    var defaultEndpoint: String {
        switch self {
        case .claude: return "https://api.anthropic.com"
        case .openai: return "https://api.openai.com"
        }
    }

    var defaultModel: String {
        switch self {
        case .claude: return "claude-sonnet-4-20250514"
        case .openai: return "gpt-4o"
        }
    }
}

/// Thin async wrapper around URLSession supporting Claude and OpenAI-compatible APIs.
@MainActor
class LLMService: ObservableObject {
    @Published var isTestingConnection = false
    @Published var connectionStatus: ConnectionStatus = .notConfigured

    enum ConnectionStatus: Equatable {
        case notConfigured
        case connected
        case failed(String)
    }

    /// Test that the configured API endpoint and key are valid.
    func testConnection(provider: LLMProvider, endpoint: String, apiKey: String, model: String) async -> ConnectionStatus {
        guard !apiKey.isEmpty else { return .failed("API key is empty") }
        guard !endpoint.isEmpty else { return .failed("Endpoint is empty") }

        do {
            let _ = try await complete(
                systemPrompt: "Reply with exactly: ok",
                userPrompt: "Test",
                provider: provider,
                endpoint: endpoint,
                apiKey: apiKey,
                model: model,
                maxTokens: 10
            )
            return .connected
        } catch {
            return .failed(error.localizedDescription)
        }
    }

    /// Send a completion request to the configured LLM.
    func complete(
        systemPrompt: String,
        userPrompt: String,
        provider: LLMProvider,
        endpoint: String,
        apiKey: String,
        model: String,
        maxTokens: Int = 4096,
        jsonMode: Bool = false
    ) async throws -> String {
        let url: URL
        let request: URLRequest

        switch provider {
        case .claude:
            url = URL(string: "\(endpoint)/v1/messages")!
            request = buildClaudeRequest(
                url: url, apiKey: apiKey, model: model,
                systemPrompt: systemPrompt, userPrompt: userPrompt,
                maxTokens: maxTokens
            )
        case .openai:
            url = URL(string: "\(endpoint)/v1/chat/completions")!
            request = buildOpenAIRequest(
                url: url, apiKey: apiKey, model: model,
                systemPrompt: systemPrompt, userPrompt: userPrompt,
                maxTokens: maxTokens,
                jsonMode: jsonMode
            )
        }

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw LLMError.invalidResponse
        }
        guard (200...299).contains(httpResponse.statusCode) else {
            let body = String(data: data, encoding: .utf8) ?? "No body"
            throw LLMError.httpError(httpResponse.statusCode, body)
        }

        return try extractContent(from: data, provider: provider)
    }

    // MARK: - Request Builders

    private func buildClaudeRequest(
        url: URL, apiKey: String, model: String,
        systemPrompt: String, userPrompt: String, maxTokens: Int
    ) -> URLRequest {
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        req.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        req.timeoutInterval = 120

        let body: [String: Any] = [
            "model": model,
            "max_tokens": maxTokens,
            "system": systemPrompt,
            "messages": [
                ["role": "user", "content": userPrompt]
            ]
        ]
        req.httpBody = try? JSONSerialization.data(withJSONObject: body)
        return req
    }

    private func buildOpenAIRequest(
        url: URL, apiKey: String, model: String,
        systemPrompt: String, userPrompt: String, maxTokens: Int,
        jsonMode: Bool = false
    ) -> URLRequest {
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        req.timeoutInterval = 120

        var body: [String: Any] = [
            "model": model,
            "max_completion_tokens": maxTokens,
            "messages": [
                ["role": "system", "content": systemPrompt],
                ["role": "user", "content": userPrompt]
            ]
        ]
        if jsonMode {
            body["response_format"] = ["type": "json_object"]
        }
        req.httpBody = try? JSONSerialization.data(withJSONObject: body)
        return req
    }

    // MARK: - Response Parsing

    private func extractContent(from data: Data, provider: LLMProvider) throws -> String {
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw LLMError.parseError("Invalid JSON response")
        }

        switch provider {
        case .claude:
            guard let content = json["content"] as? [[String: Any]],
                  let first = content.first,
                  let text = first["text"] as? String else {
                throw LLMError.parseError("Missing content[0].text in Claude response")
            }
            return text

        case .openai:
            guard let choices = json["choices"] as? [[String: Any]],
                  let first = choices.first,
                  let message = first["message"] as? [String: Any],
                  let text = message["content"] as? String else {
                throw LLMError.parseError("Missing choices[0].message.content in OpenAI response")
            }
            return text
        }
    }
}

enum LLMError: LocalizedError {
    case invalidResponse
    case httpError(Int, String)
    case parseError(String)

    var errorDescription: String? {
        switch self {
        case .invalidResponse: return "Invalid response from server"
        case .httpError(let code, let body): return "HTTP \(code): \(body.prefix(200))"
        case .parseError(let msg): return msg
        }
    }
}
