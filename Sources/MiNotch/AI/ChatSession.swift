import CoreGraphics
import Foundation

struct ChatMessage: Identifiable, Sendable {
    enum Role: String, Sendable {
        case user, assistant, tool
    }

    let id = UUID()
    let role: Role
    var text: String
    /// Asistente: consumo de la respuesta completa (una consulta por cada paso con herramientas).
    var usages: [ConsultationUsage] = []
    var isComplete = false
    /// Texto extraído de la imagen adjunta a la pregunta.
    var imageText: String?
    /// Asistente: razonamiento del modelo. No se muestra, pero con herramientas DeepSeek exige reenviarlo.
    var reasoning = ""
    /// Asistente: herramientas que pidió usar.
    var toolCalls: [ToolCall] = []
    /// Herramienta: a qué llamada responde, cuál fue y una línea para el chat.
    var toolCallID: String?
    var toolName: String?
    var toolSummary: String?
    var toolFailed = false

    /// Lo que recibe DeepSeek: la pregunta y, si hay, el texto de la imagen.
    var apiContent: String {
        guard let imageText else { return text }
        return """
            Texto de una imagen que adjunté, como una captura de pantalla (extraído con OCR, puede tener errores):
            \"\"\"
            \(imageText)
            \"\"\"

            \(text)
            """
    }
}

/// Conversación compartida por todas las píldoras. Vive mientras la app está abierta.
@MainActor
final class ChatSession: ObservableObject {
    @Published private(set) var messages: [ChatMessage] = []
    @Published var input = ""
    @Published private(set) var isStreaming = false
    @Published private(set) var errorMessage: String?
    @Published private(set) var hasAPIKey = false
    /// Texto de la imagen adjunta, pendiente de enviarse con la próxima pregunta.
    @Published private(set) var imageText: String?
    /// La imagen tenía más de `imageTextLimit` caracteres y se recortó.
    @Published private(set) var imageTextWasTrimmed = false
    /// Vision extrayendo el texto de la imagen adjunta.
    @Published private(set) var isReadingImage = false

    /// Tope por imagen: una captura llena de texto puede costar miles de tokens.
    static let imageTextLimit = 15_000

    @Published private(set) var balance: DeepSeekBalance?
    @Published private(set) var balanceError: String?
    @Published private(set) var isRefreshingBalance = false
    @Published private(set) var balanceUpdatedAt: Date?
    private var balanceTask: Task<Void, Never>?
    private var credentialsVersion = UUID()

    /// Carpeta donde el asistente lee, escribe y ejecuta comandos.
    let workspace = Workspace()
    /// Acción del asistente esperando que el usuario la apruebe o rechace.
    @Published private(set) var pendingApproval: ToolApproval?
    private var approvalContinuation: CheckedContinuation<Bool, Never>?
    /// Tope de pasos con herramientas por mensaje, por si el modelo entra en un bucle.
    private static let maxSteps = 25

    /// Lo define AppDelegate: abre la ventana de configuración.
    var onOpenSettings: (() -> Void)?

    /// Copia en memoria de la key: se lee al consultar saldo o enviar un mensaje.
    private var apiKey: String?
    private var streamTask: Task<Void, Never>?

    init() {
        hasAPIKey = KeychainStore.exists()
    }

    // MARK: - API key

    func saveAPIKey(_ key: String) {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        stop()
        resetBalance()
        hasAPIKey = KeychainStore.save(trimmed)
        apiKey = hasAPIKey ? trimmed : nil
        errorMessage = nil
        refreshBalance()
    }

    func deleteAPIKey() {
        stop()
        resetBalance()
        KeychainStore.delete()
        apiKey = nil
        hasAPIKey = false
        errorMessage = nil
    }

    func openSettings() {
        onOpenSettings?()
    }

    /// Fuera del hilo principal: el Llavero puede mostrar un diálogo de permiso que bloquea.
    private func resolveAPIKey() async -> String? {
        if let apiKey { return apiKey }
        let version = credentialsVersion
        let loaded = await Task.detached { KeychainStore.load() }.value
        guard version == credentialsVersion else { return nil }
        apiKey = loaded
        return loaded
    }

    private func resetBalance() {
        credentialsVersion = UUID()
        balanceTask?.cancel()
        balanceTask = nil
        balance = nil
        balanceError = nil
        balanceUpdatedAt = nil
        isRefreshingBalance = false
    }

    func refreshBalanceIfNeeded() {
        guard balanceUpdatedAt.map({ Date().timeIntervalSince($0) < 60 }) != true else { return }
        refreshBalance()
    }

    func refreshBalance() {
        guard hasAPIKey, !isRefreshingBalance else { return }
        isRefreshingBalance = true
        balanceError = nil
        let version = credentialsVersion
        balanceTask = Task { [weak self] in
            guard let self else { return }
            do {
                guard let key = await resolveAPIKey() else { throw DeepSeekError.missingAPIKey }
                try Task.checkCancellation()
                let result = try await DeepSeekClient(apiKey: key, model: DeepSeekClient.defaultModel).balance()
                guard version == credentialsVersion, !Task.isCancelled else { return }
                balance = result
                balanceUpdatedAt = Date()
            } catch {
                guard version == credentialsVersion, !Task.isCancelled else { return }
                balanceError = error.localizedDescription
            }
            isRefreshingBalance = false
            balanceTask = nil
        }
    }

    // MARK: - Imagen adjunta

    func attachImage(at url: URL) {
        attachImage(ImageTextReader.image(at: url))
    }

    /// nil: lo que llegó no se pudo abrir como imagen.
    func attachImage(_ image: CGImage?) {
        guard hasAPIKey else {
            openSettings()
            return
        }
        guard let image else {
            errorMessage = ImageTextReader.Failure.unreadableImage.localizedDescription
            return
        }
        guard !isReadingImage else { return }
        isReadingImage = true
        errorMessage = nil

        Task {
            do {
                let text = try await ImageTextReader.recognizeText(in: image)
                imageTextWasTrimmed = text.count > Self.imageTextLimit
                imageText = String(text.prefix(Self.imageTextLimit))
            } catch {
                errorMessage = error.localizedDescription
            }
            isReadingImage = false
        }
    }

    func discardImageText() {
        imageText = nil
        imageTextWasTrimmed = false
    }

    // MARK: - Chat

    /// Cambia al borrar la conversación: una respuesta que sigue terminando ya no la toca.
    private var conversationID = UUID()

    func send() {
        var text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        let imageText = imageText
        if text.isEmpty, imageText != nil {
            text = "Explicame este texto."
        }
        // Mientras se lee la imagen, esperar: si no, la pregunta saldría sin el texto.
        guard !text.isEmpty, !isStreaming, !isReadingImage, hasAPIKey else { return }

        input = ""
        discardImageText()
        errorMessage = nil
        messages.append(ChatMessage(role: .user, text: text, imageText: imageText))
        isStreaming = true

        let model = UserDefaults.standard.string(forKey: DeepSeekClient.modelDefaultsKey) ?? DeepSeekClient.defaultModel
        let conversation = conversationID
        streamTask = Task { [weak self] in
            await self?.runTurn(model: model, conversation: conversation)
        }
    }

    /// Una respuesta del asistente: consulta a DeepSeek y, mientras pida herramientas, las ejecuta
    /// (con aprobación si escriben o ejecutan) y vuelve a consultar con los resultados.
    private func runTurn(model: String, conversation: UUID) async {
        var usages: [ConsultationUsage] = []
        do {
            guard let apiKey = await resolveAPIKey() else { throw DeepSeekError.missingAPIKey }
            let client = DeepSeekClient(apiKey: apiKey, model: model)
            var isDone = false

            for _ in 0..<Self.maxSteps {
                try Task.checkCancellation()
                let history = messages
                let reply = ChatMessage(role: .assistant, text: "")
                messages.append(reply)

                var calls: [Int: ToolCall] = [:]
                for try await event in client.stream(history, workingDirectory: workspace.directory) {
                    try Task.checkCancellation()
                    guard let index = messages.firstIndex(where: { $0.id == reply.id }) else { continue }
                    switch event {
                    case .text(let delta):
                        messages[index].text += delta
                    case .reasoning(let delta):
                        messages[index].reasoning += delta
                    case .toolCall(let callIndex, let id, let name, let arguments):
                        var call = calls[callIndex] ?? ToolCall(id: "", name: "", arguments: "")
                        if let id { call.id = id }
                        call.name += name ?? ""
                        call.arguments += arguments ?? ""
                        calls[callIndex] = call
                    case .usage(let tokens, let model, let date):
                        usages.append(ConsultationUsage(tokens: tokens, model: model, date: date))
                    }
                }
                try Task.checkCancellation()

                let toolCalls = calls.sorted { $0.key < $1.key }.map(\.value)
                guard !toolCalls.isEmpty, let index = messages.firstIndex(where: { $0.id == reply.id }) else {
                    isDone = true
                    break
                }
                messages[index].toolCalls = toolCalls
                for call in toolCalls {
                    try Task.checkCancellation()
                    await runTool(call, conversation: conversation)
                }
            }

            if !isDone {
                errorMessage = "El asistente llegó al límite de \(Self.maxSteps) pasos seguidos. Escribí «seguí» para que continúe."
            }
        } catch {
            if !Task.isCancelled, conversation == conversationID { errorMessage = error.localizedDescription }
        }
        finishTurn(usages: usages, conversation: conversation)
        refreshBalance()
    }

    private func runTool(_ call: ToolCall, conversation: UUID) async {
        let tool = AgentTool(rawValue: call.name)
        let args = call.parsedArguments
        var summary = tool.map { $0.summary(args ?? [:]) } ?? call.name
        let outcome: ToolOutcome

        if let tool, let args {
            if let approval = tool.approval(for: args, in: workspace.directory), !(await requestApproval(approval)) {
                outcome = ToolOutcome(text: "El usuario rechazó esta acción.", failed: true)
                summary += " — rechazado"
            } else if tool == .changeDirectory {
                outcome = changeDirectory(to: args["path"] ?? "")
            } else {
                outcome = await tool.execute(args, in: workspace.directory)
            }
        } else {
            outcome = ToolOutcome(text: tool == nil ? "Herramienta desconocida: \(call.name)." : "Los argumentos no son JSON válido.", failed: true)
        }

        guard conversation == conversationID else { return }
        messages.append(ChatMessage(
            role: .tool, text: outcome.text,
            toolCallID: call.id, toolName: call.name, toolSummary: summary, toolFailed: outcome.failed
        ))
    }

    private func changeDirectory(to path: String) -> ToolOutcome {
        let url = AgentTool.directoryURL(path, from: workspace.directory)
        guard Workspace.isDirectory(url) else {
            return ToolOutcome(text: "No existe la carpeta \(url.path).", failed: true)
        }
        workspace.move(to: url)
        return ToolOutcome(text: "Carpeta de trabajo: \(workspace.directory.path)")
    }

    // MARK: - Aprobación

    func resolveApproval(_ approved: Bool) {
        approvalContinuation?.resume(returning: approved)
        approvalContinuation = nil
        pendingApproval = nil
    }

    private func requestApproval(_ approval: ToolApproval) async -> Bool {
        guard !Task.isCancelled else { return false }
        return await withCheckedContinuation { continuation in
            approvalContinuation = continuation
            pendingApproval = approval
        }
    }

    func stop() {
        streamTask?.cancel()
        // Una aprobación pendiente cuenta como rechazada: así la respuesta termina enseguida.
        resolveApproval(false)
    }

    func clear() {
        stop()
        conversationID = UUID()
        messages.removeAll()
        errorMessage = nil
    }

    /// Cierra la respuesta: quita los pasos vacíos, contesta las herramientas que quedaron sin resultado
    /// (si no, la próxima consulta da error) y deja el consumo en el último mensaje del asistente.
    private func finishTurn(usages: [ConsultationUsage], conversation: UUID) {
        isStreaming = false
        streamTask = nil
        guard conversation == conversationID else { return }

        messages.removeAll { $0.role == .assistant && $0.text.isEmpty && $0.toolCalls.isEmpty }
        let answered = Set(messages.compactMap(\.toolCallID))
        let unanswered = messages.filter { $0.role == .assistant }.flatMap(\.toolCalls).filter { !answered.contains($0.id) }
        for call in unanswered {
            messages.append(ChatMessage(
                role: .tool, text: "Cancelado por el usuario.",
                toolCallID: call.id, toolName: call.name, toolSummary: "\(call.name) — cancelado", toolFailed: true
            ))
        }
        if let last = messages.lastIndex(where: { $0.role == .assistant }) {
            messages[last].usages = usages
            messages[last].isComplete = true
        }
    }
}
