import AppKit
import SwiftUI

/// Preferencias por categoría, compartidas entre notch y ventana.
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
    @AppStorage("terminalFontSize") private var terminalFontSize = 12.0
    @AppStorage(LocalDiagnostics.enabledKey) private var diagnosticsEnabled = false
    @ObservedObject private var diagnostics = LocalDiagnostics.shared

    var body: some View {
        TabView {
            accountSettings.tabItem { Label("Cuenta", systemImage: "person.crop.circle") }
            interfaceSettings.tabItem { Label("Apariencia", systemImage: "macwindow") }
            terminalSettings.tabItem { Label("Terminal", systemImage: "terminal") }
            agentSettings.tabItem { Label("Agentes", systemImage: "cpu") }
            shortcuts.tabItem { Label("Atajos", systemImage: "keyboard") }
            privacySettings.tabItem { Label("Privacidad", systemImage: "hand.raised") }
        }
        .padding(12)
        .frame(width: 580, height: 520)
        .onAppear { account.refreshBalanceIfNeeded() }
    }

    private var accountSettings: some View {
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

        }
        .formStyle(.grouped)
    }

    private var interfaceSettings: some View {
        Form {
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
    }

    private var terminalSettings: some View {
        Form {
            Section("Texto") {
                Slider(value: $terminalFontSize, in: 10...24, step: 1) {
                    Text("Tamaño: \(Int(terminalFontSize)) pt")
                }
            }
            Section("Estado de los comandos") {
                Text("La terminal local informa cuándo empieza y termina cada comando y su código de salida. En SSH, otros shells o aplicaciones interactivas, el estado corresponde al proceso local hasta que vuelve el prompt.")
                    .font(.callout)
            }
            Section("Abrir proyectos") {
                Text("Desde Finder: seleccioná una carpeta y elegí Servicios → Abrir carpeta en MiNotch. También podés copiar su enlace desde el menú de la carpeta en MiNotch.")
                    .font(.callout)
            }
        }
        .formStyle(.grouped)
    }

    private var agentSettings: some View {
        Form {
            Section("Aprobaciones") {
                Picker("Antes de modificar o ejecutar", selection: $account.approvalMode) {
                    ForEach(ApprovalMode.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                Text("El acceso total de un agente externo siempre requiere aprobación.").font(.footnote)
            }
            Section("Actividad") {
                Text("Los trabajos muestran los eventos que entrega cada CLI: herramientas, ejecución y errores. Grok conserva su formato de respuesta final.")
                Text("Hasta \(ExternalAgents.maxRunning) trabajos simultáneos por pestaña. Podés detenerlos desde su actividad o desde el menú de agentes.")
            }
        }
        .formStyle(.grouped)
    }

    private var shortcuts: some View {
        Form {
            Section("Pestañas y ventanas") {
                LabeledContent("Nueva pestaña", value: "⌘T")
                LabeledContent("Cerrar pestaña o ventana", value: "⌘W")
                LabeledContent("Siguiente / anterior", value: "⌘] / ⌘[")
                LabeledContent("Seleccionar pestaña", value: "⌘1…⌘8")
                LabeledContent("Agente / Terminal", value: "⌘E")
                LabeledContent("Mostrar barra lateral", value: "⌃⌘S")
                LabeledContent("Abrir ventana", value: "⌘0")
                LabeledContent("Configuración", value: "⌘,")
            }
            Text("Los atajos de pestañas funcionan cuando MiNotch tiene el foco.").font(.footnote)
        }
        .formStyle(.grouped)
    }

    private var privacySettings: some View {
        Form {
            Section("Credenciales y contenido") {
                Text("La API key se guarda en el Llavero. Los mensajes y resultados de herramientas se envían al proveedor del asistente; cada CLI externo usa su propia cuenta y configuración.")
                    .font(.callout)
            }
            Section("Diagnóstico local") {
                Toggle("Activar diagnóstico local", isOn: $diagnosticsEnabled)
                    .onChange(of: diagnosticsEnabled) { if !diagnosticsEnabled { diagnostics.clear() } }
                Text("Hasta 200 eventos en memoria: respuesta de la cola principal al abrir el notch, duración y fallos de agentes, y códigos de salida del shell. No incluye comandos, rutas, conversaciones ni claves. La preferencia se recuerda; los eventos se borran al cerrar la app.")
                    .font(.footnote)
                LabeledContent("Eventos registrados", value: "\(diagnostics.entries.count)")
                HStack {
                    Button("Copiar diagnóstico") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(diagnostics.report, forType: .string)
                    }
                    Button("Borrar", action: diagnostics.clear)
                }
                .disabled(diagnostics.entries.isEmpty)
            }
        }
        .formStyle(.grouped)
    }

    private func save() {
        account.saveAPIKey(draft.text)
        draft.text = ""
    }
}
