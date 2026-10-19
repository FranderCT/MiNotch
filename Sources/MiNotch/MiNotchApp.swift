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
    /// Una sola conversación, compartida por las píldoras de todas las pantallas.
    private let chat = ChatSession()
    private lazy var settings = SettingsWindowController(chat: chat)

    func applicationDidFinishLaunching(_ notification: Notification) {
        setupStatusItem()
        setupMainMenu()
        chat.onOpenSettings = { [weak self] in self?.openSettings() }

        screenManager.onScreensChange = { [weak self] screens in
            self?.syncPanels(with: screens)
        }
        screenManager.start()

        mouseTracker.onMove = { [weak self] point in
            self?.routeMouse(at: point)
        }
        mouseTracker.start()
    }

    func applicationWillTerminate(_ notification: Notification) {
        // Que no queden ssh u otras sesiones del asistente corriendo sin dueño.
        chat.terminals.closeAll()
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
            let panel = panels.removeValue(forKey: id) ?? NotchPanel(chat: chat)
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
        let settingsItem = NSMenuItem(title: "Configurar API key…", action: #selector(openSettings), keyEquivalent: ",")
        settingsItem.target = self
        menu.addItem(settingsItem)
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Salir", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        item.menu = menu

        statusItem = item
    }

    /// Menú principal invisible (app .accessory): sin él no funcionan Cmd+C/V/X/A/Z en los campos de texto.
    private func setupMainMenu() {
        let edit = NSMenu(title: "Editar")
        edit.addItem(withTitle: "Deshacer", action: Selector(("undo:")), keyEquivalent: "z")
        edit.addItem(withTitle: "Rehacer", action: Selector(("redo:")), keyEquivalent: "Z")
        edit.addItem(.separator())
        edit.addItem(withTitle: "Cortar", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: "Copiar", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "Pegar", action: #selector(pasteOrAttachImage(_:)), keyEquivalent: "v").target = self
        edit.addItem(withTitle: "Seleccionar todo", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")

        let editItem = NSMenuItem()
        editItem.submenu = edit
        let mainMenu = NSMenu()
        mainMenu.addItem(editItem)
        NSApp.mainMenu = mainMenu
    }

    @objc private func openSettings() {
        settings.show()
    }

    /// Cmd+V en el notch: una imagen copiada se adjunta (se extrae su texto); el texto se pega como siempre.
    @objc private func pasteOrAttachImage(_ sender: Any?) {
        if NSApp.keyWindow is NotchPanel, let image = ImageTextReader.image(from: .general) {
            chat.attachImage(image)
        } else {
            NSApp.sendAction(#selector(NSText.paste(_:)), to: nil, from: sender)
        }
    }
}
