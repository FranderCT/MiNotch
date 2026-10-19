import Foundation

/// Cliente mínimo de la API de DeepSeek (formato compatible con OpenAI) con respuestas en streaming.
struct DeepSeekClient: Sendable {
    static let models = ["deepseek-flash", "deepseek-v4-pro"]
    static let defaultModel = "deepseek-flash"
    static let modelDefaultsKey = "deepseekModel"

    private static let endpoint = URL(string: "https://api.deepseek.com/chat/completions")!
    private static func systemPrompt(workingDirectory: URL) -> String {
        """
        Sos un asistente de programación que vive en el notch de una Mac. Trabajás en la carpeta \
        \(workingDirectory.path) y tenés herramientas para listar, leer, buscar, crear y editar archivos \
        y ejecutar comandos de zsh ahí.
        - Las rutas relativas son relativas a esa carpeta; no podés tocar archivos fuera de ella \
        (para trabajar en otra, usá change_directory).
        - Crear o editar archivos, ejecutar comandos y cambiar de carpeta requieren que el usuario apruebe \
        cada acción. Si rechaza una, no insistas: preguntá cómo seguir.
        - Antes de editar un archivo, leelo. Para cambios puntuales usá edit_file; write_file para archivos \
        nuevos o reescrituras completas.
        - No ejecutes comandos destructivos (rm -rf, git reset --hard, git push --force…) salvo que el usuario \
        lo pida explícitamente. No arranques servidores ni procesos que no terminan: decile al usuario cómo \
        correrlos él.
        - El espacio para mostrar texto es chico: respondé breve y directo, en el idioma en que te escriban. \
        Al terminar una tarea, resumí en una o dos líneas qué hiciste.
        """
    }

    let apiKey: String
    let model: String

    /// Emite los fragmentos de la respuesta a medida que llegan: texto, razonamiento y llamadas a herramientas.
    func stream(_ history: [ChatMessage], workingDirectory: URL) -> AsyncThrowingStream<DeepSeekStreamEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let request = try makeRequest(history, workingDirectory: workingDirectory)
                    let (bytes, response) = try await URLSession.shared.bytes(for: request)
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
                        let delta = chunk.choices.first?.delta
                        if let reasoning = delta?.reasoning_content, !reasoning.isEmpty {
                            continuation.yield(.reasoning(reasoning))
                        }
                        if let text = delta?.content, !text.isEmpty {
                            continuation.yield(.text(text))
                        }
                        // Cada llamada llega en pedazos: id y nombre al principio, los argumentos de a poco.
                        for call in delta?.tool_calls ?? [] {
                            continuation.yield(.toolCall(index: call.index, id: call.id, name: call.function?.name, arguments: call.function?.arguments))
                        }
                        if let usage = chunk.usage {
                            continuation.yield(.usage(usage, model: chunk.model ?? model, date: chunk.created.map { Date(timeIntervalSince1970: $0) } ?? Date()))
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

    func balance() async throws -> DeepSeekBalance {
        var request = URLRequest(url: URL(string: "https://api.deepseek.com/user/balance")!)
        request.timeoutInterval = 30
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw DeepSeekError.invalidResponse }
        guard http.statusCode == 200 else {
            throw DeepSeekError.http(status: http.statusCode, body: String(decoding: data, as: UTF8.self))
        }
        return try JSONDecoder().decode(DeepSeekBalance.self, from: data)
    }

    private func makeRequest(_ history: [ChatMessage], workingDirectory: URL) throws -> URLRequest {
        let messages = [RequestBody.Message(role: "system", content: Self.systemPrompt(workingDirectory: workingDirectory))]
            + history.map { RequestBody.Message($0) }

        var request = URLRequest(url: Self.endpoint)
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(RequestBody(model: model, messages: messages, tools: AgentTool.definitions, stream: true, stream_options: .init(include_usage: true)))
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
        let content: String?
        var reasoning_content: String?
        var tool_calls: [ToolCallPayload]?
        var tool_call_id: String?

        init(role: String, content: String) {
            self.role = role
            self.content = content
        }

        init(_ message: ChatMessage) {
            role = message.role.rawValue
            switch message.role {
            case .user:
                content = message.apiContent
            case .assistant:
                // Con herramientas, DeepSeek exige reenviar el razonamiento de cada respuesta.
                content = message.text.isEmpty && !message.toolCalls.isEmpty ? nil : message.text
                reasoning_content = message.reasoning.isEmpty ? nil : message.reasoning
                tool_calls = message.toolCalls.isEmpty ? nil : message.toolCalls.map(ToolCallPayload.init)
            case .tool:
                content = message.text
                tool_call_id = message.toolCallID
            }
        }

        func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(role, forKey: .role)
            // null explícito: un asistente que solo llamó herramientas no tiene texto.
            try container.encode(content, forKey: .content)
            try container.encodeIfPresent(reasoning_content, forKey: .reasoning_content)
            try container.encodeIfPresent(tool_calls, forKey: .tool_calls)
            try container.encodeIfPresent(tool_call_id, forKey: .tool_call_id)
        }

        private enum CodingKeys: String, CodingKey {
            case role, content, reasoning_content, tool_calls, tool_call_id
        }
    }

    struct ToolCallPayload: Encodable {
        struct Function: Encodable {
            let name: String
            let arguments: String
        }

        let id: String
        let type = "function"
        let function: Function

        init(_ call: ToolCall) {
            id = call.id
            function = Function(name: call.name, arguments: call.arguments)
        }
    }

    let model: String
    let messages: [Message]
    let tools: [ToolDefinition]
    let stream: Bool
    struct StreamOptions: Encodable { let include_usage: Bool }
    let stream_options: StreamOptions
}

enum DeepSeekStreamEvent: Sendable {
    case text(String)
    case reasoning(String)
    /// Pedazo de una llamada a herramienta; `index` identifica a cuál pertenece.
    case toolCall(index: Int, id: String?, name: String?, arguments: String?)
    case usage(DeepSeekUsage, model: String, date: Date)
}

struct StreamChunk: Decodable {
    struct Choice: Decodable {
        struct Delta: Decodable {
            struct ToolCallDelta: Decodable {
                struct Function: Decodable {
                    let name: String?
                    let arguments: String?
                }

                let index: Int
                let id: String?
                let function: Function?
            }

            let content: String?
            let reasoning_content: String?
            let tool_calls: [ToolCallDelta]?
        }

        let delta: Delta
    }

    let choices: [Choice]
    let usage: DeepSeekUsage?
    let model: String?
    let created: TimeInterval?
}
