// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "Clipmacxxer",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "Clipmacxxer",
            path: "Sources/Clipmacxxer"
        )
    ]
)
