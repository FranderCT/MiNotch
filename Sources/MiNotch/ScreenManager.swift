import AppKit

/// Avisa con la lista de pantallas al arrancar y cada vez que cambia la configuración de monitores.
@MainActor
final class ScreenManager {
    var onScreensChange: (([NSScreen]) -> Void)?

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

    private func notify() {
        onScreensChange?(NSScreen.screens)
    }

    deinit {
        if let observer { NotificationCenter.default.removeObserver(observer) }
    }
}

extension NSScreen {
    var displayID: CGDirectDisplayID? {
        (deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value
    }

    /// Tamaño del notch físico, o nil si la pantalla no tiene.
    var notchSize: CGSize? {
        guard safeAreaInsets.top > 0,
              let left = auxiliaryTopLeftArea,
              let right = auxiliaryTopRightArea else { return nil }
        return CGSize(width: right.minX - left.maxX, height: safeAreaInsets.top)
    }
}
