// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "Tack",
    platforms: [.macOS("26.0")],
    targets: [
        .executableTarget(
            name: "Tack",
            path: "Sources/Tack",
            swiftSettings: [.swiftLanguageMode(.v5)]
        )
    ]
)
