import Foundation

/// Parte el flujo de bytes del shell en los puntos donde zsh avisa (por OSC) que un comando empieza o termina.
/// Así la app puede actuar justo entre "lo anterior" y "lo siguiente" (limpiar la pantalla, guardar un bloque)
/// sin carreras con los bytes que ya están en camino.
///
/// Los bytes de cada aviso siguen en el flujo (SwiftTerm los procesa igual que antes); el divisor solo marca dónde cortar.
struct ShellStreamSplitter {
    enum Segment: Equatable {
        case bytes([UInt8])
        /// Después de los bytes del aviso: el comando ya está corriendo.
        case commandStarted(command: String?, directory: String?)
        /// Antes de los bytes del aviso: la salida del comando está completa en la terminal.
        case commandEnded(exitCode: Int)
        case directoryChanged(String)
    }

    private let prefix: [UInt8]
    private var carry: [UInt8] = []

    /// El comando y la carpeta vienen de shell: se muestran, nunca se ejecutan, y se acotan.
    static let maxTextBytes = 8_192
    private static let maxPayload = 16_384

    init(token: String) {
        // ESC ] 6973 ; <token> ;
        prefix = [0x1B, 0x5D] + Array("\(ShellIntegration.oscCode);\(token);".utf8)
    }

    private enum Match {
        case notMarker
        case partial
        case marker(end: Int, payload: String)
    }

    mutating func split(_ chunk: ArraySlice<UInt8>) -> [Segment] {
        var data = carry
        data.append(contentsOf: chunk)
        carry = []
        var segments: [Segment] = []
        var plainStart = 0
        var index = 0

        func flush(to end: Int) {
            if end > plainStart { segments.append(.bytes(Array(data[plainStart..<end]))) }
            plainStart = end
        }

        while index < data.count {
            guard data[index] == 0x1B else { index += 1; continue }
            switch match(in: data, at: index) {
            case .notMarker:
                index += 1
            case .partial:
                // Un aviso cortado entre dos lecturas: se retiene hasta tener el resto.
                flush(to: index)
                carry = Array(data[index...])
                return segments
            case .marker(let end, let payload):
                let fields = payload.split(separator: ";", omittingEmptySubsequences: false).map(String.init)
                switch fields.first {
                case "start":
                    flush(to: end)
                    segments.append(.commandStarted(
                        command: fields.count > 1 ? Self.decode(fields[1]) : nil,
                        directory: fields.count > 2 ? Self.decode(fields[2]) : nil
                    ))
                case "ready":
                    flush(to: index)
                    segments.append(.commandEnded(exitCode: fields.count > 1 ? Int(fields[1]) ?? 0 : 0))
                case "cwd":
                    flush(to: end)
                    if fields.count > 1, let path = Self.decode(fields[1]) { segments.append(.directoryChanged(path)) }
                default:
                    break
                }
                index = end
            }
        }
        flush(to: data.count)
        return segments
    }

    private func match(in data: [UInt8], at index: Int) -> Match {
        let available = data.count - index
        for offset in 0..<min(available, prefix.count) where data[index + offset] != prefix[offset] {
            return .notMarker
        }
        if available < prefix.count { return .partial }

        var cursor = index + prefix.count
        let limit = min(data.count, cursor + Self.maxPayload)
        while cursor < limit {
            if data[cursor] == 0x07 { return .marker(end: cursor + 1, payload: Self.string(data[(index + prefix.count)..<cursor])) }
            if data[cursor] == 0x1B {
                guard cursor + 1 < data.count else { return .partial }
                if data[cursor + 1] == 0x5C { return .marker(end: cursor + 2, payload: Self.string(data[(index + prefix.count)..<cursor])) }
            }
            cursor += 1
        }
        return limit == data.count ? .partial : .notMarker
    }

    private static func string(_ bytes: ArraySlice<UInt8>) -> String {
        String(decoding: bytes, as: UTF8.self)
    }

    /// Base64 → texto. Todo lo que viene del shell se acota y se limpia de caracteres de control.
    static func decode(_ base64: String) -> String? {
        guard !base64.isEmpty, base64.utf8.count <= maxTextBytes * 2, let data = Data(base64Encoded: base64),
              data.count <= maxTextBytes else { return nil }
        let text = String(decoding: data, as: UTF8.self)
        return text.unicodeScalars.map { $0.value < 32 && $0 != "\n" && $0 != "\t" ? " " : Character($0) }
            .map(String.init).joined()
    }
}
