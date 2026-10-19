// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "MiNotch",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "MiNotch",
            path: "Sources/MiNotch"
        )
    ]
)
