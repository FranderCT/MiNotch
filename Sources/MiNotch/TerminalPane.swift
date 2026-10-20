import AppKit
import SwiftUI

// Modo Terminal con estilo de terminal moderna: los comandos terminados son bloques (comando + salida) en una
// lista; la terminal viva solo aparece mientras corre algo; abajo, los chips de carpeta y rama con el editor.

private let dim = Color.white.opacity(0.45)
private let dividerColor = Color.white.opacity(0.07)
private let commandGreen = Color(red: 0.65, green: 0.89, blue: 0.63)

struct TerminalPane: View {
    @ObservedObject var chat: ChatSession
    @ObservedObject var shell: TabShell
    @ObservedObject var blocks: BlockStore
    @ObservedObject var workspace: Workspace
    let style: ChatStyle

    @AppStorage("hideTerminalZeroState") private var hideZeroState = false
    @StateObject private var completion = CompletionController()

    private var directory: URL { shell.currentDirectory ?? workspace.directory }
    private var isRunning: Bool { shell.runningCommand != nil }

    var body: some View {
        VStack(spacing: 0) {
            // Zona de bloques; la terminal viva se superpone abajo mientras corre un comando.
            GeometryReader { geometry in
                ZStack(alignment: .bottom) {
                    blockList(bottomInset: isRunning && !shell.isAlternateScreen ? geometry.size.height * 0.5 : 0)
                        .opacity(shell.isAlternateScreen ? 0 : 1)
                    // Siempre en la jerarquía y con el mismo tamaño al correr o no: así el shell no ve cambios de
                    // ventana (SIGWINCH) entre un comando y otro. Con el prompt libre es invisible.
                    liveTerminal
                        .frame(height: shell.isAlternateScreen ? geometry.size.height : geometry.size.height * 0.5)
                        .opacity(isRunning || shell.isAlternateScreen ? 1 : 0)
                        .allowsHitTesting(isRunning || shell.isAlternateScreen)
                }
            }
            if !shell.isAlternateScreen {
                Rectangle().fill(dividerColor).frame(height: 1)
                promptArea
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityValue(shell.commandState.summary)
        .background(WindowReader { completion.hostWindow = $0 })
        .onAppear { completion.attach(shell: shell, directory: { directory }, recents: { workspace.recents }) }
        .onDisappear { completion.detach() }
        // Con el menú abierto, seguir escribiendo filtra las opciones.
        .onChange(of: shell.draft) { completion.refresh() }
        .onChange(of: shell.commandState.phase) { if shell.commandState.phase != .ready { completion.close() } }
    }

    // MARK: - Bloques

    private func blockList(bottomInset: CGFloat) -> some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    // Después de un `clear` no vuelve la bienvenida: ya se corrieron comandos.
                    if blocks.blocks.isEmpty && !isRunning && !hideZeroState && shell.commandState.completedCommands == 0 {
                        ZeroStateCard(style: style) { hideZeroState = true }
                            .padding(style.isNotch ? 10 : 16)
                    }
                    ForEach(blocks.blocks) { block in
                        BlockRow(
                            block: block,
                            isSelected: blocks.selectedID == block.id,
                            style: style,
                            canRerun: shell.commandState.phase == .ready && !block.command.contains("\n"),
                            onSelect: { blocks.selectedID = blocks.selectedID == block.id ? nil : block.id },
                            onToggleExpanded: { blocks.toggleExpanded(block.id) },
                            onRerun: { shell.rerun(block.command, in: directory) },
                            onAskAgent: { askAgent(about: block) }
                        )
                    }
                    if let running = shell.runningCommand {
                        RunningHeader(running: running, style: style)
                    }
                    Color.clear.frame(height: max(bottomInset, 1)).id("fondo")
                }
            }
            .scrollIndicators(style.isNotch ? .never : .automatic)
            // Al final cuando cambia la lista. Diferido: mover el scroll durante el layout lo dispara de nuevo.
            .onChange(of: blocks.blocks.count) { scrollToBottom(proxy) }
            .onChange(of: shell.runningCommand) { scrollToBottom(proxy) }
            .onAppear { scrollToBottom(proxy) }
        }
    }

    private func scrollToBottom(_ proxy: ScrollViewProxy) {
        DispatchQueue.main.async { proxy.scrollTo("fondo", anchor: .bottom) }
    }

    private var liveTerminal: some View {
        TerminalHost(shell: shell, directory: workspace.directory)
            .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
            .padding(.horizontal, style.isNotch ? 6 : 10)
            .padding(.vertical, style.isNotch ? 4 : 6)
    }

    // MARK: - Entrada

    private var promptArea: some View {
        VStack(alignment: .leading, spacing: 6) {
            PromptChips(shell: shell, workspace: workspace, style: style, onPickDirectory: completion.openDirectoryPicker)
            TerminalInputComposer(shell: shell, directory: workspace.directory, fontSize: style.fontSize)
            hintBar
        }
        .padding(.horizontal, style.isNotch ? 10 : 16)
        .padding(.top, 8)
        .padding(.bottom, style.isNotch ? 6 : 8)
        .overlay(alignment: .topLeading) {
            // Sobre el editor, sin mover el resto (así el shell no ve cambios de tamaño).
            if completion.isOpen {
                CompletionPopup(controller: completion, fontSize: style.fontSize)
                    .alignmentGuide(.top) { $0[.bottom] }
                    .padding(.leading, style.isNotch ? 26 : 34)
            }
        }
        .background(
            // Atajos sin botón visible: ⌘↵ manda lo escrito al agente; ⌘K limpia los bloques.
            ZStack {
                Button("Preguntar al agente", action: askAgentWithDraft)
                    .keyboardShortcut(.return, modifiers: .command)
                Button("Limpiar bloques") { blocks.clear() }
                    .keyboardShortcut("k", modifiers: .command)
            }
            .opacity(0)
            .frame(width: 0, height: 0)
        )
    }

    private var hintBar: some View {
        HStack(spacing: 12) {
            hint("⌘↵", "preguntar al agente")
            hint("↑↓", "historial")
            hint("⇥", "completar")
            hint("⌘K", "limpiar")
            Spacer(minLength: 0)
        }
        .font(.system(size: max(9, style.fontSize - 3), design: .monospaced))
        .foregroundStyle(dim)
    }

    private func hint(_ keys: String, _ text: String) -> some View {
        HStack(spacing: 4) {
            Text(keys).padding(.horizontal, 4).background(.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 3))
            Text(text)
        }
    }

    // MARK: - Agente

    private func askAgentWithDraft() {
        let text = shell.draft.trimmingCharacters(in: .whitespacesAndNewlines)
        shell.draft = ""
        chat.input = text
        chat.mode = .agent
        if !text.isEmpty { chat.send() }
    }

    /// Lleva un bloque al agente con su salida como contexto, sin enviarlo: queda listo para completar la pregunta.
    private func askAgent(about block: TerminalBlock) {
        var text = "Corrí este comando en la terminal"
        if let code = block.exitCode, code != 0 { text += " y falló (código \(code))" }
        text += ":\n$ \(block.command)\n"
        if !block.plainOutput.isEmpty { text += "\n```\n\(block.plainOutput.suffix(6_000))\n```\n" }
        text += block.failed ? "\n¿Qué falló y cómo lo arreglo?" : "\n"
        chat.input = text
        chat.mode = .agent
    }
}

// MARK: - Piezas

/// Tarjeta de bienvenida de una sesión nueva, con los atajos.
private struct ZeroStateCard: View {
    let style: ChatStyle
    let onDismiss: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Image(systemName: "apple.terminal")
                    .foregroundStyle(AITheme.accent)
                Text("Nueva sesión de terminal")
                    .font(.system(size: style.fontSize + 3, weight: .semibold))
                Spacer(minLength: 0)
                Button("No mostrar de nuevo", action: onDismiss)
                    .buttonStyle(.plain)
                    .font(.system(size: style.fontSize - 3))
                    .foregroundStyle(dim)
            }
            row("⌘↵", "preguntarle al agente con lo que escribiste")
            row("⌘E", "cambiar entre Agente y Terminal")
            row("↑ ⇥", "historial y sugerencias mientras escribes")
            row("⌃C", "cancelar el comando en curso")
            row("✦", "en cada bloque: copiar, repetir o preguntarle al agente")
        }
        .font(.system(size: style.fontSize - 1))
        .foregroundStyle(.white.opacity(0.85))
    }

    private func row(_ keys: String, _ text: String) -> some View {
        HStack(spacing: 8) {
            Text(keys)
                .font(.system(size: style.fontSize - 2, design: .monospaced))
                .frame(minWidth: 34, alignment: .leading)
            Text(text).foregroundStyle(.white.opacity(0.65))
        }
    }
}

/// Estado de pasar el mouse por un bloque (los botones aparecen al pasar).
@MainActor
private final class HoverState: ObservableObject {
    @Published var isHovering = false
}

/// Un comando terminado: franja de estado, comando, metadatos, salida y acciones.
private struct BlockRow: View {
    let block: TerminalBlock
    let isSelected: Bool
    let style: ChatStyle
    let canRerun: Bool
    let onSelect: () -> Void
    let onToggleExpanded: () -> Void
    let onRerun: () -> Void
    let onAskAgent: () -> Void

    @StateObject private var hover = HoverState()

    private var stripeColor: Color {
        if block.isRunning { return AITheme.cyan }
        guard let code = block.exitCode else { return .white.opacity(0.2) }
        return code == 0 ? commandGreen.opacity(0.8) : AITheme.pink
    }

    private var visibleLines: ArraySlice<BlockLine> {
        block.isExpanded ? block.lines[...] : block.lines.prefix(TerminalBlock.collapsedLineLimit)
    }

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            Rectangle().fill(stripeColor).frame(width: 3)
            VStack(alignment: .leading, spacing: 5) {
                header
                if block.usedFullScreen && !block.hasOutput {
                    Text("programa de pantalla completa")
                        .font(.system(size: style.fontSize - 2, design: .monospaced))
                        .foregroundStyle(dim)
                }
                if block.hasOutput { output }
            }
            .padding(.horizontal, style.isNotch ? 8 : 12)
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(isSelected ? Color.white.opacity(0.05) : (hover.isHovering ? Color.white.opacity(0.025) : .clear))
        .overlay(alignment: .bottom) { Rectangle().fill(dividerColor).frame(height: 1) }
        .contentShape(Rectangle())
        .onTapGesture(perform: onSelect)
        .onHover { hover.isHovering = $0 }
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            CommandText(command: block.command, fontSize: style.fontSize)
                .lineLimit(3)
                .textSelection(.enabled)
            Spacer(minLength: 6)
            if block.failed, let code = block.exitCode {
                Text("código \(code)")
                    .font(.system(size: style.fontSize - 3, weight: .medium, design: .monospaced))
                    .foregroundStyle(AITheme.pink)
            }
            if let duration = block.duration, duration >= 1 {
                Text(Self.format(duration))
                    .font(.system(size: style.fontSize - 3, design: .monospaced))
                    .foregroundStyle(dim)
            }
            if hover.isHovering || isSelected { actions }
        }
    }

    private var actions: some View {
        HStack(spacing: 8) {
            action("doc.on.doc", "Copiar comando") { copy(block.command) }
            action("text.alignleft", "Copiar salida") { copy(block.plainOutput) }
                .disabled(block.plainOutput.isEmpty)
            action("arrow.clockwise", "Repetir comando", action: onRerun)
                .disabled(!canRerun)
            action("sparkles", "Preguntarle al agente por este bloque", action: onAskAgent)
        }
    }

    private func action(_ icon: String, _ help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon).font(.system(size: style.fontSize - 1))
        }
        .buttonStyle(.plain)
        .foregroundStyle(.white.opacity(0.6))
        .help(help)
        .accessibilityLabel(help)
    }

    private var output: some View {
        VStack(alignment: .leading, spacing: 0) {
            Group {
                if visibleLines.count > TerminalBlock.collapsedLineLimit {
                    LazyVStack(alignment: .leading, spacing: 0) { lineViews }
                } else {
                    VStack(alignment: .leading, spacing: 0) { lineViews }
                }
            }
            .textSelection(.enabled)
            if block.lines.count > TerminalBlock.collapsedLineLimit || block.isTruncated {
                Button(action: onToggleExpanded) {
                    Text(footer)
                        .font(.system(size: style.fontSize - 2, design: .monospaced))
                        .foregroundStyle(AITheme.violet)
                }
                .buttonStyle(.plain)
                .padding(.top, 4)
            }
        }
    }

    @ViewBuilder
    private var lineViews: some View {
        ForEach(Array(visibleLines.enumerated()), id: \.offset) { _, line in
            Text(Self.attributed(line, fontSize: style.fontSize))
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var footer: String {
        let hidden = block.lines.count - TerminalBlock.collapsedLineLimit
        var text = block.isExpanded
            ? "Mostrar menos"
            : "Mostrar \(max(hidden, 0)) líneas más"
        if block.isTruncated { text += " · la salida era más larga: se guardan las últimas \(BlockCapture.maxStoredLines)" }
        return text
    }

    private func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    private static func format(_ seconds: TimeInterval) -> String {
        seconds < 60 ? String(format: "%.1f s", seconds) : "\(Int(seconds) / 60) min \(Int(seconds) % 60) s"
    }

    // MARK: Colores

    static func attributed(_ line: BlockLine, fontSize: CGFloat) -> AttributedString {
        guard !line.isEmpty else { return AttributedString(" ") }
        var result = AttributedString()
        for run in line {
            var piece = AttributedString(run.text)
            var foreground = color(run.fg)
            var background = color(run.bg)
            if run.inverse {
                let swapped = background ?? AITheme.background
                background = foreground ?? Color.white.opacity(0.9)
                foreground = swapped
            }
            let base = foreground ?? Color.white.opacity(0.9)
            piece.foregroundColor = run.dim ? base.opacity(0.6) : base
            if let background { piece.backgroundColor = background }
            var font = Font.system(size: fontSize, weight: run.bold ? .bold : .regular, design: .monospaced)
            if run.italic { font = font.italic() }
            piece.font = font
            if run.underline { piece.underlineStyle = .single }
            if run.strike { piece.strikethroughStyle = .single }
            result.append(piece)
        }
        return result
    }

    private static func color(_ color: BlockColor) -> Color? {
        switch color {
        case .none:
            return nil
        case .palette(let index):
            let (r, g, b) = ANSIPalette.rgb(index)
            return Color(red: Double(r) / 255, green: Double(g) / 255, blue: Double(b) / 255)
        case .rgb(let r, let g, let b):
            return Color(red: Double(r) / 255, green: Double(g) / 255, blue: Double(b) / 255)
        }
    }
}

/// El comando con la primera palabra resaltada, como en el editor.
private struct CommandText: View {
    let command: String
    let fontSize: CGFloat

    var body: some View {
        let font = Font.system(size: fontSize, weight: .semibold, design: .monospaced)
        let split = command.firstIndex(where: { $0 == " " || $0 == "\n" }) ?? command.endIndex
        var head = AttributedString(String(command[..<split]))
        head.foregroundColor = commandGreen
        var tail = AttributedString(String(command[split...]))
        tail.foregroundColor = .white.opacity(0.92)
        var whole = head
        whole.append(tail)
        whole.font = font
        return Text(whole)
    }
}

/// Encabezado del comando que está corriendo, con el tiempo transcurrido.
private struct RunningHeader: View {
    let running: RunningCommand
    let style: ChatStyle

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 0) {
            Rectangle().fill(AITheme.cyan).frame(width: 3)
            HStack(spacing: 10) {
                CommandText(command: running.command, fontSize: style.fontSize).lineLimit(2)
                Spacer(minLength: 6)
                // Solo mientras corre: el temporizador no gasta nada con el prompt libre.
                TimelineView(.periodic(from: running.startedAt, by: 1)) { context in
                    Text("\(Int(context.date.timeIntervalSince(running.startedAt))) s")
                        .font(.system(size: style.fontSize - 3, design: .monospaced))
                        .foregroundStyle(AITheme.cyan)
                }
            }
            .padding(.horizontal, style.isNotch ? 8 : 12)
            .padding(.vertical, 8)
        }
    }
}

/// Carpeta, rama y archivos cambiados, sobre el editor.
private struct PromptChips: View {
    @ObservedObject var shell: TabShell
    @ObservedObject var workspace: Workspace
    let style: ChatStyle
    let onPickDirectory: () -> Void

    private var path: String {
        ((shell.currentDirectory ?? workspace.directory).path as NSString).abbreviatingWithTildeInPath
    }

    var body: some View {
        HStack(spacing: 6) {
            Button(action: onPickDirectory) {
                chip("folder", path)
            }
            .buttonStyle(.plain)
            .disabled(shell.commandState.phase != .ready)
            .help("Carpeta actual: \(path). Clic para ir a la carpeta superior, una subcarpeta o una reciente.")
            .accessibilityLabel("Cambiar de carpeta")
            if let git = workspace.git {
                chip("arrow.triangle.branch", git.branch)
                    .help(git.isDetached ? "HEAD separado en \(git.branch)" : "Rama \(git.branch)")
                chip("plusminus", "\(git.changedFiles)", tint: git.changedFiles > 0 ? AITheme.pink : nil)
                    .help(git.hasChanges == true
                          ? "\(git.changedFiles) archivos con cambios · +\(git.insertions) −\(git.deletions) líneas"
                          : "Sin cambios pendientes")
            }
            Spacer(minLength: 0)
        }
    }

    private func chip(_ icon: String, _ text: String, tint: Color? = nil) -> some View {
        HStack(spacing: 4) {
            Image(systemName: icon).font(.system(size: style.fontSize - 3))
            Text(text).lineLimit(1).truncationMode(.head)
        }
        .font(.system(size: style.fontSize - 2, weight: .medium, design: .monospaced))
        .foregroundStyle(tint ?? .white.opacity(0.75))
        .padding(.horizontal, 7)
        .padding(.vertical, 3)
        .background(.white.opacity(0.07), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
    }
}
