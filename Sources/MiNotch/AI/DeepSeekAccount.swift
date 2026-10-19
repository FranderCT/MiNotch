import Foundation

/// Lo común a todas las pestañas: API key, saldo de la cuenta y cuánto pregunta el asistente.
@MainActor
final class DeepSeekAccount: ObservableObject {
    @Published private(set) var hasAPIKey = false

    @Published private(set) var balance: DeepSeekBalance?
    @Published private(set) var balanceError: String?
    @Published private(set) var isRefreshingBalance = false
    @Published private(set) var balanceUpdatedAt: Date?
    private var balanceTask: Task<Void, Never>?
    private var credentialsVersion = UUID()

    /// Preguntar antes de cada acción o hacerlo todo solo (salvo lo peligroso). Se recuerda entre reinicios.
    @Published var approvalMode = ApprovalMode(rawValue: UserDefaults.standard.string(forKey: ApprovalMode.defaultsKey) ?? "") ?? .ask {
        didSet {
            UserDefaults.standard.set(approvalMode.rawValue, forKey: ApprovalMode.defaultsKey)
            onApprovalModeChange?(approvalMode)
        }
    }

    /// Los define AppDelegate y ChatTabs: abrir la configuración, cortar las respuestas al cambiar la key
    /// y aprobar lo que estaba esperando al pasar a automático.
    var onOpenSettings: (() -> Void)?
    var onCredentialsChange: (() -> Void)?
    var onApprovalModeChange: ((ApprovalMode) -> Void)?

    /// Copia en memoria de la key: se lee al consultar saldo o enviar un mensaje.
    private var apiKey: String?

    init() {
        hasAPIKey = KeychainStore.exists()
    }

    // MARK: - API key

    func saveAPIKey(_ key: String) {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        onCredentialsChange?()
        resetBalance()
        hasAPIKey = KeychainStore.save(trimmed)
        apiKey = hasAPIKey ? trimmed : nil
        refreshBalance()
    }

    func deleteAPIKey() {
        onCredentialsChange?()
        resetBalance()
        KeychainStore.delete()
        apiKey = nil
        hasAPIKey = false
    }

    func openSettings() {
        onOpenSettings?()
    }

    /// Fuera del hilo principal: el Llavero puede mostrar un diálogo de permiso que bloquea.
    func resolveAPIKey() async -> String? {
        if let apiKey { return apiKey }
        let version = credentialsVersion
        let loaded = await Task.detached { KeychainStore.load() }.value
        guard version == credentialsVersion else { return nil }
        apiKey = loaded
        return loaded
    }

    // MARK: - Saldo

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
}
