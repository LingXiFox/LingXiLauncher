import XCTest
@testable import LauncherCore

/// M2.5 — JVM/native architecture selection and Mach-O verification.
final class JVMArchitectureTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = try FixtureLoader.temporaryDirectory("lingxi-jvm-arch")
    }

    override func tearDownWithError() throws {
        if let root { try? FileManager.default.removeItem(at: root) }
    }

    private func runtime(architecture: PlatformContext.CPUArch) -> JavaRuntime {
        JavaRuntime(
            executable: URL(fileURLWithPath: "/fake/java"),
            versionString: "17.0.1",
            majorVersion: 17,
            architecture: architecture,
            vendor: "Test",
            hostArchitecture: .arm64
        )
    }

    func testForJVMUsesRuntimeArchitectureAndDetectsRosetta() throws {
        let x86 = try PlatformContext.forJVM(runtime(architecture: .x86_64))
        XCTAssertEqual(x86.architecture, .x86_64)
        XCTAssertEqual(x86.hostArchitecture, .arm64)
        XCTAssertTrue(x86.isTranslated)

        let arm = try PlatformContext.forJVM(runtime(architecture: .arm64))
        XCTAssertEqual(arm.architecture, .arm64)
        XCTAssertEqual(arm.hostArchitecture, .arm64)
        XCTAssertFalse(arm.isTranslated)
    }

    func testRosettaDetectionHelper() {
        XCTAssertTrue(JavaRuntimeInspector.detectRosetta(javaArchitecture: .x86_64, hardwareArchitecture: .arm64))
        XCTAssertFalse(JavaRuntimeInspector.detectRosetta(javaArchitecture: .arm64, hardwareArchitecture: .arm64))
        XCTAssertFalse(JavaRuntimeInspector.detectRosetta(javaArchitecture: .x86_64, hardwareArchitecture: .x86_64))
    }

    func testLegacyNativesAreResolvedPerJVMArchitecture() throws {
        let gameRoot = root.appendingPathComponent("mc", isDirectory: true)
        let versionDirectory = gameRoot.appendingPathComponent("versions/1.16.5", isDirectory: true)
        try FileManager.default.createDirectory(at: versionDirectory, withIntermediateDirectories: true)
        try FileManager.default.copyItem(
            at: try FixtureLoader.url("versions/1.16.5.json"),
            to: versionDirectory.appendingPathComponent("1.16.5.json")
        )
        let layout = GameDataLayout(gameRoot: gameRoot, dataRoot: root.appendingPathComponent("data", isDirectory: true))
        let version = try VersionResolver().resolve(versionID: "1.16.5", from: gameRoot)
        let resolver = DependencyResolver(ruleEvaluator: RuleEvaluator())

        let armPlatform = PlatformContext(os: .macOS, architecture: .arm64, osVersion: "14.4.1", hostArchitecture: .arm64)
        let x86Platform = PlatformContext(os: .macOS, architecture: .x86_64, osVersion: "14.4.1", hostArchitecture: .arm64)

        let armDeps = try resolver.resolve(version: version, layout: layout, platform: armPlatform)
        let x86Deps = try resolver.resolve(version: version, layout: layout, platform: x86Platform)

        XCTAssertEqual(armDeps.nativesDirectory.lastPathComponent, "arm64")
        XCTAssertEqual(x86Deps.nativesDirectory.lastPathComponent, "x86_64")
        XCTAssertNotEqual(armDeps.nativesDirectory, x86Deps.nativesDirectory)
        XCTAssertEqual(armDeps.legacyNatives.count, 8)
        XCTAssertEqual(x86Deps.legacyNatives.count, 8)

        // Plain `natives-macos` cannot be classified statically: warn on arm64, stay quiet for a
        // matching x86_64 JVM.
        XCTAssertTrue(armDeps.diagnostics.contains { $0.severity == .warning && $0.code == .javaArchitectureMismatch })
        XCTAssertFalse(x86Deps.diagnostics.contains { $0.severity == .warning && $0.code == .javaArchitectureMismatch })
    }

    func testBuilderUsesContextPlatformForArgumentRules() throws {
        let platformArm = PlatformContext(os: .macOS, architecture: .arm64, osVersion: "14.4.1")
        let platformX86 = PlatformContext(os: .macOS, architecture: .x86_64, osVersion: "14.4.1", hostArchitecture: .arm64)
        let version = ResolvedVersion(
            id: "synthetic",
            type: "release",
            mainClass: "net.minecraft.client.main.Main",
            assetIndexID: "1",
            javaRequirement: JavaVersionRequirement(majorVersion: 17),
            libraries: [],
            jvmArguments: [.argument("-cp"), .argument("${classpath}")],
            gameArguments: [
                .argument("--fixed"),
                .conditional(
                    rules: [Rule(action: .allow, os: RuleOS(arch: "x86_64"))],
                    values: ["--x86-only"]
                )
            ],
            defaultUserJVMArguments: [],
            assetIndex: nil,
            clientLogging: nil,
            clientJar: nil,
            inheritsFrom: nil,
            versionDirectory: root,
            metadataURL: root.appendingPathComponent("version.json"),
            releaseTime: nil
        )
        let dependencies = makeDependencies()
        let builder = LaunchPlanBuilder(argumentResolver: ArgumentResolver(ruleEvaluator: RuleEvaluator()))
        let profile = try LocalOfflineIdentity.makeProfile(playerName: "ArchUser")

        let armContext = LaunchContext(
            instanceDirectory: root.appendingPathComponent("instance"),
            gameDirectory: root.appendingPathComponent("instance/.minecraft"),
            javaExecutable: URL(fileURLWithPath: "/fake/java"),
            platform: platformArm,
            identity: .localOffline(profile)
        )
        let x86Context = LaunchContext(
            instanceDirectory: root.appendingPathComponent("instance"),
            gameDirectory: root.appendingPathComponent("instance/.minecraft"),
            javaExecutable: URL(fileURLWithPath: "/fake/java"),
            platform: platformX86,
            identity: .localOffline(profile)
        )
        let armPlan = try builder.build(version: version, context: armContext, dependencies: dependencies)
        let x86Plan = try builder.build(version: version, context: x86Context, dependencies: dependencies)
        XCTAssertFalse(armPlan.arguments.contains("--x86-only"))
        XCTAssertTrue(x86Plan.arguments.contains("--x86-only"))
    }

    func testValidateRejectsNativeArchitectureMismatches() throws {
        let builder = LaunchPlanBuilder(argumentResolver: ArgumentResolver(ruleEvaluator: RuleEvaluator()))
        let profile = try LocalOfflineIdentity.makeProfile(playerName: "ArchUser")
        let version = makeVersion()
        let gameDirectory = root.appendingPathComponent("instance/.minecraft")
        try FileManager.default.createDirectory(at: gameDirectory, withIntermediateDirectories: true)

        func context(javaArch: PlatformContext.CPUArch) -> LaunchContext {
            LaunchContext(
                instanceDirectory: root.appendingPathComponent("instance"),
                gameDirectory: gameDirectory,
                javaExecutable: URL(fileURLWithPath: "/fake/java"),
                platform: PlatformContext(os: .macOS, architecture: javaArch, osVersion: "14.4.1", hostArchitecture: .arm64),
                identity: .localOffline(profile)
            )
        }
        func runtime(_ arch: PlatformContext.CPUArch) -> JavaRuntime {
            JavaRuntime(
                executable: URL(fileURLWithPath: "/fake/java"),
                versionString: "17.0.1",
                majorVersion: 17,
                architecture: arch,
                hostArchitecture: .arm64
            )
        }

        let x86Native = ResolvedNative(
            classifier: "natives-macos",
            file: ResolvedFile(path: root.appendingPathComponent("native-x86.jar")),
            architectureHint: .x86_64
        )
        let armNative = ResolvedNative(
            classifier: "natives-macos-arm64",
            file: ResolvedFile(path: root.appendingPathComponent("native-arm.jar")),
            architectureHint: .arm64
        )

        let armContext = context(javaArch: .arm64)
        let armPlan = try builder.build(version: version, context: armContext, dependencies: makeDependencies(natives: [x86Native]))
        let diagnosticsArm = builder.validate(
            version: version, context: armContext, plan: armPlan,
            dependencies: makeDependencies(natives: [x86Native]), java: runtime(.arm64)
        )
        XCTAssertTrue(diagnosticsArm.contains {
            $0.severity == .error && $0.code == .javaArchitectureMismatch && $0.message.contains("x86_64")
        })

        let x86Context = context(javaArch: .x86_64)
        let x86Plan = try builder.build(version: version, context: x86Context, dependencies: makeDependencies(natives: [armNative]))
        let diagnosticsX86 = builder.validate(
            version: version, context: x86Context, plan: x86Plan,
            dependencies: makeDependencies(natives: [armNative]), java: runtime(.x86_64)
        )
        XCTAssertTrue(diagnosticsX86.contains {
            $0.severity == .error && $0.code == .javaArchitectureMismatch && $0.message.contains("arm64")
        })

        // Matching combinations and Rosetta get no arch error, only a Rosetta warning.
        let matching = builder.validate(
            version: version, context: x86Context, plan: x86Plan,
            dependencies: makeDependencies(natives: [x86Native]), java: runtime(.x86_64)
        )
        XCTAssertFalse(matching.contains { $0.severity == .error && $0.code == .javaArchitectureMismatch })
        XCTAssertTrue(matching.contains { $0.severity == .warning && $0.message.contains("Rosetta") })

        // A missing native archive is a blocking missingDependency.
        let missing = MissingDependency(
            kind: .native,
            path: root.appendingPathComponent("missing-native.jar"),
            reason: .absent
        )
        let missingPlan = try builder.build(version: version, context: x86Context, dependencies: makeDependencies(missing: [missing]))
        let missingDiagnostics = builder.validate(
            version: version, context: x86Context, plan: missingPlan,
            dependencies: makeDependencies(missing: [missing]), java: runtime(.x86_64)
        )
        XCTAssertTrue(missingDiagnostics.contains { $0.severity == .error && $0.code == .missingDependency })
    }

    func testMachOHeaderParsing() {
        let arm64 = Data([0xCF, 0xFA, 0xED, 0xFE, 0x0C, 0x00, 0x00, 0x01] + Array(repeating: 0, count: 56))
        XCTAssertEqual(MachOInspector.architectures(in: arm64), [.arm64])
        let x86 = Data([0xCF, 0xFA, 0xED, 0xFE, 0x07, 0x00, 0x00, 0x01] + Array(repeating: 0, count: 56))
        XCTAssertEqual(MachOInspector.architectures(in: x86), [.x86_64])
        let text = Data("not a mach-o binary".utf8)
        XCTAssertTrue(MachOInspector.architectures(in: text).isEmpty)
    }

    func testNativeArchiveInspectionAndCompatibility() throws {
        func inspect(_ name: String) throws -> Set<PlatformContext.CPUArch> {
            try NativeArchiveInspector.architectures(ofArchive: try FixtureLoader.url("zip/\(name).zip"))
        }
        XCTAssertEqual(try inspect("native_macho_arm64"), [.arm64])
        XCTAssertEqual(try inspect("native_macho_x86_64"), [.x86_64])
        XCTAssertEqual(try inspect("native_macho_fat"), [.arm64, .x86_64])
        XCTAssertEqual(try inspect("native_macho_mixed"), [.arm64, .x86_64])
        XCTAssertTrue(try inspect("native_macho_text").isEmpty)

        let archive = try FixtureLoader.url("zip/native_macho_x86_64.zip")
        let native = ResolvedNative(classifier: "natives-macos", file: ResolvedFile(path: archive))
        let armDiagnostics = NativeCompatibility.diagnostics(for: [native], jvmArchitecture: .arm64)
        XCTAssertEqual(armDiagnostics.count, 1)
        XCTAssertEqual(armDiagnostics.first?.code, .javaArchitectureMismatch)
        XCTAssertTrue(armDiagnostics.first?.message.contains("x86_64") ?? false)
        XCTAssertTrue(NativeCompatibility.diagnostics(for: [native], jvmArchitecture: .x86_64).isEmpty)
    }

    // MARK: - Fixtures

    private func makeVersion() -> ResolvedVersion {
        ResolvedVersion(
            id: "synthetic",
            type: "release",
            mainClass: "net.minecraft.client.main.Main",
            assetIndexID: "1",
            javaRequirement: JavaVersionRequirement(majorVersion: 17),
            libraries: [],
            jvmArguments: [.argument("-cp"), .argument("${classpath}")],
            gameArguments: [.argument("--username"), .argument("${auth_player_name}")],
            defaultUserJVMArguments: [],
            assetIndex: nil,
            clientLogging: nil,
            clientJar: nil,
            inheritsFrom: nil,
            versionDirectory: root,
            metadataURL: root.appendingPathComponent("version.json"),
            releaseTime: nil
        )
    }

    private func makeDependencies(
        natives: [ResolvedNative] = [],
        missing: [MissingDependency] = []
    ) -> DependencyResolution {
        let library = root.appendingPathComponent("libraries/example.jar")
        return DependencyResolution(
            layout: GameDataLayout(gameRoot: root.appendingPathComponent("mc"), dataRoot: root.appendingPathComponent("data")),
            classpath: [library],
            classpathFiles: [ResolvedFile(path: library, sha1: nil, size: nil)],
            legacyNatives: natives,
            nativesDirectory: root.appendingPathComponent("natives/arm64"),
            clientJar: nil,
            assetIndexFile: nil,
            loggingFile: nil,
            missing: missing,
            diagnostics: []
        )
    }
}
