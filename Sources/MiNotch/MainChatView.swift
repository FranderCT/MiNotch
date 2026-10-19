import AppKit
import SwiftUI

// Ventana principal con estilo de terminal: pestañas en una barra lateral y la conversación en monoespaciada.

/// Estado de la ventana que en el notch vive en NotchState (las Command Line Tools no incluyen `@State`).
@MainActor
final class WindowState: ObservableObject {
    @Published var isDropTargeted = false
    @Published var search = ""
}

private let mono = Font.system(size: 13, design: .monospaced)
private let dim = Color.white.opacity(0.45)

struct WindowRootView: View {
    @ObservedObject var tabs: ChatTabs
    @ObservedObject var state: WindowState

    var body: some View {
        let chat = tabs.selected
        HStack(spacing: 0) {
            TabSidebar(tabs: tabs, state: state)
                .frame(width: 240)
            Rectangle()
                .fill(.white.opacity(0.08))
                .frame(width: 1)
            WindowChat(
                tabs: tabs, chat: chat, account: tabs.account, workspace: chat.workspace,
                terminals: chat.terminals, agents: chat.externalAgents, state: state
            )
            // Cada pestaña con su foco y su scroll.
            .id(chat.id)
        }
        .background(Color(white: 0.055))
        .preferredColorScheme(.dark)
    }
}

// MARK: - Barra lateral

private struct TabSidebar: View {
    @ObservedObject var tabs: ChatTabs
    @ObservedObject var state: WindowState

    private var filtered: [ChatSession] {
        let query = state.search.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else { return tabs.tabs }
        return tabs.tabs.filter { tab in
            [tab.conversationTitle, tab.workspace.displayPath, tab.workspace.git?.branch ?? ""]
                .contains { $0.localizedCaseInsensitiveContains(query) }
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                HStack(spacing: 5) {
                    Image(systemName: "magnifyingglass")
                        .foregroundStyle(dim)
                    TextField("Buscar pestañas…", text: $state.search)
                        .textFieldStyle(.plain)
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 5)
                .background(.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                Button(action: tabs.newTab) {
                    Image(systemName: "plus")
                        .font(.system(size: 12, weight: .semibold))
                }
                .buttonStyle(.plain)
                .disabled(!tabs.canAddTab)
                .help(tabs.canAddTab ? "Nueva pestaña en la misma carpeta (⌘T)" : "Máximo \(ChatTabs.maxTabs) pestañas")
            }

            ScrollView {
                VStack(spacing: 2) {
                    ForEach(filtered) { tab in
                        let index = tabs.tabs.firstIndex { $0.id == tab.id } ?? 0
                        SidebarTabRow(
                            tab: tab,
                            workspace: tab.workspace,
                            shortcut: index < 9 ? index + 1 : nil,
                            isSelected: tab.id == tabs.selectedID,
                            onSelect: { tabs.select(tab.id) },
                            onClose: { tabs.close(tab.id) }
                        )
                    }
                }
            }
            .scrollIndicators(.never)

            HStack {
                BalanceView(account: tabs.account)
                Spacer(minLength: 0)
                Button(action: tabs.account.openSettings) {
                    Image(systemName: "gearshape")
                }
                .buttonStyle(.plain)
                .help("Configuración: API key, modelo y dónde se muestra MiNotch")
            }
            .font(.system(size: 10, weight: .medium))
            .foregroundStyle(dim)
        }
        .padding(10)
        .font(.system(size: 11))
        .foregroundStyle(.white.opacity(0.85))
        .background(Color(white: 0.085))
    }
}

/// Una pestaña: estado, título de la conversación, rama (o carpeta) y su atajo.
private struct SidebarTabRow: View {
    @ObservedObject var tab: ChatSession
    @ObservedObject var workspace: Workspace
    let shortcut: Int?
    let isSelected: Bool
    let onSelect: () -> Void
    let onClose: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            statusIcon
                .frame(width: 14)
                .padding(.top, 1)
            VStack(alignment: .leading, spacing: 2) {
                Text(tab.conversationTitle)
                    .font(.system(size: 12, weight: isSelected ? .semibold : .regular))
                    .lineLimit(1)
                HStack(spacing: 4) {
                    if let git = workspace.git {
                        Image(systemName: "arrow.triangle.branch")
                        Text(git.branch)
                    } else {
                        Image(systemName: "folder")
                        Text(workspace.directory.lastPathComponent)
                    }
                }
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(dim)
                .lineLimit(1)
            }
            Spacer(minLength: 4)
            if let shortcut {
                Text("⌘\(shortcut)")
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.3))
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(isSelected ? .white.opacity(0.1) : .clear, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
        .contentShape(Rectangle())
        .onTapGesture(perform: onSelect)
        .contextMenu {
            Button("Cerrar pestaña", action: onClose)
        }
        .help("\(tab.number) · \(workspace.displayPath)\n\(tab.statusText)")
    }

    @ViewBuilder
    private var statusIcon: some View {
        if tab.needsAttention {
            Image(systemName: "exclamationmark.circle.fill").foregroundStyle(AITheme.pink)
        } else if tab.isStreaming {
            Image(systemName: "sparkle").foregroundStyle(AITheme.cyan)
        } else if tab.mode == .terminal {
            Image(systemName: "apple.terminal").foregroundStyle(dim)
        } else {
            Image(systemName: "circle").foregroundStyle(.white.opacity(0.25))
        }
    }
}

// MARK: - Conversación

private struct WindowChat: View {
    @ObservedObject var tabs: ChatTabs
    @ObservedObject var chat: ChatSession
    @ObservedObject var account: DeepSeekAccount
    @ObservedObject var workspace: Workspace
    @ObservedObject var terminals: TerminalSessions
    @ObservedObject var agents: ExternalAgents
    @ObservedObject var state: WindowState

    @AppStorage(DeepSeekClient.modelDefaultsKey) private var model = DeepSeekClient.defaultModel
    @FocusState private var isInputFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            topBar
            separator
            if chat.mode == .terminal {
                // La terminal no necesita API key: es un shell local.
                TerminalHost(shell: chat.shell, directory: workspace.directory)
                    .padding(8)
            } else if account.hasAPIKey {
                transcript
            } else {
                missingKey
            }
            cards
            if chat.mode == .agent {
                separator
                inputLine
            }
            statusLine
        }
        .overlay {
            if state.isDropTargeted {
                DropHint()
            }
        }
        .onDrop(of: [.fileURL, .image], isTargeted: $state.isDropTargeted) { ImageAttachment.handleDrop($0, into: chat) }
        // Como en una terminal: esc corta la respuesta.
        .onExitCommand { if chat.isStreaming { chat.stop() } }
        .onAppear {
            account.refreshBalanceIfNeeded()
            workspace.refreshGit()
            isInputFocused = true
        }
    }

    private var separator: some View {
        Rectangle().fill(.white.opacity(0.08)).frame(height: 1)
    }

    private var topBar: some View {
        HStack(spacing: 10) {
            Text("\(chat.number)")
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(dim)
            Text(chat.conversationTitle)
                .font(.system(size: 12, weight: .semibold))
                .lineLimit(1)
            Spacer(minLength: 8)
            ModeSwitch(chat: chat, showsAllTitles: true)
            Button(action: chat.clear) {
                Image(systemName: "trash")
            }
            .buttonStyle(.plain)
            .disabled(chat.messages.isEmpty)
            .opacity(chat.messages.isEmpty ? 0.3 : 1)
            .help("Borrar la conversación de esta pestaña")
        }
        .font(.system(size: 11))
        .foregroundStyle(.white.opacity(0.8))
        .padding(.horizontal, 14)
        .frame(height: 36)
    }

    /// Sin los pasos del asistente que solo pidieron herramientas: esas se ven como filas propias.
    private var visibleMessages: [ChatMessage] {
        chat.messages.filter { message in
            message.role != .assistant || !message.text.isEmpty
                || (chat.isStreaming && message.id == chat.messages.last?.id)
        }
    }

    private var transcript: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 12) {
                    if chat.messages.isEmpty {
                        welcome
                    }
                    ForEach(visibleMessages) { message in
                        TerminalMessageRow(message: message, isActive: chat.isStreaming && message.id == chat.messages.last?.id)
                            .id(message.id)
                    }
                    if let error = chat.errorMessage {
                        ErrorRow(text: error)
                    }
                }
                .font(mono)
                .padding(.horizontal, 18)
                .padding(.vertical, 14)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .onChange(of: "\(chat.messages.count)\(chat.messages.last?.text.count ?? 0)") {
                if let id = visibleMessages.last?.id {
                    proxy.scrollTo(id, anchor: .bottom)
                }
            }
        }
        .frame(maxHeight: .infinity)
    }

    private var welcome: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Text("✻").foregroundStyle(AITheme.accent)
                Text("MiNotch").fontWeight(.semibold)
                Text("· DeepSeek \(model.replacingOccurrences(of: "deepseek-", with: ""))").foregroundStyle(dim)
            }
            Text("  cwd: \(workspace.displayPath)\(workspace.git.map { "  ⎇ \($0.branch)" } ?? "")")
                .foregroundStyle(dim)
            Text("  Leo, creo y edito archivos, ejecuto comandos, uso la terminal de la pestaña y dirijo otras pestañas y agentes (Claude Code, Codex…).")
                .foregroundStyle(dim)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(AITheme.accent.opacity(0.5), lineWidth: 1))
    }

    private var missingKey: some View {
        VStack(spacing: 10) {
            Text("Falta tu API key de DeepSeek")
            Button("Configurar API key", action: account.openSettings)
        }
        .font(mono)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// Aprobaciones, contraseñas, avisos de otras pestañas e imagen adjunta.
    @ViewBuilder
    private var cards: some View {
        let other = tabs.needingAttention.first { $0.id != chat.id }
        let hasImage = chat.isReadingImage || chat.imageText != nil
        if other != nil || chat.pendingApproval != nil || chat.pendingSecret != nil || (chat.mode == .agent && hasImage) {
            VStack(alignment: .leading, spacing: 8) {
                if let other {
                    AttentionBanner(other: other) { tabs.select(other.id) }
                }
                if let approval = chat.pendingApproval {
                    ApprovalCard(approval: approval, onDecide: chat.resolveApproval)
                }
                if let request = chat.pendingSecret {
                    SecretCard(chat: chat, request: request)
                }
                if chat.mode == .agent {
                    if chat.isReadingImage {
                        ReadingImageChip()
                    } else if let imageText = chat.imageText {
                        ImageTextChip(text: imageText, wasTrimmed: chat.imageTextWasTrimmed, onRemove: chat.discardImageText)
                    }
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var inputLine: some View {
        let hasImage = chat.imageText != nil || chat.isReadingImage
        return HStack(spacing: 10) {
            Text("❯")
                .font(.system(size: 14, weight: .bold, design: .monospaced))
                .foregroundStyle(AITheme.accent)
            TextField(hasImage ? "¿Qué querés saber de la imagen? (Enter = explicar)" : "Pedile algo a DeepSeek…", text: $chat.input)
                .textFieldStyle(.plain)
                .font(mono)
                .focused($isInputFocused)
                .onSubmit { chat.send() }
                .disabled(!account.hasAPIKey)
            Button { ImageAttachment.pick(into: chat) } label: {
                Image(systemName: "photo.badge.plus")
            }
            .buttonStyle(.plain)
            .foregroundStyle(dim)
            .disabled(!account.hasAPIKey || chat.isReadingImage)
            .help("Adjuntar una imagen (o arrastrala acá, o pegala con ⌘V): extraigo su texto")
            if chat.isStreaming {
                Button(action: chat.stop) {
                    Image(systemName: "stop.circle.fill")
                        .foregroundStyle(AITheme.pink)
                }
                .buttonStyle(.plain)
                .help("Detener (esc)")
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    /// Como la línea de estado de una terminal: modo de aprobación a la izquierda, contexto a la derecha.
    private var statusLine: some View {
        HStack(spacing: 14) {
            HStack(spacing: 4) {
                Text("▸▸").foregroundStyle(account.approvalMode == .auto ? AITheme.pink : dim)
                ApprovalModeMenu(account: account)
            }
            if chat.isStreaming {
                Text(chat.needsAttention ? "esperando tu respuesta" : "esc para detener")
                    .foregroundStyle(dim)
            }
            Spacer(minLength: 8)
            DirectoryMenu(workspace: workspace, isDisabled: chat.isStreaming, showsPath: true)
            if let git = workspace.git {
                GitBadge(git: git, showsDiffStat: true)
            }
            if !terminals.sessions.isEmpty {
                TerminalsMenu(terminals: terminals)
            }
            if !agents.jobs.isEmpty {
                AgentsMenu(agents: agents)
            }
            Text(model.replacingOccurrences(of: "deepseek-", with: ""))
                .foregroundStyle(dim)
        }
        .font(.system(size: 11, design: .monospaced))
        .foregroundStyle(.white.opacity(0.7))
        .padding(.horizontal, 14)
        .frame(height: 28)
        .background(Color(white: 0.075))
    }
}

/// Un mensaje con estilo de terminal: ❯ lo tuyo, ● el asistente, ⎿ las herramientas.
private struct TerminalMessageRow: View {
    let message: ChatMessage
    let isActive: Bool

    var body: some View {
        switch message.role {
        case .user:
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text("❯").foregroundStyle(AITheme.accent)
                VStack(alignment: .leading, spacing: 4) {
                    if let fromTab = message.fromTab {
                        Text("tarea de la pestaña \(fromTab)").font(.system(size: 11, design: .monospaced)).foregroundStyle(dim)
                    }
                    if let imageText = message.imageText {
                        ImageTextChip(text: imageText)
                    }
                    Text(message.text)
                        .textSelection(.enabled)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
        case .assistant:
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                if message.text.isEmpty && isActive {
                    Text("✻ Pensando…").foregroundStyle(AITheme.accent)
                } else {
                    Text("●").foregroundStyle(.white.opacity(0.9))
                    VStack(alignment: .leading, spacing: 4) {
                        Text(MessageRow.markdown(message.text))
                            .foregroundStyle(.white.opacity(0.92))
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        if message.isComplete {
                            Text(message.usages.costText)
                                .font(.system(size: 11, design: .monospaced))
                                .foregroundStyle(dim)
                                .help(message.usages.details)
                        }
                    }
                }
            }
        case .tool:
            HStack(spacing: 6) {
                Text("  ⎿").foregroundStyle(dim)
                Image(systemName: message.toolName.flatMap(AgentTool.init(rawValue:))?.icon ?? "wrench")
                    .frame(width: 14)
                Text(message.toolSummary ?? message.toolName ?? "")
                    .lineLimit(1)
                    .truncationMode(.middle)
                if message.toolFailed {
                    Text("✗").foregroundStyle(AITheme.pink)
                }
            }
            .font(.system(size: 12, design: .monospaced))
            .foregroundStyle(.white.opacity(0.55))
            .help(String(message.text.prefix(1500)))
        }
    }
}
