import AppKit
import SwiftTerm

/// Terminal visible de una pestaña (modo Terminal): un zsh real emulado con SwiftTerm.
/// La comparten el usuario y el asistente, que la usa como sesión 0 de las herramientas de terminal.
/// El shell arranca la primera vez que hace falta, en la carpeta de la pestaña.
@MainActor
final class TabShell: NSObject, ObservableObject, LocalProcessTerminalViewDelegate {
    let view = ShellTerminalView(frame: NSRect(x: 0, y: 0, width: 680, height: 360))
    @Published private(set) var isRunning = false
    @Published private(set) var exitCode: Int32?
    @Published private(set) var commandState = ShellCommandState()
    @Published var draft = ""
    @Published private(set) var inputHistory: [String] = []
    @Published private(set) var isEditingDirectly = false
    @Published private(set) var inputError: String?
    private var integration: ShellIntegration?
    /// Momento del último envío del asistente: la salida posterior es su respuesta.
    private var lastSentAt = Date.distantPast

    private static let screenLines = 80
    /// Lugares donde se muestra (notch y/o ventana). La vista de AppKit solo puede estar en uno a la vez.
    private let hosts = NSHashTable<TerminalContainer>.weakObjects()

    override init() {
        super.init()
        view.processDelegate = self
        view.font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
        view.nativeBackgroundColor = .black
        view.nativeForegroundColor = NSColor(white: 0.92, alpha: 1)
        view.caretColor = NSColor(AITheme.violet)
        view.optionAsMetaKey = false
        view.onDirectInput = { [weak self] in
            guard let self, self.commandState.phase == .ready else { return }
            self.isEditingDirectly = true
        }
    }

    func startIfNeeded(in directory: URL) {
        guard !isRunning else { return }
        var environment = ProcessInfo.processInfo.environment
        environment["TERM"] = "xterm-256color"
        environment["COLORTERM"] = "truecolor"
        environment["LANG"] = environment["LANG"] ?? "es_ES.UTF-8"
        commandState = ShellCommandState()
        do {
            integration = try ShellIntegration(environment: &environment)
            let token = integration!.token
            view.getTerminal().registerOscHandler(code: ShellIntegration.oscCode) { [weak self] bytes in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    let payload = String(decoding: bytes, as: UTF8.self)
                    self.commandState.receive(payload, token: token)
                    if payload.hasPrefix("\(token);ready;"), self.commandState.phase == .ready {
                        self.isEditingDirectly = false
                    }
                }
            }
        } catch {
            commandState.phase = .unavailable
            LocalDiagnostics.shared.record(.shellIntegrationFailure)
        }
        // "-zsh": shell de login, como Terminal.app (carga .zprofile: Homebrew, fnm…).
        view.startProcess(
            executable: "/bin/zsh",
            environment: environment.map { "\($0.key)=\($0.value)" },
            execName: "-zsh",
            currentDirectory: directory.path
        )
        exitCode = nil
        isRunning = true
    }

    /// Para cerrar la pestaña o la app: SIGHUP como al cerrar una ventana de Terminal (corta también ssh).
    func terminate() {
        view.stopInputMonitor()
        guard isRunning else { return }
        if view.process.shellPid != 0 { kill(view.process.shellPid, SIGHUP) }
        view.terminate()
        isRunning = false
        integration = nil
    }

    // MARK: - Dónde se muestra

    /// El contenedor que acaba de aparecer se queda con la terminal.
    func attach(to container: TerminalContainer) {
        hosts.add(container)
        container.adopt(view)
    }

    /// Al desaparecer un contenedor (por ejemplo, se cierra el notch), la terminal vuelve a otro visible.
    func detach(from container: TerminalContainer) {
        hosts.remove(container)
        guard view.superview == container else { return }
        view.removeFromSuperview()
        if let other = hosts.allObjects.first(where: { $0.window != nil }) {
            other.adopt(view)
        }
    }

    // MARK: - Uso desde el asistente

    /// El editor solo envía al prompt confirmado, nunca a un programa o una contraseña.
    func submitDraft(in directory: URL) {
        guard isRunning, commandState.phase == .ready, !isEditingDirectly,
              !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        let command = draft
        guard !command.unicodeScalars.contains(where: { ($0.value < 32 && $0 != "\n" && $0 != "\t") || $0.value == 127 }) else {
            inputError = "Quitá los caracteres de control antes de enviar el comando."
            return
        }
        let bracketed = view.getTerminal().bracketedPasteMode
        guard bracketed || !command.contains("\n") else {
            inputError = "Este shell no admite el pegado multilínea; enviá una sola línea."
            return
        }
        inputError = nil
        draft = ""
        inputHistory.removeAll { $0 == command }
        inputHistory.append(command)
        inputHistory = Array(inputHistory.suffix(100))
        // Reservar el prompt antes de lanzar la tarea evita un segundo envío por doble Enter.
        commandState.phase = .awaitingInput
        let input = bracketed ? "\u{1b}[200~" + command + "\u{1b}[201~\r" : command + "\r"
        Task { await write(input, in: directory) }
    }

    /// Texto tal cual: incluir "\r" para Enter o "\u{03}" para Ctrl+C.
    func write(_ text: String, in directory: URL) async {
        startIfNeeded(in: directory)
        let start = Date()
        while commandState.phase == .starting, isRunning, Date().timeIntervalSince(start) < 3 {
            if Task.isCancelled { return }
            try? await Task.sleep(for: .milliseconds(30))
        }
        guard !Task.isCancelled, isRunning else { return }
        if commandState.phase == .starting { commandState.phase = .unavailable }
        if commandState.phase == .ready {
            commandState.phase = .awaitingInput
            commandState.lastExitCode = nil
        }
        lastSentAt = Date()
        view.send(txt: text)
    }

    /// Espera el prompt confirmado por zsh, un pedido de contraseña o el límite de lectura.
    func readScreen(maxWait: TimeInterval) async -> String {
        let start = Date()
        while !Task.isCancelled, isRunning, Date().timeIntervalSince(start) < maxWait {
            try? await Task.sleep(for: .milliseconds(150))
            let last = view.lastOutputAt
            if commandState.phase == .ready { break }
            if last > lastSentAt, Date().timeIntervalSince(last) >= 0.3,
               TerminalSession.secretPrompt(in: screenText) != nil { break }
        }
        return screenText
    }

    /// Lo que se ve: pantalla y el final del historial, sin líneas vacías al final.
    var screenText: String {
        let text = String(decoding: view.getTerminal().getBufferAsData(), as: UTF8.self)
        var lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        while lines.last?.trimmingCharacters(in: .whitespaces).isEmpty == true { lines.removeLast() }
        return lines.suffix(Self.screenLines).joined(separator: "\n")
    }

    // MARK: - LocalProcessTerminalViewDelegate (SwiftTerm avisa en el hilo principal)

    nonisolated func sizeChanged(source: LocalProcessTerminalView, newCols: Int, newRows: Int) {}
    nonisolated func setTerminalTitle(source: LocalProcessTerminalView, title: String) {}
    nonisolated func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}

    nonisolated func processTerminated(source: TerminalView, exitCode: Int32?) {
        MainActor.assumeIsolated {
            self.isRunning = false
            self.exitCode = exitCode
            self.integration = nil
            LocalDiagnostics.shared.record(.shellExit, value: Double(exitCode ?? -1))
        }
    }
}

/// Hueco para la terminal en el notch o en la ventana.
final class TerminalContainer: NSView {
    func adopt(_ terminal: NSView) {
        guard terminal.superview != self else { return }
        terminal.removeFromSuperview()
        terminal.frame = bounds
        terminal.autoresizingMask = [.width, .height]
        addSubview(terminal)
        // Recién mostrada: el teclado va a la terminal.
        DispatchQueue.main.async { [weak self, weak terminal] in
            guard let self, let terminal, terminal.superview == self else { return }
            self.window?.makeKey()
            self.window?.makeFirstResponder(terminal)
        }
    }
}

/// La vista de SwiftTerm, con lo que necesita el notch.
final class ShellTerminalView: LocalProcessTerminalView {
    var onDirectInput: (() -> Void)?
    private var inputMonitor: Any?

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        stopInputMonitor()
        guard window != nil else { return }
        inputMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            MainActor.assumeIsolated {
                if let self, self.window?.firstResponder === self,
                   !event.modifierFlags.contains(.command) {
                    self.onDirectInput?()
                }
            }
            return event
        }
    }

    func stopInputMonitor() {
        if let inputMonitor { NSEvent.removeMonitor(inputMonitor) }
        inputMonitor = nil
    }

    override func paste(_ sender: Any) {
        onDirectInput?()
        super.paste(sender)
    }

    override func insertText(_ string: Any, replacementRange: NSRange) {
        onDirectInput?()
        super.insertText(string, replacementRange: replacementRange)
    }
    /// Para saber cuándo un comando terminó de responder.
    private(set) var lastOutputAt = Date.distantPast

    override func dataReceived(slice: ArraySlice<UInt8>) {
        lastOutputAt = Date()
        super.dataReceived(slice: slice)
    }

    /// El panel del notch toma el teclado solo si la vista clicada lo pide (como un campo de texto).
    override var needsPanelToBecomeKey: Bool { true }
}
