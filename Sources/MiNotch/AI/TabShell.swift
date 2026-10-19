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
    /// Momento del último envío del asistente: la salida posterior es su respuesta.
    private var lastSentAt = Date.distantPast

    private static let screenLines = 80

    override init() {
        super.init()
        view.processDelegate = self
        view.font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
        view.nativeBackgroundColor = .black
        view.nativeForegroundColor = NSColor(white: 0.92, alpha: 1)
        view.caretColor = NSColor(AITheme.violet)
        view.optionAsMetaKey = false
    }

    func startIfNeeded(in directory: URL) {
        guard !isRunning else { return }
        var environment = ProcessInfo.processInfo.environment
        environment["TERM"] = "xterm-256color"
        environment["COLORTERM"] = "truecolor"
        environment["LANG"] = environment["LANG"] ?? "es_ES.UTF-8"
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
        guard isRunning else { return }
        if view.process.shellPid != 0 { kill(view.process.shellPid, SIGHUP) }
        view.terminate()
        isRunning = false
    }

    // MARK: - Uso desde el asistente

    /// Texto tal cual: incluir "\r" para Enter o "\u{03}" para Ctrl+C.
    func write(_ text: String, in directory: URL) {
        startIfNeeded(in: directory)
        lastSentAt = Date()
        view.send(txt: text)
    }

    /// Espera a que la salida se calme (o `maxWait`) y devuelve las últimas líneas de la pantalla.
    func readScreen(maxWait: TimeInterval) async -> String {
        let start = Date()
        while !Task.isCancelled, isRunning, Date().timeIntervalSince(start) < maxWait {
            try? await Task.sleep(for: .milliseconds(150))
            let last = view.lastOutputAt
            if last > lastSentAt, Date().timeIntervalSince(last) >= 1.0 { break }
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
        }
    }
}

/// La vista de SwiftTerm, con lo que necesita el notch.
final class ShellTerminalView: LocalProcessTerminalView {
    /// Para saber cuándo un comando terminó de responder.
    private(set) var lastOutputAt = Date.distantPast

    override func dataReceived(slice: ArraySlice<UInt8>) {
        lastOutputAt = Date()
        super.dataReceived(slice: slice)
    }

    /// El panel del notch toma el teclado solo si la vista clicada lo pide (como un campo de texto).
    override var needsPanelToBecomeKey: Bool { true }
}
