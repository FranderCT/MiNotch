import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// Contenido del notch expandido: encabezado, conversación y campo de texto.
struct ChatView: View {
    @ObservedObject var tabs: ChatTabs
    /// La pestaña seleccionada.
    @ObservedObject var chat: ChatSession
    @ObservedObject var account: DeepSeekAccount
    @ObservedObject var workspace: Workspace
    @ObservedObject var terminals: TerminalSessions
    @ObservedObject var agents: ExternalAgents
    /// Alto de la franja superior (barra de menú o notch físico); ahí va el encabezado.
    let topInset: CGFloat
    /// En el notch: botón para abrir la ventana. En la ventana no hace falta.
    var showsWindowButton = true

    @AppStorage(DeepSeekClient.modelDefaultsKey) private var model = DeepSeekClient.defaultModel
    @FocusState private var isInputFocused: Bool
    /// Una imagen arrastrada está sobre el notch. Vive en NotchState: las Command Line Tools no incluyen la macro `@State`.
    @Binding var isDropTargeted: Bool

    var body: some View {
        VStack(spacing: 10) {
            header
                .frame(height: topInset)
            tabStrip
            statusBar
            if chat.mode == .terminal {
                // La terminal no necesita API key: es un shell local.
                TerminalHost(shell: chat.shell, directory: workspace.directory)
                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            } else if account.hasAPIKey {
                conversation
            } else {
                missingKey
            }
            if let other = tabs.needingAttention.first(where: { $0.id != chat.id }) {
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
                        .frame(maxWidth: .infinity, alignment: .leading)
                } else if let imageText = chat.imageText {
                    ImageTextChip(text: imageText, wasTrimmed: chat.imageTextWasTrimmed, onRemove: chat.discardImageText)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                inputBar
            }
        }
        .padding(.horizontal, 16)
        .padding(.bottom, 14)
        .foregroundStyle(.white)
        .overlay {
            if isDropTargeted {
                DropHint()
            }
        }
        .onDrop(of: [.fileURL, .image], isTargeted: $isDropTargeted) { ImageAttachment.handleDrop($0, into: chat) }
        .onAppear {
            account.refreshBalanceIfNeeded()
            // La rama pudo cambiar desde otra terminal mientras el notch estaba cerrado.
            workspace.refreshGit()
        }
        .onChange(of: chat.isReadingImage) {
            // Recién adjuntada: listo para escribir la pregunta.
            if chat.isReadingImage { isInputFocused = true }
        }
    }

    // MARK: - Secciones

    /// Extremos izquierdo y derecho: en la MacBook quedan a los lados del notch físico.
    private var header: some View {
        HStack(spacing: 6) {
            ModeSwitch(chat: chat)

            Spacer()

            Text(model.replacingOccurrences(of: "deepseek-", with: ""))
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(.white.opacity(0.7))
                .padding(.horizontal, 7)
                .padding(.vertical, 2)
                .background(.white.opacity(0.08), in: Capsule())
            Button(action: chat.clear) {
                Image(systemName: "trash")
                    .font(.system(size: 11))
                    .foregroundStyle(.white.opacity(0.7))
            }
            .buttonStyle(.plain)
            .disabled(chat.messages.isEmpty)
            .opacity(chat.messages.isEmpty ? 0.3 : 1)
            .help("Borrar la conversación de esta pestaña")
            if showsWindowButton {
                headerButton("macwindow", help: "Abrir en una ventana (⌘0)", action: tabs.openWindow)
            }
            headerButton("gearshape", help: "Configuración: API key, modelo y dónde se muestra MiNotch", action: account.openSettings)
        }
        .padding(.horizontal, 6)
    }

    private func headerButton(_ icon: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 11))
                .foregroundStyle(.white.opacity(0.7))
        }
        .buttonStyle(.plain)
        .help(help)
        .accessibilityLabel(help)
    }

    /// Sin los pasos del asistente que solo pidieron herramientas: esas se ven como filas propias.
    private var visibleMessages: [ChatMessage] {
        chat.messages.filter { message in
            message.role != .assistant || !message.text.isEmpty
                || (chat.isStreaming && message.id == chat.messages.last?.id)
        }
    }

    @ViewBuilder
    private var conversation: some View {
        if chat.messages.isEmpty && chat.errorMessage == nil {
            emptyState
        } else {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 10) {
                        ForEach(visibleMessages) { message in
                            MessageRow(message: message, isActive: chat.isStreaming && message.id == chat.messages.last?.id)
                                .id(message.id)
                        }
                        if let error = chat.errorMessage {
                            ErrorRow(text: error)
                        }
                    }
                    .font(.system(size: 13))
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .scrollIndicators(.never)
                .onChange(of: "\(chat.messages.count)\(chat.messages.last?.text.count ?? 0)") {
                    if let id = visibleMessages.last?.id {
                        proxy.scrollTo(id, anchor: .bottom)
                    }
                }
            }
            .frame(maxHeight: .infinity)
        }
    }

    /// Pestañas, como en una terminal: cada una con su conversación y su carpeta.
    private var tabStrip: some View {
        HStack(spacing: 6) {
            ScrollView(.horizontal) {
                HStack(spacing: 4) {
                    ForEach(tabs.tabs) { tab in
                        TabChip(
                            tab: tab,
                            workspace: tab.workspace,
                            isSelected: tab.id == tabs.selectedID,
                            onSelect: { tabs.select(tab.id) },
                            onClose: { tabs.close(tab.id) }
                        )
                    }
                }
            }
            .scrollIndicators(.never)
            Button(action: tabs.newTab) {
                Image(systemName: "plus")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.75))
            }
            .buttonStyle(.plain)
            .disabled(!tabs.canAddTab)
            .help(tabs.canAddTab ? "Nueva pestaña en la misma carpeta (⌘T)" : "Máximo \(ChatTabs.maxTabs) pestañas")
            .accessibilityLabel("Nueva pestaña")
        }
    }

    /// Carpeta de trabajo (con menú para cambiarla), rama de git y saldo de DeepSeek.
    private var statusBar: some View {
        HStack(spacing: 10) {
            DirectoryMenu(workspace: workspace, isDisabled: chat.isStreaming)
            if let git = workspace.git {
                GitBadge(git: git)
            }
            if !terminals.sessions.isEmpty {
                TerminalsMenu(terminals: terminals)
            }
            if !agents.jobs.isEmpty {
                AgentsMenu(agents: agents)
            }
            ApprovalModeMenu(account: account)
            Spacer(minLength: 0)
            BalanceView(account: account)
        }
        .font(.system(size: 10, weight: .medium))
        .foregroundStyle(.white.opacity(0.65))
    }

    private var emptyState: some View {
        VStack(spacing: 6) {
            Image(systemName: "sparkles")
                .font(.system(size: 26, weight: .medium))
                .foregroundStyle(AITheme.accent)
            Text("¿En qué te ayudo?")
                .font(.system(size: 15, weight: .semibold))
            Text("Trabajo en \(workspace.directory.lastPathComponent): leo, creo y edito archivos y ejecuto comandos (con tu aprobación).")
                .font(.system(size: 11))
                .foregroundStyle(.white.opacity(0.5))
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var missingKey: some View {
        VStack(spacing: 10) {
            Image(systemName: "key.fill")
                .font(.system(size: 22))
                .foregroundStyle(AITheme.accent)
            Text("Falta tu API key de DeepSeek")
                .font(.system(size: 13, weight: .medium))
            Button(action: account.openSettings) {
                Text("Configurar API key")
                    .font(.system(size: 12, weight: .semibold))
                    .padding(.horizontal, 14)
                    .padding(.vertical, 6)
                    .background(AITheme.accent, in: Capsule())
            }
            .buttonStyle(.plain)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var inputBar: some View {
        let isEmpty = chat.input.trimmingCharacters(in: .whitespaces).isEmpty
        let hasImage = chat.imageText != nil || chat.isReadingImage
        let canPress = chat.isStreaming || (!chat.isReadingImage && (!isEmpty || hasImage))

        return HStack(spacing: 8) {
            Button { ImageAttachment.pick(into: chat) } label: {
                Image(systemName: "photo.badge.plus")
                    .font(.system(size: 13))
                    .foregroundStyle(.white.opacity(0.75))
            }
            .buttonStyle(.plain)
            .disabled(!account.hasAPIKey || chat.isReadingImage)
            .help("Adjuntar una imagen (o arrastrala acá, o pegala con ⌘V): extraigo su texto")
            .accessibilityLabel("Adjuntar imagen")

            TextField(hasImage ? "¿Qué querés saber de la imagen? (Enter = explicar)" : "Pedile algo a DeepSeek…", text: $chat.input)
                .textFieldStyle(.plain)
                .font(.system(size: 13))
                .focused($isInputFocused)
                .onSubmit { chat.send() }
                .disabled(!account.hasAPIKey)

            Button {
                chat.isStreaming ? chat.stop() : chat.send()
            } label: {
                Image(systemName: chat.isStreaming ? "stop.fill" : "arrow.up")
                    .font(.system(size: 11, weight: .bold))
                    .frame(width: 26, height: 26)
                    .background(AITheme.accent, in: Circle())
            }
            .buttonStyle(.plain)
            .disabled(!canPress)
            .opacity(canPress ? 1 : 0.35)
        }
        .padding(.leading, 10)
        .padding(.trailing, 5)
        .padding(.vertical, 5)
        .background(.white.opacity(0.06), in: Capsule())
        .overlay(
            Capsule()
                .strokeBorder(AITheme.accent, lineWidth: 1)
                .opacity(0.55)
        )
    }
}

struct MessageRow: View {
    let message: ChatMessage
    /// Es el último mensaje y la respuesta sigue en curso.
    let isActive: Bool

    var body: some View {
        switch message.role {
        case .user:
            VStack(alignment: .trailing, spacing: 4) {
                if let fromTab = message.fromTab {
                    Label("Tarea de la pestaña \(fromTab)", systemImage: "arrow.down.left.square")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(.white.opacity(0.6))
                }
                if let imageText = message.imageText {
                    ImageTextChip(text: imageText)
                }
                Text(message.text)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 7)
                    .background(AITheme.accent, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            }
            .frame(maxWidth: 340, alignment: .trailing)
            .frame(maxWidth: .infinity, alignment: .trailing)
        case .assistant:
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: "sparkles")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(AITheme.accent)
                    .padding(.top, 2)
                if message.text.isEmpty && isActive {
                    TypingDots()
                } else if !message.text.isEmpty {
                    VStack(alignment: .leading, spacing: 5) {
                        Text(Self.markdown(message.text))
                            .foregroundStyle(.white.opacity(0.92))
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        if message.isComplete {
                            Text(message.usages.costText)
                                .font(.system(size: 10))
                                .foregroundStyle(.white.opacity(0.5))
                                .help(message.usages.details)
                        }
                    }
                }
            }
        case .tool:
            ToolRow(message: message)
        }
    }

    /// Negritas, cursivas, código y links; conserva los saltos de línea.
    static func markdown(_ text: String) -> AttributedString {
        let options = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        return (try? AttributedString(markdown: text, options: options)) ?? AttributedString(text)
    }
}

/// Texto de una imagen adjunta a una pregunta: muestra el comienzo y el tooltip, un fragmento más largo.
struct ImageTextChip: View {
    let text: String
    var wasTrimmed = false
    /// Solo en el chip pendiente de enviar: quita el texto adjunto.
    var onRemove: (() -> Void)?

    private var preview: String {
        text.split(whereSeparator: \.isNewline).first.map(String.init) ?? text
    }

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: "photo")
                .foregroundStyle(AITheme.accent)
            Text("“\(preview)”")
                .lineLimit(1)
                .truncationMode(.tail)
            if wasTrimmed {
                Text("· recortado")
                    .foregroundStyle(AITheme.pink)
                    .fixedSize()
                    .help("La imagen superaba \(ChatSession.imageTextLimit.formatted()) caracteres de texto: solo se envía el comienzo.")
            }
            if let onRemove {
                Button(action: onRemove) {
                    Image(systemName: "xmark")
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Quitar imagen adjunta")
            }
        }
        .font(.system(size: 10, weight: .medium))
        .foregroundStyle(.white.opacity(0.75))
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(.white.opacity(0.08), in: Capsule())
        .help("Texto de la imagen (\(text.count) caracteres):\n\(text.prefix(600))")
    }
}

/// Mientras Vision extrae el texto (la primera vez en el sistema puede tardar un rato).
struct ReadingImageChip: View {
    var body: some View {
        HStack(spacing: 6) {
            ProgressView()
                .controlSize(.mini)
            Text("Leyendo texto de la imagen…")
        }
        .font(.system(size: 10, weight: .medium))
        .foregroundStyle(.white.opacity(0.75))
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(.white.opacity(0.08), in: Capsule())
    }
}

/// Aviso mientras se arrastra una imagen sobre el notch.
struct DropHint: View {
    var body: some View {
        RoundedRectangle(cornerRadius: 18, style: .continuous)
            .strokeBorder(AITheme.accent, style: StrokeStyle(lineWidth: 1.5, dash: [6, 4]))
            .background(.black.opacity(0.75), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            .overlay {
                Label("Soltá la imagen para leer su texto", systemImage: "photo.badge.plus")
                    .font(.system(size: 13, weight: .semibold))
            }
            .padding(.horizontal, 8)
            .padding(.bottom, 8)
            .allowsHitTesting(false)
    }
}

/// Una herramienta que usó el asistente: una línea; el tooltip muestra el resultado.
private struct ToolRow: View {
    let message: ChatMessage

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: message.toolName.flatMap(AgentTool.init(rawValue:))?.icon ?? "wrench")
                .frame(width: 14)
            Text(message.toolSummary ?? message.toolName ?? "")
                .lineLimit(1)
                .truncationMode(.middle)
            if message.toolFailed {
                Image(systemName: "xmark.circle.fill")
                    .foregroundStyle(AITheme.pink)
            }
        }
        .font(.system(size: 11, design: .monospaced))
        .foregroundStyle(.white.opacity(0.55))
        .padding(.leading, 19)
        .help(String(message.text.prefix(1500)))
    }
}

/// Acción del asistente que espera aprobación: qué quiere hacer, el detalle y los botones.
struct ApprovalCard: View {
    let approval: ToolApproval
    let onDecide: (Bool) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let reason = approval.riskReason {
                Label("Parece riesgoso (\(reason)): se pregunta aunque esté en automático.", systemImage: "exclamationmark.triangle.fill")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(AITheme.pink)
                    .lineLimit(2)
            }
            HStack(spacing: 6) {
                Image(systemName: approval.icon)
                    .foregroundStyle(AITheme.accent)
                Text(approval.title)
                    .font(.system(size: 12, weight: .semibold))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 0)
                Button("Rechazar") { onDecide(false) }
                    .buttonStyle(.plain)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.white.opacity(0.75))
                Button { onDecide(true) } label: {
                    Text("Aprobar")
                        .font(.system(size: 11, weight: .semibold))
                        .padding(.horizontal, 10)
                        .padding(.vertical, 3)
                        .background(AITheme.accent, in: Capsule())
                }
                .buttonStyle(.plain)
            }
            if !approval.detail.isEmpty {
                ScrollView {
                    Text(approval.detail)
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(.white.opacity(0.8))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: 64)
                .padding(6)
                .background(.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            }
        }
        .padding(8)
        .background(.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(AITheme.accent, lineWidth: 1)
                .opacity(0.6)
        )
    }
}

/// La terminal de la pestaña (SwiftTerm). La vista vive en TabShell: cambiar de modo o de pestaña no la cierra.
struct TerminalHost: NSViewRepresentable {
    let shell: TabShell
    let directory: URL

    func makeNSView(context: Context) -> TerminalContainer {
        shell.startIfNeeded(in: directory)
        let container = TerminalContainer()
        shell.attach(to: container)
        return container
    }

    func updateNSView(_ container: TerminalContainer, context: Context) {}

    func makeCoordinator() -> TabShell { shell }

    /// El shell es de la pestaña: si se cierra el notch, la terminal vuelve a la ventana (si está abierta).
    static func dismantleNSView(_ container: TerminalContainer, coordinator shell: TabShell) {
        shell.detach(from: container)
    }
}

/// Una pestaña: carpeta y estado (respondiendo, o esperando aprobación o contraseña).
private struct TabChip: View {
    @ObservedObject var tab: ChatSession
    @ObservedObject var workspace: Workspace
    let isSelected: Bool
    let onSelect: () -> Void
    let onClose: () -> Void

    var body: some View {
        HStack(spacing: 5) {
            if tab.needsAttention {
                Circle().fill(AITheme.pink).frame(width: 6, height: 6)
            } else if tab.isStreaming {
                Circle().fill(AITheme.cyan).frame(width: 6, height: 6)
            }
            Text("\(tab.number)")
                .foregroundStyle(.white.opacity(0.4))
            Text(tab.displayName)
                .lineLimit(1)
                .truncationMode(.middle)
            if isSelected {
                Button(action: onClose) {
                    Image(systemName: "xmark")
                        .font(.system(size: 8, weight: .bold))
                }
                .buttonStyle(.plain)
                .help("Cerrar pestaña (⌘W): corta la respuesta y cierra sus sesiones de terminal")
            }
        }
        .font(.system(size: 11, weight: isSelected ? .semibold : .regular))
        .foregroundStyle(.white.opacity(isSelected ? 0.95 : 0.6))
        .padding(.horizontal, 9)
        .padding(.vertical, 3)
        .frame(maxWidth: 150)
        .background(.white.opacity(isSelected ? 0.14 : 0.05), in: Capsule())
        .contentShape(Capsule())
        .onTapGesture(perform: onSelect)
        .help(tabHelp)
    }

    private var tabHelp: String {
        let state = tab.needsAttention ? "Esperando tu aprobación o contraseña" : tab.isStreaming ? "Respondiendo…" : nil
        return [workspace.displayPath, workspace.git.map { "⎇ \($0.branch)" }, state].compactMap { $0 }.joined(separator: "\n")
    }
}

/// Rama de git de la carpeta de trabajo; un punto si hay cambios sin commitear.
struct GitBadge: View {
    let git: GitInfo
    /// En la ventana: también las líneas +/−, como en una terminal.
    var showsDiffStat = false

    var body: some View {
        HStack(spacing: 3) {
            Image(systemName: "arrow.triangle.branch")
            Text(git.branch)
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(maxWidth: 110, alignment: .leading)
            if git.hasChanges == true {
                if showsDiffStat, git.insertions + git.deletions > 0 {
                    Text("+\(git.insertions)").foregroundStyle(Color.green.opacity(0.85))
                    Text("−\(git.deletions)").foregroundStyle(AITheme.pink)
                } else {
                    Circle().fill(AITheme.pink).frame(width: 5, height: 5)
                }
            }
        }
        .help(help)
    }

    private var help: String {
        let head = git.isDetached ? "HEAD separado en \(git.branch)" : "Rama \(git.branch)"
        let changes = switch git.hasChanges {
        case true?: "Hay cambios sin commitear (+\(git.insertions) −\(git.deletions) líneas)"
        case false?: "Sin cambios pendientes"
        case nil: "Revisando cambios…"
        }
        return "\(head)\n\(changes)\nRepositorio: \((git.root.path as NSString).abbreviatingWithTildeInPath)"
    }
}

struct ErrorRow: View {
    let text: String

    var body: some View {
        HStack(alignment: .top, spacing: 6) {
            Image(systemName: "exclamationmark.triangle.fill")
            Text(text)
        }
        .font(.system(size: 12))
        .foregroundStyle(AITheme.pink)
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(AITheme.pink.opacity(0.12), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }
}
