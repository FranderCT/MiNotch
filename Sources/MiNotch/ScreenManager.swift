import AppKit

/// Elige la pantalla donde vive el notch y avisa cuando cambia la configuración de monitores.
@MainActor
final class ScreenManager {
    var onScreenChange: ((NSScreen) -> Void)?

    // Solo se escribe en start() (main actor) y se lee en deinit.
    private nonisolated(unsafe) var observer: NSObjectProtocol?

    func start() {
        observer = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.notify() }
        }
        notify()
    }

    /// Primer monitor externo; si no hay, la pantalla principal (la de la barra de menú).
    static func targetScreen() -> NSScreen? {
        NSScreen.screens.first { !$0.isBuiltIn } ?? NSScreen.screens.first
    }

    private func notify() {
        guard let screen = Self.targetScreen() else { return }
        onScreenChange?(screen)
    }

    deinit {
        if let observer { NotificationCenter.default.removeObserver(observer) }
    }
}

private extension NSScreen {
    var displayID: CGDirectDisplayID? {
        (deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value
    }

    var isBuiltIn: Bool {
        guard let displayID else { return false }
        return CGDisplayIsBuiltin(displayID) != 0
    }
}
