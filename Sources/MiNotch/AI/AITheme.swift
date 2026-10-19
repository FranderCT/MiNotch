import SwiftUI

/// Paleta y efectos visuales "IA": violeta → azul → cian → rosa.
enum AITheme {
    static let violet = Color(red: 0.58, green: 0.38, blue: 0.98)
    static let blue = Color(red: 0.25, green: 0.52, blue: 1.0)
    static let cyan = Color(red: 0.20, green: 0.85, blue: 0.95)
    static let pink = Color(red: 0.96, green: 0.36, blue: 0.68)

    /// Degradado principal para íconos, burbujas y botones.
    static let accent = LinearGradient(colors: [violet, blue], startPoint: .topLeading, endPoint: .bottomTrailing)

    /// Fondo de la interfaz (ventana y notch abierto): gris casi negro, como una terminal.
    static let background = Color(white: 0.055)
    /// Borde sutil del notch abierto, como el de una ventana.
    static let border = Color.white.opacity(0.1)
}
