// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "GlowKey",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .library(
            name: "GlowKeyCore",
            targets: ["GlowKeyCore"]
        ),
        .executable(
            name: "glowkey",
            targets: ["glowkey"]
        ),
        .executable(
            name: "glowkey-shade",
            targets: ["glowkey-shade"]
        ),
        .executable(
            name: "glowkey-hotkeys",
            targets: ["glowkey-hotkeys"]
        ),
        .executable(
            name: "glowkey-daemon",
            targets: ["glowkey-daemon"]
        ),
        .executable(
            name: "glowkey-menubar",
            targets: ["glowkey-menubar"]
        )
    ],
    targets: [
        .target(
            name: "CGlowKeyDDC",
            publicHeadersPath: "include"
        ),
        .target(
            name: "GlowKeyCore",
            dependencies: ["CGlowKeyDDC"]
        ),
        .executableTarget(
            name: "glowkey",
            dependencies: ["GlowKeyCore"]
        ),
        .executableTarget(
            name: "glowkey-shade",
            dependencies: ["GlowKeyCore"]
        ),
        .executableTarget(
            name: "glowkey-hotkeys",
            dependencies: ["GlowKeyCore"]
        ),
        .executableTarget(
            name: "glowkey-daemon",
            dependencies: ["GlowKeyCore"]
        ),
        .executableTarget(
            name: "glowkey-menubar",
            dependencies: ["GlowKeyCore"]
        )
    ]
)
