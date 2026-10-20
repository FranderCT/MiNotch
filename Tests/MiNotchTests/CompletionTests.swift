import Foundation

@main
struct CompletionTests {
    static func main() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("completion-tests-\(UUID().uuidString)")
        let fm = FileManager.default
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }
        for dir in ["Assets", "Sources", "my project", "scripts", ".hidden"] {
            try fm.createDirectory(at: root.appendingPathComponent(dir), withIntermediateDirectories: true)
        }
        try fm.createDirectory(at: root.appendingPathComponent("Sources/App"), withIntermediateDirectories: true)
        for file in ["Package.swift", "README.md", "run.sh"] { try Data().write(to: root.appendingPathComponent(file)) }
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: root.appendingPathComponent("run.sh").path)

        // split
        precondition(CompletionEngine.split("cd As") == .init(head: "cd ", token: "As", wordIndex: 1, command: "cd"))
        precondition(CompletionEngine.split("cd ") == .init(head: "cd ", token: "", wordIndex: 1, command: "cd"))
        precondition(CompletionEngine.split("gi") == .init(head: "", token: "gi", wordIndex: 0, command: nil))
        let escaped = CompletionEngine.split("cat my\\ pro")
        precondition(escaped.token == "my\\ pro" && escaped.head == "cat ", "espacio escapado: \(escaped)")

        // `cd ` lista solo carpetas visibles, primero (como en la captura de referencia).
        let cd = CompletionEngine.completions(for: "cd ", directory: root, pathCommands: [])
        precondition(cd.head == "cd ")
        precondition(cd.items.map(\.display) == ["Assets/", "my project/", "scripts/", "Sources/"], "cd: \(cd.items.map(\.display))")
        precondition(cd.items.allSatisfy { $0.kind == .directory })
        precondition(cd.items[1].insertion == "my\\ project/", "se escapa: \(cd.items[1].insertion)")

        // Prefijo sin distinguir mayúsculas; archivos después de carpetas.
        let s = CompletionEngine.completions(for: "ls s", directory: root, pathCommands: [])
        precondition(s.items.map(\.display) == ["scripts/", "Sources/"], "ls s: \(s.items.map(\.display))")
        let all = CompletionEngine.completions(for: "cat ", directory: root, pathCommands: [])
        precondition(all.items.map(\.display) == ["Assets/", "my project/", "scripts/", "Sources/", "Package.swift", "README.md", "run.sh"], "cat: \(all.items.map(\.display))")
        precondition(all.items.last?.kind == .file)

        // Ocultos solo si se pide el punto; subcarpetas con barra.
        precondition(CompletionEngine.completions(for: "ls .", directory: root, pathCommands: []).items.map(\.display) == [".hidden/"])
        let nested = CompletionEngine.completions(for: "cd Sources/", directory: root, pathCommands: [])
        precondition(nested.items.map(\.insertion) == ["Sources/App/"], "anidado: \(nested.items.map(\.insertion))")

        // Comandos: integrados y PATH, sin repetir, sin sugerir el PATH entero con la línea vacía.
        let cmds = CompletionEngine.completions(for: "gi", directory: root, pathCommands: ["git", "gitk", "ping", "git"])
        precondition(cmds.items.map(\.display) == ["git", "gitk"], "comandos: \(cmds.items.map(\.display))")
        precondition(CompletionEngine.completions(for: "", directory: root, pathCommands: ["git"]).items.isEmpty)
        let ec = CompletionEngine.completions(for: "ec", directory: root, pathCommands: ["echo", "ecryptfs"])
        precondition(ec.items.first?.kind == .builtin && ec.items.first?.display == "echo", "orden: \(ec.items.map(\.display))")

        // Ejecutables por ruta (./r → run.sh, no README).
        let exe = CompletionEngine.completions(for: "./r", directory: root, pathCommands: [])
        precondition(exe.items.map(\.display) == ["run.sh"], "ejecutables: \(exe.items.map(\.display))")

        // git: subcomandos; las opciones no se completan.
        let git = CompletionEngine.completions(for: "git sta", directory: root, pathCommands: [])
        precondition(git.items.map(\.display) == ["stash", "status"] && git.items.allSatisfy { $0.kind == .subcommand }, "git: \(git.items.map(\.display))")
        precondition(CompletionEngine.completions(for: "ls -", directory: root, pathCommands: []).items.isEmpty)

        // Multilínea, inexistente y nombre peligroso.
        precondition(CompletionEngine.completions(for: "echo a\ncd ", directory: root, pathCommands: []).items.isEmpty)
        precondition(CompletionEngine.completions(for: "cd /no/existe/", directory: root, pathCommands: []).items.isEmpty)
        try fm.createDirectory(at: root.appendingPathComponent("it's $(touch X)"), withIntermediateDirectories: true)
        let odd = CompletionEngine.completions(for: "cd it", directory: root, pathCommands: [])
        precondition(odd.items.first?.insertion == "it\\'s\\ \\$\\(touch\\ X\\)/", "escape: \(odd.items.first?.insertion ?? "-")")
        // Selector de carpeta: superior, subcarpetas (sin archivos ni ocultas) y recientes sin repetir.
        let sub = root.appendingPathComponent("Sources")
        let recents = [sub, URL(fileURLWithPath: "/usr"), root]
        let choices = DirectoryChoices.items(from: root, recents: recents)
        precondition(choices.first?.kind == .parent && choices.first?.display == ".." && choices.first?.insertion == root.deletingLastPathComponent().standardizedFileURL.path, "superior: \(choices.first as Any)")
        let dirNames = choices.filter { $0.kind == .directory }.map(\.display)
        precondition(dirNames == ["Assets/", "it's $(touch X)/", "my project/", "scripts/", "Sources/"], "subcarpetas: \(dirNames)")
        let recentKinds = choices.filter { $0.kind == .recent }
        precondition(recentKinds.map(\.insertion) == ["/usr"], "recientes sin repetir ni incluir la actual: \(recentKinds.map(\.insertion))")
        precondition(DirectoryChoices.items(from: URL(fileURLWithPath: "/"), recents: []).allSatisfy { $0.kind != .parent }, "la raíz no tiene superior")
        print("Pruebas del motor de completado completadas correctamente.")
    }
}
