import AppKit
import Vision

/// "Preguntar sobre la pantalla": el usuario elige una zona y Vision extrae su texto en la Mac.
/// La imagen nunca sale de la computadora; a DeepSeek solo llega el texto.
enum ScreenTextCapture {
    enum Failure: LocalizedError {
        case permissionDenied
        case unreadableImage
        case noText

        var errorDescription: String? {
            switch self {
            case .permissionDenied:
                "MiNotch necesita permiso de Grabación de pantalla: activalo en Ajustes del Sistema → Privacidad y seguridad y volvé a abrir la app."
            case .unreadableImage:
                "No se pudo leer la captura de pantalla."
            case .noText:
                "No encontré texto en esa zona."
            }
        }
    }

    /// Texto de la zona elegida, o nil si el usuario canceló con Esc.
    static func captureText() async throws -> String? {
        guard CGPreflightScreenCaptureAccess() else {
            // La primera vez macOS muestra el aviso y agrega MiNotch a la lista de Ajustes.
            CGRequestScreenCaptureAccess()
            throw Failure.permissionDenied
        }

        let url = FileManager.default.temporaryDirectory.appendingPathComponent("minotch-\(UUID().uuidString).png")
        defer { try? FileManager.default.removeItem(at: url) }

        try await selectRegion(savingTo: url)
        // Con Esc, screencapture termina sin crear el archivo.
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }

        let text = try await Task.detached(priority: .userInitiated) { try recognizeText(at: url) }.value
        guard !text.isEmpty else { throw Failure.noText }
        return text
    }

    /// Selector nativo de macOS: cruz para elegir una zona, Espacio para una ventana, Esc para cancelar.
    private static func selectRegion(savingTo url: URL) async throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
        // -i interactivo, -x sin sonido, -o sin la sombra de la ventana.
        process.arguments = ["-i", "-x", "-o", url.path]
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            process.terminationHandler = { _ in continuation.resume() }
            do {
                try process.run()
            } catch {
                continuation.resume(throwing: error)
            }
        }
    }

    private static func recognizeText(at url: URL) throws -> String {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { throw Failure.unreadableImage }

        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true
        request.automaticallyDetectsLanguage = true
        try VNImageRequestHandler(cgImage: image).perform([request])

        return (request.results ?? [])
            .compactMap { $0.topCandidates(1).first?.string }
            .joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
