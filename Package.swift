// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "WindowMover",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "WindowMover", targets: ["WindowMover"]),
    ],
    targets: [
        .executableTarget(name: "WindowMover"),
    ],
    swiftLanguageVersions: [.v5]
)
