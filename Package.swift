// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "NotchGlass",
    platforms: [
        .macOS("26.0")
    ],
    targets: [
        .executableTarget(
            name: "NotchGlass",
            path: "Sources/NotchGlass",
            resources: [
                .copy("Resources/ambience")
            ],
            swiftSettings: [
                .swiftLanguageMode(.v5)
            ]
        )
    ]
)
