import AppKit
import SwiftUI
import UniformTypeIdentifiers

// Controles que comparten el notch y la ventana principal.

/// Agente ⇄ Terminal (⌘E). Comparten el shell: lo que hagas en uno lo ve el otro.
struct ModeSwitch: View {
    @ObservedObject var chat: ChatSession
    /// En el notch solo el seleccionado muestra el nombre: al lado del notch físico hay poco lugar.
    var showsAllTitles = false

    var body: some View {
        HStack(spacing: 2) {
            button(.agent, icon: "sparkles", title: "Agente")
            button(.terminal, icon: "apple.terminal", title: "Terminal")
        }
        .padding(2)
        .background(.white.opacity(0.08), in: Capsule())
        .help("Agente o Terminal (⌘E). La terminal de la pestaña la comparten: el asistente la usa como sesión 0.")
    }

    private func button(_ mode: TabMode, icon: String, title: String) -> some View {
        let isSelected = chat.mode == mode
        return Button {
            if !isSelected { chat.toggleMode() }
        } label: {
            HStack(spacing: 4) {
                Image(systemName: icon)
                    .foregroundStyle(isSelected ? AnyShapeStyle(AITheme.accent) : AnyShapeStyle(.white.opacity(0.6)))
                if isSelected || showsAllTitles {
                    Text(title)
                }
            }
            .font(.system(size: 11, weight: .semibold))
            .padding(.horizontal, 7)
            .padding(.vertical, 2)
            .background(isSelected ? .white.opacity(0.12) : .clear, in: Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title)
    }
}

/// Carpeta de trabajo, con recientes, "Elegir carpeta…" y "Mostrar en Finder".
struct DirectoryMenu: View {
    @ObservedObject var workspace: Workspace
    /// Cambiar de carpeta a mitad de una respuesta confundiría al asistente.
    let isDisabled: Bool
    /// En la ventana: la ruta abreviada en vez de solo el nombre.
    var showsPath = false

    var body: some View {
        Menu {
            let others = workspace.recents.filter { $0.path != workspace.directory.path }
            ForEach(others, id: \.path) { url in
                Button((url.path as NSString).abbreviatingWithTildeInPath) { workspace.move(to: url) }
            }
            if !others.isEmpty { Divider() }
            Button("Elegir carpeta…", action: workspace.chooseDirectory)
            Button("Mostrar en Finder", action: workspace.revealInFinder)
            Button("Copiar enlace de esta carpeta") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(ProjectLink.url(for: workspace.directory).absoluteString, forType: .string)
            }
        } label: {
            Label(showsPath ? workspace.displayPath : workspace.directory.lastPathComponent, systemImage: "folder")
                .lineLimit(1)
                .truncationMode(.head)
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .disabled(isDisabled)
        .help("Carpeta de trabajo del asistente: \(workspace.displayPath)")
    }
}

/// Preguntar o Automático (con la red de seguridad para comandos peligrosos).
struct ApprovalModeMenu: View {
    @ObservedObject var account: DeepSeekAccount

    var body: some View {
        Menu {
            Picker("Aprobación", selection: $account.approvalMode) {
                ForEach(ApprovalMode.allCases, id: \.self) { mode in
                    Label(mode.title, systemImage: mode.icon).tag(mode)
                }
            }
            .pickerStyle(.inline)
        } label: {
            Label(account.approvalMode.title, systemImage: account.approvalMode.icon)
                .foregroundStyle(account.approvalMode == .auto ? AITheme.pink : .white.opacity(0.65))
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .help(account.approvalMode == .auto
              ? "Automático: escribe archivos y ejecuta comandos sin preguntar. Los comandos peligrosos (rm -rf, sudo, git push --force…) se preguntan igual."
              : "Preguntar: cada vez que quiera escribir, ejecutar o cambiar de carpeta, te pide aprobación.")
    }
}

/// Trabajos de agentes externos (Claude Code, Codex…): estado, copiar la respuesta o detenerlos.
struct AgentsMenu: View {
    @ObservedObject var agents: ExternalAgents

    var body: some View {
        let running = agents.jobs.filter(\.isRunning).count
        Menu {
            ForEach(agents.jobs, id: \.id) { job in
                Menu("\(job.id) · \(job.kind.displayName) · \(Self.statusText(job))") {
                    Text(job.task.prefix(80))
                    Text(job.latestActivity)
                    ForEach(job.activities.suffix(8)) { event in Text(event.text) }
                    if job.isRunning {
                        Button("Detener", action: job.stop)
                    } else if let result = job.result {
                        Button("Copiar respuesta") {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(result, forType: .string)
                        }
                    }
                }
            }
            Divider()
            Button("Quitar los terminados", action: agents.clearFinished)
                .disabled(running == agents.jobs.count)
        } label: {
            Label(running > 0 ? "\(running)" : "\(agents.jobs.count)", systemImage: running > 0 ? "cpu.fill" : "cpu")
                .foregroundStyle(running > 0 ? AnyShapeStyle(AITheme.cyan) : AnyShapeStyle(.white.opacity(0.65)))
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .help("Agentes externos: \(running) trabajando de \(agents.jobs.count)")
    }

    private static func statusText(_ job: ExternalAgentJob) -> String {
        switch job.status {
        case .running: "trabajando desde las \(job.startedAt.formatted(date: .omitted, time: .shortened))"
        case .finished: "terminó"
        case .failed: "falló"
        case .stopped: "detenido"
        }
    }
}

/// Actividad visible sin abrir el menú; los detalles y la detención pertenecen a cada trabajo.
struct AgentActivityRow: View {
    @ObservedObject var job: ExternalAgentJob

    var body: some View {
        DisclosureGroup {
            VStack(alignment: .leading, spacing: 4) {
                ForEach(job.activities.suffix(8)) { event in
                    Text(event.text)
                        .foregroundStyle(event.isError ? Color.red : Color.secondary)
                }
                if job.isRunning { Button("Detener", action: job.stop).buttonStyle(.borderless) }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        } label: {
            HStack(spacing: 6) {
                Image(systemName: job.isRunning ? "cpu" : "exclamationmark.circle")
                Text("\(job.kind.displayName) · \(job.latestActivity)")
                    .lineLimit(1)
            }
            .foregroundStyle(job.status == .failed ? Color.red : AITheme.cyan)
        }
        .font(.system(size: 10, design: .monospaced))
    }
}

struct ShellStatusView: View {
    @ObservedObject var shell: TabShell

    var body: some View {
        Text(shell.isRunning ? shell.commandState.summary : "Shell cerrado")
            .font(.system(size: 10, design: .monospaced))
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 10)
            .padding(.bottom, 4)
            .accessibilityLabel("Estado de terminal")
            .accessibilityValue(shell.commandState.summary)
    }
}

/// Sesiones de terminal abiertas por el asistente; desde acá se pueden cerrar.
struct TerminalsMenu: View {
    @ObservedObject var terminals: TerminalSessions

    var body: some View {
        Menu {
            ForEach(terminals.sessions, id: \.id) { session in
                Button("Cerrar \(session.id): \(session.command)\(session.isRunning ? "" : " (terminó)")") {
                    terminals.close(session.id)
                }
            }
            Divider()
            Button("Cerrar todas", action: terminals.closeAll)
        } label: {
            Label("\(terminals.sessions.count)", systemImage: "apple.terminal")
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .help(terminals.sessions.map { "\($0.id): \($0.command)" }.joined(separator: "\n"))
    }
}

/// Saldo de la cuenta DeepSeek, con botón para actualizarlo.
struct BalanceView: View {
    @ObservedObject var account: DeepSeekAccount

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "wallet.bifold")
            Text(account.balance.map(\.summary) ?? (account.isRefreshingBalance ? "Consultando…" : "Sin saldo"))
                .lineLimit(1)
                .minimumScaleFactor(0.8)
            if account.balanceError != nil {
                Image(systemName: "exclamationmark.triangle")
                    .foregroundStyle(AITheme.pink)
            }
            Button(action: account.refreshBalance) {
                Image(systemName: "arrow.clockwise")
            }
            .buttonStyle(.plain)
            .disabled(account.isRefreshingBalance)
            .accessibilityLabel("Actualizar saldo de DeepSeek")
        }
        .help(account.balanceError.map { "No se pudo actualizar: \($0). El saldo mostrado puede estar desactualizado." }
              ?? "Saldo de tu cuenta DeepSeek. Se actualiza al abrir el chat y después de cada consulta.")
    }
}

/// Otra pestaña espera una aprobación o contraseña: un clic lleva a ella.
struct AttentionBanner: View {
    let other: ChatSession
    let onSelect: () -> Void

    var body: some View {
        Button(action: onSelect) {
            HStack(spacing: 6) {
                Image(systemName: "exclamationmark.bubble.fill")
                Text("La pestaña \(other.number) (\(other.displayName)) \(other.statusText.replacingOccurrences(of: "esperando que el usuario", with: "espera que"))")
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 0)
                Text("Ver")
                    .font(.system(size: 11, weight: .semibold))
            }
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(AITheme.pink)
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(AITheme.pink.opacity(0.12), in: Capsule())
        }
        .buttonStyle(.plain)
    }
}

/// Pedido de contraseña de una sesión: la escribe el usuario y va directo a la terminal.
struct SecretCard: View {
    @ObservedObject var chat: ChatSession
    let request: SecretRequest
    @FocusState private var isFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: "lock.fill")
                    .foregroundStyle(AITheme.accent)
                Text("Sesión \(request.sessionID): \(request.prompt)")
                    .font(.system(size: 12, weight: .semibold))
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .help(request.command)
            }
            HStack(spacing: 8) {
                SecureField("Contraseña", text: $chat.secretInput)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12))
                    .focused($isFocused)
                    .onSubmit { chat.submitSecret(true) }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                Button("Cancelar") { chat.submitSecret(false) }
                    .buttonStyle(.plain)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.white.opacity(0.75))
                Button { chat.submitSecret(true) } label: {
                    Text("Enviar")
                        .font(.system(size: 11, weight: .semibold))
                        .padding(.horizontal, 10)
                        .padding(.vertical, 3)
                        .background(AITheme.accent, in: Capsule())
                }
                .buttonStyle(.plain)
            }
            Text("Va directo a la terminal: DeepSeek no la ve.")
                .font(.system(size: 10))
                .foregroundStyle(.white.opacity(0.5))
        }
        .padding(8)
        .background(.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(AITheme.accent, lineWidth: 1)
                .opacity(0.6)
        )
        .onAppear { isFocused = true }
    }
}

/// Adjuntar imágenes: soltarlas (miniatura de ⌘⇧4, Finder u otra app) o elegirlas de un archivo.
enum ImageAttachment {
    @MainActor
    static func handleDrop(_ providers: [NSItemProvider], into chat: ChatSession) -> Bool {
        guard let provider = providers.first else { return false }

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

        // En el notch: teclado listo para la pregunta (la píldora queda abierta mientras se escribe).
        NSApp.windows.first { $0 is NotchPanel && $0.frame.contains(NSEvent.mouseLocation) }?.makeKey()
        return true
    }

    @MainActor
    static func pick(into chat: ChatSession) {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        panel.message = "Elegí una imagen: extraigo su texto para preguntarle a DeepSeek."
        NSApp.activate()
        if panel.runModal() == .OK, let url = panel.url {
            chat.attachImage(at: url)
        }
    }
}
