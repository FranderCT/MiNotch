import Foundation
import Combine

/// Métricas optativas en memoria. No guarda comandos, rutas, conversaciones ni credenciales.
@MainActor
final class LocalDiagnostics: ObservableObject {
    static let shared = LocalDiagnostics()
    static let enabledKey = "localDiagnosticsEnabled"
    enum Event: String { case notchOpen, agentFinished, agentFailed, shellExit, shellIntegrationFailure }
    struct Entry: Identifiable {
        let id = UUID()
        let date = Date()
        let event: Event
        let value: Double
    }
    @Published private(set) var entries: [Entry] = []

    func record(_ event: Event, value: Double = 0) {
        guard UserDefaults.standard.bool(forKey: Self.enabledKey) else { return }
        entries.append(Entry(event: event, value: value))
        if entries.count > 200 { entries.removeFirst(entries.count - 200) }
    }

    func clear() { entries.removeAll() }

    var report: String {
        (["MiNotch — diagnóstico local", "Fecha, evento, valor (ms para notchOpen; s para agentes; código para shellExit)"] + entries.map {
            "\($0.date.ISO8601Format()), \($0.event.rawValue), \(String(format: "%.3f", $0.value))"
        }).joined(separator: "\n")
    }
}
