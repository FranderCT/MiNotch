import Foundation

/// Cliente mínimo de la API de DeepSeek (formato compatible con OpenAI) con respuestas en streaming.
struct DeepSeekClient: Sendable {
    static let models = ["deepseek-flash", "deepseek-v4-pro"]
    static let defaultModel = "deepseek-flash"
    static let modelDefaultsKey = "deepseekModel"

    private static let endpoint = URL(string: "https://api.deepseek.com/chat/completions")!
    private static let systemPrompt = """
        Sos un asistente que vive en el notch de una Mac. El espacio para mostrar texto es chico: \
        respondé de forma breve y directa, en el idioma en que te escriban.
        """

    let apiKey: String
    let model: String

    /// Emite los fragmentos de texto de la respuesta a medida que llegan.
    func stream(_ history: [ChatMessage]) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let (bytes, response) = try await URLSession.shared.bytes(for: makeRequest(history))
                    guard let http = response as? HTTPURLResponse else { throw DeepSeekError.invalidResponse }
                    guard http.statusCode == 200 else {
                        var body = ""
                        for try await line in bytes.lines { body += line }
                        throw DeepSeekError.http(status: http.statusCode, body: body)
                    }

                    // Server-Sent Events: líneas "data: {json}" y al final "data: [DONE]".
                    for try await line in bytes.lines {
                        guard line.hasPrefix("data:") else { continue }
                        let payload = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
                        if payload == "[DONE]" { break }

                        let chunk = try JSONDecoder().decode(StreamChunk.self, from: Data(payload.utf8))
                        if let text = chunk.choices.first?.delta.content, !text.isEmpty {
                            continuation.yield(text)
                        }
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private func makeRequest(_ history: [ChatMessage]) throws -> URLRequest {
        let messages = [RequestBody.Message(role: "system", content: Self.systemPrompt)]
            + history.map { RequestBody.Message(role: $0.role.rawValue, content: $0.text) }

        var request = URLRequest(url: Self.endpoint)
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(RequestBody(model: model, messages: messages, stream: true))
        return request
    }
}

enum DeepSeekError: LocalizedError {
    case missingAPIKey
    case invalidResponse
    case http(status: Int, body: String)

    var errorDescription: String? {
        switch self {
        case .missingAPIKey:
            "No se pudo leer la API key del Llavero. Volvé a guardarla en Configurar API key…"
        case .invalidResponse:
            "Respuesta inválida del servidor."
        case .http(401, _):
            "API key inválida. Revisala en Configurar API key…"
        case .http(402, _):
            "Tu cuenta de DeepSeek no tiene saldo."
        case .http(429, _):
            "Demasiadas solicitudes. Esperá un momento."
        case .http(let status, let body):
            "Error \(status): \(body.prefix(200))"
        }
    }
}

private struct RequestBody: Encodable {
    struct Message: Encodable {
        let role: String
        let content: String
    }

    let model: String
    let messages: [Message]
    let stream: Bool
}

private struct StreamChunk: Decodable {
    struct Choice: Decodable {
        struct Delta: Decodable {
            let content: String?
        }

        let delta: Delta
    }

    let choices: [Choice]
}
