import Combine
import Foundation

/// Pestañas del notch, como en una terminal: cada una con su conversación, carpeta y sesiones.
/// Siempre hay al menos una.
@MainActor
final class ChatTabs: ObservableObject {
    static let maxTabs = 8

    let account: DeepSeekAccount
    @Published private(set) var tabs: [ChatSession]
    @Published private(set) var selectedID: UUID
    /// Alguna pestaña está respondiendo sin esperar al usuario: el borde gira.
    @Published private(set) var isAnyWorking = false
    private var observers: [UUID: AnyCancellable] = [:]

    init(account: DeepSeekAccount) {
        self.account = account
        let first = ChatSession(account: account)
        tabs = [first]
        selectedID = first.id
        observe(first)

        account.onCredentialsChange = { [weak self] in
            self?.tabs.forEach { $0.stop() }
        }
        account.onApprovalModeChange = { [weak self] mode in
            // Lo que estaba esperando también se aprueba, si no es peligroso.
            guard mode == .auto else { return }
            self?.tabs.forEach { $0.approvePendingIfSafe() }
        }
    }

    var selected: ChatSession {
        tabs.first { $0.id == selectedID } ?? tabs[0]
    }

    var canAddTab: Bool {
        tabs.count < Self.maxTabs
    }

    /// Como en una terminal: la pestaña nueva arranca en la carpeta de la actual.
    func newTab() {
        guard canAddTab else { return }
        let tab = ChatSession(account: account, directory: selected.workspace.directory)
        let index = (tabs.firstIndex { $0.id == selectedID } ?? tabs.count - 1) + 1
        tabs.insert(tab, at: index)
        observe(tab)
        selectedID = tab.id
    }

    /// Corta su respuesta y cierra sus sesiones de terminal. La última se reemplaza por una vacía.
    func close(_ id: UUID) {
        guard let index = tabs.firstIndex(where: { $0.id == id }) else { return }
        let tab = tabs[index]
        tab.stop()
        tab.terminals.closeAll()
        observers[id] = nil
        tabs.remove(at: index)
        if tabs.isEmpty {
            let fresh = ChatSession(account: account, directory: tab.workspace.directory)
            tabs = [fresh]
            observe(fresh)
        }
        if selectedID == id {
            selectedID = tabs[min(index, tabs.count - 1)].id
        }
        updateWorking()
    }

    func closeSelected() {
        close(selectedID)
    }

    func select(_ id: UUID) {
        guard tabs.contains(where: { $0.id == id }) else { return }
        selectedID = id
        selected.workspace.refreshGit()
    }

    /// `offset` 1 = siguiente, -1 = anterior; da la vuelta.
    func selectAdjacent(_ offset: Int) {
        guard let index = tabs.firstIndex(where: { $0.id == selectedID }) else { return }
        select(tabs[(index + offset + tabs.count) % tabs.count].id)
    }

    func closeAllTerminals() {
        tabs.forEach { $0.terminals.closeAll() }
    }

    private func observe(_ tab: ChatSession) {
        observers[tab.id] = tab.$isStreaming
            .combineLatest(tab.$pendingApproval, tab.$pendingSecret)
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.updateWorking() }
    }

    private func updateWorking() {
        let working = tabs.contains(where: \.isWorking)
        if working != isAnyWorking { isAnyWorking = working }
    }
}
