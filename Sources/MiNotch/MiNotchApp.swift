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
    private let mouseTracker = MouseTracker()
    /// Cuenta compartida y pestañas: las mismas en las píldoras de todas las pantallas.
    private let account = DeepSeekAccount()
    private lazy var tabs = ChatTabs(account: account)
    private lazy var settings = SettingsWindowController(account: account)

    func applicationDidFinishLaunching(_ notification: Notification) {
        setupStatusItem()
        setupMainMenu()
        handleTerminationSignal()
        // Qué agentes externos (Claude Code, Codex…) hay instalados, para agent_start.
        Task { await ExternalAgentKind.detectInstalled() }
        account.onOpenSettings = { [weak self] in self?.openSettings() }

        screenManager.onScreensChange = { [weak self] screens in
            self?.syncPanels(with: screens)
        }
        screenManager.start()

        mouseTracker.onMove = { [weak self] point in
            self?.routeMouse(at: point)
        }
        mouseTracker.start()
    }

    /// SIGTERM (pkill, build-app.sh) cierra como "Salir": si no, las sesiones de terminal quedan huérfanas.
    private let terminationSignal = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)

    private func handleTerminationSignal() {
        signal(SIGTERM, SIG_IGN)
        terminationSignal.setEventHandler { NSApp.terminate(nil) }
        terminationSignal.resume()
    }

    func applicationWillTerminate(_ notification: Notification) {
        // Que no queden ssh u otras sesiones del asistente corriendo sin dueño.
        tabs.shutDownAll()
    }

    private func routeMouse(at point: NSPoint) {
        // Camino rápido: cursor lejos de todas las píldoras y ninguna expandida que deba cerrarse.
        // Los marcos cambian con el modo (agente o terminal): se leen en el momento.
        guard panels.values.contains(where: { $0.frame.containsInclusive(point) })
            || panels.values.contains(where: \.isExpanded) else { return }
        panels.values.forEach { $0.updateHover(mouse: point) }
    }

    /// Reutiliza el panel de cada pantalla que sigue conectada, crea los nuevos y cierra los sobrantes.
    private func syncPanels(with screens: [NSScreen]) {
        var updated: [CGDirectDisplayID: NotchPanel] = [:]
        for screen in screens {
            guard let id = screen.displayID else { continue }
            let panel = panels.removeValue(forKey: id) ?? NotchPanel(tabs: tabs)
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

        let tabsMenu = NSMenu(title: "Pestañas")
        tabsMenu.addItem(withTitle: "Nueva pestaña", action: #selector(newTab), keyEquivalent: "t").target = self
        tabsMenu.addItem(withTitle: "Cerrar pestaña", action: #selector(closeTabOrWindow), keyEquivalent: "w").target = self
        tabsMenu.addItem(withTitle: "Pestaña siguiente", action: #selector(nextTab), keyEquivalent: "]").target = self
        tabsMenu.addItem(withTitle: "Pestaña anterior", action: #selector(previousTab), keyEquivalent: "[").target = self
        tabsMenu.addItem(.separator())
        tabsMenu.addItem(withTitle: "Agente / Terminal", action: #selector(toggleMode), keyEquivalent: "e").target = self

        let editItem = NSMenuItem()
        editItem.submenu = edit
        let tabsItem = NSMenuItem()
        tabsItem.submenu = tabsMenu
        let mainMenu = NSMenu()
        mainMenu.addItem(editItem)
        mainMenu.addItem(tabsItem)
        NSApp.mainMenu = mainMenu
    }

    @objc private func openSettings() {
        settings.show()
    }

    // Atajos de pestañas: funcionan con el notch abierto y el teclado en él.
    @objc private func newTab() {
        tabs.newTab()
    }

    /// ⌘W: en el notch cierra la pestaña; en otra ventana (Configuración), la ventana.
    @objc private func closeTabOrWindow() {
        if NSApp.keyWindow is NotchPanel {
            tabs.closeSelected()
        } else {
            NSApp.keyWindow?.performClose(nil)
        }
    }

    @objc private func toggleMode() {
        tabs.selected.toggleMode()
    }

    @objc private func nextTab() {
        tabs.selectAdjacent(1)
    }

    @objc private func previousTab() {
        tabs.selectAdjacent(-1)
    }

    /// Cmd+V en el notch: una imagen copiada se adjunta (se extrae su texto); el texto se pega como siempre.
    @objc private func pasteOrAttachImage(_ sender: Any?) {
        // En modo Terminal se pega como en cualquier terminal.
        if NSApp.keyWindow is NotchPanel, tabs.selected.mode == .agent, let image = ImageTextReader.image(from: .general) {
            tabs.selected.attachImage(image)
        } else {
            NSApp.sendAction(#selector(NSText.paste(_:)), to: nil, from: sender)
        }
    }
}
