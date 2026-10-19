// Genera el ícono de la app (.icns) a partir del logo: lo recorta con la forma redondeada de macOS
// (esquinas transparentes) y deja el margen estándar, en todos los tamaños que pide iconutil.
// Uso: swift scripts/make-icon.swift <logo.png> <salida.icns>
import AppKit

let args = CommandLine.arguments
guard args.count == 3, let logo = NSImage(contentsOfFile: args[1]),
      let source = logo.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
    print("Uso: swift scripts/make-icon.swift <logo.png> <salida.icns>")
    exit(1)
}

/// Grilla de íconos de macOS: el recuadro ocupa 824 de 1024, con esquinas de ~22 %.
func render(size: Int) -> Data {
    let canvas = CGFloat(size)
    let tile = canvas * 824 / 1024
    let rect = CGRect(x: (canvas - tile) / 2, y: (canvas - tile) / 2, width: tile, height: tile)
    let context = CGContext(
        data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
        space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    )!
    context.interpolationQuality = .high
    let radius = tile * 0.2237
    context.addPath(CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil))
    context.clip()
    context.draw(source, in: rect)
    let rep = NSBitmapImageRep(cgImage: context.makeImage()!)
    return rep.representation(using: .png, properties: [:])!
}

let iconset = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("MiNotch-\(UUID().uuidString).iconset")
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)
for points in [16, 32, 128, 256, 512] {
    try render(size: points).write(to: iconset.appendingPathComponent("icon_\(points)x\(points).png"))
    try render(size: points * 2).write(to: iconset.appendingPathComponent("icon_\(points)x\(points)@2x.png"))
}

let iconutil = Process()
iconutil.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
iconutil.arguments = ["-c", "icns", iconset.path, "-o", args[2]]
try iconutil.run()
iconutil.waitUntilExit()
try? FileManager.default.removeItem(at: iconset)
exit(iconutil.terminationStatus)
