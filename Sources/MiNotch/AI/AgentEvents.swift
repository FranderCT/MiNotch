import Foundation

/// Decodifica líneas completas antes de convertir UTF-8: los pipes pueden cortar un carácter o JSON.
struct AgentLineDecoder {
    private var pending = Data()
    private var droppingOversizedLine = false
    static let maximumLineBytes = 2_000_000

    mutating func append(_ data: Data, eof: Bool = false) -> [String] {
        var lines: [String] = []
        for byte in data {
            if byte == 10 {
                if !droppingOversizedLine, !pending.isEmpty { lines.append(String(decoding: pending, as: UTF8.self)) }
                pending.removeAll(keepingCapacity: true)
                droppingOversizedLine = false
            } else if !droppingOversizedLine {
                if pending.count < Self.maximumLineBytes {
                    pending.append(byte)
                } else {
                    pending.removeAll(keepingCapacity: true)
                    droppingOversizedLine = true
                }
            }
        }
        if eof {
            if !droppingOversizedLine, !pending.isEmpty { lines.append(String(decoding: pending, as: UTF8.self)) }
            pending.removeAll()
            droppingOversizedLine = false
        }
        return lines
    }
}

struct AgentActivity: Identifiable, Equatable, Sendable {
    let id = UUID()
    let date = Date()
    let text: String
    var isError = false

    /// Solo nombres de herramientas y texto de progreso; nunca se muestra razonamiento interno.
    static func decode(_ line: String) -> AgentActivity? {
        guard let object = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any] else { return nil }
        let type = object["type"] as? String ?? ""
        func activity(_ text: String, error: Bool = false) -> AgentActivity {
            AgentActivity(text: String(text.prefix(240)), isError: error)
        }
        switch type {
        case "system", "thread.started": return activity("Sesión conectada")
        case "turn.started": return activity("Analizando la tarea")
        case "error", "turn.failed":
            let error = object["error"] as? [String: Any]
            return activity((object["message"] as? String) ?? (error?["message"] as? String) ?? "El agente informó un error", error: true)
        case "item.started", "item.updated", "item.completed":
            guard let item = object["item"] as? [String: Any] else { return nil }
            let done = type == "item.completed"
            switch item["type"] as? String {
            case "command_execution": return activity(done ? "Comando terminado" : "Ejecutando un comando", error: (item["exit_code"] as? Int).map { $0 != 0 } ?? false)
            case "file_change": return activity(done ? "Cambios de archivos preparados" : "Editando archivos")
            case "mcp_tool_call": return activity("Herramienta: \(item["tool"] as? String ?? "MCP")")
            case "agent_message": return activity("Respuesta recibida")
            default: return nil
            }
        case "assistant":
            let message = object["message"] as? [String: Any]
            let blocks = message?["content"] as? [[String: Any]] ?? []
            if let tool = blocks.first(where: { $0["type"] as? String == "tool_use" }) {
                return activity("Herramienta: \(tool["name"] as? String ?? "agente")")
            }
            if blocks.contains(where: { $0["type"] as? String == "text" }) { return activity("Redactando respuesta") }
            return nil
        case "tool_call":
            let call = object["tool_call"] as? [String: Any]
            return activity("Herramienta: \(call?.keys.sorted().first ?? "agente") · \(object["subtype"] as? String ?? "en curso")")
        case "tool_use":
            let part = object["part"] as? [String: Any]
            let state = part?["state"] as? [String: Any]
            return activity("Herramienta: \(part?["tool"] as? String ?? "agente")", error: state?["status"] as? String == "error")
        case "text": return activity("Redactando respuesta")
        case "result": return activity("Respuesta final recibida", error: object["is_error"] as? Bool ?? false)
        case "stream_event":
            let event = object["event"] as? [String: Any]
            if let block = event?["content_block"] as? [String: Any], block["type"] as? String == "tool_use" {
                return activity("Herramienta: \(block["name"] as? String ?? "agente")")
            }
            if let delta = event?["delta"] as? [String: Any], delta["type"] as? String == "text_delta" { return activity("Redactando respuesta") }
            return nil
        default: return nil
        }
    }
}
