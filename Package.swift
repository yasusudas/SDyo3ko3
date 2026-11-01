// swift-tools-version: 6.0
import PackageDescription
let package = Package(
    name: "yo3komi",
    platforms: [.macOS(.v14)],
    products: [.executable(name: "yo3komi", targets: ["Yo3komi"])],
    targets: [
        .executableTarget(name: "Yo3komi", linkerSettings: [.linkedLibrary("sqlite3")]),
        .testTarget(name: "Yo3komiTests", dependencies: ["Yo3komi"])
    ],
    swiftLanguageModes: [.v5]
)
