import XCTest
@testable import LauncherCore

final class ModpackUpdateManagerTests: XCTestCase {
    private var root: URL!
    private var layout: GameDataLayout!

    override func setUpWithError() throws {
        root = try FixtureLoader.temporaryDirectory("lingxi-mrpack-update")
        layout = GameDataLayout(
            gameRoot: root.appendingPathComponent("mc", isDirectory: true),
            dataRoot: root.appendingPathComponent("data", isDirectory: true)
        )
    }

    override func tearDownWithError() throws {
        if let root { try? FileManager.default.removeItem(at: root) }
    }

    private func makeTarget() throws -> (Data, URL, ModrinthVersion, Data) {
        let fixture = try FixtureLoader.url("mrpack/update-target.mrpack")
        let data = try Data(contentsOf: fixture)
        let sha1 = SHA1.hexDigest(data)
        let sha512 = SHA512Digest.hexDigest(data)
        let archiveURL = URL(string: "https://cdn.modrinth.com/data/proj/versions/target/target.mrpack")!
        let targetJSON = Data("""
        {
          "id": "target-version",
          "project_id": "proj",
          "name": "Update Target",
          "version_number": "2.0.0",
          "version_type": "release",
          "game_versions": ["1.20.1"],
          "loaders": ["fabric"],
          "date_published": "2026-01-01T00:00:00Z",
          "downloads": 1,
          "files": [{
            "hashes": {"sha1": "\(sha1)", "sha512": "\(sha512)"},
            "url": "\(archiveURL.absoluteString)",
            "filename": "target.mrpack",
            "primary": true,
            "size": \(data.count)
          }]
        }
        """.utf8)
        let version = try JSONDecoder().decode(ModrinthVersion.self, from: targetJSON)
        return (data, archiveURL, version, targetJSON)
    }

    private func makeInstance(untracked: Bool = false) throws -> Instance {
        let instance = try InstanceRepository(layout: layout).create(id: "update-test", displayName: "Update", versionID: "fabric-loader-0.20.1-1.20.1")
        let file = instance.gameDirectory.appendingPathComponent("mods/fixture.jar")
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        let old = Data("old-fixture-jar".utf8)
        try old.write(to: file)
        let oldHash = SHA256Digest.hexDigest(old)
        let record = ModpackRecord(
            projectID: "proj",
            versionID: "pack-v1",
            packVersionID: "pack-v1",
            modrinthProjectID: "proj",
            modrinthVersionID: "old-version",
            minecraftVersion: "1.20.1",
            loaderKind: "fabric",
            loaderVersion: "0.20.1",
            archiveSHA256: String(repeating: "a", count: 64),
            files: untracked ? [] : [ModpackFileRecord(path: "mods/fixture.jar", sha256: oldHash, sha1: nil, sha512: nil, source: "modrinth")]
        )
        try ModpackLifecycleManager(layout: layout).save(record, instanceID: instance.id)
        return instance
    }

    func testPreviewAndApplyUsesInternalFilesAndUpdatesRecord() async throws {
        let (archiveData, archiveURL, target, targetJSON) = try makeTarget()
        let transport = StubTransport()
        await transport.setData(archiveData, for: archiveURL)
        await transport.setData(targetJSON, for: URL(string: "https://api.modrinth.com/v2/version/target-version")!)
        await transport.setData("updated-fixture-jar-v2", for: URL(string: "https://cdn.modrinth.com/data/proj/versions/v2/fixture.jar")!)
        let instance = try makeInstance()
        let manager = ModpackUpdateManager(layout: layout, transport: transport, client: ModrinthClient(transport: transport))
        let preview = try await manager.preview(instanceID: instance.id, targetVersionID: target.id)
        XCTAssertEqual(preview.targetVersionNumber, "2.0.0")
        XCTAssertTrue(preview.changes.contains { $0.path == "mods/fixture.jar" && $0.kind == .upgraded })
        XCTAssertTrue(preview.changes.contains { $0.path == "config/update.txt" && $0.kind == .added })

        let report = try await manager.apply(instanceID: instance.id, targetVersionID: target.id)
        XCTAssertTrue(report.applied.contains("mods/fixture.jar"))
        XCTAssertEqual(try String(contentsOf: instance.gameDirectory.appendingPathComponent("mods/fixture.jar"), encoding: .utf8), "updated-fixture-jar-v2")
        XCTAssertEqual(try String(contentsOf: instance.gameDirectory.appendingPathComponent("config/update.txt"), encoding: .utf8), "new override")
        let record = try ModpackLifecycleManager(layout: layout).record(instanceID: instance.id)
        XCTAssertEqual(record.modrinthVersionID, "target-version")
        XCTAssertEqual(record.packVersionID, "pack-v2")
        XCTAssertTrue(record.files.contains { $0.path == "mods/fixture.jar" })
        XCTAssertFalse(manager.pendingTransaction(instanceID: instance.id))
    }

    func testUntrackedFileIsConflictAndPreservedByDefault() async throws {
        let (archiveData, archiveURL, target, targetJSON) = try makeTarget()
        let transport = StubTransport()
        await transport.setData(archiveData, for: archiveURL)
        await transport.setData(targetJSON, for: URL(string: "https://api.modrinth.com/v2/version/target-version")!)
        await transport.setData("updated-fixture-jar-v2", for: URL(string: "https://cdn.modrinth.com/data/proj/versions/v2/fixture.jar")!)
        let instance = try makeInstance(untracked: true)
        let manager = ModpackUpdateManager(layout: layout, transport: transport, client: ModrinthClient(transport: transport))
        let preview = try await manager.preview(instanceID: instance.id, targetVersionID: target.id)
        XCTAssertTrue(preview.changes.contains { $0.path == "mods/fixture.jar" && $0.kind == .conflict })
        let report = try await manager.apply(instanceID: instance.id, targetVersionID: target.id)
        XCTAssertTrue(report.preserved.contains("mods/fixture.jar"))
        XCTAssertEqual(try String(contentsOf: instance.gameDirectory.appendingPathComponent("mods/fixture.jar"), encoding: .utf8), "old-fixture-jar")
    }

    func testDownloadFailureLeavesCurrentInstanceUntouched() async throws {
        let (archiveData, archiveURL, target, targetJSON) = try makeTarget()
        let transport = StubTransport()
        await transport.setData(archiveData, for: archiveURL)
        await transport.setData(targetJSON, for: URL(string: "https://api.modrinth.com/v2/version/target-version")!)
        await transport.setFailure(.network("offline"), for: URL(string: "https://cdn.modrinth.com/data/proj/versions/v2/fixture.jar")!)
        let instance = try makeInstance()
        let manager = ModpackUpdateManager(layout: layout, transport: transport, client: ModrinthClient(transport: transport))
        await XCTAssertThrowsErrorAsync {
            _ = try await manager.apply(instanceID: instance.id, targetVersionID: target.id)
        }
        XCTAssertEqual(try String(contentsOf: instance.gameDirectory.appendingPathComponent("mods/fixture.jar"), encoding: .utf8), "old-fixture-jar")
        let record = try ModpackLifecycleManager(layout: layout).record(instanceID: instance.id)
        XCTAssertEqual(record.modrinthVersionID, "old-version")
        XCTAssertFalse(manager.pendingTransaction(instanceID: instance.id))
    }
}

private extension XCTestCase {
    func XCTAssertThrowsErrorAsync(_ expression: @escaping () async throws -> Void) async {
        do {
            try await expression()
            XCTFail("Expected error")
        } catch {}
    }
}
