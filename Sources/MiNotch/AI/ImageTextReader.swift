import AppKit
import UniformTypeIdentifiers
import Vision

/// Extrae el texto de una imagen (una captura, una foto) con Vision, en la Mac.
/// DeepSeek no lee imágenes: le llega solo el texto.
enum ImageTextReader {
    enum Failure: LocalizedError {
        case unreadableImage
        case noText

        var errorDescription: String? {
            switch self {
            case .unreadableImage:
                "No se pudo abrir la imagen."
            case .noText:
                "No encontré texto en la imagen."
            }
        }
    }

    static func image(at url: URL) -> CGImage? {
        CGImageSourceCreateWithURL(url as CFURL, nil).flatMap { CGImageSourceCreateImageAtIndex($0, 0, nil) }
    }

    static func image(from data: Data) -> CGImage? {
        CGImageSourceCreateWithData(data as CFData, nil).flatMap { CGImageSourceCreateImageAtIndex($0, 0, nil) }
    }

    /// Imagen del portapapeles: un archivo de imagen copiado en Finder o una imagen copiada (⌃⇧⌘4).
    /// nil si lo copiado es texto, para que Cmd+V lo pegue como siempre.
    static func image(from pasteboard: NSPasteboard) -> CGImage? {
        let imageFiles: [NSPasteboard.ReadingOptionKey: Any] = [
            .urlReadingFileURLsOnly: true,
            .urlReadingContentsConformToTypes: [UTType.image.identifier],
        ]
        if let url = pasteboard.readObjects(forClasses: [NSURL.self], options: imageFiles)?.first as? URL {
            return image(at: url)
        }
        guard pasteboard.string(forType: .string) == nil,
              let data = pasteboard.data(forType: .png) ?? pasteboard.data(forType: .tiff) else { return nil }
        return image(from: data)
    }

    /// Fuera del hilo principal. La primera vez en el sistema Vision carga su modelo y puede tardar bastante.
    static func recognizeText(in image: CGImage) async throws -> String {
        let text = try await Task.detached(priority: .userInitiated) {
            let request = VNRecognizeTextRequest()
            request.recognitionLevel = .accurate
            request.usesLanguageCorrection = true
            request.automaticallyDetectsLanguage = true
            try VNImageRequestHandler(cgImage: image).perform([request])

            return (request.results ?? [])
                .compactMap { $0.topCandidates(1).first?.string }
                .joined(separator: "\n")
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }.value
        guard !text.isEmpty else { throw Failure.noText }
        return text
    }
}
