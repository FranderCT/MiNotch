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
    /// Usuario: el mensaje lo mandó otra pestaña (orquestación), no la persona.
    var fromTab: Int?

    /// Lo que recibe DeepSeek: la pregunta y, si hay, el texto de la imagen o de qué pestaña viene.
    var apiContent: String {
        var content = text
        if let imageText {
            content = """
                Texto de una imagen que adjunté, como una captura de pantalla (extraído con OCR, puede tener errores):
                \"\"\"
                \(imageText)
                \"\"\"

                \(content)
                """
        }
        if let fromTab {
            content = "[Tarea de la pestaña \(fromTab), no del usuario. Tu respuesta final es lo que recibe.]\n\(content)"
        }
        return content
    }
}

/// Conversación de una pestaña, con su carpeta, sus sesiones de terminal y sus aprobaciones.
/// La comparten las píldoras de todas las pantallas. Vive mientras la pestaña esté abierta.
@MainActor
final class ChatSession: ObservableObject, Identifiable {
    let id = UUID()
    /// Número visible y estable (no se reutiliza): así se refieren las pestañas entre sí.
    let number: Int
    /// Nombre opcional (lo pone el orquestador, por ejemplo "srv-8"); si no, se muestra la carpeta.
    @Published var title: String?
    /// Para coordinar otras pestañas (tab_list, tab_open, tab_send…).
    weak var tabs: ChatTabs?
    @Published private(set) var messages: [ChatMessage] = []
    @Published var input = ""
    @Published private(set) var isStreaming = false
    @Published private(set) var errorMessage: String?
    /// Texto de la imagen adjunta, pendiente de enviarse con la próxima pregunta.
    @Published private(set) var imageText: String?
    /// La imagen tenía más de `imageTextLimit` caracteres y se recortó.
    @Published private(set) var imageTextWasTrimmed = false
    /// Vision extrayendo el texto de la imagen adjunta.
    @Published private(set) var isReadingImage = false

    /// Tope por imagen: una captura llena de texto puede costar miles de tokens.
    static let imageTextLimit = 15_000


    /// Carpeta donde el asistente lee, escribe y ejecuta comandos.
    let workspace: Workspace
    /// Cuenta, saldo y modo de aprobación: compartidos con las otras pestañas.
    let account: DeepSeekAccount
    /// Acción del asistente esperando que el usuario la apruebe o rechace.
    @Published private(set) var pendingApproval: ToolApproval?
    private var approvalContinuation: CheckedContinuation<Bool, Never>?
    /// Sesiones de terminal interactivas (ssh, sudo…) abiertas por el asistente.
    let terminals = TerminalSessions()
    /// Una sesión pide contraseña: la escribe el usuario y va directo a la terminal, nunca a DeepSeek.
    @Published private(set) var pendingSecret: SecretRequest?
    @Published var secretInput = ""
    private var secretContinuation: CheckedContinuation<String?, Never>?
    /// Tope de pasos con herramientas por mensaje, por si el modelo entra en un bucle.
    private static let maxSteps = 25


    private var streamTask: Task<Void, Never>?

    init(account: DeepSeekAccount, number: Int, directory: URL? = nil, title: String? = nil) {
        self.account = account
        self.number = number
        self.title = title
        workspace = Workspace(directory: directory)
    }

    /// Trabajando por su cuenta (no esperando al usuario): para el borde animado.
    var isWorking: Bool {
        isStreaming && pendingApproval == nil && pendingSecret == nil
    }

    /// Necesita al usuario: una aprobación o una contraseña.
    var needsAttention: Bool {
        pendingApproval != nil || pendingSecret != nil
    }

    /// Nombre para mostrar: el título o, si no tiene, la carpeta.
    var displayName: String {
        title ?? workspace.directory.lastPathComponent
    }

    /// Para tab_list y tab_read.
    var statusText: String {
        if pendingApproval != nil { return "esperando que el usuario apruebe una acción" }
        if pendingSecret != nil { return "esperando que el usuario escriba una contraseña" }
        return isStreaming ? "trabajando" : "libre"
    }

    /// La última respuesta con texto del asistente.
    var lastReply: String? {
        messages.last { $0.role == .assistant && !$0.text.isEmpty }?.text
    }


    // MARK: - Imagen adjunta

    func attachImage(at url: URL) {
        attachImage(ImageTextReader.image(at: url))
    }

    /// nil: lo que llegó no se pudo abrir como imagen.
    func attachImage(_ image: CGImage?) {
        guard account.hasAPIKey else {
            account.openSettings()
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
        guard !text.isEmpty, !isStreaming, !isReadingImage, account.hasAPIKey else { return }

        input = ""
        discardImageText()
        start(ChatMessage(role: .user, text: text, imageText: imageText))
    }

    /// Tarea que manda otra pestaña. false si esta está ocupada o falta la API key.
    func receive(_ text: String, fromTab: Int) -> Bool {
        guard !isStreaming, !isReadingImage, account.hasAPIKey else { return false }
        start(ChatMessage(role: .user, text: text, fromTab: fromTab))
        return true
    }

    private func start(_ message: ChatMessage) {
        errorMessage = nil
        messages.append(message)
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
            guard let apiKey = await account.resolveAPIKey() else { throw DeepSeekError.missingAPIKey }
            let client = DeepSeekClient(apiKey: apiKey, model: model)
            var isDone = false
            // El usuario pudo cambiar de rama desde otra terminal.
            workspace.refreshGit()

            for _ in 0..<Self.maxSteps {
                try Task.checkCancellation()
                let history = messages
                let reply = ChatMessage(role: .assistant, text: "")
                messages.append(reply)

                var calls: [Int: ToolCall] = [:]
                for try await event in client.stream(history, workingDirectory: workspace.directory, git: workspace.git, tabContext: tabContext) {
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
        account.refreshBalance()
    }

    private func runTool(_ call: ToolCall, conversation: UUID) async {
        let tool = AgentTool(rawValue: call.name)
        let args = call.parsedArguments
        var summary = tool.map { $0.summary(args ?? [:]) } ?? call.name
        let outcome: ToolOutcome

        if let tool, let args {
            if let approval = tool.approval(for: args, in: workspace.directory),
               account.approvalMode == .ask || approval.riskReason != nil,
               !(await requestApproval(approval)) {
                outcome = ToolOutcome(text: "El usuario rechazó esta acción.", failed: true)
                summary += " — rechazado"
            } else if tool == .changeDirectory {
                outcome = changeDirectory(to: args["path"] ?? "")
            } else if tool.isTerminal {
                outcome = await runTerminalTool(tool, args)
            } else if tool.isTab {
                outcome = await runTabTool(tool, args)
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

    // MARK: - Pestañas (orquestación)

    /// Para el system prompt: qué pestaña es esta y cuáles hay.
    private var tabContext: String {
        let others = tabs?.tabs.filter { $0.id != id }.map { "\($0.number) (\($0.displayName), \($0.statusText))" } ?? []
        let list = others.isEmpty ? "No hay otras pestañas abiertas." : "Otras pestañas: \(others.joined(separator: "; "))."
        return "Estás en la pestaña \(number) (\(displayName)). \(list)"
    }

    private func runTabTool(_ tool: AgentTool, _ args: [String: String]) async -> ToolOutcome {
        guard let tabs else { return ToolOutcome(text: "Las pestañas no están disponibles.", failed: true) }
        let wait = min(max(Double(args["wait_seconds"] ?? "") ?? 120, 1), 600)

        if tool == .tabList {
            let lines = tabs.tabs.map { tab in
                var line = "\(tab.number) · \(tab.displayName)\(tab.id == id ? " (esta)" : "") · \(tab.workspace.displayPath)"
                if let git = tab.workspace.git { line += " · rama \(git.branch)" }
                if !tab.terminals.sessions.isEmpty { line += " · \(tab.terminals.sessions.count) sesión(es) de terminal" }
                line += " · \(tab.statusText)"
                if tab.id != id, let reply = tab.lastReply { line += "\n   última respuesta: \(reply.prefix(200))" }
                return line
            }
            return ToolOutcome(text: lines.joined(separator: "\n"))
        }

        if tool == .tabOpen {
            let directory = args["directory"].map { AgentTool.directoryURL($0, from: workspace.directory) } ?? workspace.directory
            guard Workspace.isDirectory(directory) else {
                return ToolOutcome(text: "No existe la carpeta \(directory.path).", failed: true)
            }
            guard let tab = tabs.newTab(directory: directory, title: args["name"], select: false) else {
                return ToolOutcome(text: "No se pueden abrir más de \(ChatTabs.maxTabs) pestañas: cerrá alguna con tab_close.", failed: true)
            }
            guard let task = args["task"], !task.isEmpty else {
                return ToolOutcome(text: "Pestaña \(tab.number) abierta (\(tab.displayName)) en \(tab.workspace.displayPath).")
            }
            _ = tab.receive(task, fromTab: number)
            return ToolOutcome(text: "Pestaña \(tab.number) abierta (\(tab.displayName)) y trabajando en la tarea. Usá tab_read para ver el resultado.")
        }

        guard let target = Int(args["tab"] ?? "").flatMap(tabs.tab(number:)) else {
            return ToolOutcome(text: "No existe la pestaña \(args["tab"] ?? ""). Usá tab_list.", failed: true)
        }
        guard target.id != id else {
            return ToolOutcome(text: "Esa es esta misma pestaña.", failed: true)
        }

        switch tool {
        case .tabSend:
            guard target.receive(args["message"] ?? "", fromTab: number) else {
                return ToolOutcome(text: "La pestaña \(target.number) está \(target.statusText): esperá con tab_read y volvé a intentar.", failed: true)
            }
            guard args["wait"]?.lowercased() != "false" else {
                return ToolOutcome(text: "Tarea enviada a la pestaña \(target.number). Usá tab_read para el resultado.")
            }
            return await result(of: target, maxWait: wait)
        case .tabRead:
            return await result(of: target, maxWait: wait)
        case .tabClose:
            tabs.close(target.id)
            return ToolOutcome(text: "Pestaña \(target.number) cerrada (con sus sesiones de terminal).")
        default:
            return ToolOutcome(text: "Herramienta de pestañas desconocida.", failed: true)
        }
    }

    /// Espera a que la otra pestaña termine (o necesite al usuario, o se acabe el tiempo) y trae su respuesta.
    private func result(of target: ChatSession, maxWait: TimeInterval) async -> ToolOutcome {
        let start = Date()
        while target.isStreaming, !target.needsAttention, !Task.isCancelled, Date().timeIntervalSince(start) < maxWait {
            try? await Task.sleep(for: .milliseconds(300))
        }
        let reply = target.lastReply.map { String($0.prefix(8000)) } ?? "(todavía sin respuesta)"
        if target.isStreaming {
            return ToolOutcome(text: "La pestaña \(target.number) sigue \(target.statusText). Respuesta hasta ahora:\n\(reply)")
        }
        let error = target.errorMessage.map { "\nError: \($0)" } ?? ""
        return ToolOutcome(text: "Pestaña \(target.number) terminó.\n\(reply)\(error)", failed: target.errorMessage != nil)
    }

    // MARK: - Terminal

    private func runTerminalTool(_ tool: AgentTool, _ args: [String: String]) async -> ToolOutcome {
        let wait = min(max(Double(args["wait_seconds"] ?? "") ?? 15, 1), 120)
        if tool == .terminalStart {
            do {
                let session = try terminals.start(args["command"] ?? "", in: workspace.directory)
                let output = await collectOutput(of: session, maxWait: wait)
                return ToolOutcome(text: "Sesión \(session.id) abierta (\(session.command)).\n\(output)")
            } catch {
                return ToolOutcome(text: "No se pudo abrir la sesión: \(error.localizedDescription)", failed: true)
            }
        }

        guard let id = Int(args["session"] ?? ""), let session = terminals.session(id) else {
            let open = terminals.sessions.map { "\($0.id) (\($0.command))" }.joined(separator: ", ")
            return ToolOutcome(text: "No existe la sesión \(args["session"] ?? ""). Abiertas: \(open.isEmpty ? "ninguna" : open).", failed: true)
        }
        switch tool {
        case .terminalSend:
            guard session.isRunning else {
                return ToolOutcome(text: "La sesión \(id) ya terminó (código \(session.exitStatus)).", failed: true)
            }
            let enter = args["enter"]?.lowercased() != "false"
            session.write((args["input"] ?? "") + (enter ? "\r" : ""))
            return ToolOutcome(text: await collectOutput(of: session, maxWait: wait))
        case .terminalClose:
            terminals.close(id)
            return ToolOutcome(text: "Sesión \(id) cerrada.")
        default:
            return ToolOutcome(text: await collectOutput(of: session, maxWait: wait))
        }
    }

    /// Lee la salida nueva y, si termina pidiendo una contraseña, se la pide al usuario (no al modelo).
    private func collectOutput(of session: TerminalSession, maxWait: TimeInterval) async -> String {
        var transcript = await session.readNew(maxWait: maxWait)
        // Hasta 3 intentos: ssh y sudo vuelven a pedirla si está mal.
        for _ in 0..<3 {
            guard session.isRunning, let prompt = TerminalSession.secretPrompt(in: transcript) else { break }
            guard let secret = await requestSecret(SecretRequest(sessionID: session.id, command: session.command, prompt: prompt)) else {
                transcript += "\n[El usuario no ingresó la contraseña. La sesión sigue esperándola: cerrala o mandá Ctrl+C.]"
                break
            }
            session.write(secret + "\r")
            // La terminal no la muestra, pero por las dudas nunca llega al modelo.
            let next = await session.readNew(maxWait: maxWait).replacingOccurrences(of: secret, with: "••••")
            transcript += "\n[el usuario ingresó la contraseña]\n" + next
        }
        if !session.isRunning {
            transcript += "\n[La sesión terminó con código \(session.exitStatus)]"
        }
        return transcript.isEmpty ? "(sin salida nueva)" : transcript
    }

    func submitSecret(_ send: Bool) {
        let secret = send ? secretInput : nil
        secretInput = ""
        pendingSecret = nil
        secretContinuation?.resume(returning: secret)
        secretContinuation = nil
    }

    private func requestSecret(_ request: SecretRequest) async -> String? {
        guard !Task.isCancelled else { return nil }
        return await withCheckedContinuation { continuation in
            secretContinuation = continuation
            secretInput = ""
            pendingSecret = request
        }
    }

    // MARK: - Aprobación

    /// Al pasar a automático: lo que estaba esperando se aprueba, salvo que sea peligroso.
    func approvePendingIfSafe() {
        if let pending = pendingApproval, pending.riskReason == nil {
            resolveApproval(true)
        }
    }

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
        // Una aprobación o contraseña pendiente cuenta como rechazada: así la respuesta termina enseguida.
        resolveApproval(false)
        submitSecret(false)
    }

    func clear() {
        stop()
        conversationID = UUID()
        // El asistente nuevo no sabría que existen.
        terminals.closeAll()
        messages.removeAll()
        errorMessage = nil
    }

    /// Cierra la respuesta: quita los pasos vacíos, contesta las herramientas que quedaron sin resultado
    /// (si no, la próxima consulta da error) y deja el consumo en el último mensaje del asistente.
    private func finishTurn(usages: [ConsultationUsage], conversation: UUID) {
        isStreaming = false
        streamTask = nil
        // Los comandos del asistente pueden haber cambiado de rama o dejado cambios.
        workspace.refreshGit()
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

/// Pedido de contraseña de una sesión de terminal.
struct SecretRequest: Sendable {
    let sessionID: Int
    let command: String
    /// La línea de la terminal, por ejemplo "usuario@servidor's password:".
    let prompt: String
}
