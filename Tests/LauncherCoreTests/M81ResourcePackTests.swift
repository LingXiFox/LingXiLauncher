import XCTest
@testable import LauncherCore

final class M81ResourcePackTests: XCTestCase {
    private var root: URL!
    private var layout: GameDataLayout!
    private var instance: Instance!

    override func setUpWithError() throws {
        root = try FixtureLoader.temporaryDirectory("lingxi-m81-resourcepack")
        layout = GameDataLayout(
            gameRoot: root.appendingPathComponent("mc", isDirectory: true),
            dataRoot: root.appendingPathComponent("data", isDirectory: true)
        )
        let versionDir = layout.gameRoot.appendingPathComponent("versions/1.20.1", isDirectory: true)
        try FileManager.default.createDirectory(at: versionDir, withIntermediateDirectories: true)
        let json: [String: Any] = ["id": "1.20.1", "type": "release", "mainClass": "net.minecraft.client.main.Main", "assets": "1.20", "assetIndex": ["id": "1.20"], "arguments": ["game": ["--version", "${version_name}"], "jvm": []], "libraries": []]
        try JSONSerialization.data(withJSONObject: json).write(to: versionDir.appendingPathComponent("1.20.1.json"))
        instance = try InstanceRepository(layout: layout).create(id: "rp-test", displayName: "RP", versionID: "1.20.1")
        try Data("resourcePacks:[]\n".utf8).write(to: instance.gameDirectory.appendingPathComponent("options.txt"))
    }

    override func tearDownWithError() throws {
        if let root { try? FileManager.default.removeItem(at: root) }
    }

    func testLocalImportListsAndDeletesResourcePack() throws {
        let manager = ResourcePackManager(layout: layout)
        let source = try FixtureLoader.url("resourcepacks/valid.zip")
        let record = try manager.importLocal(instanceID: instance.id, archiveURL: source)
        XCTAssertEqual(record.source, "local")
        XCTAssertEqual(try manager.list(instanceID: instance.id).count, 1)
        XCTAssertTrue(FileManager.default.fileExists(atPath: instance.gameDirectory.appendingPathComponent("resourcepacks/valid.zip").path))
        try manager.delete(instanceID: instance.id, fileName: "valid.zip")
        XCTAssertTrue(try manager.list(instanceID: instance.id).isEmpty)
    }

    func testUnmanagedFileConflictIsRejected() throws {
        let dir = instance.gameDirectory.appendingPathComponent("resourcepacks", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try Data("do-not-overwrite".utf8).write(to: dir.appendingPathComponent("valid.zip"))
        XCTAssertThrowsError(try ResourcePackManager(layout: layout).importLocal(
            instanceID: instance.id,
            archiveURL: try FixtureLoader.url("resourcepacks/valid.zip")
        )) { error in
            XCTAssertEqual((error as? LauncherError)?.code, .usageError)
        }
        XCTAssertEqual(try Data(contentsOf: dir.appendingPathComponent("valid.zip")), Data("do-not-overwrite".utf8))
    }

    func testValidatorRejectsMissingPackMetaAndTraversal() throws {
        let dir = try FixtureLoader.temporaryDirectory("lingxi-rp-invalid")
        defer { try? FileManager.default.removeItem(at: dir) }
        let missing = dir.appendingPathComponent("missing.zip")
        try Data("not-a-zip".utf8).write(to: missing)
        XCTAssertThrowsError(try ResourcePackArchiveValidator.validate(archive: missing))
    }

    func testEnabledStateUsesOptionsAndPreservesOtherKeys() throws {
        let manager = ResourcePackManager(layout: layout)
        _ = try manager.importLocal(instanceID: instance.id, archiveURL: try FixtureLoader.url("resourcepacks/valid.zip"))
        try Data("version:2692\nresourcePacks:[]\nfoo:bar\n".utf8).write(to: instance.gameDirectory.appendingPathComponent("options.txt"))
        try manager.setEnabled(instanceID: instance.id, fileName: "valid.zip", enabled: true)
        let text = try String(contentsOf: instance.gameDirectory.appendingPathComponent("options.txt"), encoding: .utf8)
        XCTAssertTrue(text.contains("foo:bar"))
        XCTAssertTrue(text.contains("file/valid.zip"))
        try manager.setEnabled(instanceID: instance.id, fileName: "valid.zip", enabled: false)
        let disabled = try String(contentsOf: instance.gameDirectory.appendingPathComponent("options.txt"), encoding: .utf8)
        XCTAssertFalse(disabled.contains("file/valid.zip"))
    }
}

extension M81ResourcePackTests {
    func testCrossFilenameUpdateIsTransactionalAndPreservesEnabledState() async throws {
        let zip = try Data(contentsOf: FixtureLoader.url("resourcepacks/valid.zip"))
        let sha1 = SHA1.hexDigest(zip)
        let sha512 = SHA512Digest.hexDigest(zip)
        let transport = StubTransport()
        let oldURL = URL(string: "https://cdn.modrinth.com/data/rp/versions/old/valid.zip")!
        let newURL = URL(string: "https://cdn.modrinth.com/data/rp/versions/new/updated.zip")!
        await transport.setData(zip, for: oldURL)
        await transport.setData(zip, for: newURL)
        func version(_ id: String, number: String, filename: String, url: URL) -> Data {
            Data("""
            {"id":"\(id)","project_id":"rp","name":"Pack","version_number":"\(number)",
             "version_type":"release","game_versions":["1.20.1"],"loaders":["minecraft"],
             "date_published":"2026-01-01T00:00:00Z","downloads":1,
             "files":[{"hashes":{"sha1":"\(sha1)","sha512":"\(sha512)"},"url":"\(url.absoluteString)",
             "filename":"\(filename)","primary":true,"size":\(zip.count)}]}
            """.utf8)
        }
        await transport.setData(Data(#"{"id":"rp","title":"Pack","description":"","project_type":"resourcepack","game_versions":["1.20.1"],"loaders":["minecraft"]}"#.utf8), for: URL(string: "https://api.modrinth.com/v2/project/rp")!)
        await transport.setData(version("old", number: "1.0", filename: "valid.zip", url: oldURL), for: URL(string: "https://api.modrinth.com/v2/version/old")!)
        await transport.setData(version("new", number: "2.0", filename: "updated.zip", url: newURL), for: URL(string: "https://api.modrinth.com/v2/version/new")!)
        let client = ModrinthClient(transport: transport)
        let manager = ResourcePackManager(layout: layout, client: client, transport: transport)
        _ = try await manager.install(instanceID: instance.id, projectID: "rp", versionID: "old")
        try manager.setEnabled(instanceID: instance.id, fileName: "valid.zip", enabled: true)
        let updated = try await manager.update(instanceID: instance.id, projectID: "rp", versionID: "new")
        XCTAssertEqual(updated.fileName, "updated.zip")
        XCTAssertTrue(updated.enabled)
        XCTAssertFalse(FileManager.default.fileExists(atPath: instance.gameDirectory.appendingPathComponent("resourcepacks/valid.zip").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: instance.gameDirectory.appendingPathComponent("resourcepacks/updated.zip").path))
        let options = try String(contentsOf: instance.gameDirectory.appendingPathComponent("options.txt"), encoding: .utf8)
        XCTAssertTrue(options.contains("file/updated.zip"))
        XCTAssertFalse(options.contains("file/valid.zip"))
        XCTAssertEqual(try manager.list(instanceID: instance.id).count, 1)
    }
}
