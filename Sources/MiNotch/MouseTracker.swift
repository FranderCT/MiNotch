import AppKit

/// Único punto de escucha del movimiento del mouse para toda la app.
@MainActor
final class MouseTracker {
    var onMove: ((NSPoint) -> Void)?

    private var monitors: [Any] = []

    func start() {
        guard monitors.isEmpty else { return }
        // Global: eventos que van a otras apps (paneles en click-through).
        // Local: eventos que llegan a esta app (panel aceptando el mouse).
        if let global = NSEvent.addGlobalMonitorForEvents(matching: .mouseMoved, handler: { [weak self] _ in
            MainActor.assumeIsolated { self?.handleMove() }
        }) {
            monitors.append(global)
        }
        if let local = NSEvent.addLocalMonitorForEvents(matching: .mouseMoved, handler: { [weak self] event in
            MainActor.assumeIsolated { self?.handleMove() }
            return event
        }) {
            monitors.append(local)
        }
    }

    func stop() {
        monitors.forEach(NSEvent.removeMonitor)
        monitors.removeAll()
    }

    private func handleMove() {
        onMove?(NSEvent.mouseLocation)
    }
}

extension NSRect {
    /// Como `contains`, pero incluye los bordes: el cursor pegado arriba de la pantalla también cuenta.
    func containsInclusive(_ point: NSPoint) -> Bool {
        point.x >= minX && point.x <= maxX && point.y >= minY && point.y <= maxY
    }
}
