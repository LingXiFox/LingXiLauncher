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

    func testPreviewSignatureRejectsFilesChangedAfterPreview() async throws {
        let (archiveData, archiveURL, target, targetJSON) = try makeTarget()
        let transport = StubTransport()
        await transport.setData(archiveData, for: archiveURL)
        await transport.setData(targetJSON, for: URL(string: "https://api.modrinth.com/v2/version/target-version")!)
        await transport.setData("updated-fixture-jar-v2", for: URL(string: "https://cdn.modrinth.com/data/proj/versions/v2/fixture.jar")!)
        let instance = try makeInstance()
        let manager = ModpackUpdateManager(layout: layout, transport: transport, client: ModrinthClient(transport: transport))
        let preview = try await manager.preview(instanceID: instance.id, targetVersionID: target.id)
        let file = instance.gameDirectory.appendingPathComponent("mods/fixture.jar")
        try Data("changed-after-preview".utf8).write(to: file)
        await XCTAssertThrowsErrorAsync {
            _ = try await manager.apply(
                instanceID: instance.id,
                targetVersionID: target.id,
                expectedPlanSignature: preview.signature
            )
        }
        XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), "changed-after-preview")
    }

    func testUserModifiedFileIsReportedWhenTargetFileIsUnchanged() async throws {
        let fixture = try FixtureLoader.url("mrpack/update-target.mrpack")
        let package = try MrpackParser.parse(
            archive: fixture,
            extractionRoot: root.appendingPathComponent("identity-extract", isDirectory: true)
        )
        guard let targetFile = package.files.first(where: { $0.relativePath == "mods/fixture.jar" }),
              let sha1 = targetFile.sha1, let sha512 = targetFile.sha512 else {
            return XCTFail("fixture is missing hashes")
        }
        let instance = try makeInstance()
        let existing = try ModpackLifecycleManager(layout: layout).record(instanceID: instance.id)
        let modifiedRecord = ModpackRecord(
            projectID: existing.projectID,
            versionID: existing.versionID,
            packVersionID: existing.packVersionID,
            modrinthProjectID: existing.modrinthProjectID,
            modrinthVersionID: existing.modrinthVersionID,
            minecraftVersion: existing.minecraftVersion,
            loaderKind: existing.loaderKind,
            loaderVersion: existing.loaderVersion,
            archiveSHA256: existing.archiveSHA256,
            files: [ModpackFileRecord(
                path: "mods/fixture.jar",
                sha256: String(repeating: "f", count: 64),
                sha1: sha1, sha512: sha512,
                source: "modrinth", userModified: false
            )]
        )
        try ModpackLifecycleManager(layout: layout).save(modifiedRecord, instanceID: instance.id)
        let (archiveData, archiveURL, target, targetJSON) = try makeTarget()
        let transport = StubTransport()
        await transport.setData(archiveData, for: archiveURL)
        await transport.setData(targetJSON, for: URL(string: "https://api.modrinth.com/v2/version/target-version")!)
        await transport.setData("updated-fixture-jar-v2", for: URL(string: "https://cdn.modrinth.com/data/proj/versions/v2/fixture.jar")!)
        let manager = ModpackUpdateManager(layout: layout, transport: transport, client: ModrinthClient(transport: transport))
        let preview = try await manager.preview(instanceID: instance.id, targetVersionID: target.id)
        let change = try XCTUnwrap(preview.changes.first(where: { $0.path == "mods/fixture.jar" }))
        XCTAssertEqual(change.kind, .userModified)
        XCTAssertTrue(change.userModified)
        let report = try await manager.apply(instanceID: instance.id, targetVersionID: target.id)
        XCTAssertTrue(report.preserved.contains("mods/fixture.jar"))
        XCTAssertEqual(
            try String(contentsOf: instance.gameDirectory.appendingPathComponent("mods/fixture.jar"), encoding: .utf8),
            "old-fixture-jar"
        )
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

    func testLegacyModpackFileRecordUsesSHA256AsBothHashes() throws {
        let hash = String(repeating: "a", count: 64)
        let data = Data("""
        {"path":"mods/legacy.jar","sha256":"\(hash)","source":"modrinth","userModified":false}
        """.utf8)
        let record = try JSONDecoder().decode(ModpackFileRecord.self, from: data)
        XCTAssertEqual(record.originalHash, hash)
        XCTAssertEqual(record.currentHash, hash)
        XCTAssertFalse(record.userModified)
    }

    func testPreservedUserEditKeepsOfficialOriginalHashAndUpdatesCurrentHash() async throws {
        let (archiveData, archiveURL, target, targetJSON) = try makeTarget()
        let transport = StubTransport()
        await transport.setData(archiveData, for: archiveURL)
        await transport.setData(targetJSON, for: URL(string: "https://api.modrinth.com/v2/version/target-version")!)
        await transport.setData("updated-fixture-jar-v2", for: URL(string: "https://cdn.modrinth.com/data/proj/versions/v2/fixture.jar")!)
        let instance = try makeInstance()
        let manager = ModpackUpdateManager(layout: layout, transport: transport, client: ModrinthClient(transport: transport))
        let file = instance.gameDirectory.appendingPathComponent("mods/fixture.jar")
        let userEdit = Data("user-edited-local".utf8)
        try userEdit.write(to: file)
        let preview = try await manager.preview(instanceID: instance.id, targetVersionID: target.id)
        let change = try XCTUnwrap(preview.changes.first(where: { $0.path == "mods/fixture.jar" }))
        XCTAssertEqual(change.kind, .userModified)
        XCTAssertEqual(change.currentSHA256, SHA256Digest.hexDigest(userEdit))
        XCTAssertNotEqual(change.currentSHA256, change.newSHA256)

        let report = try await manager.apply(instanceID: instance.id, targetVersionID: target.id)
        XCTAssertTrue(report.preserved.contains("mods/fixture.jar"))
        let record = try ModpackLifecycleManager(layout: layout).record(instanceID: instance.id)
        let preserved = try XCTUnwrap(record.files.first(where: { $0.path == "mods/fixture.jar" }))
        XCTAssertEqual(preserved.originalHash, SHA256Digest.hexDigest(Data("old-fixture-jar".utf8)))
        XCTAssertEqual(preserved.currentHash, SHA256Digest.hexDigest(userEdit))
        XCTAssertTrue(preserved.userModified)

        let secondPreview = try await manager.preview(instanceID: instance.id, targetVersionID: target.id)
        let secondChange = try XCTUnwrap(secondPreview.changes.first(where: { $0.path == "mods/fixture.jar" }))
        XCTAssertEqual(secondChange.kind, .userModified)
        XCTAssertEqual(secondChange.currentSHA256, SHA256Digest.hexDigest(userEdit))

        try Data("changed-again".utf8).write(to: file)
        await XCTAssertThrowsErrorAsync {
            _ = try await manager.apply(
                instanceID: instance.id,
                targetVersionID: target.id,
                expectedPlanSignature: secondPreview.signature
            )
        }
        XCTAssertEqual(try Data(contentsOf: file), Data("changed-again".utf8))
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

// MARK: - M9.0 transaction failure tests

extension ModpackUpdateManagerTests {
    private func makeTransactionRoot(instanceID: String) throws -> URL {
        let root = layout.dataRoot
            .appendingPathComponent("modpack-updates", isDirectory: true)
            .appendingPathComponent(instanceID, isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private func writeState(
        in root: URL,
        instanceID: String,
        status: String,
        paths: [String],
        backups: [String: [String: Any]] = [:]
    ) throws {
        let state: [String: Any] = [
            "id": root.lastPathComponent,
            "instanceID": instanceID,
            "status": status,
            "affectedPaths": paths,
            "hadRecord": false,
            "backups": backups,
        ]
        let data = try JSONSerialization.data(withJSONObject: state, options: [.sortedKeys])
        try data.write(to: root.appendingPathComponent("state.json"), options: [.atomic])
    }

    func testCommittedTransactionRecoveryOnlyCleansAndNeverRollsBack() throws {
        let instance = try InstanceRepository(layout: layout).create(id: "committed-recovery", displayName: "Committed", versionID: nil)
        let file = instance.gameDirectory.appendingPathComponent("mods/new.jar")
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("committed-new-file".utf8).write(to: file)
        let root = try makeTransactionRoot(instanceID: instance.id)
        try writeState(in: root, instanceID: instance.id, status: "committed", paths: ["mods/new.jar"])
        XCTAssertFalse(try ModpackUpdateManager(layout: layout).recover(instanceID: instance.id))
        XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), "committed-new-file")
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.path))
    }

    func testCorruptStateIsPreservedAndRejected() throws {
        let instance = try InstanceRepository(layout: layout).create(id: "corrupt-state", displayName: "Corrupt", versionID: nil)
        let root = try makeTransactionRoot(instanceID: instance.id)
        try Data("not-json".utf8).write(to: root.appendingPathComponent("state.json"))
        XCTAssertThrowsError(try ModpackUpdateManager(layout: layout).recover(instanceID: instance.id))
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.path))
    }

    func testGameRunningRefusesUpdateBeforeAnyFileChanges() async throws {
        struct Running: InstanceRuntimeChecking {
            func isRunning(instanceID: String) -> Bool { true }
        }
        let (archiveData, archiveURL, target, targetJSON) = try makeTarget()
        let transport = StubTransport()
        await transport.setData(archiveData, for: archiveURL)
        await transport.setData(targetJSON, for: URL(string: "https://api.modrinth.com/v2/version/target-version")!)
        let instance = try makeInstance()
        let manager = ModpackUpdateManager(
            layout: layout,
            transport: transport,
            client: ModrinthClient(transport: transport),
            runtime: Running()
        )
        await XCTAssertThrowsErrorAsync {
            _ = try await manager.apply(instanceID: instance.id, targetVersionID: target.id)
        }
        XCTAssertEqual(
            try String(contentsOf: instance.gameDirectory.appendingPathComponent("mods/fixture.jar"), encoding: .utf8),
            "old-fixture-jar"
        )
        XCTAssertFalse(manager.pendingTransaction(instanceID: instance.id))
    }

    func testRecoveryFailureKeepsTransactionAndDoesNotPartiallyDelete() throws {
        let instance = try InstanceRepository(layout: layout).create(id: "recovery-failure", displayName: "Recovery", versionID: nil)
        let first = instance.gameDirectory.appendingPathComponent("mods/a.jar")
        let second = instance.gameDirectory.appendingPathComponent("mods/b.jar")
        try FileManager.default.createDirectory(at: first.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("current-a".utf8).write(to: first)
        try Data("current-b".utf8).write(to: second)
        let root = try makeTransactionRoot(instanceID: instance.id)
        let backupRoot = root.appendingPathComponent("backup/files/mods", isDirectory: true)
        try FileManager.default.createDirectory(at: backupRoot, withIntermediateDirectories: true)
        let backupA = backupRoot.appendingPathComponent("a.jar")
        try Data("old-a".utf8).write(to: backupA)
        let hashA = try SHA256Digest.hexDigest(ofFileAt: backupA)
        try writeState(
            in: root,
            instanceID: instance.id,
            status: "applying",
            paths: ["mods/a.jar", "mods/b.jar"],
            backups: [
                "mods/a.jar": ["path": "mods/a.jar", "sha256": hashA, "size": 5, "existed": true],
                "mods/b.jar": ["path": "mods/b.jar", "sha256": "deadbeef", "size": 5, "existed": true],
            ]
        )
        XCTAssertThrowsError(try ModpackUpdateManager(layout: layout).recover(instanceID: instance.id))
        XCTAssertEqual(try String(contentsOf: first, encoding: .utf8), "current-a")
        XCTAssertEqual(try String(contentsOf: second, encoding: .utf8), "current-b")
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.path))
        let state = try JSONSerialization.jsonObject(with: Data(contentsOf: root.appendingPathComponent("state.json"))) as? [String: Any]
        XCTAssertEqual(state?["status"] as? String, "rollbackFailed")
    }

    func testMissingBackupNeverDeletesCurrentFile() throws {
        let instance = try InstanceRepository(layout: layout).create(id: "missing-backup", displayName: "Missing", versionID: nil)
        let file = instance.gameDirectory.appendingPathComponent("mods/protected.jar")
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("user-data-must-survive".utf8).write(to: file)
        let root = try makeTransactionRoot(instanceID: instance.id)
        try writeState(
            in: root,
            instanceID: instance.id,
            status: "applying",
            paths: ["mods/protected.jar"],
            backups: ["mods/protected.jar": ["path": "mods/protected.jar", "sha256": "deadbeef", "size": 23, "existed": true]]
        )
        XCTAssertThrowsError(try ModpackUpdateManager(layout: layout).recover(instanceID: instance.id))
        XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), "user-data-must-survive")
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.path))
        let state = try JSONSerialization.jsonObject(with: Data(contentsOf: root.appendingPathComponent("state.json"))) as? [String: Any]
        XCTAssertEqual(state?["status"] as? String, "rollbackFailed")
    }
}
