import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// Contenido del notch expandido: encabezado, conversación y campo de texto.
struct ChatView: View {
    @ObservedObject var chat: ChatSession
    @ObservedObject var workspace: Workspace
    /// Alto de la franja superior (barra de menú o notch físico); ahí va el encabezado.
    let topInset: CGFloat

    @AppStorage(DeepSeekClient.modelDefaultsKey) private var model = DeepSeekClient.defaultModel
    @FocusState private var isInputFocused: Bool
    /// Una imagen arrastrada está sobre el notch. Vive en NotchState: las Command Line Tools no incluyen la macro `@State`.
    @Binding var isDropTargeted: Bool

    var body: some View {
        VStack(spacing: 10) {
            header
                .frame(height: topInset)
            if chat.hasAPIKey {
                statusBar
                conversation
            } else {
                missingKey
            }
            if let approval = chat.pendingApproval {
                ApprovalCard(approval: approval, onDecide: chat.resolveApproval)
            }
            if chat.isReadingImage {
                ReadingImageChip()
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else if let imageText = chat.imageText {
                ImageTextChip(text: imageText, wasTrimmed: chat.imageTextWasTrimmed, onRemove: chat.discardImageText)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            inputBar
        }
        .padding(.horizontal, 16)
        .padding(.bottom, 14)
        .foregroundStyle(.white)
        .overlay {
            if isDropTargeted {
                DropHint()
            }
        }
        .onDrop(of: [.fileURL, .image], isTargeted: $isDropTargeted, perform: attachDroppedImage)
        .onAppear { chat.refreshBalanceIfNeeded() }
        .onChange(of: chat.isReadingImage) {
            // Recién adjuntada: listo para escribir la pregunta.
            if chat.isReadingImage { isInputFocused = true }
        }
    }

    // MARK: - Imagen adjunta

    /// La miniatura de una captura (⌘⇧4), un archivo de Finder o una imagen arrastrada desde otra app.
    private func attachDroppedImage(_ providers: [NSItemProvider]) -> Bool {
        guard let provider = providers.first else { return false }
        let chat = chat

        if provider.canLoadObject(ofClass: URL.self) {
            _ = provider.loadObject(ofClass: URL.self) { url, _ in
                guard let url else { return }
                Task { @MainActor in chat.attachImage(at: url) }
            }
        } else if provider.hasItemConformingToTypeIdentifier(UTType.image.identifier) {
            provider.loadDataRepresentation(forTypeIdentifier: UTType.image.identifier) { data, _ in
                let image = data.flatMap { ImageTextReader.image(from: $0) }
                Task { @MainActor in chat.attachImage(image) }
            }
        } else {
            return false
        }

        // Teclado listo para la pregunta: la píldora queda abierta mientras se escribe.
        NSApp.windows.first { $0 is NotchPanel && $0.frame.contains(NSEvent.mouseLocation) }?.makeKey()
        return true
    }

    private func pickImage() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        panel.message = "Elegí una imagen: extraigo su texto para preguntarle a DeepSeek."
        NSApp.activate()
        if panel.runModal() == .OK, let url = panel.url {
            chat.attachImage(at: url)
        }
    }

    // MARK: - Secciones

    /// Extremos izquierdo y derecho: en la MacBook quedan a los lados del notch físico.
    private var header: some View {
        HStack(spacing: 6) {
            Image(systemName: "sparkles")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(AITheme.accent)
            Text("DeepSeek")
                .font(.system(size: 12, weight: .semibold))

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
        }
        .padding(.horizontal, 6)
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

    /// Carpeta de trabajo (con menú para cambiarla) y saldo de DeepSeek.
    private var statusBar: some View {
        HStack(spacing: 10) {
            directoryMenu
            Spacer(minLength: 0)
            balance
        }
        .font(.system(size: 10, weight: .medium))
        .foregroundStyle(.white.opacity(0.65))
    }

    private var directoryMenu: some View {
        Menu {
            let others = workspace.recents.filter { $0.path != workspace.directory.path }
            ForEach(others, id: \.path) { url in
                Button((url.path as NSString).abbreviatingWithTildeInPath) { workspace.move(to: url) }
            }
            if !others.isEmpty { Divider() }
            Button("Elegir carpeta…", action: workspace.chooseDirectory)
            Button("Mostrar en Finder", action: workspace.revealInFinder)
        } label: {
            Label(workspace.directory.lastPathComponent, systemImage: "folder")
                .lineLimit(1)
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        // Cambiar de carpeta a mitad de una respuesta confundiría al asistente.
        .disabled(chat.isStreaming)
        .help("Carpeta de trabajo del asistente: \(workspace.displayPath)")
    }

    private var balance: some View {
        HStack(spacing: 6) {
            Image(systemName: "wallet.bifold")
            Text(chat.balance.map { "Saldo: \($0.summary)" } ?? (chat.isRefreshingBalance ? "Consultando saldo…" : "Saldo no disponible"))
                .lineLimit(1)
                .minimumScaleFactor(0.8)
            if chat.balanceError != nil {
                Image(systemName: "exclamationmark.triangle")
                    .foregroundStyle(AITheme.pink)
            }
            Spacer(minLength: 0)
            Button(action: chat.refreshBalance) {
                Image(systemName: "arrow.clockwise")
            }
            .buttonStyle(.plain)
            .disabled(chat.isRefreshingBalance)
            .accessibilityLabel("Actualizar saldo de DeepSeek")
        }
        .help(chat.balanceError.map { "No se pudo actualizar: \($0). El saldo mostrado puede estar desactualizado." }
              ?? "Saldo de tu cuenta DeepSeek. Se actualiza al abrir el chat y después de cada consulta.")
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
            Button(action: chat.openSettings) {
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
            Button(action: pickImage) {
                Image(systemName: "photo.badge.plus")
                    .font(.system(size: 13))
                    .foregroundStyle(.white.opacity(0.75))
            }
            .buttonStyle(.plain)
            .disabled(!chat.hasAPIKey || chat.isReadingImage)
            .help("Adjuntar una imagen (o arrastrala acá, o pegala con ⌘V): extraigo su texto")
            .accessibilityLabel("Adjuntar imagen")

            TextField(hasImage ? "¿Qué querés saber de la imagen? (Enter = explicar)" : "Pedile algo a DeepSeek…", text: $chat.input)
                .textFieldStyle(.plain)
                .font(.system(size: 13))
                .focused($isInputFocused)
                .onSubmit { chat.send() }
                .disabled(!chat.hasAPIKey)

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

private struct MessageRow: View {
    let message: ChatMessage
    /// Es el último mensaje y la respuesta sigue en curso.
    let isActive: Bool

    var body: some View {
        switch message.role {
        case .user:
            VStack(alignment: .trailing, spacing: 4) {
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
    private static func markdown(_ text: String) -> AttributedString {
        let options = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        return (try? AttributedString(markdown: text, options: options)) ?? AttributedString(text)
    }
}

/// Texto de una imagen adjunta a una pregunta: muestra el comienzo y el tooltip, un fragmento más largo.
private struct ImageTextChip: View {
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
private struct ReadingImageChip: View {
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
private struct DropHint: View {
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
private struct ApprovalCard: View {
    let approval: ToolApproval
    let onDecide: (Bool) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
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

private struct ErrorRow: View {
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
