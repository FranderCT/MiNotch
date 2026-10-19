import AppKit

/// Carpeta donde trabaja el asistente: lee, escribe y ejecuta comandos solo dentro de ella.
@MainActor
final class Workspace: ObservableObject {
    static let defaultDirectory = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Documents/PERSONAL/ASISTENTE-NOTCH", isDirectory: true)

    private static let directoryKey = "workspaceDirectory"
    private static let recentsKey = "workspaceRecents"
    private static let maxRecents = 8

    @Published private(set) var directory: URL
    /// Carpetas usadas, la más reciente primero (incluye la actual).
    @Published private(set) var recents: [URL]

    init() {
        let defaults = UserDefaults.standard
        let saved = defaults.string(forKey: Self.directoryKey).map { URL(fileURLWithPath: $0, isDirectory: true) }
        let directory = saved.flatMap { Self.isDirectory($0) ? $0 : nil } ?? Self.defaultDirectory
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        self.directory = directory
        recents = (defaults.stringArray(forKey: Self.recentsKey) ?? [])
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
        recents = Array(([url] + recents.filter { $0.path != url.path }).prefix(Self.maxRecents))
        UserDefaults.standard.set(url.path, forKey: Self.directoryKey)
        UserDefaults.standard.set(recents.map(\.path), forKey: Self.recentsKey)
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
}
