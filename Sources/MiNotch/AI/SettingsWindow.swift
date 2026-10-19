import AppKit
import SwiftUI

/// Ventana de configuración: API key (en el Llavero) y modelo.
@MainActor
final class SettingsWindowController {
    private let chat: ChatSession
    private var window: NSWindow?

    init(chat: ChatSession) {
        self.chat = chat
    }

    func show() {
        if window == nil {
            let hosting = NSHostingView(rootView: SettingsView(chat: chat, draft: KeyDraft()))
            let window = NSWindow(
                contentRect: NSRect(origin: .zero, size: hosting.fittingSize),
                styleMask: [.titled, .closable],
                backing: .buffered,
                defer: false
            )
            window.title = "MiNotch — Configuración"
            window.contentView = hosting
            window.isReleasedWhenClosed = false
            window.center()
            self.window = window
        }
        NSApp.activate()
        window?.makeKeyAndOrderFront(nil)
    }
}

/// Texto escrito en el campo de la key (las Command Line Tools no incluyen la macro `@State`).
private final class KeyDraft: ObservableObject {
    @Published var text = ""
}

private struct SettingsView: View {
    @ObservedObject var chat: ChatSession
    @ObservedObject var draft: KeyDraft
    @AppStorage(DeepSeekClient.modelDefaultsKey) private var model = DeepSeekClient.defaultModel

    var body: some View {
        Form {
            Section {
                LabeledContent("Estado") {
                    Text(chat.hasAPIKey ? "API key guardada en el Llavero" : "Sin API key")
                        .foregroundStyle(chat.hasAPIKey ? .green : .secondary)
                }
                SecureField(chat.hasAPIKey ? "Reemplazar API key" : "API key", text: $draft.text)
                    .onSubmit(save)
                HStack {
                    Link("Obtener una API key", destination: URL(string: "https://platform.deepseek.com/api_keys")!)
                        .font(.footnote)
                    Spacer()
                    if chat.hasAPIKey {
                        Button("Borrar", role: .destructive) { chat.deleteAPIKey() }
                    }
                    Button("Guardar", action: save)
                        .keyboardShortcut(.defaultAction)
                        .disabled(draft.text.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            } header: {
                Text("DeepSeek")
            }

            Section {
                Picker("Modelo", selection: $model) {
                    ForEach(DeepSeekClient.models, id: \.self) { Text($0) }
                }
            } footer: {
                Text("deepseek-flash es rápido y barato; deepseek-v4-pro es más capaz.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(width: 440)
        .fixedSize()
    }

    private func save() {
        chat.saveAPIKey(draft.text)
        draft.text = ""
    }
}
