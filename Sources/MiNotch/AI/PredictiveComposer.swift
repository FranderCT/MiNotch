import AppKit
import SwiftUI

@MainActor
private final class ProjectPredictionContext: ObservableObject {
    @Published var commands = InputPredictions.commands
    func load(_ directory: URL) async {
        let result = await Task.detached(priority: .utility) {
            InputPredictions.projectCommands(in: directory)
        }.value
        guard !Task.isCancelled else { return }
        commands = result
    }
}

struct TerminalInputComposer: View {
    @ObservedObject var shell: TabShell
    let directory: URL
    let fontSize: CGFloat
    @StateObject private var project = ProjectPredictionContext()

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
          HStack(alignment: .top, spacing: 10) {
            Text("❯")
                .foregroundStyle(AITheme.cyan)
                .padding(.top, 4)
            PredictiveComposer(
                text: $shell.draft,
                suggestions: InputPredictions.suggestions(for: shell.draft, history: shell.inputHistory, candidates: project.commands),
                placeholder: shell.isEditingDirectly ? "Entrada en la terminal · Ctrl+C vuelve al editor" : (shell.commandState.phase == .ready ? "Escribí un comando…" : "El editor estará listo cuando vuelva el prompt"),
                fontSize: fontSize,
                isEnabled: shell.isRunning && shell.commandState.phase == .ready && !shell.isEditingDirectly,
                fallbackResponder: shell.view,
                onSubmit: { shell.submitDraft(in: directory) }
            )
          }
          if let error = shell.inputError {
              Text(error).font(.system(size: 11)).foregroundStyle(AITheme.pink)
          }
        }
        .task(id: directory) { await project.load(directory) }
    }
}

/// Editor multilínea con una continuación visual que solo entra al borrador al aceptarla.
struct PredictiveComposer: View {
    @Binding var text: String
    let suggestions: [String]
    let placeholder: String
    let fontSize: CGFloat
    var isEnabled = true
    var fallbackResponder: NSView? = nil
    var onCancel: (() -> Void)? = nil
    let onSubmit: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            PredictionEditor(text: $text, suggestions: suggestions, placeholder: placeholder,
                             fontSize: fontSize, isEnabled: isEnabled, fallbackResponder: fallbackResponder,
                             onCancel: onCancel, onSubmit: onSubmit)
                .frame(height: fontSize * 3 + 10)
            HStack(spacing: 8) {
                Text(suggestions.isEmpty ? "Enter enviar · ⇧Enter nueva línea" : "Tab completar · ↑↓ sugerencias · Esc descartar")
                Spacer(minLength: 0)
                Text("Predicción local")
            }
            .font(.system(size: max(9, fontSize - 3), design: .monospaced))
            .foregroundStyle(.white.opacity(0.35))
        }
    }
}

private struct PredictionEditor: NSViewRepresentable {
    @Binding var text: String
    let suggestions: [String]
    let placeholder: String
    let fontSize: CGFloat
    let isEnabled: Bool
    let fallbackResponder: NSView?
    let onCancel: (() -> Void)?
    let onSubmit: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        let editor = PredictiveTextView(frame: .zero)
        editor.isRichText = false
        editor.isAutomaticQuoteSubstitutionEnabled = false
        editor.isAutomaticDashSubstitutionEnabled = false
        editor.isAutomaticTextReplacementEnabled = false
        editor.isAutomaticSpellingCorrectionEnabled = false
        editor.drawsBackground = false
        editor.textColor = .white
        editor.insertionPointColor = NSColor(AITheme.cyan)
        editor.textContainerInset = NSSize(width: 0, height: 4)
        editor.textContainer?.lineFragmentPadding = 0
        editor.isVerticallyResizable = true
        editor.isHorizontallyResizable = false
        editor.autoresizingMask = [.width]
        editor.textContainer?.widthTracksTextView = true
        editor.delegate = context.coordinator
        editor.minSize = NSSize(width: 0, height: 40)
        editor.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        scroll.documentView = editor
        update(editor)
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        context.coordinator.parent = self
        guard let editor = scroll.documentView as? PredictiveTextView else { return }
        // No reemplazar texto durante composición de caracteres (IME).
        if editor.string != text, !editor.hasMarkedText() {
            editor.string = text
            editor.setSelectedRange(NSRange(location: (text as NSString).length, length: 0))
        }
        update(editor)
    }

    private func update(_ editor: PredictiveTextView) {
        editor.font = .monospacedSystemFont(ofSize: fontSize, weight: .regular)
        editor.isEditable = isEnabled
        editor.placeholder = placeholder
        editor.candidates = suggestions
        editor.submit = onSubmit
        editor.cancel = onCancel
        editor.setAccessibilityLabel(placeholder)
        editor.needsDisplay = true
        if !isEnabled, let fallbackResponder, editor.window?.firstResponder === editor {
            editor.didFocusInitially = false
            editor.window?.makeFirstResponder(fallbackResponder)
        }
        if isEnabled, !editor.didFocusInitially, editor.window != nil {
            editor.didFocusInitially = true
            DispatchQueue.main.async { [weak editor] in
                guard let editor, editor.isEditable else { return }
                editor.window?.makeFirstResponder(editor)
            }
        }
    }

    @MainActor final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: PredictionEditor
        init(_ parent: PredictionEditor) { self.parent = parent }
        func textDidChange(_ notification: Notification) {
            guard let editor = notification.object as? PredictiveTextView else { return }
            parent.text = editor.string
            editor.dismissed = false
            editor.needsDisplay = true
        }
        func textViewDidChangeSelection(_ notification: Notification) {
            (notification.object as? PredictiveTextView)?.needsDisplay = true
        }
    }
}

private final class PredictiveTextView: NSTextView {
    var didFocusInitially = false
    var placeholder = ""
    var submit: (() -> Void)?
    var cancel: (() -> Void)?
    var dismissed = false
    private var candidateIndex = 0
    var candidates: [String] = [] {
        didSet {
            if oldValue != candidates { candidateIndex = 0; dismissed = false }
            setAccessibilityHelp(candidates.first.map { "Sugerencia: \($0). Tab para completar." })
        }
    }
    override var needsPanelToBecomeKey: Bool { true }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard window != nil, isEditable, !didFocusInitially else { return }
        didFocusInitially = true
        DispatchQueue.main.async { [weak self] in
            guard let self, self.isEditable else { return }
            self.window?.makeFirstResponder(self)
        }
    }

    private var continuation: String? {
        guard isEditable, !dismissed, !hasMarkedText(), !candidates.isEmpty,
              selectedRange() == NSRange(location: (string as NSString).length, length: 0) else { return nil }
        let candidate = candidates[candidateIndex % candidates.count]
        guard candidate.hasPrefix(string), candidate.count > string.count else { return nil }
        return String(candidate.dropFirst(string.count))
    }

    override func keyDown(with event: NSEvent) {
        let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            .subtracting([.capsLock, .numericPad, .function])
        if !hasMarkedText(), modifiers.isEmpty {
            if (event.keyCode == 48 || event.keyCode == 124), let suffix = continuation {
                insertText(suffix, replacementRange: selectedRange())
                return
            }
            if event.keyCode == 53, continuation != nil {
                dismissed = true; needsDisplay = true; return
            }
            if event.keyCode == 53, let cancel { cancel(); return }
            if [UInt16(125), 126].contains(event.keyCode), continuation != nil {
                candidateIndex = (candidateIndex + (event.keyCode == 125 ? 1 : candidates.count - 1)) % candidates.count
                needsDisplay = true; return
            }
            if event.keyCode == 36 || event.keyCode == 76 {
                guard isEditable else { return }
                submit?(); return
            }
        }
        if event.keyCode == 36, modifiers == .shift, !hasMarkedText(), isEditable {
            insertText("\n", replacementRange: selectedRange()); return
        }
        super.keyDown(with: event)
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        let attributes: [NSAttributedString.Key: Any] = [
            .font: font ?? NSFont.monospacedSystemFont(ofSize: 13, weight: .regular),
            .foregroundColor: NSColor.white.withAlphaComponent(0.32)
        ]
        if string.isEmpty {
            (placeholder as NSString).draw(at: textContainerOrigin, withAttributes: attributes)
        } else if let suffix = continuation, let window {
            let screenRect = firstRect(forCharacterRange: selectedRange(), actualRange: nil)
            let caret = convert(window.convertFromScreen(screenRect), from: nil)
            // La continuación es decorativa: no altera selección, undo, portapapeles ni el borrador.
            NSGraphicsContext.saveGraphicsState()
            NSBezierPath(rect: visibleRect).addClip()
            (suffix.components(separatedBy: .newlines).first! as NSString)
                .draw(at: NSPoint(x: caret.minX, y: caret.minY), withAttributes: attributes)
            NSGraphicsContext.restoreGraphicsState()
        }
    }
}
