import AppKit

@main
@MainActor
enum MiNotchApp {
    // Referencia fuerte: NSApplication.delegate es weak.
    private static let delegate = AppDelegate()

    static func main() {
        let app = NSApplication.shared
        app.delegate = delegate
        // Sin ícono en el Dock ni en Cmd+Tab (también cuando se corre con `swift run`).
        app.setActivationPolicy(.accessory)
        app.run()
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem?
    /// Un panel por pantalla conectada.
    private var panels: [CGDirectDisplayID: NotchPanel] = [:]
    /// Áreas de todos los paneles: fuera de ellas el movimiento del mouse se descarta enseguida.
    private var hotZones: [NSRect] = []
    private let screenManager = ScreenManager()
    private let mouseTracker = MouseTracker()

    func applicationDidFinishLaunching(_ notification: Notification) {
        setupStatusItem()

        screenManager.onScreensChange = { [weak self] screens in
            self?.syncPanels(with: screens)
        }
        screenManager.start()

        mouseTracker.onMove = { [weak self] point in
            self?.routeMouse(at: point)
        }
        mouseTracker.start()
    }

    private func routeMouse(at point: NSPoint) {
        // Camino rápido: cursor lejos de todas las píldoras y ninguna expandida que deba cerrarse.
        guard hotZones.contains(where: { $0.containsInclusive(point) })
            || panels.values.contains(where: \.isExpanded) else { return }
        panels.values.forEach { $0.updateHover(mouse: point) }
    }

    /// Reutiliza el panel de cada pantalla que sigue conectada, crea los nuevos y cierra los sobrantes.
    private func syncPanels(with screens: [NSScreen]) {
        var updated: [CGDirectDisplayID: NotchPanel] = [:]
        for screen in screens {
            guard let id = screen.displayID else { continue }
            let panel = panels.removeValue(forKey: id) ?? NotchPanel()
            panel.position(on: screen)
            panel.orderFrontRegardless()
            updated[id] = panel
        }
        panels.values.forEach { $0.close() }
        panels = updated
        hotZones = updated.values.map(\.frame)
    }

    private func setupStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.image = NSImage(systemSymbolName: "capsule.fill", accessibilityDescription: "MiNotch")

        let menu = NSMenu()
        menu.addItem(NSMenuItem(title: "Salir", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        item.menu = menu

        statusItem = item
    }
}
