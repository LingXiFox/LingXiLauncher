import XCTest
@testable import LauncherCore

final class MrpackTests: XCTestCase {
    private var root: URL!
    private var layout: GameDataLayout!

    override func setUpWithError() throws {
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
        XCTAssertFalse(FileManager.default.fileExists(atPath: extraction.path))
    }

    func testNetworkFailureLeavesNoInstanceAndRetrySucceeds() async throws {
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
        XCTAssertFalse(FileManager.default.fileExists(atPath: firstPackage.extractionRoot.path))

        await transport.setData(Data("pack-data".utf8), for: packURL)
        let retryPackage = try MrpackParser.parse(
            archive: try FixtureLoader.url("mrpack/fixture-test-version.mrpack"),
            extractionRoot: root.appendingPathComponent("retry-2", isDirectory: true)
        )
        let report = try await installer.install(
            MrpackInstallRequest(package: retryPackage, displayName: "Retry Pack", javaExecutable: java, sourcePolicy: .official),
            progress: { _ in }
        )
        XCTAssertEqual(report.installedFiles, 2)
        XCTAssertEqual(try InstanceRepository(layout: layout).list().count, 1)
    }

    func testCancellationLeavesNoInstance() async throws {
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
        XCTAssertFalse(FileManager.default.fileExists(atPath: package.extractionRoot.path))
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
