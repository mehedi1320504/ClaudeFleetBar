// swift-tools-version: 6.0
import PackageDescription

// Sparkle is pulled in as a binary target rather than as a package dependency.
// Its Package.swift is itself only a one-line binaryTarget pointing at this
// same zip, but resolving it makes SwiftPM mirror-clone the whole Sparkle
// repository — measured here at ~300 KB/min against a 3 MB/s link, because the
// cost is the repository's history, not the framework. Naming the artifact
// directly fetches 11 MB in under four seconds and pins it by checksum.
let sparkleVersion = "2.9.6"
let sparkleChecksum = "8d5fb41d960b43f4a68aa14126bf62b098544ec8d191cdcc73eb14e63a8e7606"

let package = Package(
    name: "ClaudeFleetBar",
    platforms: [.macOS(.v14)],
    targets: [
        .binaryTarget(
            name: "Sparkle",
            url: "https://github.com/sparkle-project/Sparkle/releases/download/\(sparkleVersion)/Sparkle-for-Swift-Package-Manager.zip",
            checksum: sparkleChecksum
        ),
        .executableTarget(
            name: "ClaudeFleetBar",
            dependencies: ["Sparkle"],
            path: "Sources/ClaudeFleetBar",
            swiftSettings: [.swiftLanguageMode(.v6)],
            linkerSettings: [
                .linkedFramework("Security"),
                .linkedFramework("AppKit"),
                .linkedFramework("UserNotifications"),
                // Sparkle.framework is embedded in Contents/Frameworks by
                // scripts/build-app.sh; the executable has to be told to look
                // for it there.
                .unsafeFlags(["-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Frameworks"]),
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
