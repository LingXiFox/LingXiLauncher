import XCTest
@testable import LauncherCore

/// In-memory inputs for one launch-plan test. Every URL lives under a test-owned temporary
/// directory, so nothing is written outside it.
private struct T06PlanFixture {
    let root: URL
    let layout: GameDataLayout
    let instanceDirectory: URL
    let gameDirectory: URL
    let javaExecutable: URL
    let nativesDirectory: URL
    let classpath: [URL]
    let version: ResolvedVersion
    let dependencies: DependencyResolution
    let context: LaunchContext

    var classpathValue: String {
        classpath.map(\.path).joined(separator: ":")
    }
}

final class LaunchPlanBuilderTests: XCTestCase {
    private var builder: LaunchPlanBuilder {
        LaunchPlanBuilder(argumentResolver: ArgumentResolver(ruleEvaluator: T06TestRuleEvaluator()))
    }

    private let defaultJVMArguments: [ArgumentEntry] = [
        .argument("-Xms512M"),
        .argument("-Djava.library.path=${natives_directory}/java"),
        .argument("-Dminecraft.launcher.brand=${launcher_name}"),
        .argument("-Dminecraft.launcher.version=${launcher_version}"),
        .argument("-cp"),
        .argument("${classpath}"),
    ]

    private let defaultGameArguments: [ArgumentEntry] = [
        .argument("--username"), .argument("${auth_player_name}"),
        .argument("--uuid"), .argument("${auth_uuid}"),
        .argument("--accessToken"), .argument("${auth_access_token}"),
        .argument("--xuid"), .argument("${auth_xuid}"),
        .argument("--clientId"), .argument("${clientid}"),
        .argument("--userType"), .argument("${user_type}"),
        .argument("--gameDir"), .argument("${game_directory}"),
    ]

    // MARK: - Plan shape

    func testBuildsPlanWithExpandedVariablesAndMetadataOrder() throws {
        let fixture = try makeFixture()
        let plan = try builder.build(
            version: fixture.version,
            context: fixture.context,
            dependencies: fixture.dependencies
        )

        XCTAssertEqual(plan.javaExecutable, fixture.javaExecutable)
        XCTAssertEqual(plan.workingDirectory, fixture.gameDirectory)
        XCTAssertEqual(plan.environmentOverrides, [:])
        XCTAssertEqual(plan.versionID, "test-version")
        XCTAssertEqual(plan.identityMode, .localOffline)
        XCTAssertEqual(plan.arguments.count, plan.redactedArguments.count)

        XCTAssertEqual(argumentValue(after: "--username", in: plan.arguments), "TestPlayer")
        XCTAssertEqual(argumentValue(after: "--gameDir", in: plan.arguments), fixture.gameDirectory.path)
        XCTAssertEqual(argumentValue(after: "-cp", in: plan.arguments), fixture.classpathValue)
        XCTAssertTrue(plan.arguments.contains("-Djava.library.path=\(fixture.nativesDirectory.path)/java"))
        XCTAssertTrue(plan.arguments.contains("-Dminecraft.launcher.brand=LingXi Launcher"))
        XCTAssertTrue(plan.arguments.contains(fixture.version.mainClass))
        XCTAssertFalse(plan.arguments.contains { $0.contains("${") })
        XCTAssertFalse(plan.redactedArguments.contains { $0.contains("${") })
    }

    func testAdditionalJVMArgumentsLandImmediatelyBeforeClasspathFlag() throws {
        let fixture = try makeFixture(additionalJVMArguments: ["-Dfoo=bar", "-Dlingxi.feature=on"])
        let plan = try builder.build(
            version: fixture.version,
            context: fixture.context,
            dependencies: fixture.dependencies
        )

        let cpIndex = try XCTUnwrap(plan.arguments.firstIndex(of: "-cp"))
        XCTAssertEqual(Array(plan.arguments[(cpIndex - 2)..<cpIndex]), ["-Dfoo=bar", "-Dlingxi.feature=on"])
        XCTAssertEqual(plan.arguments[cpIndex - 3], "-Dminecraft.launcher.version=0.1.0")
        XCTAssertEqual(plan.arguments[cpIndex + 1], fixture.classpathValue)

        let redactedCPIndex = try XCTUnwrap(plan.redactedArguments.firstIndex(of: "-cp"))
        XCTAssertEqual(Array(plan.redactedArguments[(redactedCPIndex - 2)..<redactedCPIndex]), ["-Dfoo=bar", "-Dlingxi.feature=on"])
    }

    func testAdditionalJVMArgumentsAreAppendedWhenNoClasspathFlagExists() throws {
        let fixture = try makeFixture(
            additionalJVMArguments: ["-Dfoo=bar"],
            jvmArguments: [.argument("-Xmx1G")]
        )
        let plan = try builder.build(
            version: fixture.version,
            context: fixture.context,
            dependencies: fixture.dependencies
        )
        XCTAssertEqual(Array(plan.arguments.prefix(3)), ["-Xmx1G", "-Dfoo=bar", fixture.version.mainClass])
    }

    func testLoggingArgumentIsInsertedBeforeClasspathFlag() throws {
        let logging = ClientLogging(
            argument: "-Dlog4j.configurationFile=${path}",
            file: Artifact(path: "log_configs/client.xml"),
            type: "log4j2-xml"
        )
        let fixture = try makeFixture(
            additionalJVMArguments: ["-Dfoo=bar"],
            clientLogging: logging,
            includeLoggingFile: true
        )
        let plan = try builder.build(
            version: fixture.version,
            context: fixture.context,
            dependencies: fixture.dependencies
        )

        let loggingPath = fixture.layout.loggingConfigsDirectory.appendingPathComponent("client.xml").path
        let cpIndex = try XCTUnwrap(plan.arguments.firstIndex(of: "-cp"))
        XCTAssertEqual(plan.arguments[cpIndex - 1], "-Dlog4j.configurationFile=\(loggingPath)")
        XCTAssertEqual(plan.arguments[cpIndex - 2], "-Dfoo=bar")
    }

    func testLoggingArgumentIsOmittedWhenLoggingFileIsMissing() throws {
        let logging = ClientLogging(
            argument: "-Dlog4j.configurationFile=${path}",
            file: Artifact(path: "log_configs/client.xml")
        )
        let fixture = try makeFixture(clientLogging: logging, includeLoggingFile: false)
        let plan = try builder.build(
            version: fixture.version,
            context: fixture.context,
            dependencies: fixture.dependencies
        )
        // No logging file ⇒ `${path}` is not provided, so the log4j property is not inserted at all.
        XCTAssertFalse(plan.arguments.contains { $0.hasPrefix("-Dlog4j.configurationFile=") })
        XCTAssertEqual(plan.arguments.filter { $0 == "-cp" }.count, 1)
    }

    func testEnabledLauncherFeatureIncludesRuleGatedGameArgument() throws {
        let gameArguments: [ArgumentEntry] = [
            .argument("--username"),
            .argument("${auth_player_name}"),
            .conditional(
                rules: [Rule(action: .allow, features: ["is_demo_user": true])],
                values: ["--demo"]
            ),
        ]
        let fixture = try makeFixture(features: ["is_demo_user": true], gameArguments: gameArguments)
        let plan = try builder.build(
            version: fixture.version,
            context: fixture.context,
            dependencies: fixture.dependencies
        )
        XCTAssertEqual(plan.arguments.last, "--demo")
        XCTAssertEqual(plan.arguments.count, plan.redactedArguments.count)
    }

    func testClasspathWithSpacesAndChineseCharactersStaysOneArgument() throws {
        let fixture = try makeFixture(
            classpathRelativePaths: [
                "some dir with spaces/中文 库.jar",
                "plain/library.jar",
            ]
        )
        let plan = try builder.build(
            version: fixture.version,
            context: fixture.context,
            dependencies: fixture.dependencies
        )

        XCTAssertEqual(argumentValue(after: "-cp", in: plan.arguments), fixture.classpathValue)
        XCTAssertEqual(plan.arguments.filter { $0.contains("中文") }.count, 1)
        XCTAssertEqual(plan.arguments.filter { $0.contains("some dir with spaces") }.count, 1)
        XCTAssertTrue(fixture.classpathValue.contains(
            "\(fixture.layout.librariesDirectory.path)/some dir with spaces/中文 库.jar"
        ))
        XCTAssertTrue(fixture.classpathValue.contains(
            "\(fixture.layout.librariesDirectory.path)/plain/library.jar"
        ))
    }

    func testRepeatedBuildsAndPreviewsAreDeterministic() throws {
        let fixture = try makeFixture(additionalJVMArguments: ["-Dfoo=bar"])
        let java = makeJava(majorVersion: 17)

        let firstPlan = try builder.build(
            version: fixture.version,
            context: fixture.context,
            dependencies: fixture.dependencies
        )
        let secondPlan = try builder.build(
            version: fixture.version,
            context: fixture.context,
            dependencies: fixture.dependencies
        )
        XCTAssertEqual(firstPlan.arguments, secondPlan.arguments)
        XCTAssertEqual(firstPlan.redactedArguments, secondPlan.redactedArguments)
        XCTAssertEqual(firstPlan.workingDirectory, secondPlan.workingDirectory)
        XCTAssertEqual(firstPlan.environmentOverrides, secondPlan.environmentOverrides)

        let firstPreview = try builder.preview(
            version: fixture.version,
            context: fixture.context,
            dependencies: fixture.dependencies,
            java: java
        )
        let secondPreview = try builder.preview(
            version: fixture.version,
            context: fixture.context,
            dependencies: fixture.dependencies,
            java: java
        )
        XCTAssertEqual(firstPreview.jvmArguments, secondPreview.jvmArguments)
        XCTAssertEqual(firstPreview.gameArguments, secondPreview.gameArguments)
        XCTAssertEqual(firstPreview.classpathEntries, secondPreview.classpathEntries)
        XCTAssertEqual(firstPreview.classpathEntryCount, secondPreview.classpathEntryCount)
        XCTAssertEqual(firstPreview.diagnostics, secondPreview.diagnostics)
        XCTAssertEqual(firstPreview.missingDependencies, secondPreview.missingDependencies)
        XCTAssertEqual(firstPreview.identityDisplayName, secondPreview.identityDisplayName)
    }

    // MARK: - Identity

    func testLocalOfflineIdentityUsesExplicitNonSecretPlaceholders() throws {
        let profile = try LocalOfflineIdentity.makeProfile(playerName: "OfflineSteve")
        let fixture = try makeFixture(identity: .localOffline(profile))
        let plan = try builder.build(
            version: fixture.version,
            context: fixture.context,
            dependencies: fixture.dependencies
        )

        let expectedUUID = profile.stableOfflineUUID.uuidString
            .replacingOccurrences(of: "-", with: "")
            .lowercased()
        XCTAssertFalse(expectedUUID.contains("-"))
        XCTAssertEqual(argumentValue(after: "--username", in: plan.arguments), "OfflineSteve")
        XCTAssertEqual(argumentValue(after: "--uuid", in: plan.arguments), expectedUUID)
        XCTAssertEqual(argumentValue(after: "--accessToken", in: plan.arguments), "0")
        XCTAssertEqual(argumentValue(after: "--xuid", in: plan.arguments), "0")
        XCTAssertEqual(argumentValue(after: "--clientId", in: plan.arguments), "0")
        XCTAssertEqual(argumentValue(after: "--userType", in: plan.arguments), "legacy")

        // Even the explicit "0" token is treated as a secret in redacted output; the UUID is not.
        XCTAssertEqual(argumentValue(after: "--accessToken", in: plan.redactedArguments), LauncherInfo.redactionPlaceholder)
        XCTAssertEqual(argumentValue(after: "--uuid", in: plan.redactedArguments), expectedUUID)
    }

    func testLicensedOfflineIdentityIsRejectedInBuildAndPreview() throws {
        let verified = PreviouslyVerifiedProfile(
            profile: MinecraftProfile(id: UUID(), name: "VerifiedPlayer"),
            verifiedAt: Date(timeIntervalSince1970: 1_700_000_000)
        )
        let fixture = try makeFixture(identity: .licensedOffline(verified))

        XCTAssertThrowsError(
            try builder.build(
                version: fixture.version,
                context: fixture.context,
                dependencies: fixture.dependencies
            )
        ) { error in
            guard let launcherError = error as? LauncherError else {
                return XCTFail("Expected LauncherError, got \(error)")
            }
            XCTAssertEqual(launcherError.code, .unauthorized)
            XCTAssertTrue(launcherError.message.contains("M3"), launcherError.message)
        }

        XCTAssertThrowsError(
            try builder.preview(
                version: fixture.version,
                context: fixture.context,
                dependencies: fixture.dependencies,
                java: makeJava(majorVersion: 17)
            )
        ) { error in
            XCTAssertEqual((error as? LauncherError)?.code, .unauthorized)
        }
    }

    // MARK: - Redaction

    func testMicrosoftSessionTokenIsRedactedEverywhere() throws {
        let token = "test-session-token-9f8e7d6c"
        let profileID = try XCTUnwrap(UUID(uuidString: "069a79f4-44e9-4726-a5be-fca90e38aaf5"))
        let session = AuthorizedMinecraftSession(
            profile: MinecraftProfile(id: profileID, name: "Notch"),
            xuid: "2535400000000000",
            userType: "msa",
            expiresAt: Date(timeIntervalSinceNow: 3_600),
            accessToken: token
        )
        let fixture = try makeFixture(identity: .microsoft(session))

        let plan = try builder.build(
            version: fixture.version,
            context: fixture.context,
            dependencies: fixture.dependencies
        )
        XCTAssertTrue(plan.arguments.contains(token))
        XCTAssertEqual(plan.arguments.count, plan.redactedArguments.count)
        XCTAssertFalse(plan.redactedArguments.contains(token))
        XCTAssertTrue(plan.redactedArguments.contains(LauncherInfo.redactionPlaceholder))
        XCTAssertFalse(plan.description.contains(token))
        XCTAssertFalse(plan.debugDescription.contains(token))

        // Only the token is secret; the UUID, XUID, client id and user type stay inspectable.
        let expectedUUID = profileID.uuidString.replacingOccurrences(of: "-", with: "").lowercased()
        XCTAssertEqual(argumentValue(after: "--uuid", in: plan.redactedArguments), expectedUUID)
        XCTAssertEqual(argumentValue(after: "--xuid", in: plan.redactedArguments), "2535400000000000")
        XCTAssertEqual(argumentValue(after: "--clientId", in: plan.redactedArguments), "0")
        XCTAssertEqual(argumentValue(after: "--userType", in: plan.redactedArguments), "msa")

        let preview = try builder.preview(
            version: fixture.version,
            context: fixture.context,
            dependencies: fixture.dependencies,
            java: makeJava(majorVersion: 17)
        )
        XCTAssertFalse(preview.gameArguments.contains(token))
        XCTAssertFalse(preview.jvmArguments.contains(token))
        XCTAssertFalse(preview.description.contains(token))
        XCTAssertTrue(preview.gameArguments.contains(LauncherInfo.redactionPlaceholder))
        XCTAssertEqual(argumentValue(after: "--accessToken", in: preview.gameArguments), LauncherInfo.redactionPlaceholder)
    }

    // MARK: - Preview

    func testPreviewReportsClasspathDependenciesJavaAndDiagnostics() throws {
        let missing = [
            MissingDependency(
                kind: .library,
                path: URL(fileURLWithPath: "/tmp/missing/lib.jar"),
                reason: .absent,
                downloadURL: URL(string: "https://example.invalid/lib.jar")
            ),
            MissingDependency(
                kind: .assetObject,
                path: URL(fileURLWithPath: "/tmp/missing/objects/ab/abcdef"),
                reason: .sizeMismatch
            ),
        ]
        let fixture = try makeFixture(
            missing: missing,
            dependencyDiagnostics: [.info("dependency resolution complete")]
        )
        let java = makeJava(majorVersion: 17, architecture: .arm64)
        let preview = try builder.preview(
            version: fixture.version,
            context: fixture.context,
            dependencies: fixture.dependencies,
            java: java
        )

        XCTAssertEqual(preview.identityMode, .localOffline)
        XCTAssertEqual(preview.identityDisplayName, fixture.context.identity.displayName)
        XCTAssertEqual(preview.versionID, "test-version")
        XCTAssertEqual(preview.javaExecutable, fixture.javaExecutable)
        XCTAssertEqual(preview.mainClass, fixture.version.mainClass)
        XCTAssertEqual(preview.classpathEntryCount, fixture.classpath.count)
        XCTAssertEqual(preview.classpathEntries, fixture.classpath.map(\.path))
        XCTAssertEqual(preview.gameDirectory, fixture.gameDirectory)
        XCTAssertEqual(preview.missingDependencies, missing)
        XCTAssertEqual(preview.diagnostics.filter { $0.code == .missingDependency }.count, missing.count)
        XCTAssertTrue(preview.diagnostics.contains(.info("dependency resolution complete")))
        XCTAssertTrue(preview.jvmArguments.contains("-Dlauncher.test=1"))
        XCTAssertTrue(preview.hasBlockingDiagnostics)
    }

    func testPreviewContainsExpandedJVMPrefixIncludingAdditionalArgumentsAndLogging() throws {
        let logging = ClientLogging(
            argument: "-Dlog4j.configurationFile=${path}",
            file: Artifact(path: "log_configs/client.xml")
        )
        let fixture = try makeFixture(
            additionalJVMArguments: ["-Dfoo=bar"],
            clientLogging: logging,
            includeLoggingFile: true
        )
        let preview = try builder.preview(
            version: fixture.version,
            context: fixture.context,
            dependencies: fixture.dependencies,
            java: makeJava(majorVersion: 17)
        )

        XCTAssertTrue(preview.jvmArguments.contains("-Dfoo=bar"))
        XCTAssertTrue(preview.jvmArguments.contains("-cp"))
        XCTAssertEqual(argumentValue(after: "-cp", in: preview.jvmArguments), fixture.classpathValue)
        let loggingPath = fixture.layout.loggingConfigsDirectory.appendingPathComponent("client.xml").path
        XCTAssertTrue(preview.jvmArguments.contains("-Dlog4j.configurationFile=\(loggingPath)"))
        XCTAssertFalse(preview.jvmArguments.contains { $0.contains("${") })
    }

    func testPreviewWithoutJavaReportsJavaNotFound() throws {
        let fixture = try makeFixture()
        let preview = try builder.preview(
            version: fixture.version,
            context: fixture.context,
            dependencies: fixture.dependencies,
            java: nil
        )
        XCTAssertTrue(preview.diagnostics.contains { $0.code == .javaNotFound && $0.severity == .error })
        XCTAssertTrue(preview.hasBlockingDiagnostics)
    }

    // MARK: - validate()

    func testValidateIsCleanForACompleteLaunch() throws {
        let fixture = try makeFixture()
        let plan = try builder.build(
            version: fixture.version,
            context: fixture.context,
            dependencies: fixture.dependencies
        )
        let diagnostics = builder.validate(
            version: fixture.version,
            context: fixture.context,
            plan: plan,
            dependencies: fixture.dependencies,
            java: makeJava(majorVersion: 17)
        )
        XCTAssertEqual(diagnostics, [])
    }

    func testValidateReportsEveryMissingDependencyAsError() throws {
        let missing = [
            MissingDependency(kind: .clientJar, path: URL(fileURLWithPath: "/tmp/client.jar"), reason: .absent),
            MissingDependency(kind: .loggingConfig, path: URL(fileURLWithPath: "/tmp/client.xml"), reason: .absent),
        ]
        let fixture = try makeFixture(missing: missing)
        let plan = try builder.build(
            version: fixture.version,
            context: fixture.context,
            dependencies: fixture.dependencies
        )
        let diagnostics = builder.validate(
            version: fixture.version,
            context: fixture.context,
            plan: plan,
            dependencies: fixture.dependencies,
            java: makeJava(majorVersion: 17)
        )
        let missingErrors = diagnostics.filter { $0.code == .missingDependency }
        XCTAssertEqual(missingErrors.count, missing.count)
        XCTAssertTrue(missingErrors.allSatisfy { $0.severity == .error })
    }

    func testValidateJavaVersionRequirement() throws {
        let fixture = try makeFixture(javaMajorRequirement: 17)
        let plan = try builder.build(
            version: fixture.version,
            context: fixture.context,
            dependencies: fixture.dependencies
        )

        let tooOld = builder.validate(
            version: fixture.version,
            context: fixture.context,
            plan: plan,
            dependencies: fixture.dependencies,
            java: makeJava(majorVersion: 8)
        )
        XCTAssertEqual(tooOld.filter { $0.code == .javaVersionMismatch }.count, 1)
        XCTAssertEqual(tooOld.first { $0.code == .javaVersionMismatch }?.severity, .error)

        let newer = builder.validate(
            version: fixture.version,
            context: fixture.context,
            plan: plan,
            dependencies: fixture.dependencies,
            java: makeJava(majorVersion: 21)
        )
        XCTAssertEqual(newer.filter { $0.code == .javaVersionMismatch }.count, 1)
        XCTAssertEqual(newer.first { $0.code == .javaVersionMismatch }?.severity, .warning)

        let missing = builder.validate(
            version: fixture.version,
            context: fixture.context,
            plan: plan,
            dependencies: fixture.dependencies,
            java: nil
        )
        XCTAssertEqual(missing.filter { $0.code == .javaNotFound }.count, 1)
        XCTAssertEqual(missing.first { $0.code == .javaNotFound }?.severity, .error)
    }

    func testValidateReportsLegacyX86NativeAgainstArm64Java() throws {
        let legacyNative = ResolvedNative(
            classifier: "natives-macos",
            file: ResolvedFile(path: URL(fileURLWithPath: "/tmp/libraries/lwjgl-natives-macos.jar")),
            architectureHint: .x86_64
        )
        let fixture = try makeFixture(legacyNatives: [legacyNative])
        let plan = try builder.build(
            version: fixture.version,
            context: fixture.context,
            dependencies: fixture.dependencies
        )

        let armJava = builder.validate(
            version: fixture.version,
            context: fixture.context,
            plan: plan,
            dependencies: fixture.dependencies,
            java: makeJava(majorVersion: 17, architecture: .arm64)
        )
        let mismatch = armJava.filter { $0.code == .javaArchitectureMismatch }
        XCTAssertEqual(mismatch.count, 1)
        XCTAssertEqual(mismatch.first?.severity, .error)
        XCTAssertTrue(mismatch.first?.message.contains("natives-macos") ?? false)

        let x86Java = builder.validate(
            version: fixture.version,
            context: fixture.context,
            plan: plan,
            dependencies: fixture.dependencies,
            java: makeJava(majorVersion: 17, architecture: .x86_64)
        )
        XCTAssertFalse(x86Java.contains { $0.code == .javaArchitectureMismatch })
    }

    func testValidateWarnsButDoesNotBlockForAbsentGameDirectory() throws {
        let fixture = try makeFixture(gameDirectoryExists: false)
        let plan = try builder.build(
            version: fixture.version,
            context: fixture.context,
            dependencies: fixture.dependencies
        )
        let diagnostics = builder.validate(
            version: fixture.version,
            context: fixture.context,
            plan: plan,
            dependencies: fixture.dependencies,
            java: makeJava(majorVersion: 17)
        )
        let ioFailure = diagnostics.filter { $0.code == .ioFailure }
        XCTAssertEqual(ioFailure.count, 1)
        XCTAssertEqual(ioFailure.first?.severity, .warning)
        XCTAssertFalse(diagnostics.contains { $0.severity == .error })
        XCTAssertFalse(diagnostics.isEmpty)
    }

    func testValidateRejectsMissingOrDuplicateClasspathFlag() throws {
        let noFlag = try makeFixture(jvmArguments: [.argument("-Xmx1G")])
        let noFlagPlan = try builder.build(
            version: noFlag.version,
            context: noFlag.context,
            dependencies: noFlag.dependencies
        )
        let noFlagDiagnostics = builder.validate(
            version: noFlag.version,
            context: noFlag.context,
            plan: noFlagPlan,
            dependencies: noFlag.dependencies,
            java: makeJava(majorVersion: 17)
        )
        XCTAssertTrue(noFlagDiagnostics.contains {
            $0.code == .invalidMetadata && $0.severity == .error && $0.message.contains("0 '-cp'")
        })

        let duplicate = try makeFixture(
            jvmArguments: [.argument("-cp"), .argument("-cp"), .argument("${classpath}")]
        )
        let duplicatePlan = try builder.build(
            version: duplicate.version,
            context: duplicate.context,
            dependencies: duplicate.dependencies
        )
        let duplicateDiagnostics = builder.validate(
            version: duplicate.version,
            context: duplicate.context,
            plan: duplicatePlan,
            dependencies: duplicate.dependencies,
            java: makeJava(majorVersion: 17)
        )
        XCTAssertTrue(duplicateDiagnostics.contains {
            $0.code == .invalidMetadata && $0.severity == .error && $0.message.contains("2 '-cp'")
        })
    }

    func testValidateRejectsEmptyMainClass() throws {
        let fixture = try makeFixture(mainClass: "   ")
        let plan = try builder.build(
            version: fixture.version,
            context: fixture.context,
            dependencies: fixture.dependencies
        )
        let diagnostics = builder.validate(
            version: fixture.version,
            context: fixture.context,
            plan: plan,
            dependencies: fixture.dependencies,
            java: makeJava(majorVersion: 17)
        )
        let invalidMetadata = diagnostics.filter { $0.code == .invalidMetadata }
        XCTAssertEqual(invalidMetadata.count, 1)
        XCTAssertTrue(invalidMetadata[0].message.contains("mainClass"), invalidMetadata[0].message)
    }

    // MARK: - Fixture end-to-end

    func testPreviewFromReal26_3Fixture() throws {
        let data = try FixtureLoader.data("versions/26.3.json")
        let metadata = try VersionMetadata.decode(from: data)
        let root = try FixtureLoader.temporaryDirectory("t06-fixture-26-3")
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }

        let layout = GameDataLayout(
            gameRoot: root.appendingPathComponent("minecraft", isDirectory: true),
            dataRoot: root.appendingPathComponent("data", isDirectory: true)
        )
        let versionDirectory = layout.versionsDirectory.appendingPathComponent("26.3", isDirectory: true)
        let metadataURL = versionDirectory.appendingPathComponent("26.3.json", isDirectory: false)
        let version = try VersionResolver().resolve(
            metadata: metadata,
            versionID: "26.3",
            versionDirectory: versionDirectory,
            metadataURL: metadataURL
        )

        // Dependency resolution is out of scope for T06: this synthetic resolution only mirrors
        // what a real resolver would produce, so the preview can be exercised end-to-end.
        var classpath: [URL] = []
        for library in metadata.libraries {
            if let relativePath = library.artifactRelativePath {
                classpath.append(try layout.libraryURL(relativePath: relativePath))
            }
        }
        XCTAssertGreaterThan(classpath.count, 100)
        let loggingPath = layout.loggingConfigsDirectory.appendingPathComponent("client-1.21.2.xml")
        let dependencies = DependencyResolution(
            layout: layout,
            classpath: classpath,
            classpathFiles: [],
            legacyNatives: [],
            nativesDirectory: root.appendingPathComponent("data/natives/26.3/arm64", isDirectory: true),
            clientJar: nil,
            assetIndexFile: nil,
            loggingFile: ResolvedFile(path: loggingPath),
            missing: [],
            diagnostics: []
        )

        let profile = try LocalOfflineIdentity.makeProfile(playerName: "FixtureUser")
        let instanceDirectory = root.appendingPathComponent("instances/fixture", isDirectory: true)
        let gameDirectory = instanceDirectory.appendingPathComponent(".minecraft", isDirectory: true)
        try FileManager.default.createDirectory(at: gameDirectory, withIntermediateDirectories: true)
        let javaExecutable = root.appendingPathComponent("jdk-25/bin/java", isDirectory: false)
        let context = LaunchContext(
            instanceDirectory: instanceDirectory,
            gameDirectory: gameDirectory,
            javaExecutable: javaExecutable,
            identity: .localOffline(profile),
            additionalJVMArguments: ["-Dlingxi.test=1"],
            features: [:]
        )
        let java = JavaRuntime(
            executable: javaExecutable,
            versionString: "25.0.1",
            majorVersion: 25,
            architecture: .arm64
        )

        let preview = try builder.preview(
            version: version,
            context: context,
            dependencies: dependencies,
            java: java
        )

        XCTAssertEqual(preview.versionID, "26.3")
        XCTAssertEqual(preview.mainClass, "net.minecraft.client.main.Main")
        XCTAssertEqual(preview.classpathEntryCount, classpath.count)
        XCTAssertEqual(preview.classpathEntries.count, classpath.count)
        XCTAssertEqual(preview.javaExecutable, javaExecutable)
        XCTAssertEqual(preview.gameDirectory, gameDirectory)
        XCTAssertEqual(argumentValue(after: "--username", in: preview.gameArguments), "FixtureUser")
        XCTAssertEqual(argumentValue(after: "--gameDir", in: preview.gameArguments), gameDirectory.path)
        XCTAssertEqual(
            argumentValue(after: "--accessToken", in: preview.gameArguments),
            LauncherInfo.redactionPlaceholder
        )
        // Feature-gated arguments (demo, custom resolution, quick play) are absent by default.
        XCTAssertFalse(preview.gameArguments.contains("--demo"))
        XCTAssertFalse(preview.gameArguments.contains("--width"))
        XCTAssertFalse(preview.gameArguments.contains("--quickPlayPath"))
        XCTAssertFalse(preview.gameArguments.contains { $0.contains("${") })

        XCTAssertTrue(preview.jvmArguments.contains("-Dlingxi.test=1"))
        XCTAssertTrue(preview.jvmArguments.contains("-Dlog4j.configurationFile=\(loggingPath.path)"))
        XCTAssertEqual(argumentValue(after: "-cp", in: preview.jvmArguments), classpath.map(\.path).joined(separator: ":"))
        if try PlatformContext.current().os == .macOS {
            XCTAssertTrue(preview.jvmArguments.contains("-XstartOnFirstThread"))
        }
        XCTAssertTrue(preview.diagnostics.isEmpty, "\(preview.diagnostics)")
        XCTAssertFalse(preview.hasBlockingDiagnostics)

        // The executable plan keeps the same structure and count, with only the token redacted.
        let plan = try builder.build(version: version, context: context, dependencies: dependencies)
        XCTAssertEqual(plan.arguments.count, plan.redactedArguments.count)
        XCTAssertEqual(plan.identityMode, .localOffline)
        XCTAssertEqual(argumentValue(after: "--accessToken", in: plan.arguments), "0")
        XCTAssertEqual(argumentValue(after: "--accessToken", in: plan.redactedArguments), LauncherInfo.redactionPlaceholder)
        XCTAssertEqual(plan.arguments.firstIndex(of: version.mainClass), preview.jvmArguments.count)
    }

    // MARK: - Helpers

    private func makeJava(
        majorVersion: Int,
        architecture: PlatformContext.CPUArch = .arm64
    ) -> JavaRuntime {
        JavaRuntime(
            executable: URL(fileURLWithPath: "/usr/bin/java"),
            versionString: "\(majorVersion).0.1",
            majorVersion: majorVersion,
            architecture: architecture
        )
    }

    private func argumentValue(after flag: String, in arguments: [String]) -> String? {
        guard let index = arguments.firstIndex(of: flag), arguments.indices.contains(index + 1) else {
            return nil
        }
        return arguments[index + 1]
    }

    private func makeFixture(
        identity: LaunchIdentity? = nil,
        features: [String: Bool] = [:],
        additionalJVMArguments: [String] = ["-Dlauncher.test=1"],
        classpathRelativePaths: [String] = ["a/a-1.0.jar", "b/b-2.0.jar"],
        jvmArguments: [ArgumentEntry]? = nil,
        gameArguments: [ArgumentEntry]? = nil,
        mainClass: String = "com.example.Main",
        javaMajorRequirement: Int? = 17,
        clientLogging: ClientLogging? = nil,
        includeLoggingFile: Bool = false,
        legacyNatives: [ResolvedNative] = [],
        missing: [MissingDependency] = [],
        dependencyDiagnostics: [LaunchDiagnostic] = [],
        gameDirectoryExists: Bool = true
    ) throws -> T06PlanFixture {
        let root = try FixtureLoader.temporaryDirectory("t06-launch-plan")
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }

        let layout = GameDataLayout(
            gameRoot: root.appendingPathComponent("minecraft", isDirectory: true),
            dataRoot: root.appendingPathComponent("data", isDirectory: true)
        )
        let instanceDirectory = root.appendingPathComponent("instances/test", isDirectory: true)
        let gameDirectory = instanceDirectory.appendingPathComponent(".minecraft", isDirectory: true)
        if gameDirectoryExists {
            try FileManager.default.createDirectory(at: gameDirectory, withIntermediateDirectories: true)
        }
        let classpath = classpathRelativePaths.map {
            layout.librariesDirectory.appendingPathComponent($0, isDirectory: false)
        }
        let nativesDirectory = root.appendingPathComponent("data/natives/test/arm64", isDirectory: true)
        let javaExecutable = root.appendingPathComponent("jdk/bin/java", isDirectory: false)
        let loggingFile = includeLoggingFile
            ? ResolvedFile(path: layout.loggingConfigsDirectory.appendingPathComponent("client.xml", isDirectory: false))
            : nil

        let resolvedIdentity: LaunchIdentity
        if let identity {
            resolvedIdentity = identity
        } else {
            resolvedIdentity = .localOffline(try LocalOfflineIdentity.makeProfile(playerName: "TestPlayer"))
        }

        let versionDirectory = layout.versionsDirectory.appendingPathComponent("test-version", isDirectory: true)
        let version = ResolvedVersion(
            id: "test-version",
            type: "release",
            mainClass: mainClass,
            assetIndexID: "5",
            javaRequirement: JavaVersionRequirement(component: "java-runtime-gamma", majorVersion: javaMajorRequirement),
            libraries: [],
            jvmArguments: jvmArguments ?? defaultJVMArguments,
            gameArguments: gameArguments ?? defaultGameArguments,
            defaultUserJVMArguments: [],
            assetIndex: nil,
            clientLogging: clientLogging,
            clientJar: nil,
            inheritsFrom: nil,
            versionDirectory: versionDirectory,
            metadataURL: try layout.versionJSONURL("test-version"),
            releaseTime: nil
        )
        let dependencies = DependencyResolution(
            layout: layout,
            classpath: classpath,
            classpathFiles: [],
            legacyNatives: legacyNatives,
            nativesDirectory: nativesDirectory,
            clientJar: nil,
            assetIndexFile: nil,
            loggingFile: loggingFile,
            missing: missing,
            diagnostics: dependencyDiagnostics
        )
        let context = LaunchContext(
            instanceDirectory: instanceDirectory,
            gameDirectory: gameDirectory,
            javaExecutable: javaExecutable,
            identity: resolvedIdentity,
            additionalJVMArguments: additionalJVMArguments,
            features: features,
            launcherName: "LingXi Launcher",
            launcherVersion: "0.1.0"
        )
        return T06PlanFixture(
            root: root,
            layout: layout,
            instanceDirectory: instanceDirectory,
            gameDirectory: gameDirectory,
            javaExecutable: javaExecutable,
            nativesDirectory: nativesDirectory,
            classpath: classpath,
            version: version,
            dependencies: dependencies,
            context: context
        )
    }
}
