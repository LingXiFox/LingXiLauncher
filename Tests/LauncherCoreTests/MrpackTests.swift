import XCTest
import MacPlatform
@testable import LauncherCore

final class MrpackTests: XCTestCase {
    private var root: URL!
    private var layout: GameDataLayout!

    override func setUpWithError() throws {
        MacPlatform.install()
        root = try FixtureLoader.temporaryDirectory("lingxi-mrpack")
        layout = GameDataLayout(
            gameRoot: root.appendingPathComponent("mc", isDirectory: true),
            dataRoot: root.appendingPathComponent("data", isDirectory: true)
        )
    }

    override func tearDownWithError() throws {
        if let root { try? FileManager.default.removeItem(at: root) }
    }

    func testParsesFormatOneFabricPackAndClientOverrides() throws {
        let extraction = root.appendingPathComponent("extract", isDirectory: true)
        let package = try MrpackParser.parse(
            archive: try FixtureLoader.url("mrpack/fixture-fabric.mrpack"),
            extractionRoot: extraction
        )
        XCTAssertEqual(package.name, "Fixture Fabric Pack")
        XCTAssertEqual(package.minecraftVersion, "1.20.1")
        XCTAssertEqual(package.loader, .fabric(loaderVersion: "0.20.1"))
        XCTAssertEqual(package.files.count, 1)
        XCTAssertEqual(package.files.first?.relativePath, "mods/fixture.jar")
        XCTAssertEqual(package.skippedClientUnsupported, 1)
        XCTAssertEqual(package.overrides.count, 3)
        let override = try XCTUnwrap(package.overrides.first { $0.relativePath == "config/fixture.txt" })
        XCTAssertEqual(try String(contentsOf: override.sourceURL, encoding: .utf8), "client override")
        XCTAssertTrue(FileManager.default.fileExists(atPath: extraction.path))
    }

    func testParsesNeoForgePackDependency() throws {
        let package = try MrpackParser.parse(
            archive: try FixtureLoader.url("mrpack/fixture-neoforge.mrpack"),
            extractionRoot: root.appendingPathComponent("neoforge-extract", isDirectory: true)
        )
        XCTAssertEqual(package.loader, .neoforge(loaderVersion: "21.1.265"))
        XCTAssertEqual(package.minecraftVersion, "1.21.1")
        XCTAssertEqual(package.name, "NeoForge Fixture Pack")
    }

    func testRejectsUnsafeOrUnverifiableManifestFiles() throws {
        let cases: [(String, LauncherError.Code)] = [
            ("mrpack/bad-path.mrpack", .pathEscapesRoot),
            ("mrpack/bad-download.mrpack", .invalidMetadata),
            ("mrpack/bad-hash.mrpack", .invalidMetadata),
            ("mrpack/unsupported-loader.mrpack", .unsupportedVersion),
            ("mrpack/bad-format.mrpack", .unsupportedVersion),
        ]
        for (index, item) in cases.enumerated() {
            let extraction = root.appendingPathComponent("bad-\(index)", isDirectory: true)
            XCTAssertThrowsError(
                try MrpackParser.parse(
                    archive: try FixtureLoader.url(item.0),
                    extractionRoot: extraction
                ),
                item.0
            ) { error in
                XCTAssertEqual((error as? LauncherError)?.code, item.1, item.0)
            }
            XCTAssertFalse(FileManager.default.fileExists(atPath: extraction.path), "parser must clean failed extraction")
        }
    }

    func testInstallsPackIntoFreshInstanceAndCommitsOverrides() async throws {
        guard let java = try? JavaRuntimeInspector().discoverDefaultExecutable() else {
            throw XCTSkip("No Java runtime available for the synthetic mrpack install test")
        }
        let fixture = try SyntheticInstallation()
        let transport = StubTransport()
        await fixture.populate(transport)
        let packURL = URL(string: "https://cdn.modrinth.com/data/pack/versions/1/pack.jar")!
        await transport.setData(Data("pack-data".utf8), for: packURL)
        let extraction = root.appendingPathComponent("install-extract", isDirectory: true)
        let package = try MrpackParser.parse(
            archive: try FixtureLoader.url("mrpack/fixture-test-version.mrpack"),
            extractionRoot: extraction
        )
        let installer = MrpackInstaller(layout: layout, transport: transport)
        let report = try await installer.install(
            MrpackInstallRequest(
                package: package,
                displayName: "Synthetic Pack",
                javaExecutable: java,
                sourcePolicy: .official
            ),
            progress: { _ in }
        )
        XCTAssertEqual(report.minecraftVersionID, "test-version")
        XCTAssertEqual(report.loader, .vanilla)
        let instances = try InstanceRepository(layout: layout).list()
        XCTAssertEqual(instances.count, 1)
        let installed = try XCTUnwrap(instances.first)
        XCTAssertEqual(installed.id, report.instanceID)
        XCTAssertEqual(
            try String(contentsOf: installed.gameDirectory.appendingPathComponent("mods/pack.jar"), encoding: .utf8),
            "pack-data"
        )
        XCTAssertEqual(
            try String(contentsOf: installed.gameDirectory.appendingPathComponent("config/pack.txt"), encoding: .utf8),
            "client-pack"
        )
        XCTAssertTrue(FileManager.default.fileExists(atPath: installed.gameDirectory.appendingPathComponent("config/pack.txt").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: extraction.path), "successful install owns and removes the temporary tree")
    }

    func testOptionalClientFilesRequireExplicitSelection() async throws {
        guard let java = try? JavaRuntimeInspector().discoverDefaultExecutable() else {
            throw XCTSkip("No Java runtime available for the synthetic mrpack install test")
        }
        let fixture = try SyntheticInstallation()
        let optionalData = Data("optional-mod|exact-bytes".utf8)
        let optionalURL = URL(string: "https://cdn.modrinth.com/data/pack/versions/1/optional.jar")!
        let optionalFile = MrpackFile(
            relativePath: "mods/optional.jar",
            sha1: SHA1.hexDigest(optionalData),
            sha512: SHA512Digest.hexDigest(optionalData),
            downloadURL: optionalURL,
            fileSize: optionalData.count,
            clientEnvironment: "optional"
        )

        func makePackage(_ name: String) throws -> MrpackPackage {
            let parsed = try MrpackParser.parse(
                archive: try FixtureLoader.url("mrpack/fixture-test-version.mrpack"),
                extractionRoot: root.appendingPathComponent(name, isDirectory: true)
            )
            return MrpackPackage(
                archiveURL: parsed.archiveURL,
                archiveSHA256: parsed.archiveSHA256,
                name: parsed.name,
                versionID: parsed.versionID,
                summary: parsed.summary,
                minecraftVersion: parsed.minecraftVersion,
                loader: parsed.loader,
                files: parsed.files + [optionalFile],
                overrides: parsed.overrides,
                skippedClientUnsupported: parsed.skippedClientUnsupported,
                extractionRoot: parsed.extractionRoot
            )
        }

        let transport = StubTransport()
        await fixture.populate(transport)
        await transport.setData(Data("pack-data".utf8), for: URL(string: "https://cdn.modrinth.com/data/pack/versions/1/pack.jar")!)
        await transport.setData(optionalData, for: optionalURL)
        let installer = MrpackInstaller(layout: layout, transport: transport)

        let off = try makePackage("optional-off-extract")
        let offReport = try await installer.install(
            MrpackInstallRequest(package: off, displayName: "Optional Off", javaExecutable: java, sourcePolicy: .official),
            progress: { _ in }
        )
        XCTAssertEqual(offReport.downloadedFiles, 1)
        let requestedAfterOff = await transport.requestedURLs
        XCTAssertFalse(requestedAfterOff.contains(optionalURL.absoluteString))
        let offInstance = try XCTUnwrap(try InstanceRepository(layout: layout).list().first { $0.id == offReport.instanceID })
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: offInstance.gameDirectory.appendingPathComponent("mods/optional.jar").path
        ))

        let on = try makePackage("optional-on-extract")
        let onReport = try await installer.install(
            MrpackInstallRequest(
                package: on,
                displayName: "Optional On",
                javaExecutable: java,
                sourcePolicy: .official,
                selectedOptionalPaths: [optionalFile.relativePath]
            ),
            progress: { _ in }
        )
        XCTAssertEqual(onReport.downloadedFiles, 2)
        let requestedAfterOn = await transport.requestedURLs
        XCTAssertTrue(requestedAfterOn.contains(optionalURL.absoluteString))
        let onInstance = try XCTUnwrap(try InstanceRepository(layout: layout).list().first { $0.id == onReport.instanceID })
        XCTAssertEqual(
            try Data(contentsOf: onInstance.gameDirectory.appendingPathComponent("mods/optional.jar")),
            optionalData
        )
    }

    func testNetworkFailureLeavesNoInstanceAndRetryUsesSamePackage() async throws {
        guard let java = try? JavaRuntimeInspector().discoverDefaultExecutable() else {
            throw XCTSkip("No Java runtime available for the synthetic mrpack install test")
        }
        let fixture = try SyntheticInstallation()
        let transport = StubTransport()
        await fixture.populate(transport)
        let packURL = URL(string: "https://cdn.modrinth.com/data/pack/versions/1/pack.jar")!
        await transport.setFailure(.network("offline"), for: packURL, times: 3)
        let firstPackage = try MrpackParser.parse(
            archive: try FixtureLoader.url("mrpack/fixture-test-version.mrpack"),
            extractionRoot: root.appendingPathComponent("retry-1", isDirectory: true)
        )
        let installer = MrpackInstaller(layout: layout, transport: transport)
        do {
            _ = try await installer.install(
                MrpackInstallRequest(package: firstPackage, displayName: "Retry Pack", javaExecutable: java, sourcePolicy: .official),
                progress: { _ in }
            )
            XCTFail("Expected network failure")
        } catch {
            XCTAssertEqual((error as? LauncherError)?.code, .downloadFailed)
        }
        XCTAssertTrue(try InstanceRepository(layout: layout).list().isEmpty)
        XCTAssertTrue(FileManager.default.fileExists(atPath: firstPackage.extractionRoot.path), "failure must preserve the validated package for retry")

        await transport.setData(Data("pack-data".utf8), for: packURL)
        let report = try await installer.install(
            MrpackInstallRequest(package: firstPackage, displayName: "Retry Pack", javaExecutable: java, sourcePolicy: .official),
            progress: { _ in }
        )
        XCTAssertEqual(report.installedFiles, 2)
        XCTAssertEqual(try InstanceRepository(layout: layout).list().count, 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: firstPackage.extractionRoot.path), "retry success consumes the package")
    }

    func testCancellationPreservesPackageAndRetrySucceeds() async throws {
        guard let java = try? JavaRuntimeInspector().discoverDefaultExecutable() else {
            throw XCTSkip("No Java runtime available for the synthetic mrpack install test")
        }
        let fixture = try SyntheticInstallation()
        let transport = StubTransport(delay: 0.5)
        await fixture.populate(transport)
        await transport.setData(Data("pack-data".utf8), for: URL(string: "https://cdn.modrinth.com/data/pack/versions/1/pack.jar")!)
        let package = try MrpackParser.parse(
            archive: try FixtureLoader.url("mrpack/fixture-test-version.mrpack"),
            extractionRoot: root.appendingPathComponent("cancel", isDirectory: true)
        )
        let installer = MrpackInstaller(layout: layout, transport: transport)
        for _ in 0..<2 {
            let task = Task {
                try await installer.install(
                    MrpackInstallRequest(package: package, displayName: "Cancel Pack", javaExecutable: java, sourcePolicy: .official),
                    progress: { _ in }
                )
            }
            try await Task.sleep(nanoseconds: 150_000_000)
            task.cancel()
            do {
                _ = try await task.value
                XCTFail("Expected cancellation")
            } catch is CancellationError {
                // expected
            } catch {
                // Downloader may surface a cancellation as a download failure; either way no commit.
            }
            XCTAssertTrue(try InstanceRepository(layout: layout).list().isEmpty)
            XCTAssertTrue(FileManager.default.fileExists(atPath: package.extractionRoot.path), "every cancellation must preserve the package for retry")
        }

        await transport.setData(Data("pack-data".utf8), for: URL(string: "https://cdn.modrinth.com/data/pack/versions/1/pack.jar")!)
        let report = try await installer.install(
            MrpackInstallRequest(package: package, displayName: "Cancel Pack", javaExecutable: java, sourcePolicy: .official),
            progress: { _ in }
        )
        XCTAssertEqual(report.installedFiles, 2)
        XCTAssertEqual(try InstanceRepository(layout: layout).list().count, 1)
    }

    func testDamagedPackFileDoesNotCreateInstance() async throws {
        guard let java = try? JavaRuntimeInspector().discoverDefaultExecutable() else {
            throw XCTSkip("No Java runtime available for the synthetic mrpack install test")
        }
        let fixture = try SyntheticInstallation()
        let transport = StubTransport()
        await fixture.populate(transport)
        await transport.setData(Data("wrong-bytes".utf8), for: URL(string: "https://cdn.modrinth.com/data/pack/versions/1/pack.jar")!)
        let package = try MrpackParser.parse(
            archive: try FixtureLoader.url("mrpack/fixture-test-version.mrpack"),
            extractionRoot: root.appendingPathComponent("damaged-extract", isDirectory: true)
        )
        let installer = MrpackInstaller(layout: layout, transport: transport)
        do {
            _ = try await installer.install(
                MrpackInstallRequest(package: package, displayName: "Damaged Pack", javaExecutable: java, sourcePolicy: .official),
                progress: { _ in }
            )
            XCTFail("Expected hash/size failure")
        } catch {
            XCTAssertTrue([LauncherError.Code.sizeMismatch, .hashMismatch, .downloadFailed].contains((error as? LauncherError)?.code))
        }
        XCTAssertTrue(try InstanceRepository(layout: layout).list().isEmpty)
    }

    func testRejectsArchiveTraversalAndSymlinkBeforeIndex() throws {
        for (name, extractionName) in [("zip/native_traversal.zip", "traversal"), ("zip/native_symlink.zip", "symlink")] {
            let extraction = root.appendingPathComponent(extractionName, isDirectory: true)
            XCTAssertThrowsError(
                try MrpackParser.parse(
                    archive: try FixtureLoader.url(name),
                    extractionRoot: extraction
                ),
                name
            ) { error in
                XCTAssertEqual((error as? LauncherError)?.code, .pathEscapesRoot, name)
            }
            XCTAssertFalse(FileManager.default.fileExists(atPath: extraction.path))
        }
    }

    func testTrustedDownloadHostsAndRedirectSafety() throws {
        XCTAssertTrue(MrpackParser.isTrustedDownloadURL(URL(string: "https://cdn.modrinth.com/data/x/versions/1/x.jar")!))
        XCTAssertTrue(MrpackParser.isTrustedDownloadURL(URL(string: "https://github.com/owner/repo/releases/download/v1/x.jar")!))
        XCTAssertTrue(MrpackParser.isTrustedDownloadURL(URL(string: "https://raw.githubusercontent.com/owner/repo/main/x.jar")!))
        XCTAssertTrue(MrpackParser.isTrustedDownloadURL(URL(string: "https://gitlab.com/owner/repo/-/raw/main/x.jar")!))
        for bad in [
            "https://evil.example/x.jar",
            "http://cdn.modrinth.com/x.jar",
            "https://cdn.modrinth.com.evil.example/x.jar",
            "https://cdn.modrinth.com:444/x.jar",
            "https://user:pass@cdn.modrinth.com/x.jar",
            "https://cdn.modrinth.com/",
        ] {
            XCTAssertFalse(MrpackParser.isTrustedDownloadURL(URL(string: bad)!), bad)
        }
    }


    func testRedirectPolicyRejectsInsecureOrCredentialedTargets() {
        XCTAssertNoThrow(try DownloadRedirectPolicy.validate(
            URL(string: "https://objects.githubusercontent.com/github-production-release-asset/file.jar")!
        ))
        for bad in [
            "http://cdn.modrinth.com/file.jar",
            "https://user:pass@cdn.modrinth.com/file.jar",
            "https://cdn.modrinth.com:444/file.jar",
            "ftp://cdn.modrinth.com/file.jar",
        ] {
            XCTAssertThrowsError(try DownloadRedirectPolicy.validate(URL(string: bad)!), bad)
        }
    }

    func testExistingInstanceIsNeverTouchedByNewPackInstall() async throws {
        guard let java = try? JavaRuntimeInspector().discoverDefaultExecutable() else {
            throw XCTSkip("No Java runtime available for the synthetic mrpack install test")
        }
        let fixture = try SyntheticInstallation()
        let transport = StubTransport()
        await fixture.populate(transport)

        let repository = InstanceRepository(layout: layout)
        let existing = try repository.create(id: "keep-me", displayName: "Keep Me", versionID: "test-version")
        let world = existing.gameDirectory.appendingPathComponent("saves/keep/world", isDirectory: true)
        try FileManager.default.createDirectory(at: world, withIntermediateDirectories: true)
        let level = world.appendingPathComponent("level.dat")
        let sentinel = Data("existing-world-must-survive".utf8)
        try sentinel.write(to: level)
        let options = existing.gameDirectory.appendingPathComponent("options.txt")
        try Data("fov:0.5\n".utf8).write(to: options)

        await transport.setData(
            Data("pack-data".utf8),
            for: URL(string: "https://cdn.modrinth.com/data/pack/versions/1/pack.jar")!
        )
        let package = try MrpackParser.parse(
            archive: try FixtureLoader.url("mrpack/fixture-test-version.mrpack"),
            extractionRoot: root.appendingPathComponent("existing-safe", isDirectory: true)
        )
        let report = try await MrpackInstaller(layout: layout, transport: transport).install(
            MrpackInstallRequest(
                package: package,
                displayName: "Separate Pack",
                javaExecutable: java,
                sourcePolicy: .official
            ),
            progress: { _ in }
        )

        XCTAssertNotEqual(report.instanceID, existing.id)
        XCTAssertEqual(try Data(contentsOf: level), sentinel)
        XCTAssertEqual(try String(contentsOf: options, encoding: .utf8), "fov:0.5\n")
        XCTAssertEqual(try repository.list().count, 2)
        let installed = try XCTUnwrap(repository.list().first { $0.id == report.instanceID })
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: installed.gameDirectory.appendingPathComponent("saves/keep").path
        ))
    }

    func testRejectsMissingIndex() throws {
        let archive = root.appendingPathComponent("empty.mrpack")
        let emptyRoot = root.appendingPathComponent("empty", isDirectory: true)
        try FileManager.default.createDirectory(at: emptyRoot, withIntermediateDirectories: true)
        let zip = emptyRoot.appendingPathComponent("empty.zip")
        try Data("not a zip".utf8).write(to: zip)
        // A non-ZIP archive is rejected before any index lookup.
        XCTAssertThrowsError(
            try MrpackParser.parse(archive: zip, extractionRoot: root.appendingPathComponent("badzip", isDirectory: true))
        )
        _ = archive
    }
}
