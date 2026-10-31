// swift-tools-version: 6.0
// LingXi Launcher — native Minecraft: Java Edition launcher.
// Platform-specific code lives only in MacPlatform/WindowsPlatform; LauncherCore is portable.

import PackageDescription

var cliDependencies: [Target.Dependency] = ["LauncherCore"]
var platformTargets: [Target] = []
var testDependencies: [Target.Dependency] = ["LauncherCore"]

#if os(macOS)
cliDependencies.append("MacPlatform")
testDependencies.append("MacPlatform")
platformTargets = [
    .target(
        name: "MacPlatform",
        dependencies: ["LauncherCore"],
        path: "Sources/MacPlatform",
        swiftSettings: [.swiftLanguageMode(.v6)]
    ),
    .executableTarget(
        name: "LingXiMac",
        dependencies: ["LauncherCore", "MacPlatform"],
        path: "Apps/LingXiMac/Sources",
        swiftSettings: [.swiftLanguageMode(.v6)]
    ),
]
#elseif os(Windows)
cliDependencies.append("WindowsPlatform")
testDependencies.append("WindowsPlatform")
platformTargets = [
    .target(
        name: "WindowsPlatform",
        dependencies: ["LauncherCore"],
        path: "Sources/WindowsPlatform",
        swiftSettings: [.swiftLanguageMode(.v6)]
    ),
    .executableTarget(
        name: "LingXiCLIWindows",
        dependencies: cliDependencies,
        path: "Sources/LingXiCLI",
        swiftSettings: [.swiftLanguageMode(.v6)]
    ),
]
#endif

var packageTargets: [Target] = [
    .target(
        name: "LauncherCore",
        dependencies: [.product(name: "Crypto", package: "swift-crypto")],
        swiftSettings: [.swiftLanguageMode(.v6)]
    ),
    .executableTarget(
        name: "LingXiCLI",
        dependencies: cliDependencies,
        swiftSettings: [.swiftLanguageMode(.v6)]
    ),
    .testTarget(
        name: "PlatformCompatibilityTests",
        dependencies: testDependencies,
        swiftSettings: [.swiftLanguageMode(.v6)]
    ),
]
#if os(macOS)
packageTargets.append(.testTarget(
    name: "LauncherCoreTests",
    dependencies: testDependencies,
    resources: [.copy("Fixtures")],
    swiftSettings: [.swiftLanguageMode(.v6)]
))
#endif
packageTargets.append(contentsOf: platformTargets)

#if os(Windows)
let cliProduct = Product.executable(name: "lingxi", targets: ["LingXiCLIWindows"])
#else
let cliProduct = Product.executable(name: "lingxi", targets: ["LingXiCLI"])
#endif

let package = Package(
    name: "LingXiLauncher",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .library(name: "LauncherCore", targets: ["LauncherCore"]),
        cliProduct,
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-crypto.git", from: "3.15.1"),
    ],
    targets: packageTargets
)
