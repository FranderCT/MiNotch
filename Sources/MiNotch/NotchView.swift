import SwiftUI

/// Estado compartido entre el panel (que detecta el hover) y la vista (que lo dibuja).
@MainActor
final class NotchState: ObservableObject {
    static let expandedSize = CGSize(width: 500, height: 360)
    static let collapsedWidth: CGFloat = 200
    /// Espacio libre entre la píldora en reposo y el borde inferior de la barra de menú.
    static let gapToWindows: CGFloat = 4

    @Published var isExpanded = false
    @Published var isDropTargeted = false
    /// Se ajusta a la altura de la barra de menú de la pantalla actual.
    @Published var collapsedSize = CGSize(width: collapsedWidth, height: 26)

    /// Tamaño en reposo según la pantalla: cubre el notch físico si existe;
    /// si no, cabe en la barra de menú sin invadir el área de las ventanas.
    func fit(to screen: NSScreen) {
        if let notch = screen.notchSize {
            collapsedSize = CGSize(width: max(Self.collapsedWidth, notch.width), height: notch.height)
            return
        }

        collapsedSize.width = Self.collapsedWidth
        let menuBarHeight = screen.frame.maxY - screen.visibleFrame.maxY
        // Barra de menú oculta (auto-hide): usar una altura estándar.
        let available = menuBarHeight > 0 ? menuBarHeight : 30
        collapsedSize.height = max(available - Self.gapToWindows, 16)
    }
}

struct NotchView: View {
    @ObservedObject var state: NotchState
    @ObservedObject var chat: ChatSession

    private var size: CGSize {
        state.isExpanded ? NotchState.expandedSize : state.collapsedSize
    }

    private var cornerRadius: CGFloat {
        state.isExpanded ? 32 : 14
    }

    private var shape: UnevenRoundedRectangle {
        // Bordes superiores rectos (pegados al borde de la pantalla), inferiores redondeados.
        UnevenRoundedRectangle(
            bottomLeadingRadius: cornerRadius,
            bottomTrailingRadius: cornerRadius,
            style: .continuous
        )
    }

    var body: some View {
        shape
        .fill(.black)
        .overlay(alignment: .top) {
            if state.isExpanded {
                // Tamaño fijo: durante la animación la píldora lo va recortando en vez de re-maquetarlo.
                ZStack(alignment: .top) {
                    AIBackgroundTint()
                    ChatView(chat: chat, workspace: chat.workspace, topInset: state.collapsedSize.height, isDropTargeted: $state.isDropTargeted)
                }
                .frame(width: NotchState.expandedSize.width, height: NotchState.expandedSize.height)
                .transition(.opacity)
            }
        }
        .clipShape(shape)
        .overlay {
            // Siempre con colores de IA. Estático en reposo (0 % de CPU); gira mientras responde.
            GlowBorder(shape: shape, isAnimating: chat.isStreaming)
                .opacity(chat.isStreaming ? 1 : 0.75)
        }
        .frame(width: size.width, height: size.height)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .animation(.spring(response: 0.38, dampingFraction: 0.72), value: state.isExpanded)
    }
}
