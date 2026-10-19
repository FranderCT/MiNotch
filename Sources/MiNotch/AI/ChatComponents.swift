import AppKit
import SwiftUI
import UniformTypeIdentifiers

// Piezas de la interfaz que comparten el notch y la ventana (ver MainChatView).

/// Texto de una imagen adjunta a una pregunta: muestra el comienzo y el tooltip, un fragmento más largo.
struct ImageTextChip: View {
    let text: String
    var wasTrimmed = false
    /// Solo en el chip pendiente de enviar: quita el texto adjunto.
    var onRemove: (() -> Void)?

    private var preview: String {
        text.split(whereSeparator: \.isNewline).first.map(String.init) ?? text
    }

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: "photo")
                .foregroundStyle(AITheme.accent)
            Text("“\(preview)”")
                .lineLimit(1)
                .truncationMode(.tail)
            if wasTrimmed {
                Text("· recortado")
                    .foregroundStyle(AITheme.pink)
                    .fixedSize()
                    .help("La imagen superaba \(ChatSession.imageTextLimit.formatted()) caracteres de texto: solo se envía el comienzo.")
            }
            if let onRemove {
                Button(action: onRemove) {
                    Image(systemName: "xmark")
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Quitar imagen adjunta")
            }
        }
        .font(.system(size: 10, weight: .medium))
        .foregroundStyle(.white.opacity(0.75))
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(.white.opacity(0.08), in: Capsule())
        .help("Texto de la imagen (\(text.count) caracteres):\n\(text.prefix(600))")
    }
}

/// Mientras Vision extrae el texto (la primera vez en el sistema puede tardar un rato).
struct ReadingImageChip: View {
    var body: some View {
        HStack(spacing: 6) {
            ProgressView()
                .controlSize(.mini)
            Text("Leyendo texto de la imagen…")
        }
        .font(.system(size: 10, weight: .medium))
        .foregroundStyle(.white.opacity(0.75))
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(.white.opacity(0.08), in: Capsule())
    }
}

/// Aviso mientras se arrastra una imagen sobre el notch.
struct DropHint: View {
    var body: some View {
        RoundedRectangle(cornerRadius: 18, style: .continuous)
            .strokeBorder(AITheme.accent, style: StrokeStyle(lineWidth: 1.5, dash: [6, 4]))
            .background(.black.opacity(0.75), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            .overlay {
                Label("Soltá la imagen para leer su texto", systemImage: "photo.badge.plus")
                    .font(.system(size: 13, weight: .semibold))
            }
            .padding(.horizontal, 8)
            .padding(.bottom, 8)
            .allowsHitTesting(false)
    }
}

/// Acción del asistente que espera aprobación: qué quiere hacer, el detalle y los botones.
struct ApprovalCard: View {
    let approval: ToolApproval
    let onDecide: (Bool) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let reason = approval.riskReason {
                Label("Parece riesgoso (\(reason)): se pregunta aunque esté en automático.", systemImage: "exclamationmark.triangle.fill")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(AITheme.pink)
                    .lineLimit(2)
            }
            HStack(spacing: 6) {
                Image(systemName: approval.icon)
                    .foregroundStyle(AITheme.accent)
                Text(approval.title)
                    .font(.system(size: 12, weight: .semibold))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 0)
                Button("Rechazar") { onDecide(false) }
                    .buttonStyle(.plain)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.white.opacity(0.75))
                Button { onDecide(true) } label: {
                    Text("Aprobar")
                        .font(.system(size: 11, weight: .semibold))
                        .padding(.horizontal, 10)
                        .padding(.vertical, 3)
                        .background(AITheme.accent, in: Capsule())
                }
                .buttonStyle(.plain)
            }
            if !approval.detail.isEmpty {
                ScrollView {
                    Text(approval.detail)
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(.white.opacity(0.8))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: 64)
                .padding(6)
                .background(.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            }
        }
        .padding(8)
        .background(.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(AITheme.accent, lineWidth: 1)
                .opacity(0.6)
        )
    }
}

/// La terminal de la pestaña (SwiftTerm). La vista vive en TabShell: cambiar de modo o de pestaña no la cierra.
struct TerminalHost: NSViewRepresentable {
    let shell: TabShell
    let directory: URL
    @AppStorage("terminalFontSize") private var fontSize = 12.0

    func makeNSView(context: Context) -> TerminalContainer {
        shell.startIfNeeded(in: directory)
        let container = TerminalContainer()
        shell.attach(to: container)
        return container
    }

    func updateNSView(_ container: TerminalContainer, context: Context) {
        let size = min(max(fontSize, 10), 24)
        if shell.view.font.pointSize != size { shell.view.font = .monospacedSystemFont(ofSize: size, weight: .regular) }
    }

    func makeCoordinator() -> TabShell { shell }

    /// El shell es de la pestaña: si se cierra el notch, la terminal vuelve a la ventana (si está abierta).
    static func dismantleNSView(_ container: TerminalContainer, coordinator shell: TabShell) {
        shell.detach(from: container)
    }
}

/// Rama de git de la carpeta de trabajo; un punto si hay cambios sin commitear.
struct GitBadge: View {
    let git: GitInfo
    /// En la ventana: también las líneas +/−, como en una terminal.
    var showsDiffStat = false

    var body: some View {
        HStack(spacing: 3) {
            Image(systemName: "arrow.triangle.branch")
            // Recortada a mano: con frame(maxWidth:) ocuparía siempre el máximo aunque la rama sea corta.
            Text(git.branch.count > 22 ? git.branch.prefix(21) + "…" : git.branch)
                .lineLimit(1)
            if git.hasChanges == true {
                if showsDiffStat, git.insertions + git.deletions > 0 {
                    Text("+\(git.insertions)").foregroundStyle(Color.green.opacity(0.85))
                    Text("−\(git.deletions)").foregroundStyle(AITheme.pink)
                } else {
                    Circle().fill(AITheme.pink).frame(width: 5, height: 5)
                }
            }
        }
        .help(help)
    }

    private var help: String {
        let head = git.isDetached ? "HEAD separado en \(git.branch)" : "Rama \(git.branch)"
        let changes = switch git.hasChanges {
        case true?: "Hay cambios sin commitear (+\(git.insertions) −\(git.deletions) líneas)"
        case false?: "Sin cambios pendientes"
        case nil: "Revisando cambios…"
        }
        return "\(head)\n\(changes)\nRepositorio: \((git.root.path as NSString).abbreviatingWithTildeInPath)"
    }
}

struct ErrorRow: View {
    let text: String

    var body: some View {
        HStack(alignment: .top, spacing: 6) {
            Image(systemName: "exclamationmark.triangle.fill")
            Text(text)
        }
        .font(.system(size: 12))
        .foregroundStyle(AITheme.pink)
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(AITheme.pink.opacity(0.12), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }
}
