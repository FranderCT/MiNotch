import Foundation

/// Salida de un comando, escrita desde el hilo del pipe y leída al terminar.
final class OutputBuffer: @unchecked Sendable {
    private let lock = NSLock()
    private var data = Data()
    private let maxBytes: Int?

    init(maxBytes: Int? = nil) { self.maxBytes = maxBytes }

    func append(_ chunk: Data) {
        lock.withLock {
            data.append(chunk)
            if let maxBytes, data.count > maxBytes { data.removeFirst(data.count - maxBytes) }
        }
    }

    var string: String {
        lock.withLock { String(decoding: data, as: UTF8.self) }
    }
}

