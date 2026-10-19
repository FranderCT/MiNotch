import Foundation

/// Llamada a una herramienta pedida por el modelo (formato compatible con OpenAI).
struct ToolCall: Sendable {
    var id: String
    var name: String
    /// JSON tal como lo escribió el modelo; puede llegar en pedazos durante el streaming.
    var arguments: String

    /// Los argumentos como texto. nil si el JSON es inválido.
    var parsedArguments: [String: String]? {
        let json = arguments.trimmingCharacters(in: .whitespacesAndNewlines)
        if json.isEmpty { return [:] }
        guard let object = try? JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any] else { return nil }
        return object.mapValues { $0 as? String ?? "\($0)" }
    }
}

/// Resultado que vuelve al modelo y cómo se muestra en el chat.
struct ToolOutcome: Sendable {
    var text: String
    var failed = false
}

/// Acción que el usuario tiene que aprobar antes de ejecutarse.
struct ToolApproval: Sendable {
    let icon: String
    let title: String
    /// Contenido, cambio o comando a revisar.
    let detail: String
    /// Parece peligroso: se pregunta aunque esté el modo automático. Dice por qué.
    var riskReason: String?
}

/// Cuánto pregunta el asistente antes de escribir, ejecutar o cambiar de carpeta.
enum ApprovalMode: String, CaseIterable, Sendable {
    /// Cada acción espera aprobación.
    case ask
    /// Todo sin preguntar, salvo los comandos que parecen peligrosos.
    case auto

    static let defaultsKey = "approvalMode"

    var title: String {
        switch self {
        case .ask: "Preguntar"
        case .auto: "Automático"
        }
    }

    var icon: String {
        switch self {
        case .ask: "hand.raised"
        case .auto: "bolt.fill"
        }
    }
}

/// Herramientas del asistente. Las que solo leen se ejecutan solas; las que escriben, ejecutan
/// o cambian de carpeta piden aprobación. Todas trabajan dentro de la carpeta de trabajo.
enum AgentTool: String, CaseIterable, Sendable {
    case listDirectory = "list_directory"
    case readFile = "read_file"
    case searchFiles = "search_files"
    case writeFile = "write_file"
    case editFile = "edit_file"
    case runCommand = "run_command"
    case changeDirectory = "change_directory"
    case terminalStart = "terminal_start"
    case terminalSend = "terminal_send"
    case terminalRead = "terminal_read"
    case terminalClose = "terminal_close"
    case tabList = "tab_list"
    case tabOpen = "tab_open"
    case tabSend = "tab_send"
    case tabRead = "tab_read"
    case tabClose = "tab_close"
    case agentStart = "agent_start"
    case agentRead = "agent_read"
    case agentSend = "agent_send"
    case agentList = "agent_list"
    case agentStop = "agent_stop"

    private static let readLimit = 60_000
    private static let listLimit = 300
    private static let searchLimit = 200
    private static let commandOutputLimit = 20_000
    private static let commandTimeout: TimeInterval = 120

    var icon: String {
        switch self {
        case .listDirectory: "folder"
        case .readFile: "doc.text"
        case .searchFiles: "magnifyingglass"
        case .writeFile: "square.and.pencil"
        case .editFile: "pencil"
        case .runCommand: "terminal"
        case .changeDirectory: "arrow.right.circle"
        case .terminalStart: "apple.terminal"
        case .terminalSend: "keyboard"
        case .terminalRead: "text.alignleft"
        case .terminalClose: "xmark.square"
        case .tabList: "rectangle.stack"
        case .tabOpen: "plus.rectangle.on.rectangle"
        case .tabSend: "arrow.up.right.square"
        case .tabRead: "arrow.down.left.square"
        case .tabClose: "xmark.rectangle"
        case .agentStart: "cpu"
        case .agentRead: "tray.and.arrow.down"
        case .agentSend: "arrow.uturn.right"
        case .agentList: "list.bullet"
        case .agentStop: "stop.circle"
        }
    }

    /// Dirigen agentes externos (Claude Code, Codex…): las ejecuta ChatSession.
    var isExternalAgent: Bool {
        [.agentStart, .agentRead, .agentSend, .agentList, .agentStop].contains(self)
    }

    /// Coordinan otras pestañas: las ejecuta ChatSession, que conoce ChatTabs. No piden aprobación
    /// (no tocan archivos ni ejecutan nada); lo que haga cada pestaña se aprueba en esa pestaña.
    var isTab: Bool {
        [.tabList, .tabOpen, .tabSend, .tabRead, .tabClose].contains(self)
    }

    /// Las de terminal las ejecuta ChatSession: necesitan las sesiones abiertas y pedir contraseñas.
    var isTerminal: Bool {
        [.terminalStart, .terminalSend, .terminalRead, .terminalClose].contains(self)
    }

    /// Una línea para el chat: qué hizo (o intentó hacer) el asistente.
    func summary(_ args: [String: String]) -> String {
        let path = args["path"] ?? "."
        return switch self {
        case .listDirectory: "Listar \(path)"
        case .readFile: "Leer \(path)"
        case .searchFiles: "Buscar “\(args["pattern"] ?? "")” en \(path)"
        case .writeFile: "Escribir \(path)"
        case .editFile: "Editar \(path)"
        case .runCommand: "$ \(args["command"] ?? "")"
        case .changeDirectory: "Ir a \(path)"
        case .terminalStart: "▶ \(args["command"] ?? "")"
        case .terminalSend: "[\(args["session"] ?? "?")] \(Self.visibleInput(args["input"] ?? ""))"
        case .terminalRead: "[\(args["session"] ?? "?")] leer salida"
        case .terminalClose: "[\(args["session"] ?? "?")] cerrar"
        case .tabList: "Ver pestañas"
        case .tabOpen: "Abrir pestaña \(args["name"] ?? args["directory"] ?? "")"
        case .tabSend: "→ pestaña \(args["tab"] ?? "?"): \(args["message"] ?? "")"
        case .tabRead: "← pestaña \(args["tab"] ?? "?")"
        case .tabClose: "Cerrar pestaña \(args["tab"] ?? "?")"
        case .agentStart: "\(ExternalAgentKind(rawValue: args["agent"] ?? "")?.displayName ?? args["agent"] ?? "?"): \(args["task"] ?? "")"
        case .agentRead: "← trabajo \(args["job"] ?? "?")"
        case .agentSend: "→ trabajo \(args["job"] ?? "?"): \(args["message"] ?? "")"
        case .agentList: "Ver agentes externos"
        case .agentStop: "Detener trabajo \(args["job"] ?? "?")"
        }
    }

    /// Caracteres de control legibles: "\u{03}" → "⌃C".
    static func visibleInput(_ input: String) -> String {
        input.unicodeScalars.map { scalar in
            switch scalar.value {
            case 0x0D, 0x0A: "⏎"
            case 0x09: "⇥"
            case 0x1B: "⎋"
            case 1...26: "⌃" + String(UnicodeScalar(scalar.value + 64)!)
            default: String(scalar)
            }
        }.joined()
    }

    // MARK: - Definiciones para la API

    static let definitions: [ToolDefinition] = [
        ToolDefinition(
            name: listDirectory.rawValue,
            description: "Lista el contenido de una carpeta (las subcarpetas terminan en /).",
            properties: ["path": "Ruta relativa a la carpeta de trabajo; \".\" es la carpeta de trabajo."],
            required: ["path"]
        ),
        ToolDefinition(
            name: readFile.rawValue,
            description: "Lee un archivo de texto completo.",
            properties: ["path": "Ruta relativa a la carpeta de trabajo."],
            required: ["path"]
        ),
        ToolDefinition(
            name: searchFiles.rawValue,
            description: "Busca una expresión regular (grep -E) en los archivos de texto, recursivamente. Devuelve archivo:línea:texto.",
            properties: [
                "pattern": "Expresión regular extendida.",
                "path": "Carpeta o archivo donde buscar, relativo a la carpeta de trabajo. Por defecto \".\".",
            ],
            required: ["pattern"]
        ),
        ToolDefinition(
            name: writeFile.rawValue,
            description: "Crea un archivo o lo reemplaza entero (crea las carpetas que falten). El usuario debe aprobarlo.",
            properties: [
                "path": "Ruta relativa a la carpeta de trabajo.",
                "content": "Contenido completo del archivo.",
            ],
            required: ["path", "content"]
        ),
        ToolDefinition(
            name: editFile.rawValue,
            description: "Reemplaza un fragmento exacto de un archivo por otro. old_text debe aparecer una sola vez: incluí contexto suficiente. El usuario debe aprobarlo.",
            properties: [
                "path": "Ruta relativa a la carpeta de trabajo.",
                "old_text": "Texto actual, exacto (incluida la indentación).",
                "new_text": "Texto nuevo.",
            ],
            required: ["path", "old_text", "new_text"]
        ),
        ToolDefinition(
            name: runCommand.rawValue,
            description: "Ejecuta un comando de zsh en la carpeta de trabajo y devuelve la salida y el código de salida. Sin entrada interactiva; se corta a los 120 s. El usuario debe aprobarlo.",
            properties: ["command": "Comando de zsh."],
            required: ["command"]
        ),
        ToolDefinition(
            name: changeDirectory.rawValue,
            description: "Cambia la carpeta de trabajo (como cd). Puede ser una ruta absoluta, relativa o con ~. El usuario debe aprobarlo.",
            properties: ["path": "Carpeta nueva."],
            required: ["path"]
        ),
        ToolDefinition(
            name: terminalStart.rawValue,
            description: "Abre una sesión de terminal interactiva (con PTY) que queda viva: ssh usuario@host, un REPL, etc. Devuelve el número de sesión y la salida inicial. Si aparece un pedido de contraseña, el usuario la escribe solo: nunca se la pidas. El usuario debe aprobarlo.",
            properties: ["command": "Comando que abre la sesión, por ejemplo: ssh usuario@servidor."],
            required: ["command"]
        ),
        ToolDefinition(
            name: terminalSend.rawValue,
            description: "Escribe en una sesión abierta (por defecto agrega Enter) y devuelve la salida nueva. Para Ctrl+C mandá input \"\\u0003\" con enter \"false\". El usuario debe aprobarlo.",
            properties: [
                "session": "Número de sesión.",
                "input": "Texto a escribir, por ejemplo un comando.",
                "enter": "\"true\" (por defecto) para apretar Enter al final, \"false\" para no.",
                "wait_seconds": "Máximo a esperar la salida (por defecto 15, hasta 120).",
            ],
            required: ["session", "input"]
        ),
        ToolDefinition(
            name: terminalRead.rawValue,
            description: "Espera y devuelve la salida nueva de una sesión, para comandos que tardan.",
            properties: [
                "session": "Número de sesión.",
                "wait_seconds": "Máximo a esperar (por defecto 15, hasta 120).",
            ],
            required: ["session"]
        ),
        ToolDefinition(
            name: terminalClose.rawValue,
            description: "Cierra una sesión de terminal.",
            properties: ["session": "Número de sesión."],
            required: ["session"]
        ),
        ToolDefinition(
            name: tabList.rawValue,
            description: "Lista las pestañas del notch: número, nombre, carpeta, rama, sesiones de terminal, estado (libre, trabajando o esperando al usuario) y su última respuesta.",
            properties: [:],
            required: []
        ),
        ToolDefinition(
            name: tabOpen.rawValue,
            description: "Abre otra pestaña: un asistente independiente, con su carpeta y sus sesiones de terminal. Opcionalmente le da una primera tarea, que empieza a hacer enseguida.",
            properties: [
                "name": "Nombre corto para la pestaña, por ejemplo \"srv-8\".",
                "directory": "Carpeta de trabajo; por defecto la de esta pestaña.",
                "task": "Primera tarea, escrita como se la darías a un colega (qué hacer y qué responder al terminar).",
            ],
            required: []
        ),
        ToolDefinition(
            name: tabSend.rawValue,
            description: "Le manda una tarea a otra pestaña (tiene que estar libre). Con wait \"true\" (por defecto) espera y devuelve su respuesta final; con \"false\" vuelve enseguida, para trabajar con varias en paralelo y después juntar los resultados con tab_read.",
            properties: [
                "tab": "Número de pestaña.",
                "message": "La tarea.",
                "wait": "\"true\" (por defecto) o \"false\".",
                "wait_seconds": "Máximo a esperar (por defecto 120, hasta 600).",
            ],
            required: ["tab", "message"]
        ),
        ToolDefinition(
            name: tabRead.rawValue,
            description: "Espera a que otra pestaña termine lo que está haciendo (o necesite al usuario) y devuelve su última respuesta.",
            properties: [
                "tab": "Número de pestaña.",
                "wait_seconds": "Máximo a esperar (por defecto 120, hasta 600).",
            ],
            required: ["tab"]
        ),
        ToolDefinition(
            name: tabClose.rawValue,
            description: "Cierra otra pestaña (y sus sesiones de terminal).",
            properties: ["tab": "Número de pestaña."],
            required: ["tab"]
        ),
        ToolDefinition(
            name: agentStart.rawValue,
            description: "Lanza en segundo plano un agente de programación externo (su CLI sin interfaz) con una tarea, en una carpeta. Vuelve enseguida con un número de trabajo: usá agent_read para el resultado. Se pueden lanzar varios en paralelo. Agentes: claude (Claude Code), codex (Codex), cursor (Cursor Agent), grok (Grok), opencode (OpenCode). Con access edit o full el usuario debe aprobarlo.",
            properties: [
                "agent": "claude, codex, cursor, grok u opencode.",
                "task": "La tarea completa y autocontenida: el agente no ve esta conversación. Incluí contexto, archivos relevantes y qué tiene que responder al terminar.",
                "access": "read (solo leer y planear, por defecto), edit (editar archivos de la carpeta) o full (también ejecutar comandos sin preguntar).",
                "directory": "Carpeta donde trabaja; por defecto la de esta pestaña.",
                "model": "Opcional: modelo del agente (por ejemplo sonnet o haiku para Claude, que por defecto usa uno caro).",
            ],
            required: ["agent", "task"]
        ),
        ToolDefinition(
            name: agentRead.rawValue,
            description: "Espera a que un trabajo de un agente externo termine (o se acabe el tiempo) y devuelve su respuesta, duración y costo.",
            properties: [
                "job": "Número de trabajo.",
                "wait_seconds": "Máximo a esperar (por defecto 300, hasta 1800).",
            ],
            required: ["job"]
        ),
        ToolDefinition(
            name: agentSend.rawValue,
            description: "Sigue la misma sesión de un agente externo que ya terminó, con un mensaje nuevo (por ejemplo: \"ahora agregá tests a eso\"). Vuelve enseguida: usá agent_read.",
            properties: [
                "job": "Número de trabajo.",
                "message": "El mensaje para el agente.",
            ],
            required: ["job", "message"]
        ),
        ToolDefinition(
            name: agentList.rawValue,
            description: "Lista los agentes externos instalados y los trabajos de esta pestaña con su estado.",
            properties: [:],
            required: []
        ),
        ToolDefinition(
            name: agentStop.rawValue,
            description: "Detiene un trabajo de un agente externo.",
            properties: ["job": "Número de trabajo."],
            required: ["job"]
        ),
    ]

    // MARK: - Aprobación

    /// nil si la herramienta solo lee y se ejecuta sin preguntar.
    func approval(for args: [String: String], in root: URL) -> ToolApproval? {
        let path = args["path"] ?? ""
        switch self {
        case .listDirectory, .readFile, .searchFiles, .terminalRead, .terminalClose,
             .tabList, .tabOpen, .tabSend, .tabRead, .tabClose, .agentRead, .agentList, .agentStop:
            return nil
        case .agentStart, .agentSend:
            // agent_send lo resuelve ChatSession (necesita el trabajo para saber su acceso).
            return nil
        case .writeFile:
            let exists = Self.resolve(path, in: root).map { FileManager.default.fileExists(atPath: $0.path) } ?? false
            let content = args["content"] ?? ""
            // El salto de línea final no cuenta como otra línea.
            let lines = content.isEmpty ? 0 : content.split(separator: "\n", omittingEmptySubsequences: false).count - (content.hasSuffix("\n") ? 1 : 0)
            return ToolApproval(
                icon: icon,
                title: exists ? "Reemplazar \(path)" : "Crear \(path)",
                detail: "\(lines) \(lines == 1 ? "línea" : "líneas")\n\n\(content.prefix(4000))"
            )
        case .editFile:
            return ToolApproval(
                icon: icon,
                title: "Editar \(path)",
                detail: "− \((args["old_text"] ?? "").prefix(2000))\n\n+ \((args["new_text"] ?? "").prefix(2000))"
            )
        case .runCommand:
            let command = args["command"] ?? ""
            return ToolApproval(icon: icon, title: "Ejecutar en \(root.lastPathComponent)", detail: command, riskReason: Self.riskReason(command))
        case .changeDirectory:
            let target = Self.directoryURL(path, from: root)
            return ToolApproval(icon: icon, title: "Mover el asistente a otra carpeta", detail: (target.path as NSString).abbreviatingWithTildeInPath)
        case .terminalStart:
            let command = args["command"] ?? ""
            return ToolApproval(icon: icon, title: "Abrir una sesión de terminal en \(root.lastPathComponent)", detail: command, riskReason: Self.riskReason(command))
        case .terminalSend:
            let enter = args["enter"]?.lowercased() != "false"
            return ToolApproval(
                icon: icon,
                title: args["session"] == "0" ? "Escribir en la terminal de la pestaña" : "Escribir en la sesión \(args["session"] ?? "?")",
                detail: Self.visibleInput(args["input"] ?? "") + (enter ? " ⏎" : ""),
                riskReason: Self.riskReason(args["input"] ?? "")
            )
        }
    }

    /// Comandos que en modo automático se preguntan igual. No es una lista completa: es una red de seguridad.
    private static let riskyCommands: [(pattern: String, reason: String)] = [
        (#"\brm\s+(-\S*[rRf]|--recursive|--force)"#, "borra archivos de forma recursiva o forzada"),
        (#"\bsudo\b"#, "ejecuta como administrador"),
        (#"\bgit\s+push\b.*(\s-f\b|--force)"#, "sobrescribe el historial remoto"),
        (#"\bgit\s+(reset\s+--hard|clean\s+-\S*f)"#, "descarta cambios sin vuelta atrás"),
        (#"\b(mkfs|diskutil\s+(erase|partition)|dd\s+if=)"#, "escribe directo sobre un disco"),
        (#"\b(shutdown|reboot|halt|poweroff)\b"#, "apaga o reinicia la máquina"),
        (#"\bchmod\s+-R\b|\bchown\s+-R\b"#, "cambia permisos de forma recursiva"),
        (#"\b(kill|killall|pkill)\b"#, "mata procesos"),
        (#"\b(DROP|TRUNCATE)\s+(TABLE|DATABASE)\b"#, "borra datos de una base de datos"),
        (#"\|\s*(sh|bash|zsh)\b"#, "ejecuta un script descargado o generado"),
    ]

    /// nil si el comando no coincide con nada peligroso conocido.
    static func riskReason(_ command: String) -> String? {
        riskyCommands.first { command.range(of: $0.pattern, options: [.regularExpression, .caseInsensitive]) != nil }?.reason
    }

    // MARK: - Ejecución

    /// Fuera del hilo principal. `change_directory` lo resuelve ChatSession (cambia Workspace).
    func execute(_ args: [String: String], in root: URL) async -> ToolOutcome {
        if self == .runCommand {
            return await Self.runCommand(args["command"] ?? "", in: root)
        }
        return await Task.detached(priority: .userInitiated) {
            do {
                return try perform(args, in: root)
            } catch {
                return ToolOutcome(text: "Error: \(error.localizedDescription)", failed: true)
            }
        }.value
    }

    private func perform(_ args: [String: String], in root: URL) throws -> ToolOutcome {
        let fileManager = FileManager.default
        switch self {
        case .listDirectory:
            let url = try Self.resolveOrThrow(args["path"] ?? ".", in: root)
            let entries = try fileManager.contentsOfDirectory(at: url, includingPropertiesForKeys: [.isDirectoryKey])
                .filter { $0.lastPathComponent != ".DS_Store" }
                .map { $0.lastPathComponent + (Workspace.isDirectory($0) ? "/" : "") }
                .sorted { $0.localizedStandardCompare($1) == .orderedAscending }
            if entries.isEmpty { return ToolOutcome(text: "(carpeta vacía)") }
            let shown = entries.prefix(Self.listLimit).joined(separator: "\n")
            return ToolOutcome(text: entries.count > Self.listLimit ? "\(shown)\n… y \(entries.count - Self.listLimit) más" : shown)

        case .readFile:
            let url = try Self.resolveOrThrow(args["path"] ?? "", in: root)
            guard let text = String(data: try Data(contentsOf: url), encoding: .utf8) else {
                throw ToolError("No es un archivo de texto (UTF-8).")
            }
            guard text.count > Self.readLimit else { return ToolOutcome(text: text) }
            return ToolOutcome(text: "\(text.prefix(Self.readLimit))\n… [recortado: el archivo tiene \(text.count) caracteres]")

        case .searchFiles:
            let url = try Self.resolveOrThrow(args["path"] ?? ".", in: root)
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/grep")
            process.arguments = ["-rInE", "--exclude-dir=.git", "--exclude-dir=node_modules", "--exclude-dir=.build",
                                 "-e", args["pattern"] ?? "", url.path]
            process.currentDirectoryURL = root
            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = pipe
            try process.run()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            // Rutas relativas: más cortas para el modelo.
            let lines = String(decoding: data, as: UTF8.self)
                .split(separator: "\n")
                .map { $0.replacingOccurrences(of: root.path + "/", with: "") }
            if lines.isEmpty { return ToolOutcome(text: "Sin resultados.") }
            let shown = lines.prefix(Self.searchLimit).joined(separator: "\n")
            return ToolOutcome(text: lines.count > Self.searchLimit ? "\(shown)\n… y \(lines.count - Self.searchLimit) más" : shown)

        case .writeFile:
            let url = try Self.resolveOrThrow(args["path"] ?? "", in: root)
            let existed = fileManager.fileExists(atPath: url.path)
            try fileManager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try (args["content"] ?? "").write(to: url, atomically: true, encoding: .utf8)
            return ToolOutcome(text: existed ? "Archivo reemplazado." : "Archivo creado.")

        case .editFile:
            let url = try Self.resolveOrThrow(args["path"] ?? "", in: root)
            let oldText = args["old_text"] ?? ""
            guard !oldText.isEmpty else { throw ToolError("old_text está vacío.") }
            let text = try String(contentsOf: url, encoding: .utf8)
            let count = text.components(separatedBy: oldText).count - 1
            guard count == 1 else {
                throw ToolError(count == 0
                    ? "old_text no aparece en el archivo: leelo de nuevo y copiá el fragmento exacto."
                    : "old_text aparece \(count) veces: agregá contexto para que sea único.")
            }
            try text.replacingOccurrences(of: oldText, with: args["new_text"] ?? "").write(to: url, atomically: true, encoding: .utf8)
            return ToolOutcome(text: "Archivo editado.")

        case .runCommand, .changeDirectory, .terminalStart, .terminalSend, .terminalRead, .terminalClose,
             .tabList, .tabOpen, .tabSend, .tabRead, .tabClose,
             .agentStart, .agentRead, .agentSend, .agentList, .agentStop:
            throw ToolError("Se ejecuta en otro lado.")
        }
    }

    /// zsh de login (para tener el PATH de Homebrew, fnm, etc.). La salida se acumula a medida que llega
    /// y se deja de leer cuando el comando termina, aunque algún proceso hijo siga vivo.
    private static func runCommand(_ command: String, in root: URL) async -> ToolOutcome {
        nonisolated(unsafe) let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = ["-l", "-c", command]
        process.currentDirectoryURL = root
        process.standardInput = FileHandle.nullDevice
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        let output = OutputBuffer()
        pipe.fileHandleForReading.readabilityHandler = { output.append($0.availableData) }

        return await withTaskCancellationHandler {
            await Task.detached {
                do {
                    try process.run()
                } catch {
                    return ToolOutcome(text: "No se pudo ejecutar: \(error.localizedDescription)", failed: true)
                }
                let pid = process.processIdentifier
                let timeout = DispatchWorkItem { kill(pid, SIGTERM) }
                DispatchQueue.global().asyncAfter(deadline: .now() + commandTimeout, execute: timeout)
                process.waitUntilExit()
                timeout.cancel()
                // Margen para la última salida que quedó en el pipe.
                try? await Task.sleep(for: .milliseconds(150))
                pipe.fileHandleForReading.readabilityHandler = nil

                var text = output.string
                if text.count > commandOutputLimit {
                    text = "\(text.prefix(commandOutputLimit / 3))\n… [salida recortada] …\n\(text.suffix(commandOutputLimit * 2 / 3))"
                }
                let status = process.terminationStatus
                let killed = process.terminationReason == .uncaughtSignal
                let header = killed ? "Cortado (señal \(status); límite de \(Int(commandTimeout)) s o cancelado)" : "Código de salida: \(status)"
                return ToolOutcome(text: "\(header)\n\(text.isEmpty ? "(sin salida)" : text)", failed: killed || status != 0)
            }.value
        } onCancel: {
            if process.isRunning { process.terminate() }
        }
    }

    // MARK: - Rutas

    /// Ruta pedida por el modelo → URL dentro de la carpeta de trabajo; nil si se sale de ella.
    static func resolve(_ path: String, in root: URL) -> URL? {
        let base = root.standardizedFileURL.resolvingSymlinksInPath().path
        let url = directoryURL(path, from: root).resolvingSymlinksInPath()
        return url.path == base || url.path.hasPrefix(base + "/") ? url : nil
    }

    private static func resolveOrThrow(_ path: String, in root: URL) throws -> URL {
        guard let url = resolve(path, in: root) else {
            throw ToolError("\(path) está fuera de la carpeta de trabajo (\(root.path)). Usá change_directory si hace falta.")
        }
        return url
    }

    /// Relativa a `root`, absoluta o con ~; sin validar que quede adentro.
    static func directoryURL(_ path: String, from root: URL) -> URL {
        let expanded = (path as NSString).expandingTildeInPath
        let url = expanded.hasPrefix("/") ? URL(fileURLWithPath: expanded) : root.appendingPathComponent(expanded)
        return url.standardizedFileURL
    }
}

struct ToolError: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

/// Salida de un comando, escrita desde el hilo del pipe y leída al terminar.
final class OutputBuffer: @unchecked Sendable {
    private let lock = NSLock()
    private var data = Data()

    func append(_ chunk: Data) {
        lock.withLock { data.append(chunk) }
    }

    var string: String {
        lock.withLock { String(decoding: data, as: UTF8.self) }
    }
}

/// Definición de una herramienta en el formato de la API (todos los parámetros son texto).
struct ToolDefinition: Encodable, Sendable {
    struct Function: Encodable, Sendable {
        let name: String
        let description: String
        let parameters: Parameters
    }

    struct Parameters: Encodable, Sendable {
        struct Property: Encodable, Sendable {
            let type = "string"
            let description: String
        }

        let type = "object"
        let properties: [String: Property]
        let required: [String]
    }

    let type = "function"
    let function: Function

    init(name: String, description: String, properties: [String: String], required: [String]) {
        function = Function(
            name: name,
            description: description,
            parameters: Parameters(properties: properties.mapValues { Parameters.Property(description: $0) }, required: required)
        )
    }
}
