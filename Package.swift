// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "ClaudeFleetBar",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "ClaudeFleetBar",
            path: "Sources/ClaudeFleetBar",
            swiftSettings: [.swiftLanguageMode(.v6)],
            linkerSettings: [
                .linkedFramework("Security"),
                .linkedFramework("AppKit"),
                .linkedFramework("UserNotifications"),
            ]
        ),
        .testTarget(
            name: "ClaudeFleetBarTests",
            dependencies: ["ClaudeFleetBar"],
            path: "Tests/ClaudeFleetBarTests",
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
    ]
)
