import Foundation
import XCTest
@testable import LauncherCore

final class DependencyResolverTests: XCTestCase {
    private let evaluator = RuleEvaluator()

    // MARK: - Test environment

    private struct Environment {
        let root: URL
        let layout: GameDataLayout
    }

    private func makeEnvironment(gameRootName: String = "game") throws -> Environment {
        let root = try FixtureLoader.temporaryDirectory("lingxi-deps")
        let gameRoot = root.appendingPathComponent(gameRootName, isDirectory: true)
        try FileManager.default.createDirectory(at: gameRoot, withIntermediateDirectories: true)
        return Environment(
            root: root,
            layout: GameDataLayout(gameRoot: gameRoot, dataRoot: root.appendingPathComponent("data", isDirectory: true))
        )
    }

    private func cleanup(_ environment: Environment) {
        try? FileManager.default.removeItem(at: environment.root)
    }

    private func mac(
        architecture: PlatformContext.CPUArch = .arm64,
        osVersion: String = "14.4.1"
    ) -> PlatformContext {
        PlatformContext(os: .macOS, architecture: architecture, osVersion: osVersion)
    }

    private func linux() -> PlatformContext {
        PlatformContext(os: .linux, architecture: .x86_64, osVersion: "6.8.0")
    }

    private func write(bytes: Int, to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(repeating: 0x4A, count: bytes).write(to: url)
    }

    // MARK: - Builders

    private func makeVersion(
        id: String = "test-version",
        libraries: [Library] = [],
        clientJar: Artifact? = Artifact(
            urlString: "https://example.invalid/versions/test-version/client.jar",
            sha1: "client-jar-sha1",
            size: 16
        ),
        assetIndex: AssetIndex? = AssetIndex(
            id: "5",
            sha1: "asset-index-sha1",
            size: 24,
            urlString: "https://example.invalid/indexes/5.json"
        ),
        assetIndexID: String = "5",
        clientLogging: ClientLogging? = ClientLogging(
            argument: "-Dlog4j.configurationFile=${path}",
            file: Artifact(
                urlString: "https://example.invalid/log_configs/client-1.20.xml",
                sha1: "log-config-sha1",
                size: 12,
                id: "client-1.20.xml"
            ),
            type: "log4j2-xml"
        )
    ) -> ResolvedVersion {
        ResolvedVersion(
            id: id,
            type: "release",
            mainClass: "net.minecraft.client.main.Main",
            assetIndexID: assetIndexID,
            javaRequirement: JavaVersionRequirement(majorVersion: 21),
            libraries: libraries,
            jvmArguments: [],
            gameArguments: [],
            defaultUserJVMArguments: [],
            assetIndex: assetIndex,
            clientLogging: clientLogging,
            clientJar: clientJar,
            inheritsFrom: nil,
            versionDirectory: URL(fileURLWithPath: "/tmp/\(id)", isDirectory: true),
            metadataURL: URL(fileURLWithPath: "/tmp/\(id)/\(id).json"),
            releaseTime: nil
        )
    }

    private func library(
        _ name: String,
        path: String? = nil,
        url: String? = "https://example.invalid/libraries/lib.jar",
        sha1: String? = nil,
        size: Int? = nil,
        rules: [Rule]? = nil,
        classifiers: [String: Artifact]? = nil,
        natives: [String: String]? = nil,
        extractExclude: [String]? = nil
    ) -> Library {
        Library(
            name: name,
            rules: rules,
            artifact: Artifact(urlString: url, path: path, sha1: sha1, size: size),
            classifiers: classifiers,
            natives: natives,
            extractExclude: extractExclude
        )
    }

    private func artifact(
        path: String? = nil,
        url: String? = "https://example.invalid/native.jar",
        sha1: String? = nil,
        size: Int? = nil
    ) -> Artifact {
        Artifact(urlString: url, path: path, sha1: sha1, size: size)
    }

    private func resolution(
        of version: ResolvedVersion,
        in environment: Environment,
        platform: PlatformContext
    ) throws -> DependencyResolution {
        try DependencyResolver(ruleEvaluator: evaluator).resolve(
            version: version,
            layout: environment.layout,
            platform: platform
        )
    }

    private func libraryPath(_ relativePath: String, in environment: Environment) throws -> String {
        try environment.layout.libraryURL(relativePath: relativePath).path
    }


    private func resolveFixture(_ versionID: String, in environment: Environment) throws -> ResolvedVersion {
        let directory = environment.layout.gameRoot
            .appendingPathComponent("versions/\(versionID)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try FileManager.default.copyItem(
            at: try FixtureLoader.url("versions/\(versionID).json"),
            to: directory.appendingPathComponent("\(versionID).json")
        )
        return try VersionResolver().resolve(versionID: versionID, from: environment.layout.gameRoot)
    }

    // MARK: - Classpath composition

    func testClasspathKeepsMetadataOrderAndAppendsClientJarLast() throws {
        let environment = try makeEnvironment()
        defer { cleanup(environment) }

        let version = makeVersion(libraries: [
            library("com.example:linux:1.0", rules: [Rule(action: .allow, os: RuleOS(name: "linux"))]),
            library("com.example:all:1.0"),
            library("com.example:osx:1.0", rules: [Rule(action: .allow, os: RuleOS(name: "osx"))]),
            library("com.example:windows:1.0", rules: [Rule(action: .allow, os: RuleOS(name: "windows"))]),
            library("com.example:no-rules:1.0", rules: []),
        ])

        let result = try resolution(of: version, in: environment, platform: mac())

        let expected = [
            try libraryPath("com/example/all/1.0/all-1.0.jar", in: environment),
            try libraryPath("com/example/osx/1.0/osx-1.0.jar", in: environment),
            try libraryPath("com/example/no-rules/1.0/no-rules-1.0.jar", in: environment),
            try environment.layout.clientJarURL(version.id).path,
        ]
        XCTAssertEqual(result.classpath.map(\.path), expected)
        XCTAssertEqual(result.classpathFiles.map { $0.path.path }, expected)
        XCTAssertEqual(result.classpath.count, result.classpathFiles.count)
        XCTAssertEqual(result.legacyNatives.count, 0)
        XCTAssertEqual(
            result.nativesDirectory,
            try environment.layout.nativesDirectory(versionID: version.id, architecture: .arm64)
        )

        // Disallowed libraries are absent from both the classpath and the missing list.
        let missingLibraryPaths = result.missing.filter { $0.kind == .library }.map { $0.path.path }
        XCTAssertEqual(missingLibraryPaths, Array(expected.dropLast()))
        XCTAssertFalse(missingLibraryPaths.contains { $0.contains("linux") || $0.contains("windows") })
        XCTAssertTrue(result.diagnostics.isEmpty, "\(result.diagnostics)")
    }

    func testClasspathDeduplicatesByStandardizedPath() throws {
        let environment = try makeEnvironment()
        defer { cleanup(environment) }

        // 1.16-style metadata repeats an artifact: once as the library, once with `natives`.
        // The trailing-space copy also proves standardisation (PathSafety trims) is applied.
        let duplicatePath = "com/example/dup/1.0/dup-1.0.jar"
        let version = makeVersion(libraries: [
            library("com.example:dup:1.0", path: duplicatePath, sha1: "dup-sha1", size: 9),
            library("com.example:dup:1.0", path: duplicatePath, sha1: "dup-sha1", size: 9),
            library("com.example:dup:1.0", path: duplicatePath + "   ", sha1: "dup-sha1", size: 9),
        ])

        let result = try resolution(of: version, in: environment, platform: mac())

        XCTAssertEqual(result.classpath.count, 2)
        XCTAssertEqual(result.classpathFiles.count, 2)
        XCTAssertEqual(result.classpath.first?.path, try libraryPath(duplicatePath, in: environment))
        XCTAssertEqual(result.classpath.last?.path, try environment.layout.clientJarURL(version.id).path)
        XCTAssertEqual(result.missing.filter { $0.kind == .library }.count, 1)
        XCTAssertTrue(result.diagnostics.isEmpty, "\(result.diagnostics)")
    }

    func testMavenFallbackPathAndMetadataPropagation() throws {
        let environment = try makeEnvironment()
        defer { cleanup(environment) }

        let version = makeVersion(libraries: [
            Library(
                name: "com.example:demo:1.0",
                artifact: Artifact(
                    urlString: "https://example.invalid/demo-1.0.jar",
                    path: nil,
                    sha1: "demo-sha1",
                    size: 7
                )
            ),
        ])

        let result = try resolution(of: version, in: environment, platform: mac())
        let resolved = try XCTUnwrap(result.classpathFiles.first)

        XCTAssertEqual(resolved.path.path, try libraryPath("com/example/demo/1.0/demo-1.0.jar", in: environment))
        XCTAssertEqual(resolved.sha1, "demo-sha1")
        XCTAssertEqual(resolved.size, 7)
        XCTAssertEqual(resolved.downloadURL?.absoluteString, "https://example.invalid/demo-1.0.jar")
        XCTAssertEqual(result.classpath.first?.path, resolved.path.path)
    }

    func testPresentRequiredFilesAreNotReportedMissing() throws {
        let environment = try makeEnvironment()
        defer { cleanup(environment) }

        let relativePath = "com/example/present/1.0/present-1.0.jar"
        let version = makeVersion(libraries: [
            library("com.example:present:1.0", path: relativePath, sha1: "lib-sha1", size: 3),
        ])
        try write(bytes: 3, to: try environment.layout.libraryURL(relativePath: relativePath))
        try write(bytes: 16, to: try environment.layout.clientJarURL(version.id))
        try write(bytes: 24, to: try environment.layout.assetIndexURL(id: "5"))
        try write(bytes: 12, to: try environment.layout.loggingConfigURL(id: "client-1.20.xml"))

        let result = try resolution(of: version, in: environment, platform: mac())

        XCTAssertTrue(result.missing.isEmpty)
        XCTAssertTrue(result.diagnostics.isEmpty, "\(result.diagnostics)")
        XCTAssertEqual(result.clientJar?.path, try environment.layout.clientJarURL(version.id))
        XCTAssertEqual(result.clientJar?.sha1, "client-jar-sha1")
        XCTAssertEqual(result.assetIndexFile?.path, try environment.layout.assetIndexURL(id: "5"))
        XCTAssertEqual(result.assetIndexFile?.sha1, "asset-index-sha1")
        XCTAssertEqual(result.loggingFile?.path, try environment.layout.loggingConfigURL(id: "client-1.20.xml"))
        XCTAssertEqual(result.loggingFile?.sha1, "log-config-sha1")
    }

    // MARK: - Missing dependencies

    func testMissingFilesAreRecordedWithDownloadMetadata() throws {
        let environment = try makeEnvironment()
        defer { cleanup(environment) }

        let relativePath = "com/example/missing/1.0/missing-1.0.jar"
        let version = makeVersion(libraries: [
            library("com.example:missing:1.0", path: relativePath, sha1: "lib-sha1", size: 5),
        ])

        let result = try resolution(of: version, in: environment, platform: mac())

        XCTAssertEqual(result.missing.map(\.kind), [.library, .clientJar, .assetIndex, .loggingConfig])
        XCTAssertEqual(result.missing.map(\.reason), [.absent, .absent, .absent, .absent])

        let libraryEntry = result.missing[0]
        XCTAssertEqual(libraryEntry.path.path, try libraryPath(relativePath, in: environment))
        XCTAssertEqual(libraryEntry.sha1, "lib-sha1")
        XCTAssertEqual(libraryEntry.size, 5)
        XCTAssertEqual(libraryEntry.downloadURL?.absoluteString, "https://example.invalid/libraries/lib.jar")

        XCTAssertEqual(result.missing[1].sha1, "client-jar-sha1")
        XCTAssertEqual(result.missing[1].size, 16)
        XCTAssertEqual(result.missing[2].sha1, "asset-index-sha1")
        XCTAssertEqual(result.missing[2].size, 24)
        XCTAssertEqual(result.missing[3].sha1, "log-config-sha1")
        XCTAssertEqual(result.missing[3].size, 12)

        // All missing entries carry a usable download URL, so nothing is blocking yet.
        XCTAssertTrue(result.diagnostics.isEmpty, "\(result.diagnostics)")
    }

    func testEmptyFileAndSizeMismatchAreReported() throws {
        let environment = try makeEnvironment()
        defer { cleanup(environment) }

        let version = makeVersion()
        try write(bytes: 0, to: try environment.layout.clientJarURL(version.id))
        try write(bytes: 10, to: try environment.layout.assetIndexURL(id: "5"))
        try write(bytes: 12, to: try environment.layout.loggingConfigURL(id: "client-1.20.xml"))

        let result = try resolution(of: version, in: environment, platform: mac())

        XCTAssertEqual(result.missing.map(\.kind), [.clientJar, .assetIndex])
        XCTAssertEqual(result.missing.map(\.reason), [.emptyFile, .sizeMismatch])
    }

    func testAbsentFileWithoutDownloadURLIsOnlyReportedAsMissingDependency() throws {
        let environment = try makeEnvironment()
        defer { cleanup(environment) }

        let relativePath = "com/example/nourl/1.0/nourl-1.0.jar"
        let version = makeVersion(libraries: [
            Library(name: "com.example:nourl:1.0", artifact: Artifact(path: relativePath)),
        ])
        try write(bytes: 16, to: try environment.layout.clientJarURL(version.id))
        try write(bytes: 24, to: try environment.layout.assetIndexURL(id: "5"))
        try write(bytes: 12, to: try environment.layout.loggingConfigURL(id: "client-1.20.xml"))

        let result = try resolution(of: version, in: environment, platform: mac())

        // Missing files never produce a duplicate diagnostic: LaunchPlanBuilder.validate() turns
        // every MissingDependency into the blocking message.
        XCTAssertTrue(result.diagnostics.isEmpty, "\(result.diagnostics)")
        XCTAssertEqual(result.missing.map(\.kind), [.library])
        let entry = try XCTUnwrap(result.missing.first)
        XCTAssertEqual(entry.reason, .absent)
        XCTAssertNil(entry.downloadURL)
        XCTAssertNil(entry.sha1)
        XCTAssertNil(entry.size)
        XCTAssertEqual(entry.path.path, try libraryPath(relativePath, in: environment))
    }

    func testLibraryWithoutResolvablePathIsInvalidMetadata() throws {
        let environment = try makeEnvironment()
        defer { cleanup(environment) }

        let version = makeVersion(libraries: [Library(name: "broken", artifact: nil)])
        try write(bytes: 16, to: try environment.layout.clientJarURL(version.id))
        try write(bytes: 24, to: try environment.layout.assetIndexURL(id: "5"))
        try write(bytes: 12, to: try environment.layout.loggingConfigURL(id: "client-1.20.xml"))

        let result = try resolution(of: version, in: environment, platform: mac())

        XCTAssertEqual(result.classpath.map(\.path), [try environment.layout.clientJarURL(version.id).path])
        XCTAssertEqual(result.diagnostics.count, 1)
        let diagnostic = try XCTUnwrap(result.diagnostics.first)
        XCTAssertEqual(diagnostic.severity, .error)
        XCTAssertEqual(diagnostic.code, .invalidMetadata)
        XCTAssertTrue(diagnostic.message.contains("broken"), diagnostic.message)
    }

    func testClientJarWithoutDownloadMetadataIsStillLastClasspathEntry() throws {
        let environment = try makeEnvironment()
        defer { cleanup(environment) }

        let version = makeVersion(clientJar: nil)
        try write(bytes: 24, to: try environment.layout.assetIndexURL(id: "5"))
        try write(bytes: 12, to: try environment.layout.loggingConfigURL(id: "client-1.20.xml"))

        let result = try resolution(of: version, in: environment, platform: mac())

        XCTAssertEqual(result.classpath.count, 1)
        XCTAssertEqual(result.classpath.last?.path, try environment.layout.clientJarURL(version.id).path)
        XCTAssertEqual(result.clientJar?.path, try environment.layout.clientJarURL(version.id))
        XCTAssertNil(result.clientJar?.downloadURL)
        XCTAssertEqual(result.missing.map(\.kind), [.clientJar])
        XCTAssertTrue(result.diagnostics.isEmpty, "\(result.diagnostics)")
    }

    // MARK: - Path safety

    func testPathTraversalInArtifactPathIsRejected() throws {
        let environment = try makeEnvironment()
        defer { cleanup(environment) }

        let traversing = makeVersion(libraries: [
            Library(name: "com.example:evil:1.0", artifact: Artifact(
                urlString: "https://example.invalid/evil.jar",
                path: "../evil.jar"
            )),
        ])
        XCTAssertThrowsError(try resolution(of: traversing, in: environment, platform: mac())) { error in
            XCTAssertEqual((error as? LauncherError)?.code, .pathEscapesRoot)
        }

        let absolute = makeVersion(libraries: [
            Library(name: "com.example:evil:1.0", artifact: Artifact(
                urlString: "https://example.invalid/evil.jar",
                path: "/tmp/evil.jar"
            )),
        ])
        XCTAssertThrowsError(try resolution(of: absolute, in: environment, platform: mac())) { error in
            XCTAssertEqual((error as? LauncherError)?.code, .pathEscapesRoot)
        }
    }

    func testPathTraversalInNativeClassifierPathIsRejected() throws {
        let environment = try makeEnvironment()
        defer { cleanup(environment) }

        let version = makeVersion(libraries: [
            library(
                "com.example:evilnative:1.0",
                path: "com/example/evilnative/1.0/evilnative-1.0.jar",
                classifiers: ["natives-macos": artifact(path: "../../evil-native.jar")],
                natives: ["osx": "natives-macos"]
            ),
        ])
        XCTAssertThrowsError(try resolution(of: version, in: environment, platform: mac())) { error in
            XCTAssertEqual((error as? LauncherError)?.code, .pathEscapesRoot)
        }
    }

    func testPathsWithSpacesAndChineseCharactersArePreserved() throws {
        let environment = try makeEnvironment(gameRootName: "游戏 Root")
        defer { cleanup(environment) }

        let relativePath = "weird dir/中文/1.0/中文-1.0.jar"
        let version = makeVersion(libraries: [
            library("com.example:unicode:1.0", path: relativePath, size: 4),
        ])
        try write(bytes: 4, to: try environment.layout.libraryURL(relativePath: relativePath))

        let result = try resolution(of: version, in: environment, platform: mac())

        XCTAssertEqual(result.classpath.first?.path, try libraryPath(relativePath, in: environment))
        XCTAssertTrue(
            try XCTUnwrap(result.classpath.first).path.contains("游戏 Root/libraries/weird dir/中文/1.0/中文-1.0.jar")
        )
        XCTAssertTrue(result.missing.filter { $0.kind == .library }.isEmpty)
        XCTAssertEqual(result.classpath.last?.lastPathComponent, "test-version.jar")
    }

    // MARK: - Rule filtering

    func testRulesFilterBothMainArtifactAndLegacyNative() throws {
        let environment = try makeEnvironment()
        defer { cleanup(environment) }

        let version = makeVersion(libraries: [
            library(
                "com.example:native:1.0",
                path: "com/example/native/1.0/native-1.0.jar",
                rules: [
                    Rule(action: .allow),
                    Rule(action: .disallow, os: RuleOS(name: "osx")),
                ],
                classifiers: [
                    "natives-macos": artifact(path: "com/example/native/1.0/native-1.0-natives-macos.jar", size: 6),
                ],
                natives: ["osx": "natives-macos"]
            ),
        ])

        let macOS = try resolution(of: version, in: environment, platform: mac())
        XCTAssertEqual(macOS.classpath.map(\.path), [try environment.layout.clientJarURL(version.id).path])
        XCTAssertTrue(macOS.legacyNatives.isEmpty)
        XCTAssertFalse(macOS.missing.contains { $0.path.path.contains("native") })

        let linux = try resolution(of: version, in: environment, platform: linux())
        XCTAssertEqual(linux.classpath.count, 2)
        XCTAssertTrue(try XCTUnwrap(linux.classpath.first).path.hasSuffix("com/example/native/1.0/native-1.0.jar"))
        XCTAssertTrue(linux.legacyNatives.isEmpty)
    }

    func testInjectedRuleEvaluatorControlsLibrarySelection() throws {
        struct DenyAllEvaluator: RuleEvaluating {
            func isAllowed(_ rules: [Rule]?, platform: PlatformContext) throws -> Bool { false }
        }

        let environment = try makeEnvironment()
        defer { cleanup(environment) }

        let version = makeVersion(libraries: [
            library("com.example:one:1.0"),
            library("com.example:two:1.0"),
        ])
        try write(bytes: 16, to: try environment.layout.clientJarURL(version.id))
        try write(bytes: 24, to: try environment.layout.assetIndexURL(id: "5"))
        try write(bytes: 12, to: try environment.layout.loggingConfigURL(id: "client-1.20.xml"))

        let denied = try DependencyResolver(ruleEvaluator: DenyAllEvaluator()).resolve(
            version: version,
            layout: environment.layout,
            platform: mac()
        )
        XCTAssertEqual(denied.classpath.map(\.path), [try environment.layout.clientJarURL(version.id).path])
        XCTAssertTrue(denied.missing.filter { $0.kind == .library }.isEmpty)
    }

    // MARK: - Legacy natives (real 1.16.5 metadata)

    func testLegacyNativesFrom1165Fixture() throws {
        let environment = try makeEnvironment()
        defer { cleanup(environment) }

        let version = try resolveFixture("1.16.5", in: environment)
        let result = try resolution(of: version, in: environment, platform: mac())

        XCTAssertEqual(result.classpath.count, 35)
        XCTAssertEqual(result.classpathFiles.count, 35)
        XCTAssertEqual(Set(result.classpath.map(\.path)).count, 35)
        XCTAssertEqual(result.classpath.last?.path, try environment.layout.clientJarURL(version.id).path)
        XCTAssertTrue(result.classpathFiles.allSatisfy { $0.sha1 != nil && $0.size != nil && $0.downloadURL != nil })

        XCTAssertEqual(result.legacyNatives.count, 8)
        XCTAssertEqual(result.nativesDirectory, try environment.layout.nativesDirectory(versionID: "1.16.5", architecture: .arm64))
        XCTAssertTrue(result.legacyNatives.allSatisfy { $0.architectureHint == nil })
        XCTAssertEqual(result.legacyNatives.filter { $0.classifier == "natives-macos" }.count, 7)
        XCTAssertEqual(result.legacyNatives.filter { $0.classifier == "natives-osx" }.count, 1)

        let objcBridge = try XCTUnwrap(result.legacyNatives.first { $0.classifier == "natives-osx" })
        XCTAssertEqual(objcBridge.extractExclude, ["META-INF/"])
        XCTAssertTrue(objcBridge.file.path.path.hasSuffix("ca/weblite/java-objc-bridge/1.0.0/java-objc-bridge-1.0.0-natives-osx.jar"))
        XCTAssertEqual(objcBridge.file.sha1, "08befab4894d55875f33c3d300f4f71e6e828f64")

        let lwjgl = try XCTUnwrap(result.legacyNatives.first {
            $0.file.path.path.hasSuffix("org/lwjgl/lwjgl/3.2.1/lwjgl-3.2.1-natives-macos.jar")
        })
        XCTAssertEqual(lwjgl.extractExclude, [])
        XCTAssertEqual(lwjgl.file.size, 39835)

        // The main LWJGL 3.2.1 JAR is on the classpath, the osx-disallowed 3.2.2 variant is not,
        // and native classifier JARs are never classpath entries.
        XCTAssertTrue(result.classpath.contains { $0.path.hasSuffix("org/lwjgl/lwjgl/3.2.1/lwjgl-3.2.1.jar") })
        XCTAssertFalse(result.classpath.contains { $0.path.contains("lwjgl-3.2.2.jar") })
        XCTAssertFalse(result.classpath.contains { $0.path.contains("-natives-") })

        XCTAssertEqual(result.missing.filter { $0.kind == .library }.count, 34)
        XCTAssertEqual(result.missing.filter { $0.kind == .native }.count, 8)
        XCTAssertEqual(result.missing.filter { $0.kind == .clientJar }.count, 1)
        XCTAssertEqual(result.missing.filter { $0.kind == .assetIndex }.count, 1)
        XCTAssertEqual(result.missing.filter { $0.kind == .loggingConfig }.count, 1)
        XCTAssertEqual(result.missing.count, 45)

        // `natives-macos` archives declare no CPU architecture: one advisory warning for the whole
        // resolution (not one per native library) and never an error.
        XCTAssertEqual(result.diagnostics.count, 1)
        let warning = try XCTUnwrap(result.diagnostics.first)
        XCTAssertEqual(warning.severity, .warning)
        XCTAssertEqual(warning.code, .javaArchitectureMismatch)
        XCTAssertTrue(warning.message.contains("natives-macos"), warning.message)
        XCTAssertTrue(warning.message.contains("does not declare its CPU architecture"), warning.message)
        XCTAssertTrue(warning.suggestion?.contains("Rosetta") ?? false, warning.suggestion ?? "")

        XCTAssertEqual(result.clientJar?.path, try environment.layout.clientJarURL(version.id))
        XCTAssertEqual(result.assetIndexFile?.path, try environment.layout.assetIndexURL(id: "1.16"))
        XCTAssertEqual(result.loggingFile?.path, try environment.layout.loggingConfigURL(id: "client-1.12.xml"))

        // The warning is Apple Silicon specific: an Intel Mac needs no Rosetta hint.
        let intelResult = try resolution(of: version, in: environment, platform: mac(architecture: .x86_64))
        XCTAssertEqual(intelResult.legacyNatives.count, 8)
        XCTAssertTrue(intelResult.diagnostics.filter { $0.code == .javaArchitectureMismatch }.isEmpty)
        XCTAssertEqual(
            intelResult.nativesDirectory,
            try environment.layout.nativesDirectory(versionID: version.id, architecture: .x86_64)
        )
    }

    // MARK: - Modern natives (real 1.20.1 / 26.3 metadata)

    func testModernNativesArePlainClasspathEntriesIn1201() throws {
        let environment = try makeEnvironment()
        defer { cleanup(environment) }

        let version = try resolveFixture("1.20.1", in: environment)
        let result = try resolution(of: version, in: environment, platform: mac())

        XCTAssertTrue(result.legacyNatives.isEmpty)
        XCTAssertEqual(result.classpath.count, 59)
        XCTAssertEqual(result.classpathFiles.count, 59)
        XCTAssertTrue(result.classpath.contains { $0.path.hasSuffix("lwjgl-glfw-3.3.1-natives-macos.jar") })
        XCTAssertTrue(result.classpath.contains { $0.path.hasSuffix("lwjgl-glfw-3.3.1-natives-macos-arm64.jar") })
        XCTAssertTrue(result.classpath.contains { $0.path.hasSuffix("org/lwjgl/lwjgl-glfw/3.3.1/lwjgl-glfw-3.3.1.jar") })
        XCTAssertFalse(result.classpath.contains { $0.path.contains("natives-linux") })
        XCTAssertEqual(result.missing.filter { $0.kind == .library }.count, 58)
        XCTAssertTrue(result.missing.filter { $0.kind == .native }.isEmpty)
        XCTAssertEqual(result.missing.count, 61)
        XCTAssertTrue(result.diagnostics.isEmpty, "\(result.diagnostics)")

        let linuxResult = try resolution(of: version, in: environment, platform: linux())
        XCTAssertEqual(linuxResult.classpath.count, 53)
        XCTAssertTrue(linuxResult.legacyNatives.isEmpty)
        XCTAssertTrue(linuxResult.classpath.contains { $0.path.contains("natives-linux") })
        XCTAssertFalse(linuxResult.classpath.contains { $0.path.contains("natives-macos") })
    }

    func testModernNativesArePlainClasspathEntriesIn263() throws {
        let environment = try makeEnvironment()
        defer { cleanup(environment) }

        let version = try resolveFixture("26.3", in: environment)
        let result = try resolution(of: version, in: environment, platform: mac())

        XCTAssertTrue(result.legacyNatives.isEmpty)
        XCTAssertEqual(result.classpath.count, 81)
        XCTAssertTrue(result.classpath.contains { $0.path.hasSuffix("jtracy-1.14.38-natives-macos-arm64.jar") })
        XCTAssertTrue(result.classpath.contains { $0.path.hasSuffix("jtracy-1.14.38-natives-macos.jar") })
        XCTAssertFalse(result.classpath.contains { $0.path.contains("natives-linux") })
        XCTAssertEqual(result.missing.filter { $0.kind == .library }.count, 80)
        XCTAssertTrue(result.missing.filter { $0.kind == .native }.isEmpty)
        XCTAssertEqual(result.missing.count, 83)
        XCTAssertTrue(result.diagnostics.isEmpty, "\(result.diagnostics)")

        let linuxResult = try resolution(of: version, in: environment, platform: linux())
        XCTAssertEqual(linuxResult.classpath.count, 67)
        XCTAssertTrue(linuxResult.legacyNatives.isEmpty)
        XCTAssertFalse(linuxResult.classpath.contains { $0.path.contains("natives-macos") })
    }

    // MARK: - Native architecture hints

    func testLegacyNativeArchitectureHintsAndArm64Mismatch() throws {
        let environment = try makeEnvironment()
        defer { cleanup(environment) }

        func nativeLibrary(_ name: String, classifier: String) -> Library {
            let folder = "com/example/\(name)/1.0"
            return library(
                "com.example:\(name):1.0",
                path: "\(folder)/\(name)-1.0.jar",
                classifiers: [classifier: artifact(path: "\(folder)/\(name)-1.0-\(classifier).jar", size: 10)],
                natives: ["osx": classifier],
                extractExclude: ["META-INF/"]
            )
        }

        let version = makeVersion(libraries: [
            nativeLibrary("arm", classifier: "natives-macos-arm64"),
            nativeLibrary("x64", classifier: "natives-macos-x64"),
            nativeLibrary("x8664", classifier: "natives-macos-x86_64"),
            nativeLibrary("plain", classifier: "natives-macos"),
        ])

        let armResult = try resolution(of: version, in: environment, platform: mac())
        XCTAssertEqual(armResult.legacyNatives.count, 4)
        let hints = Dictionary(uniqueKeysWithValues: armResult.legacyNatives.map { ($0.classifier, $0.architectureHint) })
        XCTAssertEqual(hints["natives-macos-arm64"], .arm64)
        XCTAssertEqual(hints["natives-macos-x64"], .x86_64)
        XCTAssertEqual(hints["natives-macos-x86_64"], .x86_64)
        XCTAssertNil(hints["natives-macos"] ?? nil)
        XCTAssertTrue(armResult.legacyNatives.allSatisfy { $0.extractExclude == ["META-INF/"] })
        XCTAssertEqual(armResult.nativesDirectory, try environment.layout.nativesDirectory(versionID: version.id, architecture: .arm64))

        let mismatchDiagnostics = armResult.diagnostics.filter { $0.code == .javaArchitectureMismatch && $0.severity == .error }
        XCTAssertEqual(mismatchDiagnostics.count, 2)
        let unknownArchitectureWarnings = armResult.diagnostics.filter {
            $0.code == .javaArchitectureMismatch && $0.severity == .warning
        }
        XCTAssertEqual(unknownArchitectureWarnings.count, 1)
        XCTAssertTrue(unknownArchitectureWarnings.first?.message.contains("natives-macos") ?? false)
        for diagnostic in mismatchDiagnostics {
            XCTAssertEqual(diagnostic.severity, .error)
            XCTAssertTrue(diagnostic.message.contains("arm64"), diagnostic.message)
            XCTAssertTrue(diagnostic.message.contains("x86_64"), diagnostic.message)
            XCTAssertTrue(diagnostic.suggestion?.contains("Rosetta") ?? false, diagnostic.suggestion ?? "")
        }
        // Native JARs are extraction inputs only; they never join the classpath.
        XCTAssertFalse(armResult.classpath.contains { $0.path.contains("-natives-") })

        let intelResult = try resolution(of: version, in: environment, platform: mac(architecture: .x86_64))
        XCTAssertEqual(intelResult.legacyNatives.count, 4)
        XCTAssertTrue(intelResult.diagnostics.filter { $0.code == .javaArchitectureMismatch }.isEmpty)
        XCTAssertEqual(
            intelResult.nativesDirectory,
            try environment.layout.nativesDirectory(versionID: version.id, architecture: .x86_64)
        )
    }

    func testNativeClassifierMissingArtifactIsInvalidMetadata() throws {
        let environment = try makeEnvironment()
        defer { cleanup(environment) }

        let version = makeVersion(libraries: [
            library(
                "com.example:nonatives:1.0",
                path: "com/example/nonatives/1.0/nonatives-1.0.jar",
                classifiers: nil,
                natives: ["osx": "natives-macos"]
            ),
        ])

        let result = try resolution(of: version, in: environment, platform: mac())

        XCTAssertTrue(result.legacyNatives.isEmpty)
        XCTAssertEqual(result.classpath.count, 2)
        XCTAssertEqual(result.diagnostics.count, 1)
        let diagnostic = try XCTUnwrap(result.diagnostics.first)
        XCTAssertEqual(diagnostic.code, .invalidMetadata)
        XCTAssertTrue(diagnostic.message.contains("natives-macos"), diagnostic.message)
    }

    func testNativeClassifierPathFallsBackToMavenLayout() throws {
        let environment = try makeEnvironment()
        defer { cleanup(environment) }

        let classifier = artifact(path: nil, url: "https://example.invalid/native.jar", sha1: "native-sha1", size: 10)
        let version = makeVersion(libraries: [
            library(
                "com.example:nativefallback:1.0",
                path: "com/example/nativefallback/1.0/nativefallback-1.0.jar",
                classifiers: ["natives-macos": classifier],
                natives: ["osx": "natives-macos"]
            ),
        ])

        let result = try resolution(of: version, in: environment, platform: mac())
        let native = try XCTUnwrap(result.legacyNatives.first)

        XCTAssertEqual(
            native.file.path.path,
            try libraryPath("com/example/nativefallback/1.0/nativefallback-1.0-natives-macos.jar", in: environment)
        )
        XCTAssertEqual(native.file.sha1, "native-sha1")
        XCTAssertEqual(native.file.downloadURL?.absoluteString, "https://example.invalid/native.jar")
        XCTAssertEqual(result.missing.filter { $0.kind == .native }.count, 1)
    }

    func testPresentLegacyNativeIsNotReportedMissing() throws {
        let environment = try makeEnvironment()
        defer { cleanup(environment) }

        let relativePath = "com/example/presentnative/1.0/presentnative-1.0-natives-macos.jar"
        let version = makeVersion(libraries: [
            library(
                "com.example:presentnative:1.0",
                path: "com/example/presentnative/1.0/presentnative-1.0.jar",
                classifiers: ["natives-macos": artifact(path: relativePath, sha1: "native-sha1", size: 10)],
                natives: ["osx": "natives-macos"]
            ),
        ])
        try write(bytes: 10, to: try environment.layout.libraryURL(relativePath: relativePath))
        try write(bytes: 16, to: try environment.layout.clientJarURL(version.id))
        try write(bytes: 24, to: try environment.layout.assetIndexURL(id: "5"))
        try write(bytes: 12, to: try environment.layout.loggingConfigURL(id: "client-1.20.xml"))

        let result = try resolution(of: version, in: environment, platform: mac())

        XCTAssertEqual(result.legacyNatives.count, 1)
        XCTAssertTrue(result.missing.filter { $0.kind == .native }.isEmpty)
        XCTAssertEqual(result.diagnostics.count, 1)
        XCTAssertEqual(result.diagnostics.first?.severity, .warning)
        XCTAssertEqual(result.diagnostics.first?.code, .javaArchitectureMismatch)
    }

    // MARK: - Asset index and logging config

    func testLegacyAssetsProduceWarningInsteadOfMissingFile() throws {
        let environment = try makeEnvironment()
        defer { cleanup(environment) }

        let version = makeVersion(assetIndex: nil, assetIndexID: "legacy")
        try write(bytes: 16, to: try environment.layout.clientJarURL(version.id))
        try write(bytes: 12, to: try environment.layout.loggingConfigURL(id: "client-1.20.xml"))

        let result = try resolution(of: version, in: environment, platform: mac())

        XCTAssertNil(result.assetIndexFile)
        XCTAssertFalse(result.missing.contains { $0.kind == .assetIndex })
        XCTAssertEqual(result.diagnostics.count, 1)
        let warning = try XCTUnwrap(result.diagnostics.first)
        XCTAssertEqual(warning.severity, .warning)
        XCTAssertTrue(warning.message.contains("assetIndex"), warning.message)
        XCTAssertTrue(warning.message.contains("legacy"), warning.message)
    }

    func testLoggingConfigNameIsDerivedFromExplicitID() throws {
        let environment = try makeEnvironment()
        defer { cleanup(environment) }

        let version = makeVersion()

        let result = try resolution(of: version, in: environment, platform: mac())

        XCTAssertEqual(result.loggingFile?.path, try environment.layout.loggingConfigURL(id: "client-1.20.xml"))
        XCTAssertTrue(result.missing.contains { $0.kind == .loggingConfig })
    }

    func testLoggingConfigExplicitIDWinsOverPathAndURL() throws {
        let environment = try makeEnvironment()
        defer { cleanup(environment) }

        let version = makeVersion(clientLogging: ClientLogging(
            argument: "-Dlog4j.configurationFile=${path}",
            file: Artifact(
                urlString: "https://example.invalid/objects/url-name.xml",
                path: "ignored/path-name.xml",
                sha1: "explicit-sha1",
                size: 3,
                id: "client-explicit.xml"
            ),
            type: "log4j2-xml"
        ))

        let result = try resolution(of: version, in: environment, platform: mac())

        XCTAssertEqual(result.loggingFile?.path, try environment.layout.loggingConfigURL(id: "client-explicit.xml"))
        XCTAssertEqual(result.loggingFile?.downloadURL?.lastPathComponent, "url-name.xml")
    }

    func testLoggingConfigNameIsDerivedFromDownloadURL() throws {
        let environment = try makeEnvironment()
        defer { cleanup(environment) }

        let version = makeVersion(clientLogging: ClientLogging(
            argument: "-Dlog4j.configurationFile=${path}",
            file: Artifact(
                urlString: "https://example.invalid/objects/client-from-url.xml",
                sha1: "url-sha1",
                size: 5
            ),
            type: "log4j2-xml"
        ))
        let result = try resolution(of: version, in: environment, platform: mac())

        XCTAssertEqual(result.loggingFile?.path, try environment.layout.loggingConfigURL(id: "client-from-url.xml"))
        XCTAssertEqual(result.loggingFile?.sha1, "url-sha1")
        XCTAssertEqual(result.loggingFile?.size, 5)
        XCTAssertEqual(
            result.loggingFile?.downloadURL?.absoluteString,
            "https://example.invalid/objects/client-from-url.xml"
        )
    }

    func testLoggingConfigNameIsDerivedFromMetadataPath() throws {
        let environment = try makeEnvironment()
        defer { cleanup(environment) }

        let version = makeVersion(clientLogging: ClientLogging(
            argument: "-Dlog4j.configurationFile=${path}",
            file: Artifact(path: "log_configs/custom.xml", sha1: "custom-sha1", size: 3),
            type: "log4j2-xml"
        ))

        let result = try resolution(of: version, in: environment, platform: mac())

        XCTAssertEqual(result.loggingFile?.path, try environment.layout.loggingConfigURL(id: "custom.xml"))
        XCTAssertEqual(result.missing.filter { $0.kind == .loggingConfig }.count, 1)
    }

    func testLoggingMetadataWithoutFileNameIsWarning() throws {
        let environment = try makeEnvironment()
        defer { cleanup(environment) }

        let version = makeVersion(clientLogging: ClientLogging(
            argument: "-Dlog4j.configurationFile=${path}",
            file: Artifact(sha1: "nameless-sha1", size: 4),
            type: "log4j2-xml"
        ))

        let result = try resolution(of: version, in: environment, platform: mac())

        XCTAssertNil(result.loggingFile)
        XCTAssertFalse(result.missing.contains { $0.kind == .loggingConfig })
        let warning = try XCTUnwrap(result.diagnostics.first)
        XCTAssertEqual(warning.severity, .warning)
        XCTAssertEqual(warning.code, .invalidMetadata)
    }
}
