// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "MiNotch",
    platforms: [.macOS(.v14)],
    dependencies: [
        // Emulador de terminal (xterm) para el modo Terminal. 1.11.2: la última sin shaders de Metal,
        // que las Command Line Tools no pueden compilar (hace falta Xcode).
        .package(url: "https://github.com/migueldeicaza/SwiftTerm.git", exact: "1.11.2"),
    ],
    targets: [
        .executableTarget(
            name: "MiNotch",
            dependencies: [.product(name: "SwiftTerm", package: "SwiftTerm")],
            path: "Sources/MiNotch"
        )
    ]
)
