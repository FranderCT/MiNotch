import SwiftUI

/// Estado compartido entre el panel (que detecta el hover) y la vista (que lo dibuja).
@MainActor
final class NotchState: ObservableObject {
    static let expandedSize = CGSize(width: 400, height: 120)
    static let collapsedWidth: CGFloat = 200
    /// Espacio libre entre la píldora en reposo y el borde inferior de la barra de menú.
    static let gapToWindows: CGFloat = 4

    @Published var isExpanded = false
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

    private var size: CGSize {
        state.isExpanded ? NotchState.expandedSize : state.collapsedSize
    }

    private var cornerRadius: CGFloat {
        state.isExpanded ? 28 : 14
    }

    var body: some View {
        // Bordes superiores rectos (pegados al borde de la pantalla), inferiores redondeados.
        UnevenRoundedRectangle(
            bottomLeadingRadius: cornerRadius,
            bottomTrailingRadius: cornerRadius,
            style: .continuous
        )
        .fill(.black)
        .frame(width: size.width, height: size.height)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .animation(.spring(response: 0.38, dampingFraction: 0.72), value: state.isExpanded)
    }
}
