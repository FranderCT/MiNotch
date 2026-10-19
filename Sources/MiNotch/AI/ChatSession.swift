import Foundation

struct ChatMessage: Identifiable, Sendable {
    enum Role: String, Sendable {
        case user, assistant
    }

    let id = UUID()
    let role: Role
    var text: String
    var usage: ConsultationUsage?
    var isComplete = false
}

/// Conversación compartida por todas las píldoras. Vive mientras la app está abierta.
@MainActor
final class ChatSession: ObservableObject {
    @Published private(set) var messages: [ChatMessage] = []
    @Published var input = ""
    @Published private(set) var isStreaming = false
    @Published private(set) var errorMessage: String?
    @Published private(set) var hasAPIKey = false

    @Published private(set) var balance: DeepSeekBalance?
    @Published private(set) var balanceError: String?
    @Published private(set) var isRefreshingBalance = false
    @Published private(set) var balanceUpdatedAt: Date?
    private var balanceTask: Task<Void, Never>?
    private var credentialsVersion = UUID()
    private var activeReplyID: UUID?

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

    // MARK: - Chat

    func send() {
        let text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !isStreaming, hasAPIKey else { return }

        input = ""
        errorMessage = nil
        messages.append(ChatMessage(role: .user, text: text))
        let history = messages
        messages.append(ChatMessage(role: .assistant, text: ""))
        let replyID = messages.last!.id
        activeReplyID = replyID
        isStreaming = true

        let model = UserDefaults.standard.string(forKey: DeepSeekClient.modelDefaultsKey) ?? DeepSeekClient.defaultModel

        streamTask = Task { [weak self] in
            do {
                guard let apiKey = await self?.resolveAPIKey() else { throw DeepSeekError.missingAPIKey }
                try Task.checkCancellation()
                let client = DeepSeekClient(apiKey: apiKey, model: model)
                for try await event in client.stream(history) {
                    try Task.checkCancellation()
                    guard let self, let index = self.messages.firstIndex(where: { $0.id == replyID }) else { continue }
                    switch event {
                    case .text(let delta): self.messages[index].text += delta
                    case .usage(let tokens, let model, let date):
                        self.messages[index].usage = ConsultationUsage(tokens: tokens, model: model, date: date)
                    }
                }
            } catch {
                if !Task.isCancelled { self?.errorMessage = error.localizedDescription }
            }
            self?.finishReply(id: replyID)
            self?.refreshBalance()
        }
    }

    func stop() {
        streamTask?.cancel()
        if let id = activeReplyID { finishReply(id: id) }
    }

    func clear() {
        stop()
        messages.removeAll()
        errorMessage = nil
    }

    private func finishReply(id: UUID) {
        guard activeReplyID == id else { return }
        if let index = messages.firstIndex(where: { $0.id == id }) {
            if messages[index].text.isEmpty && messages[index].usage == nil {
                messages.remove(at: index)
            } else {
                messages[index].isComplete = true
            }
        }
        activeReplyID = nil
        isStreaming = false
        streamTask = nil
    }
}
