import Foundation

/// Predicción local: nunca ejecuta comandos ni envía borradores a un servicio.
enum InputPredictions {
    static let prompts = [
        "Explica cómo funciona este proyecto", "Revisa los cambios y busca errores",
        "Ayúdame a corregir este error", "Agrega pruebas para los cambios",
        "Resume los cambios realizados", "Mejora la interfaz de esta aplicación",
        "Continúa con la implementación", "Explain how this project works",
        "Review the changes for bugs", "Help me fix this error"
    ]
    static let commands = [
        "git status", "git diff", "git diff --stat", "git log --oneline -10",
        "git branch", "git add .", "git commit -m '", "git fetch",
        "ls -la", "pwd", "cd ..", "swift build", "swift test",
        "pnpm dev", "pnpm build", "pnpm test", "pnpm lint",
        "npm run dev", "npm run build", "npm test", "python3 "
    ]

    static func suggestions(for input: String, history: [String], candidates: [String], caseInsensitive: Bool = false) -> [String] {
        guard input.count >= 2, input.count <= 4_000,
              !input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return [] }
        var seen = Set<String>()
        return (history.reversed() + candidates).compactMap { candidate -> String? in
            guard let range = candidate.range(of: input, options: caseInsensitive ? [.anchored, .caseInsensitive] : [.anchored]),
                  range.upperBound < candidate.endIndex else { return nil }
            let completion = input + candidate[range.upperBound...]
            return seen.insert(completion).inserted ? completion : nil
        }.prefix(6).map { $0 }
    }

    static func shellQuote(_ text: String) -> String {
        "'" + text.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    static func shellWord(_ text: String) -> String {
        let safe = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_./-:@")
        guard !text.isEmpty else { return "''" }
        return text.map { character in
            character.unicodeScalars.allSatisfy(safe.contains) ? String(character) : "\\" + String(character)
        }.joined()
    }

    /// Solo lee nombres del directorio y scripts declarados; nunca evalúa package.json.
    static func projectCommands(in directory: URL) -> [String] {
        var result: [String] = []
        let files = (try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles]
        )) ?? []
        for url in files.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }).prefix(100) {
            let name = url.lastPathComponent
            guard !name.contains(where: { $0.isNewline || $0.asciiValue.map { $0 < 32 || $0 == 127 } == true }) else { continue }
            let quoted = shellWord(name.hasPrefix("-") ? "./" + name : name)
            if (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true {
                result.append("cd " + quoted)
                result.append("ls " + quoted)
            } else {
                result.append("cat " + quoted)
            }
        }
        let package = directory.appendingPathComponent("package.json")
        if let size = try? package.resourceValues(forKeys: [.fileSizeKey]).fileSize, size <= 262_144,
           let data = try? Data(contentsOf: package),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let scripts = json["scripts"] as? [String: Any] {
            let manager = FileManager.default.fileExists(atPath: directory.appendingPathComponent("pnpm-lock.yaml").path) ? "pnpm" : "npm"
            result += scripts.keys.sorted().filter { !$0.hasPrefix("-") && !$0.contains(where: { $0.isNewline }) }
                .map { "\(manager) run \(shellWord($0))" }
        }
        return result + commands
    }
}
