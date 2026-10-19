import Foundation

struct ChatMessage: Identifiable, Sendable {
    enum Role: String, Sendable {
        case user, assistant
    }

    let id = UUID()
    let role: Role
    var text: String
}

/// Conversación compartida por todas las píldoras. Vive mientras la app está abierta.
@MainActor
final class ChatSession: ObservableObject {
    @Published private(set) var messages: [ChatMessage] = []
    @Published var input = ""
    @Published private(set) var isStreaming = false
    @Published private(set) var errorMessage: String?
    @Published private(set) var hasAPIKey = false

    /// Lo define AppDelegate: abre la ventana de configuración.
    var onOpenSettings: (() -> Void)?

    /// Copia en memoria de la key: se lee del Llavero recién al primer envío.
    private var apiKey: String?
    private var streamTask: Task<Void, Never>?

    init() {
        hasAPIKey = KeychainStore.exists()
    }

    // MARK: - API key

    func saveAPIKey(_ key: String) {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        hasAPIKey = KeychainStore.save(trimmed)
        apiKey = hasAPIKey ? trimmed : nil
        errorMessage = nil
    }

    func deleteAPIKey() {
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
        let loaded = await Task.detached { KeychainStore.load() }.value
        apiKey = loaded
        return loaded
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
        isStreaming = true

        let model = UserDefaults.standard.string(forKey: DeepSeekClient.modelDefaultsKey) ?? DeepSeekClient.defaultModel

        streamTask = Task { [weak self] in
            do {
                guard let apiKey = await self?.resolveAPIKey() else { throw DeepSeekError.missingAPIKey }
                let client = DeepSeekClient(apiKey: apiKey, model: model)
                for try await delta in client.stream(history) {
                    self?.appendToReply(delta)
                }
            } catch {
                if !Task.isCancelled { self?.errorMessage = error.localizedDescription }
            }
            self?.finishReply()
        }
    }

    func stop() {
        streamTask?.cancel()
    }

    func clear() {
        stop()
        messages.removeAll()
        errorMessage = nil
    }

    private func appendToReply(_ delta: String) {
        guard let last = messages.indices.last else { return }
        messages[last].text += delta
    }

    private func finishReply() {
        // Si no llegó nada (error o cancelación inmediata), no dejar una burbuja vacía.
        if let last = messages.last, last.role == .assistant, last.text.isEmpty {
            messages.removeLast()
        }
        isStreaming = false
        streamTask = nil
    }
}
