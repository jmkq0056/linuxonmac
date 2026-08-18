// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "linuxonmac",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "linuxonmac",
            path: "Sources/linuxonmac",
            swiftSettings: [.swiftLanguageMode(.v5)]
        )
    ]
)
