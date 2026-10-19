import SwiftUI

/// Contenido del notch expandido: encabezado, conversación y campo de texto.
struct ChatView: View {
    @ObservedObject var chat: ChatSession
    /// Alto de la franja superior (barra de menú o notch físico); ahí va el encabezado.
    let topInset: CGFloat

    @AppStorage(DeepSeekClient.modelDefaultsKey) private var model = DeepSeekClient.defaultModel

    var body: some View {
        VStack(spacing: 10) {
            header
                .frame(height: topInset)
            if chat.hasAPIKey {
                conversation
            } else {
                missingKey
            }
            inputBar
        }
        .padding(.horizontal, 16)
        .padding(.bottom, 14)
        .foregroundStyle(.white)
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
        let canPress = chat.isStreaming || !isEmpty

        return HStack(spacing: 8) {
            TextField("Preguntale a DeepSeek…", text: $chat.input)
                .textFieldStyle(.plain)
                .font(.system(size: 13))
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
        .padding(.leading, 14)
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
            Text(message.text)
                .padding(.horizontal, 12)
                .padding(.vertical, 7)
                .background(AITheme.accent, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
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
                    Text(Self.markdown(message.text))
                        .foregroundStyle(.white.opacity(0.92))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
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
