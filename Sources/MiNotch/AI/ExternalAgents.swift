import Combine
import Foundation

/// Agentes de programación externos (sus CLIs en modo sin interfaz) que el asistente puede dirigir.
enum ExternalAgentKind: String, CaseIterable, Sendable {
    case claude, codex, cursor, grok, opencode

    var displayName: String {
        switch self {
        case .claude: "Claude Code"
        case .codex: "Codex"
        case .cursor: "Cursor Agent"
        case .grok: "Grok"
        case .opencode: "OpenCode"
        }
    }

    var executable: String {
        switch self {
        case .claude: "claude"
        case .codex: "codex"
        case .cursor: "cursor-agent"
        case .grok: "agent"
        case .opencode: "opencode"
        }
    }

    /// Argumentos para una tarea nueva (`sessionID` nil) o para seguir una sesión.
    /// Formatos y opciones verificados con corridas reales el 19/10/2026.
    func arguments(prompt: String, sessionID: String?, access: AgentAccess, model: String?, directory: URL) -> [String] {
        var args: [String]
        switch self {
        case .claude:
            let mode = switch access { case .read: "plan"; case .edit: "acceptEdits"; case .full: "bypassPermissions" }
            args = ["-p", prompt, "--output-format", "json", "--permission-mode", mode]
            if let sessionID { args += ["--resume", sessionID] }
        case .codex:
            // -c sandbox_mode sirve también al retomar (`exec resume` no acepta -s).
            let sandbox = switch access { case .read: "read-only"; case .edit: "workspace-write"; case .full: "danger-full-access" }
            args = ["exec"] + (sessionID.map { ["resume", $0] } ?? [])
            args += ["--json", "--skip-git-repo-check", "-c", "sandbox_mode=\"\(sandbox)\""]
            if let model { args += ["-m", model] }
            args.append(prompt)
            return args
        case .cursor:
            args = ["-p", prompt, "--output-format", "json", "--workspace", directory.path, "--trust"]
            switch access {
            case .read: args += ["--mode", "plan"]
            case .edit: break
            case .full: args.append("--force")
            }
            if let sessionID { args += ["--resume", sessionID] }
        case .grok:
            let mode = switch access { case .read: "plan"; case .edit: "acceptEdits"; case .full: "bypassPermissions" }
            args = ["-p", prompt, "--cwd", directory.path, "--output-format", "json", "--permission-mode", mode]
            if let sessionID { args += ["-r", sessionID] }
        case .opencode:
            args = ["run", "--format", "json"]
            switch access {
            case .read: args += ["--agent", "plan"]
            case .edit: break
            case .full: args.append("--auto")
            }
            if let sessionID { args += ["-s", sessionID] }
            if let model { args += ["-m", model] }
            args.append(prompt)
            return args
        }
        if let model { args += ["--model", model] }
        return args
    }

    /// Respuesta final, id de sesión y costo, según el formato de cada CLI.
    func parse(_ output: String) -> ExternalAgentOutput {
        var result = ExternalAgentOutput()
        let objects = Self.jsonObjects(in: output)
        switch self {
        case .claude, .cursor:
            // Claude: un objeto; Cursor: el último evento de tipo "result".
            guard let final = objects.last(where: { $0["result"] != nil || $0["type"] as? String == "result" }) else { break }
            result.text = final["result"] as? String
            result.sessionID = final["session_id"] as? String
            result.costUSD = final["total_cost_usd"] as? Double
            result.isError = final["is_error"] as? Bool ?? false
        case .grok:
            guard let final = objects.last else { break }
            result.text = final["text"] as? String
            result.sessionID = final["sessionId"] as? String
            result.costUSD = final["total_cost_usd"] as? Double
        case .codex:
            for event in objects {
                switch event["type"] as? String {
                case "thread.started":
                    result.sessionID = event["thread_id"] as? String
                case "item.completed":
                    let item = event["item"] as? [String: Any]
                    if item?["type"] as? String == "agent_message", let text = item?["text"] as? String {
                        result.text = text
                    }
                case "error", "turn.failed":
                    result.isError = true
                    result.text = result.text ?? (event["message"] as? String) ?? ((event["error"] as? [String: Any])?["message"] as? String)
                default:
                    break
                }
            }
        case .opencode:
            // Eventos por línea: el texto de la respuesta es el del último mensaje.
            var lastMessage: String?
            var parts: [String] = []
            for event in objects {
                result.sessionID = result.sessionID ?? event["sessionID"] as? String
                guard let part = event["part"] as? [String: Any] else { continue }
                if event["type"] as? String == "text", let text = part["text"] as? String {
                    let message = part["messageID"] as? String
                    if message != lastMessage { parts = []; lastMessage = message }
                    parts.append(text)
                }
                if let cost = part["cost"] as? Double { result.costUSD = (result.costUSD ?? 0) + cost }
            }
            result.text = parts.isEmpty ? nil : parts.joined(separator: "\n")
        }
        return result
    }

    /// Un objeto JSON (con saltos de línea o no) o uno por línea (NDJSON).
    private static func jsonObjects(in output: String) -> [[String: Any]] {
        if let whole = try? JSONSerialization.jsonObject(with: Data(output.utf8)) as? [String: Any] {
            return [whole]
        }
        return output.split(separator: "\n").compactMap {
            try? JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any]
        }
    }

    // MARK: - Instalados

    /// Ruta de cada CLI instalado, según el PATH del shell de login. Se busca una vez, al arrancar.
    nonisolated(unsafe) private static var installedPaths: [ExternalAgentKind: String] = [:]
    private static let lock = NSLock()

    static func detectInstalled() async {
        let found = await Task.detached(priority: .utility) {
            var paths: [ExternalAgentKind: String] = [:]
            for kind in ExternalAgentKind.allCases {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: "/bin/zsh")
                process.arguments = ["-l", "-c", "command -v \(kind.executable)"]
                let pipe = Pipe()
                process.standardOutput = pipe
                process.standardError = FileHandle.nullDevice
                process.standardInput = FileHandle.nullDevice
                guard (try? process.run()) != nil else { continue }
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                process.waitUntilExit()
                let path = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
                if process.terminationStatus == 0, path.hasPrefix("/") { paths[kind] = path }
            }
            return paths
        }.value
        lock.withLock { installedPaths = found }
    }

    static var installed: [ExternalAgentKind] {
        lock.withLock { allCases.filter { installedPaths[$0] != nil } }
    }

    var path: String? {
        Self.lock.withLock { Self.installedPaths[self] }
    }
}

enum AgentAccess: String, Sendable {
    /// Solo analiza o planea.
    case read
    /// Edita archivos de la carpeta.
    case edit
    /// También ejecuta comandos sin preguntar.
    case full

    var title: String {
        switch self {
        case .read: "solo lectura"
        case .edit: "editar archivos"
        case .full: "acceso total"
        }
    }
}

struct ExternalAgentOutput: Sendable {
    var text: String?
    var sessionID: String?
    var costUSD: Double?
    var isError = false
}

/// Un trabajo: un agente externo con su sesión. Cada `send` es una corrida nueva en la misma sesión.
@MainActor
final class ExternalAgentJob: ObservableObject, Identifiable {
    enum Status: Sendable {
        case running, finished, failed, stopped
    }

    let id: Int
    let kind: ExternalAgentKind
    let directory: URL
    let access: AgentAccess
    let model: String?
    @Published private(set) var status = Status.running
    @Published private(set) var task: String
    @Published private(set) var startedAt = Date()
    @Published private(set) var finishedAt: Date?
    private(set) var sessionID: String?
    private(set) var result: String?
    /// Suma de todas las corridas, si el CLI lo informa.
    private(set) var costUSD: Double?
    private(set) var errorText: String?
    nonisolated(unsafe) private var process: Process?

    /// Una tarea de programación puede tardar bastante; más que esto es probable que esté trabado.
    private static let timeout: TimeInterval = 30 * 60

    init(id: Int, kind: ExternalAgentKind, task: String, directory: URL, access: AgentAccess, model: String?) {
        self.id = id
        self.kind = kind
        self.task = task
        self.directory = directory
        self.access = access
        self.model = model
    }

    var isRunning: Bool { status == .running }

    func run(_ prompt: String) {
        task = prompt
        status = .running
        startedAt = Date()
        finishedAt = nil
        result = nil
        errorText = nil

        guard let path = kind.path else {
            finish(exit: -1, output: "", errorOutput: "\(kind.displayName) no está instalado (no se encontró \(kind.executable) en el PATH).")
            return
        }
        let args = kind.arguments(prompt: prompt, sessionID: sessionID, access: access, model: model, directory: directory)
        // zsh de login: los CLIs dependen del PATH y las variables de tu shell (node, claves, etc.).
        let command = "exec " + ([path] + args).map(Self.shellQuoted).joined(separator: " ")

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = ["-l", "-c", command]
        process.currentDirectoryURL = directory
        process.standardInput = FileHandle.nullDevice
        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr
        let output = OutputBuffer()
        let errorOutput = OutputBuffer()
        stdout.fileHandleForReading.readabilityHandler = { output.append($0.availableData) }
        stderr.fileHandleForReading.readabilityHandler = { errorOutput.append($0.availableData) }
        process.terminationHandler = { [weak self] finished in
            // Margen para lo último que quedó en los pipes.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                stdout.fileHandleForReading.readabilityHandler = nil
                stderr.fileHandleForReading.readabilityHandler = nil
                MainActor.assumeIsolated {
                    self?.finish(exit: finished.terminationStatus, output: output.string, errorOutput: errorOutput.string)
                }
            }
        }
        do {
            try process.run()
            self.process = process
            let pid = process.processIdentifier
            DispatchQueue.main.asyncAfter(deadline: .now() + Self.timeout) { [weak self] in
                MainActor.assumeIsolated {
                    guard let self, self.isRunning, self.process?.processIdentifier == pid else { return }
                    self.errorText = "Cortado: superó \(Int(Self.timeout / 60)) minutos."
                    process.terminate()
                }
            }
        } catch {
            finish(exit: -1, output: "", errorOutput: "No se pudo ejecutar: \(error.localizedDescription)")
        }
    }

    func stop() {
        guard isRunning else { return }
        status = .stopped
        process?.terminate()
    }

    private func finish(exit: Int32, output: String, errorOutput: String) {
        process = nil
        finishedAt = Date()
        let parsed = kind.parse(output)
        sessionID = parsed.sessionID ?? sessionID
        if let cost = parsed.costUSD { costUSD = (costUSD ?? 0) + cost }
        result = parsed.text
        if status == .stopped { return }
        if exit == 0, !parsed.isError, parsed.text != nil {
            status = .finished
        } else {
            status = .failed
            let detail = errorOutput.trimmingCharacters(in: .whitespacesAndNewlines)
            errorText = errorText ?? "Código de salida \(exit)." + (detail.isEmpty ? "" : "\n\(detail.suffix(1500))")
            // Sin respuesta parseable: lo último que imprimió sirve para entender qué pasó.
            if result == nil, !output.isEmpty { result = String(output.suffix(3000)) }
        }
    }

    /// Para el modelo: estado, duración, costo y respuesta.
    var report: String {
        let seconds = Int((finishedAt ?? Date()).timeIntervalSince(startedAt))
        var header = "Trabajo \(id) (\(kind.displayName), \(access.title), en \(directory.path))"
        switch status {
        case .running: header += " sigue trabajando (\(seconds) s)."
        case .finished: header += " terminó en \(seconds) s."
        case .failed: header += " falló tras \(seconds) s."
        case .stopped: header += " fue detenido."
        }
        if let costUSD { header += String(format: " Costo acumulado: %.4f USD.", costUSD) }
        if sessionID != nil, !isRunning { header += " Se puede seguir con agent_send." }
        var text = header
        if let errorText { text += "\nError: \(errorText)" }
        if let result { text += "\nRespuesta:\n\(result.prefix(12_000))" }
        return text
    }

    private static func shellQuoted(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}

/// Trabajos de agentes externos lanzados desde una pestaña.
@MainActor
final class ExternalAgents: ObservableObject {
    @Published private(set) var jobs: [ExternalAgentJob] = []
    private var nextID = 1
    private var observers: [Int: Any] = [:]

    static let maxRunning = 5

    func start(_ kind: ExternalAgentKind, task: String, directory: URL, access: AgentAccess, model: String?) throws -> ExternalAgentJob {
        guard jobs.filter(\.isRunning).count < Self.maxRunning else {
            throw ToolError("Ya hay \(Self.maxRunning) agentes trabajando: esperá a que alguno termine o detenelo.")
        }
        let job = ExternalAgentJob(id: nextID, kind: kind, task: task, directory: directory, access: access, model: model)
        nextID += 1
        jobs.append(job)
        // Para que el menú del notch se actualice cuando cambia el estado.
        observers[job.id] = job.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }
        job.run(task)
        return job
    }

    func job(_ id: Int) -> ExternalAgentJob? {
        jobs.first { $0.id == id }
    }

    func stopAll() {
        jobs.forEach { $0.stop() }
    }

    /// Quita de la lista los que ya terminaron.
    func clearFinished() {
        jobs.removeAll { !$0.isRunning }
    }
}
