import AppKit
import SwiftUI

/// Ventana de configuración: API key (en el Llavero) y modelo.
@MainActor
final class SettingsWindowController {
    private let account: DeepSeekAccount
    private var window: NSWindow?

    init(account: DeepSeekAccount) {
        self.account = account
    }

    func show() {
        if window == nil {
            let hosting = NSHostingView(rootView: SettingsView(account: account, draft: KeyDraft()))
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
    @ObservedObject var account: DeepSeekAccount
    @ObservedObject var draft: KeyDraft
    @AppStorage(DeepSeekClient.modelDefaultsKey) private var model = DeepSeekClient.defaultModel
    @AppStorage(InterfaceMode.defaultsKey) private var interfaceMode = InterfaceMode.notch

    var body: some View {
        Form {
            Section {
                LabeledContent("Estado") {
                    Text(account.hasAPIKey ? "API key guardada en el Llavero" : "Sin API key")
                        .foregroundStyle(account.hasAPIKey ? .green : .secondary)
                }
                SecureField(account.hasAPIKey ? "Reemplazar API key" : "API key", text: $draft.text)
                    .onSubmit(save)
                HStack {
                    Link("Obtener una API key", destination: URL(string: "https://platform.deepseek.com/api_keys")!)
                        .font(.footnote)
                    Spacer()
                    if account.hasAPIKey {
                        Button("Borrar", role: .destructive) { account.deleteAPIKey() }
                    }
                    Button("Guardar", action: save)
                        .keyboardShortcut(.defaultAction)
                        .disabled(draft.text.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            } header: {
                Text("DeepSeek")
            }

            Section("Saldo de la cuenta") {
                LabeledContent("Disponible", value: account.balance?.summary ?? "Sin consultar")
                if let error = account.balanceError {
                    Text(error).font(.footnote).foregroundStyle(.red)
                }
                Button(account.isRefreshingBalance ? "Actualizando…" : "Actualizar saldo", action: account.refreshBalance)
                    .disabled(!account.hasAPIKey || account.isRefreshingBalance)
                Link("Ver consumo y recargar", destination: URL(string: "https://platform.deepseek.com/usage")!)
                    .font(.footnote)
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

            Section {
                Picker("Mostrar en", selection: $interfaceMode) {
                    ForEach(InterfaceMode.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
            } header: {
                Text("Interfaz")
            } footer: {
                Text("La ventana es una ventana normal de macOS (Dock y ⌘Tab) con las mismas pestañas que el notch. Con las dos, comparten pestañas y conversaciones.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(width: 440)
        .fixedSize()
        .onAppear { account.refreshBalanceIfNeeded() }
    }

    private func save() {
        account.saveAPIKey(draft.text)
        draft.text = ""
    }
}
