import SwiftUI

/// Estado compartido entre el panel (que detecta el hover) y la vista (que lo dibuja).
@MainActor
final class NotchState: ObservableObject {
    static let agentSize = CGSize(width: 500, height: 380)
    /// Modo Terminal: ~100 columnas × 26 filas.
    static let terminalSize = CGSize(width: 720, height: 440)
    /// Con la barra lateral de pestañas visible, el notch se ensancha en lo que ocupa (más el separador).
    static let sidebarExtraWidth: CGFloat = ChatStyle.notch(topInset: 0).sidebarWidth + 1

    static func expandedSize(terminal: Bool, sidebar: Bool) -> CGSize {
        let base = terminal ? terminalSize : agentSize
        return CGSize(width: base.width + (sidebar ? sidebarExtraWidth : 0), height: base.height)
    }
    static let collapsedWidth: CGFloat = 200
    /// Espacio libre entre la píldora en reposo y el borde inferior de la barra de menú.
    static let gapToWindows: CGFloat = 4

    @Published var isExpanded = false
    /// Según el modo de la pestaña seleccionada.
    @Published var expandedSize = agentSize
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
    @ObservedObject var layout: ChatLayoutState

    /// Cerrado: un punto de estado como los de la barra lateral (rosa si espera al usuario, cian si responde).
    private var indicator: Color? {
        if !tabs.needingAttention.isEmpty { return AITheme.pink }
        return tabs.isAnyWorking ? AITheme.cyan : nil
    }

    /// Ancho extra de la píldora cerrada para que el punto se vea al lado del notch físico.
    private static let indicatorWidth: CGFloat = 28

    private var size: CGSize {
        if state.isExpanded { return state.expandedSize }
        var size = state.collapsedSize
        if indicator != nil { size.width += Self.indicatorWidth }
        return size
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
        // Cerrada, negra para fundirse con el notch físico; abierta, con el fondo de la ventana.
        .fill(state.isExpanded ? AITheme.background : .black)
        .overlay(alignment: .top) {
            if state.isExpanded {
                // La misma interfaz que la ventana, a escala.
                // Tamaño fijo: durante la animación la píldora lo va recortando en vez de re-maquetarlo.
                MainChatView(tabs: tabs, layout: layout, style: .notch(topInset: state.collapsedSize.height), showsWindowButton: true)
                    // Lejos de las esquinas inferiores redondeadas.
                    .padding(.horizontal, 12)
                    .padding(.bottom, 12)
                    .frame(width: state.expandedSize.width, height: state.expandedSize.height)
                    .transition(.opacity)
            }
        }
        .overlay(alignment: .trailing) {
            if !state.isExpanded, let indicator {
                // Estático: no consume CPU mientras responde.
                Circle()
                    .fill(indicator)
                    .frame(width: 7, height: 7)
                    .padding(.trailing, 11)
                    .transition(.opacity)
            }
        }
        .clipShape(shape)
        .overlay {
            if state.isExpanded {
                shape.stroke(AITheme.border, lineWidth: 1)
            }
        }
        .frame(width: size.width, height: size.height)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .animation(.spring(response: 0.38, dampingFraction: 0.72), value: state.isExpanded)
        .animation(.spring(response: 0.32, dampingFraction: 0.85), value: state.expandedSize)
        .animation(.spring(response: 0.32, dampingFraction: 0.85), value: indicator)
    }
}
