import XCTest
@testable import LauncherCore

private struct BackupFixedRuntime: InstanceRuntimeChecking {
    let running: Bool
    func isRunning(instanceID: String) -> Bool { running }
}

final class InstanceBackupTests: XCTestCase {
    private var root: URL!
    private var layout: GameDataLayout!

    override func setUpWithError() throws {
        root = try FixtureLoader.temporaryDirectory("lingxi-m73-backup")
        layout = GameDataLayout(
            gameRoot: root.appendingPathComponent("mc", isDirectory: true),
            dataRoot: root.appendingPathComponent("data", isDirectory: true)
        )
    }

    override func tearDownWithError() throws {
        if let root { try? FileManager.default.removeItem(at: root) }
    }

    func testCopyInstanceCopiesOwnedDataAndOptionalSavesWithoutChangingSource() throws {
        let repository = InstanceRepository(layout: layout)
        let source = try repository.create(id: "source", displayName: "Source", versionID: "1.20.1")
        try write("mods/example.jar", "jar", in: source.gameDirectory)
        try write("mods-disabled/off.jar", "off", in: source.gameDirectory)
        try write("shaderpacks/pack.zip", "zip", in: source.gameDirectory)
        try write("config/client.txt", "config", in: source.gameDirectory)
        try write("options.txt", "options", in: source.gameDirectory)
        try write("saves/World/level.dat", "level", in: source.gameDirectory)
        try write("resourcepacks/resource.zip", "resource", in: source.gameDirectory)
        // Metadata lives in the instance metadata directory, not the game directory.
        try write("mods.json", """
        [{"fileName":"example.jar","projectID":"P1","versionID":"V1","versionNumber":"1.0.0","title":"Example","source":"modrinth","sha1":"abc","sha512":"def","enabled":true}]
        """, in: source.directory)
        try write("shaderpacks.json", """
        [{"fileName":"pack.zip","projectID":"S1","versionID":"SV1","versionNumber":"1.0.0","title":"Shader","source":"modrinth","sha1":"s1","sha512":"s2","enabled":false}]
        """, in: source.directory)

        let report = try InstanceCopyService(layout: layout).copy(
            instanceID: source.id,
            displayName: "Copy",
            options: InstanceCopyOptions(includeSaves: true)
        )
        XCTAssertNotEqual(report.instance.id, source.id)
        XCTAssertTrue(report.copiedPaths.contains("mods"))
        XCTAssertTrue(report.copiedPaths.contains("saves"))
        XCTAssertEqual(try Data(contentsOf: source.gameDirectory.appendingPathComponent("mods/example.jar")), Data("jar".utf8))
        XCTAssertEqual(try Data(contentsOf: report.instance.gameDirectory.appendingPathComponent("mods/example.jar")), Data("jar".utf8))
        XCTAssertEqual(try Data(contentsOf: report.instance.gameDirectory.appendingPathComponent("saves/World/level.dat")), Data("level".utf8))
        XCTAssertEqual(try Data(contentsOf: report.instance.directory.appendingPathComponent("mods.json")), try Data(contentsOf: source.directory.appendingPathComponent("mods.json")))
        XCTAssertEqual(try Data(contentsOf: report.instance.directory.appendingPathComponent("shaderpacks.json")), try Data(contentsOf: source.directory.appendingPathComponent("shaderpacks.json")))
        XCTAssertEqual(try repository.load(id: source.id).manifest.displayName, "Source")
    }

    func testCopyFailureRemovesOnlyTheNewInstance() throws {
        let repository = InstanceRepository(layout: layout)
        let source = try repository.create(id: "source-fail", displayName: "Source", versionID: "1.20.1")
        let outside = root.appendingPathComponent("outside.txt")
        try Data("outside".utf8).write(to: outside)
        try FileManager.default.createDirectory(at: source.gameDirectory.appendingPathComponent("mods"), withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(
            at: source.gameDirectory.appendingPathComponent("mods/escape.jar"),
            withDestinationURL: outside
        )

        XCTAssertThrowsError(try InstanceCopyService(layout: layout).copy(instanceID: source.id, displayName: "Should Fail"))
        XCTAssertTrue(try repository.load(id: source.id).manifest.displayName == "Source")
        XCTAssertEqual(try repository.list().count, 1, "failed copy must remove the new instance")
        XCTAssertEqual(try Data(contentsOf: outside), Data("outside".utf8))
    }

    func testWorldBackupCreateVerifyRestoreAndDelete() throws {
        let instance = try makeInstance()
        let world = instance.gameDirectory.appendingPathComponent("saves/TestWorld", isDirectory: true)
        try write("level.dat", "before", in: world)
        try write("region/r.0.0.mca", "region", in: world)
        let manager = WorldBackupManager(layout: layout, runtimeRegistry: BackupFixedRuntime(running: false))

        let summary = try manager.createBackup(instanceID: instance.id, worldName: "TestWorld")
        XCTAssertEqual(summary.fileCount, 2)
        XCTAssertEqual(try manager.listBackups(instanceID: instance.id).count, 1)
        XCTAssertEqual(try manager.verifyBackup(instanceID: instance.id, backupID: summary.id).fileCount, 2)

        try Data("after".utf8).write(to: world.appendingPathComponent("level.dat"))
        _ = try manager.restore(instanceID: instance.id, backupID: summary.id)
        XCTAssertEqual(try Data(contentsOf: world.appendingPathComponent("level.dat")), Data("before".utf8))
        XCTAssertEqual(try Data(contentsOf: world.appendingPathComponent("region/r.0.0.mca")), Data("region".utf8))
        XCTAssertTrue(FileManager.default.fileExists(atPath: summary.directory.path))

        try manager.deleteBackup(instanceID: instance.id, backupID: summary.id)
        XCTAssertTrue(try manager.listBackups(instanceID: instance.id).isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: summary.directory.path))
    }

    func testBackupIncludesHiddenFilesAndVerifiesThem() throws {
        let instance = try makeInstance()
        let world = instance.gameDirectory.appendingPathComponent("saves/HiddenWorld", isDirectory: true)
        try write("level.dat", "level", in: world)
        try write(".hidden/data.bin", "hidden", in: world)
        let manager = WorldBackupManager(layout: layout, runtimeRegistry: BackupFixedRuntime(running: false))
        let summary = try manager.createBackup(instanceID: instance.id, worldName: "HiddenWorld")
        XCTAssertEqual(summary.fileCount, 2)
        let manifest = try manager.verifyBackup(instanceID: instance.id, backupID: summary.id)
        XCTAssertTrue(manifest.files.contains { $0.relativePath == ".hidden/data.bin" })
    }

    func testModpackSourceIsNeverGuessedAndRoundTrips() async throws {
        let instance = try makeInstance()
        let manager = ModpackLifecycleManager(layout: layout)
        let record = ModpackRecord(
            versionID: "pack-version-1",
            minecraftVersion: "1.20.1",
            loaderKind: "fabric",
            loaderVersion: "0.20.1",
            archiveSHA256: "abc",
            files: [ModpackFileRecord(path: "mods/a.jar", sha256: "def", source: "modrinth")]
        )
        try manager.save(record, instanceID: instance.id)
        let loaded = try manager.record(instanceID: instance.id)
        XCTAssertEqual(loaded.versionID, record.versionID)
        XCTAssertEqual(loaded.projectID, nil)
        XCTAssertEqual(loaded.files, record.files)
        do {
            _ = try await manager.checkUpdate(instanceID: instance.id)
            XCTFail("must not guess a project")
        } catch let error as LauncherError {
            XCTAssertEqual(error.code, .missingDependency)
        }
    }

    func testRestoreRefusedWhileGameRuns() throws {
        let instance = try makeInstance()
        try write("saves/World/level.dat", "level", in: instance.gameDirectory)
        let manager = WorldBackupManager(layout: layout, runtimeRegistry: BackupFixedRuntime(running: false))
        let summary = try manager.createBackup(instanceID: instance.id, worldName: "World")
        let blocked = WorldBackupManager(layout: layout, runtimeRegistry: BackupFixedRuntime(running: true))
        XCTAssertThrowsError(try blocked.restore(instanceID: instance.id, backupID: summary.id)) { error in
            XCTAssertEqual((error as? LauncherError)?.code, .launchFailed)
        }
        XCTAssertEqual(try Data(contentsOf: instance.gameDirectory.appendingPathComponent("saves/World/level.dat")), Data("level".utf8))
    }

    func testCorruptBackupIsRejectedWithoutTouchingCurrentWorld() throws {
        let instance = try makeInstance()
        try write("saves/World/level.dat", "current", in: instance.gameDirectory)
        let manager = WorldBackupManager(layout: layout, runtimeRegistry: BackupFixedRuntime(running: false))
        let summary = try manager.createBackup(instanceID: instance.id, worldName: "World")
        try Data("tampered".utf8).write(to: summary.directory.appendingPathComponent("world/level.dat"))
        XCTAssertThrowsError(try manager.restore(instanceID: instance.id, backupID: summary.id)) { error in
            XCTAssertEqual((error as? LauncherError)?.code, .invalidMetadata)
        }
        XCTAssertEqual(try Data(contentsOf: instance.gameDirectory.appendingPathComponent("saves/World/level.dat")), Data("current".utf8))
    }

    func testSymlinkedWorldAndTraversalBackupIDAreRejected() throws {
        let instance = try makeInstance()
        let saves = instance.gameDirectory.appendingPathComponent("saves", isDirectory: true)
        try FileManager.default.createDirectory(at: saves, withIntermediateDirectories: true)
        let outside = root.appendingPathComponent("outside-world", isDirectory: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        try Data("outside".utf8).write(to: outside.appendingPathComponent("level.dat"))
        try FileManager.default.createSymbolicLink(at: saves.appendingPathComponent("EscapeWorld"), withDestinationURL: outside)
        let manager = WorldBackupManager(layout: layout, runtimeRegistry: BackupFixedRuntime(running: false))

        XCTAssertThrowsError(try manager.createBackup(instanceID: instance.id, worldName: "EscapeWorld"))
        XCTAssertThrowsError(try manager.verifyBackup(instanceID: instance.id, backupID: "../outside-world"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: layout.backupsDirectory.appendingPathComponent("outside-world").path))
    }

    func testWorldDuringWriteFailureLeavesOriginalRecoverable() throws {
        let instance = try makeInstance()
        try write("saves/World/level.dat", "original", in: instance.gameDirectory)
        let manager = WorldBackupManager(layout: layout, runtimeRegistry: BackupFixedRuntime(running: false))
        let summary = try manager.createBackup(instanceID: instance.id, worldName: "World")
        // A manifest with a valid file list but a mismatched checksum must fail before the
        // existing world is moved aside.
        let manifestURL = summary.directory.appendingPathComponent("manifest.json")
        let data = try Data(contentsOf: manifestURL)
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        object["worldName"] = "World"
        object["files"] = [[
            "relativePath": "level.dat",
            "byteCount": 8,
            "sha256": String(repeating: "0", count: 64)
        ]]
        try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]).write(to: manifestURL)
        XCTAssertThrowsError(try manager.restore(instanceID: instance.id, backupID: summary.id))
        XCTAssertEqual(try Data(contentsOf: instance.gameDirectory.appendingPathComponent("saves/World/level.dat")), Data("original".utf8))
    }

    func testOldInstanceManifestWithoutNewRuntimeFieldsDecodes() throws {
        let directory = try layout.instanceDirectory("legacy")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let json: [String: Any] = [
            "id": "legacy",
            "displayName": "Legacy",
            "versionID": "1.20.1",
            "createdAt": "2026-01-01T00:00:00Z"
        ]
        try JSONSerialization.data(withJSONObject: json).write(to: directory.appendingPathComponent("instance.json"))
        let instance = try InstanceRepository(layout: layout).load(id: "legacy")
        XCTAssertEqual(instance.manifest.displayName, "Legacy")
        XCTAssertNil(instance.manifest.memoryMiB)
        XCTAssertNil(instance.manifest.javaRuntime)
    }

    private func makeInstance() throws -> Instance {
        try InstanceRepository(layout: layout).create(id: "world-instance", displayName: "Worlds", versionID: "1.20.1")
    }

    private func write(_ relative: String, _ text: String, in root: URL) throws {
        let url = root.appendingPathComponent(relative)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url)
    }
}
