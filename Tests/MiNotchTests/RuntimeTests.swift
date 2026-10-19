import Foundation

// Harness independiente: los archivos probados no necesitan la interfaz de AppKit.
struct ToolError: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

@main
struct RuntimeTests {
    @MainActor static func main() async throws {
        try testShellSignalsAndStartupFiles()
        testCommandState()
        testSplitEvents()
        testAgentEvents()
        testAgentResultsAndArguments()
        try testProjectLinks()
        testOutputBound()
        try await testLiveAgentProcess()
        print("8 pruebas de terminal, eventos, agentes y enlaces completadas correctamente.")
    }

    static func testShellSignalsAndStartupFiles() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("minotch-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        for file in [".zshenv", ".zprofile", ".zshrc", ".zlogin"] {
            var content = "print -r -- 'loaded:\(file)'\n"
            if file == ".zshrc" { content += "precmd() { return 0; }\n" }
            try content.write(to: root.appendingPathComponent(file), atomically: true, encoding: .utf8)
        }
        var environment = ["HOME": root.path, "ZDOTDIR": root.path, "PATH": "/usr/bin:/bin", "TERM": "dumb"]
        let integration = try ShellIntegration(environment: &environment)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = ["-l", "-i"]
        process.environment = environment
        let input = Pipe(), output = Pipe()
        process.standardInput = input
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        try process.run()
        let script = "print before; sleep 1.5; false\nprint -r -- restored:$ZDOTDIR previous:$?\n__minotch_missing_command__\nexit\n"
        try input.fileHandleForWriting.write(contentsOf: Data(script.utf8))
        try input.fileHandleForWriting.close()
        let transcript = String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        process.waitUntilExit()
        withExtendedLifetime(integration) {}
        for file in [".zshenv", ".zprofile", ".zshrc", ".zlogin"] {
            precondition(transcript.components(separatedBy: "loaded:\(file)").count == 2, transcript)
        }
        precondition(transcript.contains("\(integration.token);start\u{07}before"), transcript)
        precondition(transcript.contains("\(integration.token);ready;1\u{07}"), transcript)
        precondition(transcript.contains("\(integration.token);ready;127\u{07}"), transcript)
        precondition(transcript.contains("restored:\(root.path) previous:1"), transcript)
    }

    static func testCommandState() {
        var state = ShellCommandState()
        state.receive("other;ready;0", token: "test")
        precondition(state.phase == .starting)
        state.receive("test;ready;0", token: "test")
        precondition(state.phase == .ready && state.lastExitCode == nil)
        state.receive("test;start", token: "test")
        precondition(state.phase == .running && state.lastExitCode == nil)
        state.receive("test;ready;invalid", token: "test")
        precondition(state.phase == .running)
        state.receive("test;ready;42", token: "test")
        precondition(state.phase == .ready && state.lastExitCode == 42 && state.completedCommands == 1)
    }

    static func testSplitEvents() {
        var decoder = AgentLineDecoder()
        let line = #"{"type":"text","part":{"text":"café 🚀"}}"#
        var received: [String] = []
        for byte in (line + "\n" + line).utf8 { received += decoder.append(Data([byte])) }
        precondition(received == [line])
        received += decoder.append(Data(), eof: true)
        precondition(received == [line, line])
        precondition(decoder.append(Data(), eof: true).isEmpty)
        _ = decoder.append(Data(repeating: 65, count: AgentLineDecoder.maximumLineBytes + 1))
        precondition(decoder.append(Data(("\n" + line + "\n").utf8)) == [line])
    }

    static func testAgentEvents() {
        precondition(AgentActivity.decode(#"{"type":"assistant","message":{"content":[{"type":"tool_use","name":"Read"}]}}"#)?.text == "Herramienta: Read")
        precondition(AgentActivity.decode(#"{"type":"item.completed","item":{"type":"command_execution","exit_code":2}}"#)?.isError == true)
        precondition(AgentActivity.decode(#"{"type":"tool_call","subtype":"started","tool_call":{"readToolCall":{}}}"#)?.text.contains("readToolCall") == true)
        precondition(AgentActivity.decode(#"{"type":"tool_use","part":{"tool":"bash","state":{"status":"error"}}}"#)?.isError == true)
        precondition(AgentActivity.decode(#"{"type":"assistant","message":{"content":[{"type":"thinking","thinking":"private"}]}}"#) == nil)
        precondition(AgentActivity.decode("not JSON") == nil)
    }

    static func testAgentResultsAndArguments() {
        let claude = ExternalAgentKind.claude.parse("{\"type\":\"system\"}\n{\"type\":\"result\",\"result\":\"done\",\"session_id\":\"s1\",\"total_cost_usd\":0.01}")
        precondition(claude.text == "done" && claude.sessionID == "s1" && claude.costUSD == 0.01)
        let codex = ExternalAgentKind.codex.parse("{\"type\":\"thread.started\",\"thread_id\":\"s2\"}\n{\"type\":\"item.completed\",\"item\":{\"type\":\"agent_message\",\"text\":\"ok\"}}")
        precondition(codex.text == "ok" && codex.sessionID == "s2")
        let opencode = ExternalAgentKind.opencode.parse("{\"type\":\"text\",\"sessionID\":\"s3\",\"part\":{\"messageID\":\"m1\",\"text\":\"hello\"}}\n{\"type\":\"text\",\"part\":{\"messageID\":\"m1\",\"text\":\"world\"}}")
        precondition(opencode.text == "hello\nworld" && opencode.sessionID == "s3")
        for kind in [ExternalAgentKind.claude, .cursor] {
            let args = kind.arguments(prompt: "test", sessionID: "s1", access: .read, model: nil, directory: URL(fileURLWithPath: "/tmp"))
            precondition(args.contains("stream-json") && args.contains("plan") && args.contains("--resume"))
        }
    }

    static func testProjectLinks() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("MiNotch prueba café & # \(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        precondition(ProjectLink.directory(from: ProjectLink.url(for: root)) == root.resolvingSymlinksInPath())
        for text in ["minotch://open?path=relative", "minotch://open?path=/tmp&command=touch", "minotch://open?path=/tmp&path=/", "minotch://open?path=/tmp#cmd", "minotch://run?path=/tmp", "https://open?path=/tmp", "minotch://open?path=/does-not-exist", "file://remote.invalid/tmp", "file:///tmp?command=test"] {
            precondition(ProjectLink.directory(from: URL(string: text)!) == nil, text)
        }
        let file = root.appendingPathComponent("file")
        try Data().write(to: file)
        precondition(ProjectLink.directory(from: file) == nil)
    }

    static func testOutputBound() {
        let output = OutputBuffer(maxBytes: 4)
        output.append(Data("123".utf8)); output.append(Data("456".utf8))
        precondition(output.string == "3456")
    }

    @MainActor static func testLiveAgentProcess() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("minotch-agent-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let executable = root.appendingPathComponent("fixture-agent")
        let script = """
        #!/bin/sh
        printf '%s\\n' '{"type":"thread.started","thread_id":"test-session"}' '{"type":"item.started","item":{"type":"command_execution"}}'
        sleep 1.5
        printf '%s' '{"type":"item.completed","item":{"type":"agent_message","text":"terminado café"}}'
        """
        try script.write(to: executable, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
        let job = ExternalAgentJob(id: 1, kind: .codex, task: "test", directory: root, access: .read, model: nil, executablePath: executable.path)
        job.run("test")
        let deadline = Date().addingTimeInterval(5)
        while job.activities.isEmpty, job.isRunning, Date() < deadline {
            try await Task.sleep(for: .milliseconds(30))
        }
        precondition(job.isRunning && job.sessionID == "test-session", "No se recibieron eventos antes de terminar")
        precondition(job.latestActivity == "Ejecutando un comando", job.latestActivity)
        while job.isRunning, Date() < deadline { try await Task.sleep(for: .milliseconds(30)) }
        precondition(job.status == .finished && job.result == "terminado café", job.report)

        // Un callback tardío de la corrida detenida no debe cerrar ni sobrescribir la nueva.
        job.run("old")
        try await Task.sleep(for: .milliseconds(200))
        job.stop()
        job.run("new")
        try await Task.sleep(for: .milliseconds(500))
        precondition(job.isRunning && job.task == "new")
        let secondDeadline = Date().addingTimeInterval(5)
        while job.isRunning, Date() < secondDeadline { try await Task.sleep(for: .milliseconds(30)) }
        precondition(job.status == .finished && job.result == "terminado café", job.report)
    }
}
