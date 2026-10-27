import XCTest
@testable import LauncherCore

final class ManifestTests: XCTestCase {
    func testDecodesTrimmedManifest() throws {
        let data = try FixtureLoader.data("manifest/version_manifest_trimmed.json")
        let manifest = try VersionManifest.decode(from: data)
        XCTAssertEqual(manifest.latest.release, "26.3")
        XCTAssertEqual(manifest.latest.snapshot, "26.4-snapshot-5")
        XCTAssertEqual(manifest.versions.count, 3)
        let entry = try XCTUnwrap(manifest.entry(for: "26.3"))
        XCTAssertEqual(entry.type, .release)
        XCTAssertEqual(entry.sha1, "61fff1316bd50312624a858bbb5eb18fa45208ed")
        XCTAssertEqual(entry.url?.host, "piston-meta.mojang.com")
        XCTAssertEqual(manifest.latestRelease()?.id, "26.3")
        XCTAssertEqual(manifest.entry(for: "26.4-snapshot-5")?.type, .snapshot)
        XCTAssertNil(manifest.entry(for: "nope"))
    }

    func testBrokenJSONReportsInvalidMetadata() throws {
        let data = try FixtureLoader.data("invalid/manifest_invalid_json.json")
        XCTAssertThrowsError(try VersionManifest.decode(from: data)) { error in
            guard let launcherError = error as? LauncherError else {
                return XCTFail("Expected LauncherError, got \(error)")
            }
            XCTAssertEqual(launcherError.code, .invalidMetadata)
        }
    }

    func testMissingRequiredFieldReportsInvalidMetadata() throws {
        let data = try FixtureLoader.data("invalid/manifest_missing_url.json")
        XCTAssertThrowsError(try VersionManifest.decode(from: data)) { error in
            guard let launcherError = error as? LauncherError else {
                return XCTFail("Expected LauncherError, got \(error)")
            }
            XCTAssertEqual(launcherError.code, .invalidMetadata)
            XCTAssertTrue(launcherError.message.contains("url"), launcherError.message)
        }
    }

    func testUnknownVersionTypeIsExplicitError() throws {
        let json = """
        {"latest":{"release":"a","snapshot":"b"},"versions":[{"id":"a","type":"experimental","url":"https://example.invalid/a.json"}]}
        """
        XCTAssertThrowsError(try VersionManifest.decode(from: Data(json.utf8))) { error in
            XCTAssertEqual((error as? LauncherError)?.code, .invalidMetadata)
        }
    }
}

final class VersionMetadataTests: XCTestCase {
    func testDecodesModernManifest_26_3() throws {
        let data = try FixtureLoader.data("versions/26.3.json")
        let metadata = try VersionMetadata.decode(from: data)
        XCTAssertEqual(metadata.id, "26.3")
        XCTAssertEqual(metadata.type, "release")
        XCTAssertEqual(metadata.mainClass, "net.minecraft.client.main.Main")
        XCTAssertEqual(metadata.assets, "34")
        XCTAssertEqual(metadata.assetIndex?.id, "34")
        // Real metadata uses "url"; the model must not expect "urlString".
        XCTAssertEqual(metadata.assetIndex?.url?.host, "piston-meta.mojang.com")
        XCTAssertEqual(metadata.assetIndex?.size, 597035)
        XCTAssertEqual(metadata.javaVersion?.majorVersion, 25)
        XCTAssertEqual(metadata.javaVersion?.component, "java-runtime-epsilon")
        XCTAssertEqual(metadata.libraries.count, 114)
        XCTAssertEqual(metadata.downloads?.client?.sha1, "e877b6a07acd633fb3bb475002175cec036e7b87")
        XCTAssertEqual(metadata.arguments?.game.isEmpty, false)
        XCTAssertEqual(metadata.arguments?.jvm.isEmpty, false)
        XCTAssertNil(metadata.minecraftArguments)
        XCTAssertNil(metadata.inheritsFrom)
        // Newer metadata carries launcher-side default JVM flags inside `arguments`.
        XCTAssertFalse(metadata.arguments?.defaultUserJVMArguments.isEmpty ?? true)
        // Modern versions ship natives as ordinary libraries: no legacy classifiers anywhere.
        XCTAssertTrue(metadata.libraries.allSatisfy { $0.natives == nil && $0.classifiers == nil })
        XCTAssertTrue(metadata.libraries.contains { $0.name.hasSuffix(":natives-macos-arm64") })
    }

    func testDecodesLegacyNatives_1_16_5() throws {
        let data = try FixtureLoader.data("versions/1.16.5.json")
        let metadata = try VersionMetadata.decode(from: data)
        XCTAssertEqual(metadata.id, "1.16.5")
        XCTAssertEqual(metadata.javaVersion?.majorVersion, 8)
        let nativeLibraries = metadata.libraries.filter { $0.natives != nil }
        XCTAssertEqual(nativeLibraries.count, 16)
        let lwjgl = try XCTUnwrap(nativeLibraries.first { $0.name == "org.lwjgl:lwjgl:3.2.1" })
        XCTAssertEqual(lwjgl.natives?["osx"], "natives-macos")
        XCTAssertNotNil(lwjgl.classifiers?["natives-macos"]?.sha1)
        // `extract.exclude` is only declared on some native JARs (e.g. text2speech, java-objc-bridge).
        // 1.16.5 declares text2speech twice: a plain artifact and a natives variant. Only the
        // natives entry carries `extract`.
        let extracted = try XCTUnwrap(metadata.libraries.first { $0.name == "com.mojang:text2speech:1.11.3" && $0.extractExclude != nil })
        XCTAssertEqual(extracted.extractExclude?.contains("META-INF/"), true)
        XCTAssertEqual(metadata.libraries.filter { $0.extractExclude != nil }.count, 2)
        // Logging descriptors carry an id (used for assets/log_configs/<id>).
        XCTAssertEqual(metadata.logging?.client?.file.id, "client-1.12.xml")
    }

    func testArgumentEntryExpandsArrayValues() throws {
        let data = try FixtureLoader.data("versions/26.3.json")
        let metadata = try VersionMetadata.decode(from: data)
        let entries = try XCTUnwrap(metadata.arguments?.game)
        let conditional = entries.compactMap { entry -> ArgumentEntry? in
            if case let .conditional(rules, values) = entry, values.contains("--width") { return .conditional(rules: rules, values: values) }
            return nil
        }
        let widthEntry = try XCTUnwrap(conditional.first)
        guard case let .conditional(rules, values) = widthEntry else { return XCTFail("expected conditional") }
        XCTAssertEqual(values, ["--width", "${resolution_width}", "--height", "${resolution_height}"])
        XCTAssertEqual(rules.first?.features?["has_custom_resolution"], true)
    }

    func testUnknownRuleFieldIsRejected() throws {
        let data = try FixtureLoader.data("invalid/version_unknown_rule_field.json")
        XCTAssertThrowsError(try VersionMetadata.decode(from: data)) { error in
            guard let launcherError = error as? LauncherError else {
                return XCTFail("Expected LauncherError, got \(error)")
            }
            XCTAssertEqual(launcherError.code, .unsupportedVersion)
            XCTAssertTrue(launcherError.message.contains("unknownPlatformFlag"), launcherError.message)
        }
    }

    func testMissingRequiredFieldIsInvalidMetadata() throws {
        let json = #"{"type":"release","mainClass":"X","libraries":[]}"#
        XCTAssertThrowsError(try VersionMetadata.decode(from: Data(json.utf8))) { error in
            XCTAssertEqual((error as? LauncherError)?.code, .invalidMetadata)
        }
    }

    func testMavenCoordinatesAndDerivedPath() throws {
        let coordinates = try XCTUnwrap(MavenCoordinates(name: "org.lwjgl:lwjgl:3.4.3:natives-macos-arm64"))
        XCTAssertEqual(coordinates.group, "org.lwjgl")
        XCTAssertEqual(coordinates.artifact, "lwjgl")
        XCTAssertEqual(coordinates.version, "3.4.3")
        XCTAssertEqual(coordinates.classifier, "natives-macos-arm64")
        XCTAssertEqual(coordinates.relativePath, "org/lwjgl/lwjgl/3.4.3/lwjgl-3.4.3-natives-macos-arm64.jar")
        XCTAssertNil(MavenCoordinates(name: "broken"))
    }

    func testVersionRangeDecodes() throws {
        let json = #"{"latest":{"release":"a","snapshot":"b"},"versions":[]}"#
        XCTAssertNoThrow(try VersionManifest.decode(from: Data(json.utf8)))
        let rangeJSON = #"{"min":"10.0.17134"}"#
        let range = try JSONDecoder().decode(VersionRange.self, from: Data(rangeJSON.utf8))
        XCTAssertEqual(range.min, "10.0.17134")
        XCTAssertNil(range.max)
    }
}

final class VersionResolverTests: XCTestCase {
    private func makeGameRoot(fixturePath: String, versionID: String) throws -> URL {
        let root = try FixtureLoader.temporaryDirectory("lingxi-resolver")
        let versionDirectory = root.appendingPathComponent("versions/\(versionID)", isDirectory: true)
        try FileManager.default.createDirectory(at: versionDirectory, withIntermediateDirectories: true)
        try FileManager.default.copyItem(
            at: try FixtureLoader.url(fixturePath),
            to: versionDirectory.appendingPathComponent("\(versionID).json")
        )
        return root
    }

    func testResolvesVersionFromGameRoot() throws {
        let root = try makeGameRoot(fixturePath: "versions/26.3.json", versionID: "26.3")
        defer { try? FileManager.default.removeItem(at: root) }
        let resolved = try VersionResolver().resolve(versionID: "26.3", from: root)
        XCTAssertEqual(resolved.id, "26.3")
        XCTAssertEqual(resolved.mainClass, "net.minecraft.client.main.Main")
        XCTAssertEqual(resolved.assetIndexID, "34")
        XCTAssertEqual(resolved.javaRequirement.majorVersion, 25)
        XCTAssertEqual(resolved.libraries.count, 114)
        XCTAssertEqual(resolved.gameArguments.isEmpty, false)
        XCTAssertEqual(resolved.jvmArguments.isEmpty, false)
        XCTAssertEqual(resolved.clientJar?.sha1, "e877b6a07acd633fb3bb475002175cec036e7b87")
        XCTAssertNil(resolved.inheritsFrom)
        XCTAssertEqual(resolved.metadataURL.lastPathComponent, "26.3.json")
    }

    func testMissingMetadataReportsMissingDependency() throws {
        let root = try FixtureLoader.temporaryDirectory("lingxi-resolver-missing")
        defer { try? FileManager.default.removeItem(at: root) }
        XCTAssertThrowsError(try VersionResolver().resolve(versionID: "99.9", from: root)) { error in
            XCTAssertEqual((error as? LauncherError)?.code, .missingDependency)
        }
    }

    func testLegacyArgumentsAreNormalizedButMarkedLegacy() throws {
        let root = try makeGameRoot(fixturePath: "invalid/version_legacy_arguments.json", versionID: "synthetic-legacy")
        defer { try? FileManager.default.removeItem(at: root) }
        let resolved = try VersionResolver().resolve(versionID: "synthetic-legacy", from: root)
        XCTAssertEqual(resolved.compatibility, .legacyArguments)
        XCTAssertEqual(resolved.gameArguments.count, 4)
        XCTAssertTrue(resolved.gameArguments.contains(.argument("${auth_player_name}")))
        XCTAssertTrue(resolved.jvmArguments.contains(.argument("-cp")))
    }

    func testInheritanceMergesParentAndChild() throws {
        let root = try FixtureLoader.temporaryDirectory("lingxi-resolver-inheritance")
        defer { try? FileManager.default.removeItem(at: root) }
        for (id, fixture) in [
            ("1.20.1", "versions/1.20.1.json"),
            ("synthetic-inherits", "invalid/version_inherits.json"),
        ] {
            let directory = root.appendingPathComponent("versions/\(id)", isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try FileManager.default.copyItem(
                at: try FixtureLoader.url(fixture),
                to: directory.appendingPathComponent("\(id).json")
            )
        }
        let resolved = try VersionResolver().resolve(versionID: "synthetic-inherits", from: root)
        XCTAssertEqual(resolved.mainClass, "net.fabricmc.loader.impl.launch.knot.KnotClient")
        XCTAssertEqual(resolved.inheritsFrom, "1.20.1")
        XCTAssertEqual(resolved.clientJarVersionID, "1.20.1")
        XCTAssertEqual(resolved.javaRequirement.majorVersion, 17)
        XCTAssertFalse(resolved.gameArguments.isEmpty)
        XCTAssertTrue(resolved.jvmArguments.contains(.argument("-cp")))
    }

    func testMissingParentIsExplicit() throws {
        let root = try makeGameRoot(fixturePath: "invalid/version_inherits.json", versionID: "synthetic-inherits")
        defer { try? FileManager.default.removeItem(at: root) }
        XCTAssertThrowsError(try VersionResolver().resolve(versionID: "synthetic-inherits", from: root)) { error in
            XCTAssertEqual((error as? LauncherError)?.code, .missingDependency)
        }
    }

    func testCircularInheritanceIsRejected() throws {
        let root = try FixtureLoader.temporaryDirectory("lingxi-resolver-cycle")
        defer { try? FileManager.default.removeItem(at: root) }
        for id in ["a", "b"] {
            let directory = root.appendingPathComponent("versions/\(id)", isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let json = """
            {"id":"\(id)","mainClass":"x.Main","inheritsFrom":"\(id == "a" ? "b" : "a")","libraries":[],"arguments":{"game":[],"jvm":[]}}
            """
            try Data(json.utf8).write(to: directory.appendingPathComponent("\(id).json"))
        }
        XCTAssertThrowsError(try VersionResolver().resolve(versionID: "a", from: root)) { error in
            XCTAssertEqual((error as? LauncherError)?.code, .invalidMetadata)
            XCTAssertTrue((error as? LauncherError)?.message.contains("Circular") == true)
        }
    }

    func testRealFabricProfileInheritanceAndLibraryMerge() throws {
        let root = try FixtureLoader.temporaryDirectory("lingxi-resolver-fabric")
        defer { try? FileManager.default.removeItem(at: root) }
        for (id, fixture) in [
            ("1.20.1", "versions/1.20.1.json"),
            ("fabric-loader-0.20.1-1.20.1", "versions/fabric-loader-0.20.1-1.20.1.json"),
        ] {
            let directory = root.appendingPathComponent("versions/\(id)", isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try FileManager.default.copyItem(
                at: try FixtureLoader.url(fixture),
                to: directory.appendingPathComponent("\(id).json")
            )
        }
        let resolved = try VersionResolver().resolve(versionID: "fabric-loader-0.20.1-1.20.1", from: root)
        XCTAssertEqual(resolved.mainClass, "net.fabricmc.loader.impl.launch.knot.KnotClient")
        XCTAssertEqual(resolved.inheritsFrom, "1.20.1")
        XCTAssertEqual(resolved.clientJarVersionID, "1.20.1")
        XCTAssertEqual(resolved.assetIndexID, "5")
        XCTAssertEqual(resolved.javaRequirement.majorVersion, 17)
        XCTAssertEqual(resolved.compatibility, .modern)
        let asm = try XCTUnwrap(resolved.libraries.first { $0.name.hasPrefix("org.ow2.asm:asm:") })
        XCTAssertEqual(asm.name, "org.ow2.asm:asm:9.10.1")
        XCTAssertNotNil(asm.mavenArtifactURL)
        XCTAssertEqual(resolved.libraries.filter { $0.name.hasPrefix("org.ow2.asm:asm:") }.count, 1)
        XCTAssertTrue(resolved.jvmArguments.contains(.argument("-DFabricMcEmu= net.minecraft.client.main.Main ")))
        XCTAssertTrue(resolved.gameArguments.contains(.argument("--username")))
    }

    func testIDMismatchIsRejected() throws {
        let root = try makeGameRoot(fixturePath: "versions/1.20.1.json", versionID: "26.3")
        defer { try? FileManager.default.removeItem(at: root) }
        XCTAssertThrowsError(try VersionResolver().resolve(versionID: "26.3", from: root)) { error in
            XCTAssertEqual((error as? LauncherError)?.code, .invalidMetadata)
        }
    }
}
