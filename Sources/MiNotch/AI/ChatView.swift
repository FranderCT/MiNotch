import SwiftUI

/// Contenido del notch expandido: encabezado, conversación y campo de texto.
struct ChatView: View {
    @ObservedObject var chat: ChatSession
    /// Alto de la franja superior (barra de menú o notch físico); ahí va el encabezado.
    let topInset: CGFloat

    @AppStorage(DeepSeekClient.modelDefaultsKey) private var model = DeepSeekClient.defaultModel
    @FocusState private var isInputFocused: Bool

    var body: some View {
        VStack(spacing: 10) {
            header
                .frame(height: topInset)
            if chat.hasAPIKey {
                balanceBar
                conversation
            } else {
                missingKey
            }
            if let screenText = chat.screenContext {
                ScreenTextChip(text: screenText, onRemove: chat.discardScreenContext)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            inputBar
        }
        .padding(.horizontal, 16)
        .padding(.bottom, 14)
        .foregroundStyle(.white)
        .onAppear {
            chat.refreshBalanceIfNeeded()
            // Recién capturado: listo para escribir la pregunta.
            if chat.screenContext != nil { isInputFocused = true }
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

    @ViewBuilder
    private var conversation: some View {
        if chat.messages.isEmpty && chat.errorMessage == nil {
            emptyState
        } else {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 10) {
                        ForEach(chat.messages) { message in
                            MessageRow(message: message, isStreaming: chat.isStreaming)
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
                .onChange(of: chat.messages.last?.text) {
                    if let id = chat.messages.last?.id {
                        proxy.scrollTo(id, anchor: .bottom)
                    }
                }
            }
            .frame(maxHeight: .infinity)
        }
    }

    private var balanceBar: some View {
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
        .font(.system(size: 10, weight: .medium))
        .foregroundStyle(.white.opacity(0.65))
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
            Text("Escribí abajo y apretá Enter")
                .font(.system(size: 11))
                .foregroundStyle(.white.opacity(0.5))
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
        let hasScreenText = chat.screenContext != nil
        let canPress = chat.isStreaming || !isEmpty || hasScreenText

        return HStack(spacing: 8) {
            Button(action: chat.captureScreen) {
                Image(systemName: "text.viewfinder")
                    .font(.system(size: 13))
                    .foregroundStyle(.white.opacity(0.75))
            }
            .buttonStyle(.plain)
            .disabled(!chat.hasAPIKey || chat.isStreaming || chat.isCapturing)
            .help("Preguntar sobre la pantalla: elegí una zona y extraigo su texto")
            .accessibilityLabel("Preguntar sobre la pantalla")

            TextField(hasScreenText ? "¿Qué querés saber? (Enter = explicar)" : "Preguntale a DeepSeek…", text: $chat.input)
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
    let isStreaming: Bool

    var body: some View {
        switch message.role {
        case .user:
            VStack(alignment: .trailing, spacing: 4) {
                if let screenText = message.screenText {
                    ScreenTextChip(text: screenText)
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
                if message.text.isEmpty && isStreaming {
                    TypingDots()
                } else {
                    VStack(alignment: .leading, spacing: 5) {
                        Text(Self.markdown(message.text))
                            .foregroundStyle(.white.opacity(0.92))
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        if let usage = message.usage {
                            Text(usage.costText)
                                .font(.system(size: 10))
                                .foregroundStyle(.white.opacity(0.5))
                                .help(usage.details)
                        } else if message.isComplete {
                            Text("Costo no disponible")
                                .font(.system(size: 10))
                                .foregroundStyle(.white.opacity(0.5))
                                .help("DeepSeek no devolvió el consumo de esta consulta; puede ocurrir al detenerla o perder la conexión.")
                        }
                    }
                }
            }
        }
    }

    /// Negritas, cursivas, código y links; conserva los saltos de línea.
    private static func markdown(_ text: String) -> AttributedString {
        let options = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        return (try? AttributedString(markdown: text, options: options)) ?? AttributedString(text)
    }
}

/// Texto de pantalla adjunto a una pregunta: muestra el comienzo y el tooltip, un fragmento más largo.
private struct ScreenTextChip: View {
    let text: String
    /// Solo en el chip pendiente de enviar: quita el texto adjunto.
    var onRemove: (() -> Void)?

    private var preview: String {
        text.split(whereSeparator: \.isNewline).first.map(String.init) ?? text
    }

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: "text.viewfinder")
                .foregroundStyle(AITheme.accent)
            Text("“\(preview)”")
                .lineLimit(1)
                .truncationMode(.tail)
            if let onRemove {
                Button(action: onRemove) {
                    Image(systemName: "xmark")
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Quitar texto de pantalla")
            }
        }
        .font(.system(size: 10, weight: .medium))
        .foregroundStyle(.white.opacity(0.75))
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(.white.opacity(0.08), in: Capsule())
        .help("Texto de pantalla (\(text.count) caracteres):\n\(text.prefix(600))")
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
