import AppKit

/// Carpeta donde trabaja el asistente de una pestaña: lee, escribe y ejecuta comandos solo dentro de ella.
@MainActor
final class Workspace: ObservableObject {
    static let defaultDirectory = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Documents/PERSONAL/ASISTENTE-NOTCH", isDirectory: true)

    private static let directoryKey = "workspaceDirectory"
    private static let recentsKey = "workspaceRecents"
    private static let maxRecents = 8

    @Published private(set) var directory: URL
    /// Repositorio git que contiene la carpeta, o nil si no está en uno.
    @Published private(set) var git: GitInfo?
    private var gitStatusTask: Task<Void, Never>?

    /// Sin `directory`: la última carpeta usada (o la de por defecto).
    init(directory: URL? = nil) {
        let saved = UserDefaults.standard.string(forKey: Self.directoryKey).map { URL(fileURLWithPath: $0, isDirectory: true) }
        let directory = [directory, saved].compactMap { $0 }.first(where: Self.isDirectory) ?? Self.defaultDirectory
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        self.directory = directory
        refreshGit()
    }

    /// Carpetas usadas, la más reciente primero (incluye la actual). Compartidas entre pestañas.
    var recents: [URL] {
        (UserDefaults.standard.stringArray(forKey: Self.recentsKey) ?? [])
            .map { URL(fileURLWithPath: $0, isDirectory: true) }
            .filter(Self.isDirectory)
    }

    /// Ruta corta para mostrar: "~/Documents/…".
    var displayPath: String {
        (directory.path as NSString).abbreviatingWithTildeInPath
    }

    func move(to url: URL) {
        let url = url.standardizedFileURL
        guard Self.isDirectory(url) else { return }
        directory = url
        let recents = ([url] + recents.filter { $0.path != url.path }).prefix(Self.maxRecents)
        UserDefaults.standard.set(url.path, forKey: Self.directoryKey)
        UserDefaults.standard.set(recents.map(\.path), forKey: Self.recentsKey)
        refreshGit()
    }

    func chooseDirectory() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.directoryURL = directory
        panel.prompt = "Usar esta carpeta"
        panel.message = "Elegí la carpeta donde va a trabajar el asistente."
        NSApp.activate()
        if panel.runModal() == .OK, let url = panel.url {
            move(to: url)
        }
    }

    func revealInFinder() {
        NSWorkspace.shared.open(directory)
    }

    nonisolated static func isDirectory(_ url: URL) -> Bool {
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) && isDirectory.boolValue
    }

    // MARK: - Git

    /// La rama se lee al instante (es un archivo); si hay cambios sin commitear, con `git status` en segundo plano.
    /// Se llama al abrir el notch, al cambiar de carpeta o de pestaña y al terminar cada respuesta.
    func refreshGit() {
        gitStatusTask?.cancel()
        guard var info = GitInfo.read(at: directory) else {
            git = nil
            return
        }
        // Mientras llega el estado nuevo, se conserva el anterior si es el mismo repo.
        if let current = git, current.root == info.root {
            info.hasChanges = current.hasChanges
            info.insertions = current.insertions
            info.deletions = current.deletions
        }
        git = info
        let root = info.root
        gitStatusTask = Task { [weak self] in
            let status = await GitInfo.status(at: root)
            guard let self, !Task.isCancelled, self.git?.root == root else { return }
            self.git?.hasChanges = status?.hasChanges
            self.git?.insertions = status?.insertions ?? 0
            self.git?.deletions = status?.deletions ?? 0
        }
    }
}

/// Rama y estado del repositorio git que contiene una carpeta.
struct GitInfo: Equatable, Sendable {
    /// Carpeta raíz del repositorio (la que tiene .git).
    let root: URL
    /// Nombre de la rama, o el commit abreviado si HEAD está separado.
    let branch: String
    let isDetached: Bool
    /// nil mientras no se sabe.
    var hasChanges: Bool?
    /// Líneas agregadas y quitadas respecto del último commit (`git diff --shortstat HEAD`).
    var insertions = 0
    var deletions = 0

    /// Una línea para el system prompt.
    var summary: String {
        let head = isDetached ? "HEAD separado en el commit \(branch)" : "rama \(branch)"
        let changes = switch hasChanges {
        case true?: ", con cambios sin commitear (+\(insertions) −\(deletions) líneas)"
        case false?: ", sin cambios pendientes"
        case nil: ""
        }
        return "Está dentro del repositorio git \(root.path) (\(head)\(changes))."
    }

    /// Busca .git subiendo desde `directory` y lee HEAD. Sin procesos: es rápido.
    static func read(at directory: URL) -> GitInfo? {
        var folder = directory.standardizedFileURL
        while true {
            let dotGit = folder.appendingPathComponent(".git")
            if let gitDir = gitDirectory(dotGit), let head = try? String(contentsOf: gitDir.appendingPathComponent("HEAD"), encoding: .utf8) {
                let head = head.trimmingCharacters(in: .whitespacesAndNewlines)
                if head.hasPrefix("ref: ") {
                    let ref = head.dropFirst(5)
                    let branch = ref.hasPrefix("refs/heads/") ? String(ref.dropFirst(11)) : String(ref)
                    return GitInfo(root: folder, branch: branch, isDetached: false)
                }
                return GitInfo(root: folder, branch: String(head.prefix(7)), isDetached: true)
            }
            let parent = folder.deletingLastPathComponent()
            if parent.path == folder.path { return nil }
            folder = parent
        }
    }

    /// `.git` es una carpeta, o un archivo "gitdir: …" en worktrees y submódulos.
    private static func gitDirectory(_ dotGit: URL) -> URL? {
        if Workspace.isDirectory(dotGit) { return dotGit }
        guard let text = try? String(contentsOf: dotGit, encoding: .utf8), text.hasPrefix("gitdir:") else { return nil }
        let path = text.dropFirst(7).trimmingCharacters(in: .whitespacesAndNewlines)
        return path.hasPrefix("/")
            ? URL(fileURLWithPath: path)
            : dotGit.deletingLastPathComponent().appendingPathComponent(path).standardizedFileURL
    }

    /// Cambios sin commitear (`git status --porcelain`, incluye archivos nuevos) y líneas +/−. nil si git falla.
    static func status(at root: URL) async -> (hasChanges: Bool, insertions: Int, deletions: Int)? {
        await Task.detached(priority: .utility) {
            guard let porcelain = run(["status", "--porcelain"], in: root) else { return nil }
            // "3 files changed, 326 insertions(+), 19 deletions(-)"; sin commits todavía, falla: 0 y 0.
            let stat = run(["diff", "--shortstat", "HEAD"], in: root) ?? ""
            func count(_ word: String) -> Int {
                stat.firstMatch(of: try! Regex("(\\d+) \(word)"))
                    .flatMap { Int($0.output[1].substring ?? "") } ?? 0
            }
            return (!porcelain.isEmpty, count("insertion"), count("deletion"))
        }.value
    }

    private static func run(_ args: [String], in root: URL) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = ["-C", root.path] + args
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return process.terminationStatus == 0 ? String(decoding: data, as: UTF8.self) : nil
    }
}
