import AppKit
import SwiftUI

/// Menú de completado del editor de la terminal: Tab lo abre, ↑↓ navegan, Tab o Enter aceptan, Esc cierra.
/// Escucha las teclas con un monitor local (antes de que lleguen al editor), así no hace falta tocar el editor.
@MainActor
final class CompletionController: ObservableObject {
    @Published private(set) var items: [Completion] = []
    @Published private(set) var selected = 0
    @Published private(set) var isOpen = false

    /// Qué muestra la lista: completado de lo escrito o el selector de carpeta.
    enum Mode { case completion, directories }
    @Published private(set) var mode = Mode.completion

    weak var hostWindow: NSWindow?
    private var recents: () -> [URL] = { [] }
    private var head = ""
    private var shell: TabShell?
    private var directory: () -> URL = { URL(fileURLWithPath: NSHomeDirectory()) }
    private var monitor: Any?

    func attach(shell: TabShell, directory: @escaping () -> URL, recents: @escaping () -> [URL]) {
        self.shell = shell
        self.directory = directory
        self.recents = recents
        PathCommands.shared.loadIfNeeded()
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            let keyCode = event.keyCode
            let modifiers = event.modifierFlags
            let window = event.window
            let consumed = MainActor.assumeIsolated { self?.handle(keyCode: keyCode, modifiers: modifiers, window: window) ?? false }
            return consumed ? nil : event
        }
    }

    func detach() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        close()
    }

    func close() {
        guard isOpen || !items.isEmpty else { return }
        isOpen = false
        items = []
        selected = 0
        mode = .completion
    }

    /// El chip de carpeta: lista la carpeta superior, las subcarpetas y las recientes. Elegir una hace `cd`.
    func openDirectoryPicker() {
        guard let shell, shell.isRunning, shell.commandState.phase == .ready else { return }
        if isOpen, mode == .directories { close(); return }
        let choices = DirectoryChoices.items(from: directory(), recents: recents())
        guard !choices.isEmpty else { return }
        mode = .directories
        items = choices
        selected = 0
        isOpen = true
    }

    /// El borrador cambió con el menú abierto: se vuelve a filtrar, y si no queda nada se cierra.
    func refresh() {
        guard isOpen, let shell else { return }
        // Escribir cierra el selector de carpeta: ya no es lo que se está buscando.
        guard mode == .completion else { close(); return }
        let result = CompletionEngine.completions(for: shell.draft, directory: directory(), pathCommands: PathCommands.shared.names)
        guard !result.items.isEmpty else { close(); return }
        head = result.head
        items = result.items
        selected = min(selected, items.count - 1)
    }

    func accept(_ index: Int) {
        guard let shell, items.indices.contains(index) else { return }
        let item = items[index]
        let wasPicker = mode == .directories
        close()
        if wasPicker {
            shell.changeDirectory(to: URL(fileURLWithPath: item.insertion, isDirectory: true))
        } else {
            shell.draft = head + item.insertion
        }
    }

    /// true si la tecla se consumió (no llega al editor).
    private func handle(keyCode: UInt16, modifiers: NSEvent.ModifierFlags, window: NSWindow?) -> Bool {
        guard let shell, let window, window === hostWindow,
              shell.isRunning, shell.commandState.phase == .ready, !shell.isEditingDirectly,
              let editor = window.firstResponder as? NSTextView, editor.isEditable, !editor.hasMarkedText() else { return false }
        let pressed = modifiers.intersection(.deviceIndependentFlagsMask).subtracting([.capsLock, .numericPad, .function])
        guard pressed.isEmpty else { return false }

        switch keyCode {
        case 48: // Tab
            if isOpen { accept(selected); return true }
            return open(shell)
        case 125 where isOpen: // ↓
            selected = (selected + 1) % items.count
            return true
        case 126 where isOpen: // ↑
            selected = (selected + items.count - 1) % items.count
            return true
        case 36 where isOpen, 76 where isOpen: // Enter
            accept(selected)
            return true
        case 53 where isOpen: // Esc
            close()
            return true
        default:
            return false
        }
    }

    /// true si había algo que completar (Tab se consume); con una sola opción se aplica directo, como en un shell.
    private func open(_ shell: TabShell) -> Bool {
        let result = CompletionEngine.completions(for: shell.draft, directory: directory(), pathCommands: PathCommands.shared.names)
        guard !result.items.isEmpty else { return false }
        head = result.head
        items = result.items
        selected = 0
        mode = .completion
        if items.count == 1 {
            accept(0)
        } else {
            isOpen = true
        }
        return true
    }
}

/// Lista de opciones: icono, nombre y tipo a la derecha (Carpeta, Archivo, Comando…).
struct CompletionPopup: View {
    @ObservedObject var controller: CompletionController
    let fontSize: CGFloat

    private static let rowHeight: CGFloat = 26
    private static let visibleRows = 6

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(spacing: 0) {
                    ForEach(Array(controller.items.enumerated()), id: \.element.id) { index, item in
                        row(item, isSelected: index == controller.selected)
                            .id(item.id)
                            .onTapGesture { controller.accept(index) }
                    }
                }
            }
            .scrollIndicators(.never)
            .onChange(of: controller.selected) {
                if controller.items.indices.contains(controller.selected) {
                    proxy.scrollTo(controller.items[controller.selected].id)
                }
            }
        }
        .frame(width: 300, height: CGFloat(min(controller.items.count, Self.visibleRows)) * Self.rowHeight)
        .background(Color(white: 0.11), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(.white.opacity(0.12), lineWidth: 1))
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .shadow(color: .black.opacity(0.4), radius: 10, y: 4)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Opciones de completado")
    }

    private func row(_ item: Completion, isSelected: Bool) -> some View {
        HStack(spacing: 8) {
            Image(systemName: item.kind.icon)
                .font(.system(size: fontSize - 1))
                .foregroundStyle(item.kind == .directory ? AITheme.blue : .white.opacity(0.6))
                .frame(width: 16)
            Text(item.display)
                .font(.system(size: fontSize, weight: .medium, design: .monospaced))
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 6)
            Text(item.kind.rawValue)
                .font(.system(size: fontSize - 2))
                .foregroundStyle(.white.opacity(0.45))
        }
        .padding(.horizontal, 10)
        .frame(height: Self.rowHeight)
        .background(isSelected ? Color.white.opacity(0.12) : .clear)
        .contentShape(Rectangle())
    }
}

/// Entrega la ventana donde vive la vista (el monitor de teclas solo atiende a su propia ventana).
struct WindowReader: NSViewRepresentable {
    let onChange: (NSWindow?) -> Void

    func makeNSView(context: Context) -> ReaderView { ReaderView(onChange: onChange) }
    func updateNSView(_ view: ReaderView, context: Context) { view.onChange = onChange }

    final class ReaderView: NSView {
        var onChange: (NSWindow?) -> Void
        init(onChange: @escaping (NSWindow?) -> Void) {
            self.onChange = onChange
            super.init(frame: .zero)
        }
        required init?(coder: NSCoder) { fatalError() }
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            onChange(window)
        }
    }
}
