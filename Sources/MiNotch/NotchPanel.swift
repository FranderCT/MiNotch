import AppKit
import SwiftUI

/// Panel sin bordes, transparente y no activable que aloja la píldora.
/// Siempre mide el tamaño expandido; la píldora se dibuja arriba al centro dentro de él.
@MainActor
final class NotchPanel: NSPanel {
    private let state = NotchState()

    init(tabs: ChatTabs) {
        super.init(
            contentRect: NSRect(origin: .zero, size: NotchState.expandedSize),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )

        // ARC maneja la vida del panel; evita el release extra al cerrarlo.
        isReleasedWhenClosed = false
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        isMovable = false
        isFloatingPanel = true
        hidesOnDeactivate = false
        // Toma el teclado solo al hacer clic en el campo de texto, sin activar la app.
        becomesKeyOnlyIfNeeded = true
        // Por encima de la barra de menú.
        level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.mainMenuWindow)) + 2)
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        // Click-through mientras el mouse no esté sobre la píldora.
        ignoresMouseEvents = true

        let hosting = FirstClickHostingView(rootView: NotchView(state: state, tabs: tabs))
        hosting.frame = NSRect(origin: .zero, size: NotchState.expandedSize)
        contentView = hosting
    }

    override var canBecomeKey: Bool { true }
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

    var isExpanded: Bool { state.isExpanded }

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

    func updateHover(mouse: NSPoint = NSEvent.mouseLocation) {
        // Mientras se escribe (panel con teclado) queda abierta aunque el mouse salga.
        let expand = pillRect.containsInclusive(mouse) || isKeyWindow
        guard expand != state.isExpanded else { return }

        state.isExpanded = expand
        ignoresMouseEvents = !expand
    }

    override func becomeKey() {
        super.becomeKey()
        updateHover()
    }

    // Se dispara al hacer clic en otra app: si el mouse ya no está encima, se cierra.
    override func resignKey() {
        super.resignKey()
        updateHover()
    }
}

/// Los botones responden al primer clic aunque el panel no tenga el foco.
private final class FirstClickHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}
