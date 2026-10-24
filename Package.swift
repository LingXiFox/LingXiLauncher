// swift-tools-version: 6.0
// LingXi Launcher — macOS Apple Silicon native Minecraft: Java Edition launcher.
// Zero third-party dependencies: LauncherCore is the only place business logic lives.

import PackageDescription

let package = Package(
    name: "LingXiLauncher",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .library(name: "LauncherCore", targets: ["LauncherCore"]),
        .executable(name: "lingxi", targets: ["LingXiCLI"]),
    ],
    targets: [
        .target(
            name: "LauncherCore",
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .executableTarget(
            name: "LingXiCLI",
            dependencies: ["LauncherCore"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(
            name: "LauncherCoreTests",
            dependencies: ["LauncherCore"],
            resources: [.copy("Fixtures")],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
    ]
)
