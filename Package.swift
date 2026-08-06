// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "Riffle",
    platforms: [.macOS(.v13)],
    targets: [
        .target(name: "RiffleShims", path: "Sources/RiffleShims"),
        .executableTarget(name: "Riffle", dependencies: ["RiffleShims"],
                          path: "Sources/Riffle")
    ]
)
