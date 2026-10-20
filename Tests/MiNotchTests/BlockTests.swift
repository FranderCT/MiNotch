import Foundation
import SwiftTerm

/// Delegado mínimo: una terminal sin ventana para probar la captura de bloques.
final class QuietDelegate: TerminalDelegate {
    func send(source: Terminal, data: ArraySlice<UInt8>) {}
}

func b64(_ text: String) -> String { Data(text.utf8).base64EncodedString() }

@main
struct BlockTests {
    @MainActor static func main() {
        testClearDetection()
        testSplitter()
        testCapture()
        testTruncationAndClear()
        print("Pruebas de bloques y divisor de flujo completadas correctamente.")
    }

    static func testClearDetection() {
        for yes in ["clear", "  clear ", "clear -x", "reset"] {
            precondition(BlockStore.isClearCommand(yes), "debe limpiar: \(yes)")
        }
        for no in ["clearance", "echo clear", "clear foo", "ls", "git clean -fd", ""] {
            precondition(!BlockStore.isClearCommand(no), "no debe limpiar: \(no)")
        }
    }

    static func marker(_ token: String, _ payload: String) -> [UInt8] {
        Array("\u{1b}]\(ShellIntegration.oscCode);\(token);\(payload)\u{07}".utf8)
    }

    static func testSplitter() {
        let token = "TOKEN-1"
        var splitter = ShellStreamSplitter(token: token)
        let start = marker(token, "start;\(b64("ls -la"));\(b64("/tmp"))")
        let ready = marker(token, "ready;3")

        // start: bytes (con el aviso) y después el evento.
        var segments = splitter.split(Array(Array("echo\r\n".utf8) + start + Array("salida".utf8))[...])
        precondition(segments == [
            .bytes(Array("echo\r\n".utf8) + start),
            .commandStarted(command: "ls -la", directory: "/tmp"),
            .bytes(Array("salida".utf8)),
        ], "start: \(segments)")

        // ready: primero el evento, después los bytes del aviso.
        segments = splitter.split((Array("fin".utf8) + ready + Array("$ ".utf8))[...])
        precondition(segments == [
            .bytes(Array("fin".utf8)),
            .commandEnded(exitCode: 3),
            .bytes(ready + Array("$ ".utf8)),
        ], "ready: \(segments)")

        // Aviso cortado en cualquier punto entre dos lecturas.
        let whole = Array("a".utf8) + start + Array("b".utf8)
        for cut in 1..<whole.count {
            var s = ShellStreamSplitter(token: token)
            let all = s.split(whole[..<cut]) + s.split(whole[cut...])
            let joined = all.reduce(into: [UInt8]()) { if case .bytes(let b) = $1 { $0 += b } }
            precondition(joined == whole, "se perdieron bytes al cortar en \(cut)")
            precondition(all.contains(.commandStarted(command: "ls -la", directory: "/tmp")), "evento perdido al cortar en \(cut)")
        }

        // Escapes ajenos y avisos con otro token pasan sin tocar.
        var other = ShellStreamSplitter(token: token)
        let colored = Array("\u{1b}[31mrojo\u{1b}[0m".utf8) + marker("OTRO", "ready;9")
        let passthrough = other.split(colored[...])
        precondition(passthrough == [.bytes(colored)], "no debe cortar: \(passthrough)")

        // cwd, y texto de shell acotado y sin caracteres de control.
        let cwd = other.split(marker(token, "cwd;\(b64("/Users/x"))")[...])
        precondition(cwd.contains(.directoryChanged("/Users/x")))
        precondition(ShellStreamSplitter.decode(b64("a\u{1b}[2Jb")) == "a [2Jb")
        precondition(ShellStreamSplitter.decode(b64(String(repeating: "x", count: 9_000))) == nil)
        precondition(ShellStreamSplitter.decode("%%%no-base64") == nil)
    }

    @MainActor static func makeTerminal(cols: Int = 40, rows: Int = 6) -> Terminal {
        let options = TerminalOptions(cols: cols, rows: rows, scrollback: 500)
        return Terminal(delegate: QuietDelegate(), options: options)
    }

    @MainActor static func testCapture() {
        let terminal = makeTerminal()
        terminal.feed(text: "\u{1b}[H\u{1b}[2J\u{1b}[3J")
        let base0 = BlockCapture.baseRow(of: terminal)
        terminal.feed(text: "plano\r\n\u{1b}[1;31mrojo negrita\u{1b}[0m normal\r\n\u{1b}[38;2;1;2;3mtruecolor\u{1b}[0m\r\n日本語 ok\r\n")
        let out = BlockCapture.capture(terminal, baseRow: base0)
        precondition(out.plainText == "plano\nrojo negrita normal\ntruecolor\n日本語 ok", "texto: \(out.plainText.debugDescription)")
        precondition(!out.isTruncated)
        precondition(out.lines[0] == [BlockRun(text: "plano")])
        let red = out.lines[1][0]
        precondition(red.text == "rojo negrita" && red.bold && red.fg == .palette(1), "rojo: \(red)")
        precondition(out.lines[1][1] == BlockRun(text: " normal"), "resto de la línea: \(out.lines[1])")
        precondition(out.lines[2][0].fg == .rgb(1, 2, 3), "truecolor: \(out.lines[2])")
        precondition(out.lines[3][0].text == "日本語 ok", "ancho doble: \(out.lines[3])")

        // Salida vacía y solo espacios.
        let empty = makeTerminal()
        empty.feed(text: "\u{1b}[H\u{1b}[2J\u{1b}[3J   \r\n")
        precondition(BlockCapture.capture(empty).lines.isEmpty)
    }

    @MainActor static func testTruncationAndClear() {
        // Más líneas que las filas visibles: pasan al historial y se leen igual.
        let terminal = makeTerminal(cols: 20, rows: 5)
        terminal.feed(text: "\u{1b}[H\u{1b}[2J\u{1b}[3J")
        var base = BlockCapture.baseRow(of: terminal)
        for n in 1...120 { terminal.feed(text: "linea \(n)\r\n") }
        var out = BlockCapture.capture(terminal, baseRow: base)
        precondition(out.lines.count == 120 && out.plainText.hasPrefix("linea 1\n") && out.plainText.hasSuffix("linea 120"), "120 líneas: \(out.lines.count)")
        precondition(!out.isTruncated)

        // Más que el historial: se pierden las primeras y se avisa.
        for n in 121...2_000 { terminal.feed(text: "linea \(n)\r\n") }
        out = BlockCapture.capture(terminal, baseRow: base)
        precondition(out.isTruncated, "debe avisar que se perdieron líneas")
        precondition(out.plainText.hasSuffix("linea 2000"), "el final se conserva")

        // Limpiar al empezar el siguiente comando deja el buffer vacío y con la numeración reiniciada o no:
        // lo que importa es que lo viejo no reaparezca.
        terminal.feed(text: "\u{1b}[H\u{1b}[2J\u{1b}[3J")
        base = BlockCapture.baseRow(of: terminal)
        terminal.feed(text: "nuevo\r\n")
        out = BlockCapture.capture(terminal, baseRow: base)
        precondition(!out.isTruncated, "tras limpiar no hay recorte")
        precondition(out.plainText == "nuevo", "tras limpiar: \(out.plainText.debugDescription)")

        // Tope de líneas guardadas.
        let big = makeTerminal(cols: 20, rows: 5)
        big.changeHistorySize(10_000)
        big.feed(text: "\u{1b}[H\u{1b}[2J\u{1b}[3J")
        let bigBase = BlockCapture.baseRow(of: big)
        for n in 1...(BlockCapture.maxStoredLines + 500) { big.feed(text: "l\(n)\r\n") }
        out = BlockCapture.capture(big, baseRow: bigBase)
        precondition(out.lines.count == BlockCapture.maxStoredLines && out.isTruncated, "tope: \(out.lines.count)")
        precondition(out.plainText.hasSuffix("l\(BlockCapture.maxStoredLines + 500)"))
    }
}
