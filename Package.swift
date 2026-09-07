// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "NotchGlass",
    platforms: [
        .macOS("26.0")
    ],
    targets: [
        // Tiny Objective-C helper so Swift can catch Objective-C exceptions (which
        // AVAudioEngine / Contacts raise on some failure states, and which Swift's
        // do/catch cannot handle).
        .target(
            name: "ObjCSupport",
            path: "Sources/ObjCSupport"
        ),
        .executableTarget(
            name: "NotchGlass",
            dependencies: ["ObjCSupport"],
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
