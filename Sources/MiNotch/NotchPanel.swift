import AppKit
import SwiftUI

/// Panel sin bordes, transparente y no activable que aloja la píldora.
/// Siempre mide el tamaño expandido; la píldora se dibuja arriba al centro dentro de él.
@MainActor
final class NotchPanel: NSPanel {
    private let state = NotchState()
    private var monitors: [Any] = []

    init() {
        super.init(
            contentRect: NSRect(origin: .zero, size: NotchState.expandedSize),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )

        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        isMovable = false
        isFloatingPanel = true
        hidesOnDeactivate = false
        becomesKeyOnlyIfNeeded = true
        // Por encima de la barra de menú.
        level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.mainMenuWindow)) + 2)
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        // Click-through mientras el mouse no esté sobre la píldora.
        ignoresMouseEvents = true

        let hosting = NSHostingView(rootView: NotchView(state: state))
        hosting.frame = NSRect(origin: .zero, size: NotchState.expandedSize)
        contentView = hosting

        startMouseTracking()
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    /// Centra el panel pegado al borde superior de la pantalla.
    func position(on screen: NSScreen) {
        state.fit(to: screen)
        let size = NotchState.expandedSize
        let origin = NSPoint(
            x: screen.frame.midX - size.width / 2,
            y: screen.frame.maxY - size.height
        )
        setFrame(NSRect(origin: origin, size: size), display: true)
        updateHover()
    }

    // MARK: - Hover

    private func startMouseTracking() {
        // Global: eventos que van a otras apps (panel en click-through).
        // Local: eventos que llegan a esta app (panel aceptando el mouse).
        if let global = NSEvent.addGlobalMonitorForEvents(matching: .mouseMoved, handler: { [weak self] _ in
            MainActor.assumeIsolated { self?.updateHover() }
        }) {
            monitors.append(global)
        }
        if let local = NSEvent.addLocalMonitorForEvents(matching: .mouseMoved, handler: { [weak self] event in
            MainActor.assumeIsolated { self?.updateHover() }
            return event
        }) {
            monitors.append(local)
        }
    }

    /// Rectángulo visible de la píldora en coordenadas de pantalla.
    private var pillRect: NSRect {
        let size = state.isExpanded ? NotchState.expandedSize : state.collapsedSize
        return NSRect(
            x: frame.midX - size.width / 2,
            y: frame.maxY - size.height,
            width: size.width,
            height: size.height
        )
    }

    private func updateHover() {
        // El borde superior es inclusivo: el cursor pegado arriba también cuenta.
        let mouse = NSEvent.mouseLocation
        let rect = pillRect
        let inside = mouse.x >= rect.minX && mouse.x <= rect.maxX
            && mouse.y >= rect.minY && mouse.y <= rect.maxY
        guard inside != state.isExpanded else { return }

        state.isExpanded = inside
        ignoresMouseEvents = !inside
    }

    override func close() {
        monitors.forEach(NSEvent.removeMonitor)
        monitors.removeAll()
        super.close()
    }
}
