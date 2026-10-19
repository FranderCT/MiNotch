import Foundation

/// Sesión de terminal interactiva (ssh, sudo, REPLs…) que queda viva entre pasos del asistente.
/// `script` le da al comando una terminal real (PTY): sin ella ssh y sudo no pueden pedir contraseña.
final class TerminalSession: @unchecked Sendable {
    let id: Int
    let command: String

    private let process = Process()
    private let input = Pipe()
    private let output = Pipe()
    private let lock = NSLock()
    private var buffer = Data()
    /// Bytes de `buffer` que ya se le entregaron al asistente.
    private var readOffset = 0
    private var lastOutputAt = Date()

    private static let bufferLimit = 2_000_000
    /// Sin salida nueva durante este tiempo, se considera que el comando terminó de responder.
    private static let quietInterval: TimeInterval = 1.2
    private static let transcriptLimit = 12_000

    init(id: Int, command: String, directory: URL, onExit: @escaping @Sendable () -> Void) throws {
        self.id = id
        self.command = command
        process.executableURL = URL(fileURLWithPath: "/usr/bin/script")
        // Columnas fijas antes de arrancar: con el tamaño por defecto (0) la salida se desarma.
        process.arguments = ["-q", "/dev/null", "/bin/zsh", "-l", "-c", "stty cols 160 rows 48 2>/dev/null; \(command)"]
        process.currentDirectoryURL = directory
        process.environment = ProcessInfo.processInfo.environment.merging([
            // Menos secuencias de color y sin paginadores que esperan una tecla.
            "TERM": "dumb", "PAGER": "cat", "GIT_PAGER": "cat", "SYSTEMD_PAGER": "cat",
        ]) { $1 }
        process.standardInput = input
        process.standardOutput = output
        process.standardError = output
        process.terminationHandler = { _ in onExit() }
        output.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard let self, !data.isEmpty else { return }
            self.lock.withLock {
                self.buffer.append(data)
                self.lastOutputAt = Date()
                // Recorta lo más viejo si crece demasiado (un log infinito, por ejemplo).
                if self.buffer.count > Self.bufferLimit {
                    let drop = self.buffer.count - Self.bufferLimit / 2
                    self.buffer.removeFirst(drop)
                    self.readOffset = max(0, self.readOffset - drop)
                }
            }
        }
        try process.run()
    }

    var isRunning: Bool { process.isRunning }
    var exitStatus: Int32 { process.isRunning ? 0 : process.terminationStatus }

    /// Texto tal cual: incluir "\r" para Enter o caracteres de control como "\u{03}" (Ctrl+C).
    func write(_ text: String) {
        try? input.fileHandleForWriting.write(contentsOf: Data(text.utf8))
    }

    /// Espera a que la salida se calme (o a `maxWait`) y devuelve lo nuevo desde la última lectura, limpio.
    func readNew(maxWait: TimeInterval) async -> String {
        let start = Date()
        while !Task.isCancelled, isRunning, Date().timeIntervalSince(start) < maxWait {
            try? await Task.sleep(for: .milliseconds(100))
            let (hasNew, lastOutput) = lock.withLock { (buffer.count > readOffset, lastOutputAt) }
            if hasNew, Date().timeIntervalSince(lastOutput) >= Self.quietInterval { break }
        }
        // Margen para lo último que quedó en el pipe al terminar el proceso.
        if !isRunning { try? await Task.sleep(for: .milliseconds(150)) }

        let data = lock.withLock {
            let new = buffer.suffix(from: buffer.startIndex + readOffset)
            readOffset = buffer.count
            return Data(new)
        }
        let text = Self.clean(String(decoding: data, as: UTF8.self))
        guard text.count > Self.transcriptLimit else { return text }
        return "… [salida anterior recortada]\n" + text.suffix(Self.transcriptLimit)
    }

    func close() {
        output.fileHandleForReading.readabilityHandler = nil
        if process.isRunning { process.terminate() }
    }

    /// Lo que se ve en una terminal: sin secuencias de escape y con "\r" sobrescribiendo la línea.
    static func clean(_ raw: String) -> String {
        var text = raw
            .replacingOccurrences(of: #"\x{1B}\][^\x{07}\x{1B}]*(\x{07}|\x{1B}\\)"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: #"\x{1B}\[[0-?]*[ -/]*[@-~]"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: #"\x{1B}[()][A-Za-z0-9]|\x{1B}[=>78]"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: "\r\n", with: "\n")
        // Retroceso: borra el carácter anterior.
        while let range = text.range(of: #"[^\x{08}\n]\x{08}"#, options: .regularExpression) {
            text.removeSubrange(range)
        }
        return text
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { line in
                let visible = line.split(separator: "\r").last.map(String.init) ?? ""
                return visible.replacingOccurrences(of: #"\s+$"#, with: "", options: .regularExpression)
            }
            .joined(separator: "\n")
    }

    /// La última línea pide una contraseña o passphrase (ssh, sudo, llaves…). Devuelve ese pedido.
    static func secretPrompt(in transcript: String) -> String? {
        guard let last = transcript.split(separator: "\n").last.map(String.init),
              last.range(of: #"(?i)(password|passphrase|contraseña|clave)[^\n]{0,80}:\s*$"#, options: .regularExpression) != nil
        else { return nil }
        return last.trimmingCharacters(in: .whitespaces)
    }
}

/// Sesiones abiertas por el asistente. Viven hasta que terminan, se cierran o se borra la conversación.
@MainActor
final class TerminalSessions: ObservableObject {
    @Published private(set) var sessions: [TerminalSession] = []
    private var nextID = 1

    static let maxSessions = 5

    func start(_ command: String, in directory: URL) throws -> TerminalSession {
        guard sessions.count < Self.maxSessions else {
            throw ToolError("Ya hay \(Self.maxSessions) sesiones abiertas: cerrá alguna con terminal_close.")
        }
        let id = nextID
        nextID += 1
        let session = try TerminalSession(id: id, command: command, directory: directory) { [weak self] in
            Task { @MainActor in self?.objectWillChange.send() }
        }
        sessions.append(session)
        return session
    }

    func session(_ id: Int) -> TerminalSession? {
        sessions.first { $0.id == id }
    }

    func close(_ id: Int) {
        session(id)?.close()
        sessions.removeAll { $0.id == id }
    }

    func closeAll() {
        sessions.forEach { $0.close() }
        sessions.removeAll()
    }
}
