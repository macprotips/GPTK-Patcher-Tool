// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "GPTKPatcher",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "GPTKPatcher",
            path: "Sources/GPTKPatcher"
        )
    ]
)
