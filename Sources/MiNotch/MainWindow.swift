import AppKit
import SwiftUI

/// Dónde se muestra MiNotch. Se elige en Configuración.
enum InterfaceMode: String, CaseIterable, Sendable {
    case notch, window, both

    static let defaultsKey = "interfaceMode"

    static var current: InterfaceMode {
        InterfaceMode(rawValue: UserDefaults.standard.string(forKey: defaultsKey) ?? "") ?? .notch
    }

    var title: String {
        switch self {
        case .notch: "Notch"
        case .window: "Ventana"
        case .both: "Notch y ventana"
        }
    }

    var usesNotch: Bool { self != .window }
    var usesWindow: Bool { self != .notch }
}

/// Ventana normal de macOS con las mismas pestañas que el notch.
/// Mientras está abierta la app aparece en el Dock y en ⌘Tab; al cerrarla vuelve a la barra de menú.
@MainActor
final class MainWindowController: NSObject, NSWindowDelegate {
    private let tabs: ChatTabs
    private var window: MainWindow?

    init(tabs: ChatTabs) {
        self.tabs = tabs
    }

    var isVisible: Bool { window?.isVisible == true }

    func show() {
        if window == nil {
            let window = MainWindow(
                contentRect: NSRect(x: 0, y: 0, width: 1000, height: 640),
                styleMask: [.titled, .closable, .miniaturizable, .resizable],
                backing: .buffered,
                defer: false
            )
            window.title = "MiNotch"
            // Barra de título oscura y sin texto: se funde con la barra lateral, como una terminal.
            window.titleVisibility = .hidden
            window.titlebarAppearsTransparent = true
            window.appearance = NSAppearance(named: .darkAqua)
            window.backgroundColor = NSColor(white: 0.07, alpha: 1)
            window.minSize = NSSize(width: 720, height: 440)
            window.isReleasedWhenClosed = false
            window.delegate = self
            window.contentView = NSHostingView(rootView: WindowRootView(tabs: tabs, state: WindowState()))
            window.center()
            // Recuerda tamaño y posición entre usos.
            window.setFrameAutosaveName("MiNotchWindow")
            self.window = window
        }
        NSApp.setActivationPolicy(.regular)
        NSApp.activate()
        window?.makeKeyAndOrderFront(nil)
    }

    func close() {
        window?.close()
    }

    func windowWillClose(_ notification: Notification) {
        // Sin ventana, de vuelta a la barra de menú (sin Dock ni ⌘Tab).
        NSApp.setActivationPolicy(.accessory)
    }
}

/// Para distinguirla del panel del notch y de Configuración (atajos, pegar imágenes).
final class MainWindow: NSWindow {}
