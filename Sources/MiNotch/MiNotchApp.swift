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
    private var panel: NotchPanel?
    private let screenManager = ScreenManager()

    func applicationDidFinishLaunching(_ notification: Notification) {
        setupStatusItem()

        let panel = NotchPanel()
        self.panel = panel

        screenManager.onScreenChange = { [weak panel] screen in
            panel?.position(on: screen)
        }
        screenManager.start()
        panel.orderFrontRegardless()
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
