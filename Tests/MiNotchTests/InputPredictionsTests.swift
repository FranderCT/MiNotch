import Foundation

@main
struct InputPredictionsTests {
    static func main() throws {
        precondition(InputPredictions.suggestions(for: "", history: ["git status"], candidates: []).isEmpty)
        precondition(InputPredictions.suggestions(for: "g", history: ["git status"], candidates: []).isEmpty)
        let ranked = InputPredictions.suggestions(for: "git ", history: ["git status", "git diff", "git status"], candidates: ["git diff", "git log"])
        precondition(ranked == ["git status", "git diff", "git log"], "Recencia y deduplicación: \(ranked)")
        precondition(InputPredictions.suggestions(for: "git status", history: [], candidates: ["git status"]).isEmpty)
        precondition(InputPredictions.suggestions(for: "GI", history: [], candidates: ["git status"]).isEmpty)
        precondition(InputPredictions.suggestions(for: "exp", history: [], candidates: InputPredictions.prompts, caseInsensitive: true).first == "explica cómo funciona este proyecto")
        precondition(InputPredictions.suggestions(for: "ayúd", history: ["Ayúdame con café ☕"], candidates: [], caseInsensitive: true) == ["ayúdame con café ☕"])
        precondition(InputPredictions.suggestions(for: "ab", history: [], candidates: (0..<10).map { "abc\($0)" }).count == 6)

        let root = FileManager.default.temporaryDirectory.appendingPathComponent("prediction-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        for name in ["src", "my project", "it's $(touch INJECTED)", "-danger", ".hidden"] {
            try FileManager.default.createDirectory(at: root.appendingPathComponent(name), withIntermediateDirectories: true)
        }
        try Data("{}".utf8).write(to: root.appendingPathComponent("notes.txt"))
        try Data(#"{"scripts":{"dev":"vite","test:unit":"echo ok","evil'$(touch INJECTED)":"echo not executed"}}"#.utf8).write(to: root.appendingPathComponent("package.json"))
        try Data().write(to: root.appendingPathComponent("pnpm-lock.yaml"))
        let candidates = InputPredictions.projectCommands(in: root)
        for command in ["cd src", "cd my\\ project", "cd ./-danger", "cat notes.txt", "pnpm run dev", "pnpm run test:unit"] {
            precondition(candidates.contains(command), "Falta \(command)")
        }
        precondition(!candidates.contains(where: { $0.contains(".hidden") }))
        precondition(InputPredictions.suggestions(for: "cd my", history: [], candidates: candidates) == ["cd my\\ project"])
        precondition(!FileManager.default.fileExists(atPath: root.appendingPathComponent("INJECTED").path))
        // Verifica en un shell real que espacios, apóstrofos y sustituciones permanecen literales.
        let hostile = "it's $(touch INJECTED)"
        let process = Process(), output = Pipe()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = ["-f", "-c", "printf '%s\\n' " + InputPredictions.shellQuote(hostile) + " " + InputPredictions.shellWord(hostile)]
        process.currentDirectoryURL = root
        process.standardOutput = output
        try process.run()
        let actual = String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        process.waitUntilExit()
        precondition(process.terminationStatus == 0 && actual == hostile + "\n" + hostile + "\n")
        precondition(!FileManager.default.fileExists(atPath: root.appendingPathComponent("INJECTED").path))
        print("Predicción: historial, prefijos, Unicode, límites, contexto y escape de shell verificados.")
    }
}
