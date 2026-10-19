import AppKit

/// Único punto de escucha del movimiento del mouse para toda la app.
@MainActor
final class MouseTracker {
    var onMove: ((NSPoint) -> Void)?

    private var monitors: [Any] = []

    /// Al arrastrar y soltar (archivos, imágenes) el sistema escribe en este portapapeles;
    /// al mover una ventana o seleccionar texto, no.
    private let dragPasteboard = NSPasteboard(name: .drag)
    private var dragChangeCountAtMouseDown = 0

    func start() {
        guard monitors.isEmpty else { return }
        let events: NSEvent.EventTypeMask = [.mouseMoved, .leftMouseDown, .leftMouseDragged]
        // Global: eventos que van a otras apps (paneles en click-through).
        // Local: eventos que llegan a esta app (panel aceptando el mouse).
        if let global = NSEvent.addGlobalMonitorForEvents(matching: events, handler: { [weak self] event in
            MainActor.assumeIsolated { self?.handle(event.type) }
        }) {
            monitors.append(global)
        }
        if let local = NSEvent.addLocalMonitorForEvents(matching: events, handler: { [weak self] event in
            MainActor.assumeIsolated { self?.handle(event.type) }
            return event
        }) {
            monitors.append(local)
        }
    }

    func stop() {
        monitors.forEach(NSEvent.removeMonitor)
        monitors.removeAll()
    }

    private func handle(_ type: NSEvent.EventType) {
        switch type {
        case .leftMouseDown:
            dragChangeCountAtMouseDown = dragPasteboard.changeCount
        case .leftMouseDragged:
            // Solo arrastrar y soltar abre la píldora (para soltar una imagen), no mover una ventana hacia arriba.
            guard dragPasteboard.changeCount != dragChangeCountAtMouseDown else { return }
            onMove?(NSEvent.mouseLocation)
        default:
            onMove?(NSEvent.mouseLocation)
        }
    }
}

extension NSRect {
    /// Como `contains`, pero incluye los bordes: el cursor pegado arriba de la pantalla también cuenta.
    func containsInclusive(_ point: NSPoint) -> Bool {
        point.x >= minX && point.x <= maxX && point.y >= minY && point.y <= maxY
    }
}
