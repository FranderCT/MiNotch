import AppKit
import SwiftUI

// La interfaz de MiNotch, con estilo de terminal: barra superior, pestañas en una barra lateral (plegable)
// y la conversación en monoespaciada. La misma vista en la ventana y, a escala, en el notch.

/// Tamaños de cada lugar donde se muestra.
struct ChatStyle {
    let fontSize: CGFloat
    let sidebarWidth: CGFloat
    let topBarHeight: CGFloat
    /// En el notch la barra superior deja libre el centro (el notch físico) y no hay fondo propio.
    let isNotch: Bool

    static let window = ChatStyle(fontSize: 13, sidebarWidth: 240, topBarHeight: 36, isNotch: false)

    /// `topInset`: alto de la barra de menú o del notch físico; ahí va la barra superior.
    static func notch(topInset: CGFloat) -> ChatStyle {
        ChatStyle(fontSize: 12, sidebarWidth: 180, topBarHeight: topInset, isNotch: true)
    }

    var mono: Font { .system(size: fontSize, design: .monospaced) }
    var small: Font { .system(size: fontSize - 2, design: .monospaced) }
}

/// Estado de la interfaz de cada lugar (notch o ventana). Las Command Line Tools no incluyen `@State`.
@MainActor
final class ChatLayoutState: ObservableObject {
    @Published var isDropTargeted = false
    @Published var search = ""
    /// Se recuerda entre reinicios, por separado en el notch y en la ventana.
    @Published var isSidebarVisible: Bool {
        didSet { UserDefaults.standard.set(isSidebarVisible, forKey: sidebarKey) }
    }
    private let sidebarKey: String

    init(sidebarKey: String, sidebarVisibleByDefault: Bool) {
        self.sidebarKey = sidebarKey
        isSidebarVisible = UserDefaults.standard.object(forKey: sidebarKey) as? Bool ?? sidebarVisibleByDefault
    }

    func toggleSidebar() {
        isSidebarVisible.toggle()
    }
}

private let dim = Color.white.opacity(0.45)
private let separatorColor = Color.white.opacity(0.08)

struct MainChatView: View {
    @ObservedObject var tabs: ChatTabs
    @ObservedObject var layout: ChatLayoutState
    let style: ChatStyle
    /// En el notch: botón para abrir la ventana. En la ventana no hace falta.
    var showsWindowButton = false

    var body: some View {
        let chat = tabs.selected
        VStack(spacing: 0) {
            TopBar(tabs: tabs, chat: chat, layout: layout, style: style, showsWindowButton: showsWindowButton)
                .frame(height: style.topBarHeight)
            HStack(spacing: 0) {
                if layout.isSidebarVisible {
                    TabSidebar(tabs: tabs, layout: layout, style: style)
                        .frame(width: style.sidebarWidth)
                    Rectangle().fill(separatorColor).frame(width: 1)
                }
                ChatColumn(
                    tabs: tabs, chat: chat, account: tabs.account, workspace: chat.workspace,
                    terminals: chat.terminals, agents: chat.externalAgents, layout: layout, style: style
                )
                // Cada pestaña con su foco y su scroll.
                .id(chat.id)
            }
        }
        .foregroundStyle(.white)
        .preferredColorScheme(.dark)
    }
}

// MARK: - Barra superior

private struct TopBar: View {
    @ObservedObject var tabs: ChatTabs
    @ObservedObject var chat: ChatSession
    @ObservedObject var layout: ChatLayoutState
    let style: ChatStyle
    let showsWindowButton: Bool

    var body: some View {
        HStack(spacing: 8) {
            button(layout.isSidebarVisible ? "sidebar.left" : "sidebar.squares.left",
                   help: layout.isSidebarVisible ? "Ocultar pestañas (⌃⌘S)" : "Mostrar pestañas (⌃⌘S)",
                   action: layout.toggleSidebar)
            ModeSwitch(chat: chat, showsAllTitles: !style.isNotch)
            // En el notch el centro queda libre: en la MacBook ahí está el notch físico.
            if !style.isNotch {
                Text("\(chat.number)")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(dim)
                Text(chat.conversationTitle)
                    .font(.system(size: 12, weight: .semibold))
                    .lineLimit(1)
            }
            Spacer(minLength: 8)
            button("trash", help: "Borrar la conversación de esta pestaña", action: chat.clear)
                .disabled(chat.messages.isEmpty)
                .opacity(chat.messages.isEmpty ? 0.3 : 1)
            if showsWindowButton {
                button("macwindow", help: "Abrir en una ventana (⌘0)", action: tabs.openWindow)
            }
            button("gearshape", help: "Configuración: API key, modelo y dónde se muestra MiNotch", action: tabs.account.openSettings)
        }
        .font(.system(size: 11))
        .foregroundStyle(.white.opacity(0.8))
        .padding(.horizontal, style.isNotch ? 6 : 14)
    }

    private func button(_ icon: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 12))
                .foregroundStyle(.white.opacity(0.7))
        }
        .buttonStyle(.plain)
        .help(help)
        .accessibilityLabel(help)
    }
}

// MARK: - Barra lateral

private struct TabSidebar: View {
    @ObservedObject var tabs: ChatTabs
    @ObservedObject var layout: ChatLayoutState
    let style: ChatStyle

    private var filtered: [ChatSession] {
        let query = layout.search.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else { return tabs.tabs }
        return tabs.tabs.filter { tab in
            [tab.conversationTitle, tab.workspace.displayPath, tab.workspace.git?.branch ?? ""]
                .contains { $0.localizedCaseInsensitiveContains(query) }
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: style.isNotch ? 6 : 10) {
            HStack(spacing: 6) {
                HStack(spacing: 5) {
                    Image(systemName: "magnifyingglass")
                        .foregroundStyle(dim)
                    TextField("Buscar pestañas…", text: $layout.search)
                        .textFieldStyle(.plain)
                }
                .padding(.horizontal, 7)
                .padding(.vertical, 4)
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
                            style: style,
                            onSelect: { tabs.select(tab.id) },
                            onClose: { tabs.close(tab.id) }
                        )
                    }
                }
            }
            .scrollIndicators(.never)

            BalanceView(account: tabs.account)
                .font(.system(size: 10, weight: .medium, design: .monospaced))
                .foregroundStyle(dim)
        }
        .padding(style.isNotch ? 8 : 10)
        .font(.system(size: style.fontSize - 2))
        .foregroundStyle(.white.opacity(0.85))
        .background(Color.white.opacity(0.035))
    }
}

/// Una pestaña: estado, título de la conversación, rama (o carpeta) y su atajo.
private struct SidebarTabRow: View {
    @ObservedObject var tab: ChatSession
    @ObservedObject var workspace: Workspace
    let shortcut: Int?
    let isSelected: Bool
    let style: ChatStyle
    let onSelect: () -> Void
    let onClose: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 7) {
            statusIcon
                .frame(width: 13)
                .padding(.top, 1)
            VStack(alignment: .leading, spacing: 2) {
                Text(tab.conversationTitle)
                    .font(.system(size: style.fontSize - 1, weight: isSelected ? .semibold : .regular))
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
                .font(.system(size: style.fontSize - 3, design: .monospaced))
                .foregroundStyle(dim)
                .lineLimit(1)
            }
            Spacer(minLength: 4)
            if let shortcut {
                Text("⌘\(shortcut)")
                    .font(.system(size: style.fontSize - 3, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.3))
            }
        }
        .padding(.horizontal, 7)
        .padding(.vertical, style.isNotch ? 4 : 6)
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

private struct ChatColumn: View {
    @ObservedObject var tabs: ChatTabs
    @ObservedObject var chat: ChatSession
    @ObservedObject var account: DeepSeekAccount
    @ObservedObject var workspace: Workspace
    @ObservedObject var terminals: TerminalSessions
    @ObservedObject var agents: ExternalAgents
    @ObservedObject var layout: ChatLayoutState
    let style: ChatStyle

    @AppStorage(DeepSeekClient.modelDefaultsKey) private var model = DeepSeekClient.defaultModel
    @FocusState private var isInputFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            Rectangle().fill(separatorColor).frame(height: 1)
            if chat.mode == .terminal {
                // La terminal no necesita API key: es un shell local.
                TerminalHost(shell: chat.shell, directory: workspace.directory)
                    .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                    .padding(style.isNotch ? 6 : 8)
            } else if account.hasAPIKey {
                transcript
            } else {
                missingKey
            }
            cards
            if chat.mode == .agent {
                Rectangle().fill(separatorColor).frame(height: 1)
                inputLine
            }
            statusLine
        }
        .overlay {
            if layout.isDropTargeted {
                DropHint()
            }
        }
        .onDrop(of: [.fileURL, .image], isTargeted: $layout.isDropTargeted) { ImageAttachment.handleDrop($0, into: chat) }
        // Como en una terminal: esc corta la respuesta.
        .onExitCommand { if chat.isStreaming { chat.stop() } }
        .onAppear {
            account.refreshBalanceIfNeeded()
            // La rama pudo cambiar desde otra terminal mientras estaba cerrado.
            workspace.refreshGit()
            isInputFocused = true
        }
        .onChange(of: chat.isReadingImage) {
            // Recién adjuntada: listo para escribir la pregunta.
            if chat.isReadingImage { isInputFocused = true }
        }
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
                LazyVStack(alignment: .leading, spacing: style.isNotch ? 10 : 12) {
                    if chat.messages.isEmpty {
                        welcome
                    }
                    ForEach(visibleMessages) { message in
                        TerminalMessageRow(message: message, isActive: chat.isStreaming && message.id == chat.messages.last?.id, fontSize: style.fontSize)
                            .id(message.id)
                    }
                    if let error = chat.errorMessage {
                        ErrorRow(text: error)
                    }
                }
                .font(style.mono)
                .padding(.horizontal, style.isNotch ? 10 : 18)
                .padding(.vertical, style.isNotch ? 10 : 14)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .scrollIndicators(style.isNotch ? .never : .automatic)
            .onChange(of: "\(chat.messages.count)\(chat.messages.last?.text.count ?? 0)") {
                if let id = visibleMessages.last?.id {
                    proxy.scrollTo(id, anchor: .bottom)
                }
            }
        }
        .frame(maxHeight: .infinity)
    }

    private var welcome: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                Text("✻").foregroundStyle(AITheme.accent)
                Text("MiNotch").fontWeight(.semibold)
                Text("· DeepSeek \(model.replacingOccurrences(of: "deepseek-", with: ""))").foregroundStyle(dim)
            }
            Text("  cwd: \(workspace.displayPath)\(workspace.git.map { "  ⎇ \($0.branch)" } ?? "")")
                .foregroundStyle(dim)
                .lineLimit(1)
                .truncationMode(.middle)
            Text("  Leo, creo y edito archivos, ejecuto comandos, uso la terminal de la pestaña y dirijo otras pestañas y agentes.")
                .foregroundStyle(dim)
        }
        .font(style.isNotch ? style.small : style.mono)
        .padding(style.isNotch ? 9 : 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(AITheme.accent.opacity(0.5), lineWidth: 1))
    }

    private var missingKey: some View {
        VStack(spacing: 10) {
            Text("Falta tu API key de DeepSeek")
            Button("Configurar API key", action: account.openSettings)
        }
        .font(style.mono)
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
            .padding(.horizontal, style.isNotch ? 8 : 14)
            .padding(.vertical, style.isNotch ? 6 : 8)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    /// Línea de entrada de terminal: ❯, Enter envía y esc detiene.
    private var inputLine: some View {
        let hasImage = chat.imageText != nil || chat.isReadingImage
        return HStack(spacing: style.isNotch ? 8 : 10) {
            Text("❯")
                .font(.system(size: style.fontSize + 1, weight: .bold, design: .monospaced))
                .foregroundStyle(AITheme.accent)
            TextField(hasImage ? "¿Qué querés saber de la imagen? (Enter = explicar)" : "Pedile algo a DeepSeek…", text: $chat.input)
                .textFieldStyle(.plain)
                .font(style.mono)
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
        .padding(.horizontal, style.isNotch ? 10 : 16)
        .padding(.vertical, style.isNotch ? 8 : 12)
    }

    /// Como la línea de estado de una terminal: modo de aprobación a la izquierda, contexto a la derecha.
    private var statusLine: some View {
        // En el notch sin barra lateral el lugar es justo: con sesiones o agentes, la rama sin los números.
        let roomy = !style.isNotch || (terminals.sessions.isEmpty && agents.jobs.isEmpty)
        return HStack(spacing: style.isNotch ? 10 : 14) {
            HStack(spacing: 3) {
                Text("▸▸").foregroundStyle(account.approvalMode == .auto ? AITheme.pink : dim)
                ApprovalModeMenu(account: account)
            }
            if chat.isStreaming, !style.isNotch {
                Text(chat.needsAttention ? "esperando tu respuesta" : "esc para detener")
                    .foregroundStyle(dim)
            }
            Spacer(minLength: 6)
            DirectoryMenu(workspace: workspace, isDisabled: chat.isStreaming, showsPath: !style.isNotch)
            if let git = workspace.git {
                GitBadge(git: git, showsDiffStat: roomy)
            }
            if !terminals.sessions.isEmpty {
                TerminalsMenu(terminals: terminals)
            }
            if !agents.jobs.isEmpty {
                AgentsMenu(agents: agents)
            }
            if !style.isNotch {
                Text(model.replacingOccurrences(of: "deepseek-", with: ""))
                    .foregroundStyle(dim)
            }
            // Con la barra lateral visible, el saldo está abajo de las pestañas.
            if !layout.isSidebarVisible {
                BalanceView(account: account)
            }
        }
        .font(.system(size: style.fontSize - 2, design: .monospaced))
        .foregroundStyle(.white.opacity(0.7))
        .padding(.horizontal, style.isNotch ? 10 : 14)
        .frame(height: style.isNotch ? 24 : 28)
        .background(Color.white.opacity(style.isNotch ? 0.03 : 0.02))
    }
}

/// Un mensaje con estilo de terminal: ❯ lo tuyo, ● el asistente, ⎿ las herramientas.
struct TerminalMessageRow: View {
    let message: ChatMessage
    /// Es el último mensaje y la respuesta sigue en curso.
    let isActive: Bool
    /// 13 en la ventana, 12 en el notch.
    var fontSize: CGFloat = 13

    private var small: Font { .system(size: fontSize - 2, design: .monospaced) }

    var body: some View {
        switch message.role {
        case .user:
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text("❯").foregroundStyle(AITheme.accent)
                VStack(alignment: .leading, spacing: 4) {
                    if let fromTab = message.fromTab {
                        Text("tarea de la pestaña \(fromTab)").font(small).foregroundStyle(dim)
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
                        Text(Self.markdown(message.text))
                            .foregroundStyle(.white.opacity(0.92))
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        if message.isComplete {
                            Text(message.usages.costText)
                                .font(small)
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
            .font(.system(size: fontSize - 1, design: .monospaced))
            .foregroundStyle(.white.opacity(0.55))
            .help(String(message.text.prefix(1500)))
        }
    }

    /// Negritas, cursivas, código y links; conserva los saltos de línea.
    static func markdown(_ text: String) -> AttributedString {
        let options = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        return (try? AttributedString(markdown: text, options: options)) ?? AttributedString(text)
    }
}
