import XCTest
@testable import LauncherCore

final class M6InstallTests: XCTestCase {
    private var root: URL!
    private var layout: GameDataLayout!

    override func setUpWithError() throws {
        root = try FixtureLoader.temporaryDirectory("lingxi-m6")
        layout = GameDataLayout(
            gameRoot: root.appendingPathComponent("mc", isDirectory: true),
            dataRoot: root.appendingPathComponent("data", isDirectory: true)
        )
    }

    override func tearDownWithError() throws {
        if let root { try? FileManager.default.removeItem(at: root) }
    }

    func testFabricLoaderListUsesCompatibilityEndpointAndSortsStableFirst() async throws {
        let transport = StubTransport()
        let url = URL(string: "https://meta.fabricmc.net/v2/versions/loader/1.20.1")!
        let json = """
        [
          {"loader":{"version":"0.16.9","stable":false},"launcherMeta":{"min_java_version":17}},
          {"loader":{"version":"0.20.1","stable":true},"launcherMeta":{"min_java_version":8}},
          {"loader":{"version":"0.16.10","stable":true}}
        ]
        """
        await transport.setData(json, for: url)
        let installer = FabricInstaller(layout: layout, transport: transport)
        let versions = try await installer.listLoaderVersions(for: "1.20.1")
        XCTAssertEqual(versions.map(\.version), ["0.20.1", "0.16.10", "0.16.9"])
        XCTAssertEqual(versions.first?.minimumJavaVersion, 8)
        XCTAssertTrue(versions.first?.stable == true)
    }

    func testFabricLoaderListRejectsIncompatibleMinecraft() async throws {
        let transport = StubTransport()
        let url = URL(string: "https://meta.fabricmc.net/v2/versions/loader/0.0")!
        await transport.setData("[]", for: url)
        let installer = FabricInstaller(layout: layout, transport: transport)
        do {
            _ = try await installer.listLoaderVersions(for: "0.0")
            XCTFail("Expected unsupported version")
        } catch {
            XCTAssertEqual((error as? LauncherError)?.code, .unsupportedVersion)
        }
    }

    func testFabricInstallerRefusesImplicitExistingInstanceUpdate() async throws {
        let registry = InstanceRepository(layout: layout)
        let existing = try registry.create(id: "existing", displayName: "Existing", versionID: "1.20.1")
        let before = try Data(contentsOf: existing.directory.appendingPathComponent("instance.json"))
        let transport = StubTransport()
        let installer = FabricInstaller(layout: layout, transport: transport)
        let request = FabricInstallRequest(
            minecraftVersionID: "1.20.1",
            instanceID: "existing",
            updateExistingInstance: false,
            javaExecutable: URL(fileURLWithPath: "/definitely/not/java")
        )
        do {
            _ = try await installer.install(request, progress: { _ in })
            XCTFail("Expected explicit-update refusal")
        } catch {
            XCTAssertEqual((error as? LauncherError)?.code, .usageError)
        }
        XCTAssertEqual(try Data(contentsOf: existing.directory.appendingPathComponent("instance.json")), before)
        let after = try registry.load(id: "existing")
        XCTAssertEqual(after.manifest.versionID, "1.20.1")
    }

    func testOneStopExplicitUpdateBacksUpManifestAndPreservesWorldData() async throws {
        guard let java = try? JavaRuntimeInspector().discoverDefaultExecutable() else {
            throw XCTSkip("No Java runtime available for the synthetic OneStop update test")
        }
        let fixture = try SyntheticInstallation()
        let transport = StubTransport()
        await fixture.populate(transport)
        let registry = InstanceRepository(layout: layout)
        let existing = try registry.create(id: "existing", displayName: "Existing", versionID: "old-version")
        try Data("world".utf8).write(to: existing.gameDirectory.appendingPathComponent("level.dat"))
        let installer = OneStopInstaller(layout: layout, transport: transport)
        let request = OneStopInstallRequest(
            minecraftVersionID: fixture.versionID,
            loader: .vanilla,
            target: .existingInstance(id: "existing"),
            javaExecutable: java,
            sourcePolicy: .official,
            concurrency: 2
        )
        let report = try await installer.install(request, progress: { _ in })
        XCTAssertEqual(report.instanceID, "existing")
        XCTAssertEqual(report.installedVersionID, fixture.versionID)
        XCTAssertNotNil(report.backupManifest)
        XCTAssertTrue(FileManager.default.fileExists(atPath: report.backupManifest!.path))
        let updated = try registry.load(id: "existing")
        XCTAssertEqual(updated.manifest.versionID, fixture.versionID)
        XCTAssertEqual(try Data(contentsOf: updated.gameDirectory.appendingPathComponent("level.dat")), Data("world".utf8))
    }

    func testOneStopInstallerDefaultsToNewInstanceAndRejectsSilentUpdate() async throws {
        _ = try InstanceRepository(layout: layout).create(
            id: "existing",
            displayName: "Existing",
            versionID: "1.20.1"
        )
        let installer = OneStopInstaller(layout: layout, transport: StubTransport())
        let request = OneStopInstallRequest(
            minecraftVersionID: "1.20.1",
            loader: .vanilla,
            target: .newInstance(id: "existing", displayName: "Existing"),
            javaExecutable: URL(fileURLWithPath: "/definitely/not/java")
        )
        do {
            _ = try await installer.install(request, progress: { _ in })
            XCTFail("Expected collision refusal")
        } catch {
            XCTAssertEqual((error as? LauncherError)?.code, .usageError)
        }
    }

    func testFailedNewInstallDoesNotCreateTargetInstance() async throws {
        let installer = OneStopInstaller(layout: layout, transport: StubTransport())
        let request = OneStopInstallRequest(
            minecraftVersionID: "1.20.1",
            loader: .vanilla,
            target: .newInstance(id: "fresh", displayName: "Fresh"),
            javaExecutable: URL(fileURLWithPath: "/definitely/not/java")
        )
        do {
            _ = try await installer.install(request, progress: { _ in })
            XCTFail("Expected missing Java")
        } catch {
            XCTAssertEqual((error as? LauncherError)?.code, .javaNotFound)
        }
        XCTAssertNil(try? InstanceRepository(layout: layout).load(id: "fresh"))
    }

    func testJavaManagerReportsNoCompatibleRuntimeForImpossibleRequirement() throws {
        let manager = JavaManager(layout: layout, transport: StubTransport())
        XCTAssertNil(manager.selectCompatible(requirement: JavaVersionRequirement(majorVersion: 999)))
    }

    func testSHA256DigestKnownVector() {
        XCTAssertEqual(
            SHA256Digest.hexDigest(Data("abc".utf8)),
            "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"
        )
    }
}
