import Foundation
import SwiftTerm

// Bloques de terminal: cada comando con su salida, como una lista en vez de una sola rejilla.
// La terminal viva solo muestra el comando que corre; al terminar, su salida se lee del buffer
// de SwiftTerm (con colores) y queda guardada como un bloque.

// MARK: - Modelo

/// Color de una celda tal como lo pidió el programa; la vista lo traduce con `ANSIPalette`.
enum BlockColor: Equatable, Sendable {
    case none
    case palette(UInt8)
    case rgb(UInt8, UInt8, UInt8)
}

/// Tramo de texto con un mismo estilo.
struct BlockRun: Equatable, Sendable {
    var text: String
    var fg = BlockColor.none
    var bg = BlockColor.none
    var bold = false
    var dim = false
    var italic = false
    var underline = false
    var inverse = false
    var strike = false

    func hasSameStyle(as other: BlockRun) -> Bool {
        fg == other.fg && bg == other.bg && bold == other.bold && dim == other.dim
            && italic == other.italic && underline == other.underline && inverse == other.inverse && strike == other.strike
    }
}

typealias BlockLine = [BlockRun]

/// Paleta ANSI. Los 16 colores del tema (Catppuccin Mocha, licencia MIT) también se instalan en la terminal viva,
/// para que un bloque terminado y la salida en vivo se vean igual.
enum ANSIPalette {
    static let theme: [(UInt8, UInt8, UInt8)] = [
        (0x45, 0x47, 0x5a), (0xf3, 0x8b, 0xa8), (0xa6, 0xe3, 0xa1), (0xf9, 0xe2, 0xaf),
        (0x89, 0xb4, 0xfa), (0xf5, 0xc2, 0xe7), (0x94, 0xe2, 0xd5), (0xba, 0xc2, 0xde),
        (0x58, 0x5b, 0x70), (0xf3, 0x8b, 0xa8), (0xa6, 0xe3, 0xa1), (0xf9, 0xe2, 0xaf),
        (0x89, 0xb4, 0xfa), (0xf5, 0xc2, 0xe7), (0x94, 0xe2, 0xd5), (0xa6, 0xad, 0xc8),
    ]

    /// Colores 0–15 del tema; 16–231, el cubo 6×6×6 de xterm; 232–255, la escala de grises.
    static func rgb(_ index: UInt8) -> (UInt8, UInt8, UInt8) {
        let i = Int(index)
        if i < 16 { return theme[i] }
        if i < 232 {
            let c = i - 16
            let level: (Int) -> UInt8 = { $0 == 0 ? 0 : UInt8(55 + $0 * 40) }
            return (level(c / 36), level((c / 6) % 6), level(c % 6))
        }
        let gray = UInt8(8 + (i - 232) * 10)
        return (gray, gray, gray)
    }

    /// Para `TerminalView.installColors`: 16 colores de 16 bits.
    static var swiftTermColors: [SwiftTerm.Color] {
        theme.map { SwiftTerm.Color(red: UInt16($0.0) * 257, green: UInt16($0.1) * 257, blue: UInt16($0.2) * 257) }
    }
}

struct TerminalBlock: Identifiable, Equatable, Sendable {
    let id = UUID()
    var command: String
    /// Carpeta donde se ejecutó, abreviada con ~.
    var directory: String?
    let startedAt: Date
    var endedAt: Date?
    var exitCode: Int?
    /// Líneas con estilo, las últimas `BlockCapture.maxStoredLines` si hubo más.
    var lines: [BlockLine] = []
    /// Salida completa en texto plano (para copiar), con el mismo tope.
    var plainOutput = ""
    /// Había más líneas que las guardadas, o el buffer de la terminal ya había descartado las primeras.
    var isTruncated = false
    /// El programa usó la pantalla completa (vim, less, htop…): no hay salida que mostrar.
    var usedFullScreen = false
    var isExpanded = false

    var isRunning: Bool { endedAt == nil }
    var failed: Bool { (exitCode ?? 0) != 0 }
    var duration: TimeInterval? { endedAt.map { $0.timeIntervalSince(startedAt) } }
    var hasOutput: Bool { !lines.isEmpty }

    /// Cuántas líneas se muestran sin expandir.
    static let collapsedLineLimit = 200
}

/// El comando que está corriendo.
struct RunningCommand: Equatable, Sendable {
    let command: String
    let directory: String?
    let startedAt: Date
}

/// Lista de bloques de una pestaña.
@MainActor
final class BlockStore: ObservableObject {
    @Published private(set) var blocks: [TerminalBlock] = []
    @Published var selectedID: UUID?

    static let maxBlocks = 200
    /// Tope de líneas guardadas entre todos los bloques: los más viejos se descartan primero.
    static let maxTotalLines = 20_000

    func append(_ block: TerminalBlock) {
        blocks.append(block)
        trim()
    }

    func toggleExpanded(_ id: UUID) {
        guard let index = blocks.firstIndex(where: { $0.id == id }) else { return }
        blocks[index].isExpanded.toggle()
    }

    func clear() {
        blocks.removeAll()
        selectedID = nil
    }

    /// `clear`, `clear -x` y `reset`: en vez de un bloque vacío, limpian la lista.
    nonisolated static func isClearCommand(_ command: String) -> Bool {
        let words = command.split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init)
        guard let first = words.first, first == "clear" || first == "reset" else { return false }
        return words.dropFirst().allSatisfy { $0.hasPrefix("-") }
    }

    private func trim() {
        if blocks.count > Self.maxBlocks { blocks.removeFirst(blocks.count - Self.maxBlocks) }
        var total = blocks.reduce(0) { $0 + $1.lines.count }
        while total > Self.maxTotalLines, blocks.count > 1 {
            total -= blocks.removeFirst().lines.count
        }
    }

    /// Para el asistente: los últimos comandos con su salida, en texto.
    func transcript(lastBlocks count: Int = 3, maxLines: Int = 80) -> String {
        var parts: [String] = []
        for block in blocks.suffix(count) {
            var text = "$ \(block.command)"
            if !block.plainOutput.isEmpty { text += "\n" + block.plainOutput }
            if block.usedFullScreen { text += "\n[programa de pantalla completa]" }
            if let code = block.exitCode, code != 0 { text += "\n[código de salida \(code)]" }
            parts.append(text)
        }
        let lines = parts.joined(separator: "\n").split(separator: "\n", omittingEmptySubsequences: false)
        return lines.suffix(maxLines).joined(separator: "\n")
    }
}

// MARK: - Captura desde SwiftTerm

struct CapturedOutput: Equatable, Sendable {
    var lines: [BlockLine] = []
    var plainText = ""
    var isTruncated = false
}

enum BlockCapture {
    static let maxStoredLines = 3000

    /// Primera fila válida del buffer: se mide justo después de limpiar la pantalla, al empezar el comando.
    /// (Limpiar el historial corre el comienzo del buffer, así que no es siempre 0.)
    @MainActor
    static func baseRow(of terminal: Terminal) -> Int {
        validRows(of: terminal)?.lowerBound ?? 0
    }

    /// Lee la salida que quedó en el buffer activo: todo lo que hay desde la primera fila hasta la última con contenido.
    /// Se usa con el buffer recién limpiado al empezar el comando, así que todo lo que hay es de ese comando.
    /// `baseRow`: la primera fila que había al empezar; si ahora el buffer empieza más adelante, descartó líneas.
    @MainActor
    static func capture(_ terminal: Terminal, baseRow: Int? = nil) -> CapturedOutput {
        guard let range = validRows(of: terminal) else { return CapturedOutput() }
        var last = range.upperBound
        while last >= range.lowerBound, isBlank(terminal.getScrollInvariantLine(row: last)) { last -= 1 }
        guard last >= range.lowerBound else { return CapturedOutput() }

        var output = CapturedOutput()
        // Si el buffer ya descartó filas (salida muy larga), las primeras se perdieron.
        output.isTruncated = range.lowerBound > (baseRow ?? range.lowerBound)
        var first = range.lowerBound
        if last - first + 1 > maxStoredLines {
            first = last - maxStoredLines + 1
            output.isTruncated = true
        }
        var plain: [String] = []
        for row in first...last {
            guard let line = terminal.getScrollInvariantLine(row: row) else { continue }
            output.lines.append(runs(of: line, cols: terminal.cols))
            var text = line.translateToString(trimRight: true, skipNullCellsFollowingWide: true)
            while text.hasSuffix(" ") { text.removeLast() }
            plain.append(text)
        }
        output.plainText = plain.joined(separator: "\n")
        return output
    }

    /// Filas absolutas con contenido en el buffer: `getScrollInvariantLine` devuelve nil fuera de ese rango, y el
    /// comienzo se corre cuando el buffer descarta líneas viejas.
    @MainActor
    static func validRows(of terminal: Terminal) -> ClosedRange<Int>? {
        let count = max(1, terminal.getBufferAsData().reduce(0) { $1 == 10 ? $0 + 1 : $0 })
        // Un rango de `count` filas seguidas siempre contiene un múltiplo de `count`.
        var probe = 0
        var hit: Int?
        while probe < 100_000_000 {
            if terminal.getScrollInvariantLine(row: probe) != nil { hit = probe; break }
            probe += count
        }
        guard var low = hit else { return nil }
        // Hacia atrás hasta la primera fila válida, y hacia adelante hasta la última.
        var step = 1
        while low - step >= 0, terminal.getScrollInvariantLine(row: low - step) != nil { low -= step; step *= 2 }
        while low > 0, terminal.getScrollInvariantLine(row: low - 1) != nil { low -= 1 }
        var high = hit!
        step = 1
        while terminal.getScrollInvariantLine(row: high + step) != nil { high += step; step *= 2 }
        while terminal.getScrollInvariantLine(row: high + 1) != nil { high += 1 }
        return low...high
    }

    private static func isBlank(_ line: BufferLine?) -> Bool {
        guard let line else { return true }
        return line.translateToString(trimRight: true, skipNullCellsFollowingWide: true)
            .allSatisfy { $0 == " " || $0 == "\t" }
    }

    /// Celdas contiguas con el mismo estilo se juntan en un tramo; se quitan los espacios del final.
    private static func runs(of line: BufferLine, cols: Int) -> BlockLine {
        var result: BlockLine = []
        var column = 0
        let width = min(cols, line.count)
        while column < width {
            let cell = line[column]
            column += max(1, Int(cell.width))
            // Segunda mitad de un carácter ancho: ya está en la primera.
            if cell.width == 0 { continue }
            // Las celdas vacías devuelven NUL.
            var character = cell.getCharacter()
            if character == "\u{0}" { character = " " }
            var run = BlockRun(text: String(character))
            let attribute = cell.attribute
            run.fg = color(attribute.fg)
            run.bg = color(attribute.bg)
            let style = attribute.style
            run.bold = style.contains(.bold)
            run.dim = style.contains(.dim)
            run.italic = style.contains(.italic)
            run.underline = style.contains(.underline)
            run.inverse = style.contains(.inverse)
            run.strike = style.contains(.crossedOut)
            if style.contains(.invisible) { run.text = " " }
            if var last = result.last, last.hasSameStyle(as: run) {
                last.text += run.text
                result[result.count - 1] = last
            } else {
                result.append(run)
            }
        }
        // Espacios finales sin fondo propio: no aportan nada.
        while let last = result.last, last.bg == .none, !last.inverse, last.text.allSatisfy({ $0 == " " }) {
            result.removeLast()
        }
        if var last = result.last, last.bg == .none, !last.inverse {
            while last.text.hasSuffix(" ") { last.text.removeLast() }
            result[result.count - 1] = last
        }
        return result
    }

    private static func color(_ color: Attribute.Color) -> BlockColor {
        switch color {
        case .defaultColor, .defaultInvertedColor: .none
        case .ansi256(let code): .palette(code)
        case .trueColor(let r, let g, let b): .rgb(r, g, b)
        }
    }
}
