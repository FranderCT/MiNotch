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
    private let screenManager = ScreenManager()

    func applicationDidFinishLaunching(_ notification: Notification) {
        setupStatusItem()

        screenManager.onScreensChange = { [weak self] screens in
            self?.syncPanels(with: screens)
        }
        screenManager.start()
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
