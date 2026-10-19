import SwiftUI

/// Paleta y efectos visuales "IA": violeta → azul → cian → rosa.
enum AITheme {
    static let violet = Color(red: 0.58, green: 0.38, blue: 0.98)
    static let blue = Color(red: 0.25, green: 0.52, blue: 1.0)
    static let cyan = Color(red: 0.20, green: 0.85, blue: 0.95)
    static let pink = Color(red: 0.96, green: 0.36, blue: 0.68)

    /// Degradado principal para íconos, burbujas y botones.
    static let accent = LinearGradient(colors: [violet, blue], startPoint: .topLeading, endPoint: .bottomTrailing)

    /// Anillo de colores para los bordes brillantes; `angle` lo hace girar.
    static func ring(_ angle: Angle) -> AngularGradient {
        AngularGradient(colors: [violet, blue, cyan, pink, violet], center: .center, angle: angle)
    }
}

/// Tinte suave de color sobre el fondo negro del notch expandido.
struct AIBackgroundTint: View {
    var body: some View {
        ZStack {
            RadialGradient(
                colors: [AITheme.violet.opacity(0.30), .clear],
                center: .bottomLeading, startRadius: 0, endRadius: 320
            )
            RadialGradient(
                colors: [AITheme.blue.opacity(0.24), .clear],
                center: .bottomTrailing, startRadius: 0, endRadius: 300
            )
        }
        .allowsHitTesting(false)
    }
}

/// Borde con degradado y resplandor. Solo se anima (gira) cuando `isAnimating`;
/// si no, se dibuja una vez y no consume CPU. A 30 fps: el giro se ve igual y gasta menos.
struct GlowBorder<S: Shape>: View {
    let shape: S
    var isAnimating: Bool
    var lineWidth: CGFloat = 1.5

    /// Margen extra para que el resplandor no se recorte en los bordes de la vista.
    private let glowPadding: CGFloat = 16

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30, paused: !isAnimating)) { context in
            let degrees = (context.date.timeIntervalSinceReferenceDate * 120).truncatingRemainder(dividingBy: 360)
            let ring = AITheme.ring(.degrees(degrees))
            ZStack {
                shape.stroke(ring, lineWidth: lineWidth * 5)
                    .blur(radius: 8)
                    .opacity(0.7)
                shape.stroke(ring, lineWidth: lineWidth)
            }
            .padding(glowPadding)
            // Por GPU: el degradado cónico dibujado por CPU, píxel por píxel, costaba ~23 % al girar (~8 % así).
            .drawingGroup()
        }
        // Se desvanece hacia arriba: el borde superior está pegado al borde de la pantalla.
        .mask(
            LinearGradient(
                stops: [.init(color: .clear, location: 0), .init(color: .black, location: 0.5)],
                startPoint: .top,
                endPoint: .bottom
            )
        )
        .padding(-glowPadding)
        .allowsHitTesting(false)
    }
}
