import SwiftUI

/// Estado compartido entre el panel (que detecta el hover) y la vista (que lo dibuja).
@MainActor
final class NotchState: ObservableObject {
    static let agentSize = CGSize(width: 500, height: 380)
    /// Modo Terminal: ~100 columnas × 26 filas.
    static let terminalSize = CGSize(width: 720, height: 440)
    static let collapsedWidth: CGFloat = 200
    /// Espacio libre entre la píldora en reposo y el borde inferior de la barra de menú.
    static let gapToWindows: CGFloat = 4

    @Published var isExpanded = false
    /// Según el modo de la pestaña seleccionada.
    @Published var expandedSize = agentSize
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
    @ObservedObject var tabs: ChatTabs

    private var size: CGSize {
        state.isExpanded ? state.expandedSize : state.collapsedSize
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
                    let chat = tabs.selected
                    ChatView(
                        tabs: tabs, chat: chat, account: tabs.account, workspace: chat.workspace, terminals: chat.terminals,
                        topInset: state.collapsedSize.height, isDropTargeted: $state.isDropTargeted
                    )
                    // Cada pestaña con su foco y su scroll.
                    .id(chat.id)
                }
                .frame(width: state.expandedSize.width, height: state.expandedSize.height)
                .transition(.opacity)
            }
        }
        .clipShape(shape)
        .overlay {
            // Siempre con colores de IA. Estático en reposo (0 % de CPU); gira mientras responde.
            // Quieto mientras espera al usuario (aprobación o contraseña): puede ser mucho rato.
            GlowBorder(shape: shape, isAnimating: tabs.isAnyWorking)
                .opacity(tabs.isAnyWorking ? 1 : 0.75)
        }
        .frame(width: size.width, height: size.height)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .animation(.spring(response: 0.38, dampingFraction: 0.72), value: state.isExpanded)
        .animation(.spring(response: 0.32, dampingFraction: 0.85), value: state.expandedSize)
    }
}
