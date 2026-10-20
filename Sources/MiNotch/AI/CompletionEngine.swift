import Foundation

/// Una opción del menú de completado.
struct Completion: Identifiable, Equatable, Sendable {
    enum Kind: String, Sendable {
        case directory = "Carpeta"
        case file = "Archivo"
        case command = "Comando"
        case builtin = "Integrado"
        case subcommand = "Subcomando"
        case parent = "Carpeta superior"
        case recent = "Reciente"

        var icon: String {
            switch self {
            case .parent: "arrow.up.left"
            case .recent: "clock"
            case .directory: "folder.fill"
            case .file: "doc"
            case .command, .builtin: "terminal"
            case .subcommand: "arrow.triangle.branch"
            }
        }
    }

    let display: String
    /// Texto que reemplaza a la palabra que se está escribiendo (ya escapado para el shell).
    let insertion: String
    let kind: Kind
    var id: String { "\(kind.rawValue):\(insertion)" }
}

struct CompletionResult: Equatable, Sendable {
    /// Lo que ya estaba escrito antes de la palabra: el borrador nuevo es `head + insertion`.
    let head: String
    let items: [Completion]
}

/// Completado local: carpetas y archivos, comandos del PATH y subcomandos de git. Solo lee nombres de carpetas.
enum CompletionEngine {
    static let builtins = [
        "alias", "bg", "cd", "echo", "exit", "export", "fg", "history", "jobs", "kill",
        "popd", "pushd", "pwd", "set", "source", "unalias", "unset", "which",
    ]
    static let gitSubcommands = [
        "add", "bisect", "branch", "checkout", "cherry-pick", "clone", "commit", "diff", "fetch", "init",
        "log", "merge", "mv", "pull", "push", "rebase", "remote", "reset", "restore", "revert", "rm",
        "show", "stash", "status", "switch", "tag",
    ]
    /// Comandos que solo reciben carpetas.
    static let directoryOnly: Set<String> = ["cd", "pushd", "rmdir"]
    static let maxItems = 100

    struct Split: Equatable {
        let head: String
        let token: String
        /// Posición de la palabra: 0 es el comando.
        let wordIndex: Int
        let command: String?
    }

    /// Separa la última palabra (respeta los espacios escapados con barra) de lo anterior.
    static func split(_ draft: String) -> Split {
        var tokenStart = draft.startIndex
        var words: [String] = []
        var current = ""
        var escaped = false
        var index = draft.startIndex
        while index < draft.endIndex {
            let character = draft[index]
            let next = draft.index(after: index)
            if escaped {
                current.append(character)
                escaped = false
            } else if character == "\\" {
                current.append(character)
                escaped = true
            } else if character == " " || character == "\t" {
                if !current.isEmpty { words.append(current); current = "" }
                tokenStart = next
            } else {
                current.append(character)
            }
            index = next
        }
        // Si el borrador termina en espacio, la palabra actual está vacía.
        return Split(head: String(draft[..<tokenStart]), token: current, wordIndex: words.count, command: words.first)
    }

    static func completions(for draft: String, directory: URL, pathCommands: [String]) -> CompletionResult {
        let parts = split(draft)
        // Un comando con varias líneas o muy largo no se completa.
        guard !draft.contains("\n"), draft.count <= 2_000 else { return CompletionResult(head: parts.head, items: []) }

        var items: [Completion] = []
        if parts.wordIndex == 0 {
            // Sin nada escrito no se sugiere todo el PATH.
            if !parts.token.isEmpty {
                if parts.token.contains("/") {
                    items = pathCompletions(token: parts.token, directory: directory, onlyDirectories: false, executablesOnly: true)
                } else {
                    items = commandCompletions(prefix: parts.token, pathCommands: pathCommands)
                }
            }
        } else if parts.command == "git", parts.wordIndex == 1, !parts.token.hasPrefix("-") {
            items = gitSubcommands.filter { $0.hasPrefix(parts.token) }.map {
                Completion(display: $0, insertion: $0, kind: .subcommand)
            }
        } else if !parts.token.hasPrefix("-") {
            items = pathCompletions(token: parts.token, directory: directory,
                                    onlyDirectories: parts.command.map(directoryOnly.contains) ?? false, executablesOnly: false)
        }
        return CompletionResult(head: parts.head, items: Array(items.prefix(maxItems)))
    }

    static func commandCompletions(prefix: String, pathCommands: [String]) -> [Completion] {
        var seen = Set<String>()
        var result: [Completion] = []
        for (names, kind) in [(builtins, Completion.Kind.builtin), (pathCommands, .command)] {
            for name in names where name.hasPrefix(prefix) && name != prefix && seen.insert(name).inserted {
                result.append(Completion(display: name, insertion: InputPredictions.shellWord(name), kind: kind))
            }
        }
        return result.sorted { ($0.display.count, $0.display) < ($1.display.count, $1.display) }
    }

    static func pathCompletions(token: String, directory: URL, onlyDirectories: Bool, executablesOnly: Bool) -> [Completion] {
        let typed = token.replacingOccurrences(of: "\\ ", with: " ")
        let slash = typed.lastIndex(of: "/")
        let dirPart = slash.map { String(typed[...$0]) } ?? ""
        let namePrefix = slash.map { String(typed[typed.index(after: $0)...]) } ?? typed

        let base: URL
        if dirPart.isEmpty {
            base = directory
        } else if dirPart.hasPrefix("/") {
            base = URL(fileURLWithPath: dirPart, isDirectory: true)
        } else if dirPart.hasPrefix("~") {
            base = URL(fileURLWithPath: (dirPart as NSString).expandingTildeInPath, isDirectory: true)
        } else {
            base = directory.appendingPathComponent(dirPart, isDirectory: true)
        }
        let options: FileManager.DirectoryEnumerationOptions = namePrefix.hasPrefix(".") ? [] : [.skipsHiddenFiles]
        guard let urls = try? FileManager.default.contentsOfDirectory(
            at: base, includingPropertiesForKeys: [.isDirectoryKey], options: options
        ) else { return [] }

        let escapedDir = dirPart.map { $0 == " " ? "\\ " : String($0) }.joined()
        var result: [Completion] = []
        for url in urls {
            let name = url.lastPathComponent
            guard name.lowercased().hasPrefix(namePrefix.lowercased()),
                  !name.contains(where: { $0.isNewline }) else { continue }
            let isDirectory = (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
            if onlyDirectories, !isDirectory { continue }
            if executablesOnly, !isDirectory, !FileManager.default.isExecutableFile(atPath: url.path) { continue }
            let suffix = isDirectory ? "/" : ""
            result.append(Completion(
                display: name + suffix,
                insertion: escapedDir + InputPredictions.shellWord(name) + suffix,
                kind: isDirectory ? .directory : .file
            ))
        }
        return result.sorted {
            if ($0.kind == .directory) != ($1.kind == .directory) { return $0.kind == .directory }
            return $0.display.localizedStandardCompare($1.display) == .orderedAscending
        }
    }
}

/// Opciones del selector de carpeta (el chip de carpeta): la superior, las subcarpetas y las recientes.
enum DirectoryChoices {
    static let maxItems = 100

    /// `insertion` es la ruta absoluta a la que se hace `cd`.
    static func items(from directory: URL, recents: [URL]) -> [Completion] {
        let current = directory.standardizedFileURL
        var items: [Completion] = []
        let parent = current.deletingLastPathComponent().standardizedFileURL
        if parent.path != current.path {
            items.append(Completion(display: "..", insertion: parent.path, kind: .parent))
        }
        let urls = (try? FileManager.default.contentsOfDirectory(
            at: current, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles]
        )) ?? []
        let directories = urls.filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }
            .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
        for url in directories where !url.lastPathComponent.contains(where: { $0.isNewline }) {
            items.append(Completion(display: url.lastPathComponent + "/", insertion: url.standardizedFileURL.path, kind: .directory))
        }
        var seen = Set(items.map(\.insertion))
        seen.insert(current.path)
        for url in recents {
            let path = url.standardizedFileURL.path
            guard seen.insert(path).inserted else { continue }
            items.append(Completion(display: (path as NSString).abbreviatingWithTildeInPath, insertion: path, kind: .recent))
        }
        return Array(items.prefix(maxItems))
    }
}

/// Nombres de comandos del PATH del shell de login (el de la app solo trae /usr/bin y poco más). Se carga una vez.
final class PathCommands: @unchecked Sendable {
    static let shared = PathCommands()
    private let lock = NSLock()
    private var loaded: [String]?
    private var isLoading = false

    var names: [String] { lock.withLock { loaded ?? [] } }

    func loadIfNeeded() {
        let shouldLoad = lock.withLock { () -> Bool in
            guard loaded == nil, !isLoading else { return false }
            isLoading = true
            return true
        }
        guard shouldLoad else { return }
        DispatchQueue.global(qos: .utility).async { [self] in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/zsh")
            process.arguments = ["-l", "-c", "print -r -- $PATH"]
            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = FileHandle.nullDevice
            process.standardInput = FileHandle.nullDevice
            var path = ProcessInfo.processInfo.environment["PATH"] ?? "/usr/bin:/bin"
            if (try? process.run()) != nil {
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                process.waitUntilExit()
                let text = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
                if process.terminationStatus == 0, !text.isEmpty { path = text }
            }
            var names = Set<String>()
            for directory in path.split(separator: ":") {
                guard let files = try? FileManager.default.contentsOfDirectory(atPath: String(directory)) else { continue }
                for file in files where !file.hasPrefix(".") {
                    if FileManager.default.isExecutableFile(atPath: "\(directory)/\(file)") { names.insert(file) }
                }
            }
            let sorted = names.sorted()
            lock.withLock { loaded = sorted; isLoading = false }
        }
    }
}
