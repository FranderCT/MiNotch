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
    private lazy var mainWindow = MainWindowController(tabs: tabs)
    /// La interfaz del notch: la misma en las píldoras de todas las pantallas (barra lateral oculta por defecto).
    private let notchLayout = ChatLayoutState(sidebarKey: "notchSidebarVisible", sidebarVisibleByDefault: false)
    /// Notch, ventana o ambos (Configuración). Se aplica al cambiar, sin reiniciar.
    private var interfaceMode = InterfaceMode.current
    private var windowMenuItem: NSMenuItem?

    func applicationDidFinishLaunching(_ notification: Notification) {
        setupStatusItem()
        setupMainMenu()
        handleTerminationSignal()
        // Qué agentes externos (Claude Code, Codex…) hay instalados, para agent_start.
        Task { await ExternalAgentKind.detectInstalled() }
        account.onOpenSettings = { [weak self] in self?.openSettings() }
        tabs.onOpenWindow = { [weak self] in self?.showMainWindow() }

        screenManager.onScreensChange = { [weak self] screens in
            guard let self, self.interfaceMode.usesNotch else { return }
            self.syncPanels(with: screens)
        }
        mouseTracker.onMove = { [weak self] point in
            self?.routeMouse(at: point)
        }
        applyInterfaceMode(opening: true)
        screenManager.start()

        NotificationCenter.default.addObserver(forName: UserDefaults.didChangeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, InterfaceMode.current != self.interfaceMode else { return }
                self.interfaceMode = InterfaceMode.current
                self.applyInterfaceMode(opening: true)
            }
        }
    }

    /// Prende o apaga el notch (paneles y seguimiento del mouse) y la ventana según `interfaceMode`.
    private func applyInterfaceMode(opening: Bool) {
        if interfaceMode.usesNotch {
            syncPanels(with: NSScreen.screens)
            mouseTracker.start()
        } else {
            // Sin notch tampoco hace falta escuchar el mouse: cero CPU en eso.
            mouseTracker.stop()
            panels.values.forEach { $0.close() }
            panels = [:]
        }
        if interfaceMode.usesWindow {
            if opening { mainWindow.show() }
        } else {
            mainWindow.close()
        }
        windowMenuItem?.isHidden = !interfaceMode.usesWindow
    }

    /// Clic en el ícono del Dock: vuelve a mostrar la ventana.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if interfaceMode.usesWindow { mainWindow.show() }
        return true
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
            let panel = panels.removeValue(forKey: id) ?? NotchPanel(tabs: tabs, layout: notchLayout)
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
        let windowItem = NSMenuItem(title: "Abrir ventana", action: #selector(showMainWindow), keyEquivalent: "")
        windowItem.target = self
        windowItem.isHidden = !interfaceMode.usesWindow
        menu.addItem(windowItem)
        windowMenuItem = windowItem
        let settingsItem = NSMenuItem(title: "Configuración…", action: #selector(openSettings), keyEquivalent: ",")
        settingsItem.target = self
        menu.addItem(settingsItem)
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Salir", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        item.menu = menu

        statusItem = item
    }

    /// Menú principal: invisible mientras la app vive en la barra de menú (sin él no funcionan Cmd+C/V/X/A/Z);
    /// visible con la ventana abierta (la app aparece en el Dock).
    private func setupMainMenu() {
        let app = NSMenu(title: "MiNotch")
        app.addItem(withTitle: "Configuración…", action: #selector(openSettings), keyEquivalent: ",").target = self
        app.addItem(.separator())
        app.addItem(withTitle: "Ocultar MiNotch", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        app.addItem(withTitle: "Salir de MiNotch", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")

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
        let sidebarItem = tabsMenu.addItem(withTitle: "Mostrar u ocultar pestañas", action: #selector(toggleSidebar), keyEquivalent: "s")
        sidebarItem.keyEquivalentModifierMask = [.control, .command]
        sidebarItem.target = self
        tabsMenu.addItem(.separator())
        for number in 1...9 {
            let item = tabsMenu.addItem(withTitle: "Pestaña \(number)", action: #selector(selectTabByShortcut(_:)), keyEquivalent: "\(number)")
            item.target = self
            item.tag = number
        }

        let window = NSMenu(title: "Ventana")
        window.addItem(withTitle: "Minimizar", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        window.addItem(withTitle: "Mostrar la ventana de MiNotch", action: #selector(showMainWindow), keyEquivalent: "0").target = self

        let appItem = NSMenuItem()
        appItem.submenu = app
        let editItem = NSMenuItem()
        editItem.submenu = edit
        let windowItem = NSMenuItem()
        windowItem.submenu = window
        let tabsItem = NSMenuItem()
        tabsItem.submenu = tabsMenu
        let mainMenu = NSMenu()
        mainMenu.addItem(appItem)
        mainMenu.addItem(editItem)
        mainMenu.addItem(tabsItem)
        mainMenu.addItem(windowItem)
        NSApp.mainMenu = mainMenu
    }

    @objc private func openSettings() {
        settings.show()
    }

    @objc private func showMainWindow() {
        // Desde el notch en "solo notch": pasa a "notch y ventana" (al cambiar el ajuste se abre la ventana).
        if !interfaceMode.usesWindow {
            UserDefaults.standard.set(InterfaceMode.both.rawValue, forKey: InterfaceMode.defaultsKey)
        } else {
            mainWindow.show()
        }
    }

    /// El notch o la ventana principal: donde viven las pestañas.
    private var isChatWindowKey: Bool {
        NSApp.keyWindow is NotchPanel || NSApp.keyWindow is MainWindow
    }

    // Atajos de pestañas: funcionan con el notch abierto y el teclado en él.
    @objc private func newTab() {
        tabs.newTab()
    }

    /// ⌘W: en el notch o la ventana principal cierra la pestaña; en Configuración, la ventana.
    @objc private func closeTabOrWindow() {
        if isChatWindowKey {
            tabs.closeSelected()
        } else {
            NSApp.keyWindow?.performClose(nil)
        }
    }

    /// ⌘1…⌘9: la pestaña en esa posición.
    @objc private func selectTabByShortcut(_ sender: NSMenuItem) {
        guard tabs.tabs.indices.contains(sender.tag - 1) else { return }
        tabs.select(tabs.tabs[sender.tag - 1].id)
    }

    /// ⌃⌘S: la barra lateral de donde esté el teclado (ventana o notch).
    @objc private func toggleSidebar() {
        (NSApp.keyWindow is MainWindow ? mainWindow.layout : notchLayout).toggleSidebar()
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
        if isChatWindowKey, tabs.selected.mode == .agent, let image = ImageTextReader.image(from: .general) {
            tabs.selected.attachImage(image)
        } else {
            NSApp.sendAction(#selector(NSText.paste(_:)), to: nil, from: sender)
        }
    }
}
