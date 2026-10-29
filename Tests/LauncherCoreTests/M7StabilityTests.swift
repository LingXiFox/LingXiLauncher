import XCTest
@testable import LauncherCore

final class M7StabilityTests: XCTestCase {
    private var root: URL!
    private var layout: GameDataLayout!

    override func setUpWithError() throws {
        root = try FixtureLoader.temporaryDirectory("lingxi-m73-stability")
        layout = GameDataLayout(
            gameRoot: root.appendingPathComponent("mc", isDirectory: true),
            dataRoot: root.appendingPathComponent("data", isDirectory: true)
        )
    }

    override func tearDownWithError() throws {
        if let root { try? FileManager.default.removeItem(at: root) }
    }

    func testNeoForgeTransactionCommitCleansPrivateBackupOnly() throws {
        let source = root.appendingPathComponent("stage/libraries/net/neoforged/test.jar")
        try write("new", to: source)
        let destination = layout.librariesDirectory.appendingPathComponent("net/neoforged/test.jar")
        try write("old", to: destination)
        let unrelated = layout.librariesDirectory.appendingPathComponent("keep/other.jar")
        try write("keep", to: unrelated)

        let transaction = try NeoForgeFileTransaction(layout: layout)
        let backupRoot = transaction.backupRootForTesting
        try transaction.installLibraries(from: root.appendingPathComponent("stage/libraries"))
        XCTAssertTrue(FileManager.default.fileExists(atPath: backupRoot.path))
        transaction.commit()

        XCTAssertFalse(FileManager.default.fileExists(atPath: backupRoot.path))
        XCTAssertEqual(try Data(contentsOf: destination), Data("new".utf8))
        XCTAssertEqual(try Data(contentsOf: unrelated), Data("keep".utf8))
    }

    func testNeoForgeTransactionRollbackRestoresOldLibraryAndVersion() throws {
        let library = layout.librariesDirectory.appendingPathComponent("net/neoforged/runtime.jar")
        try write("old-library", to: library)
        let sourceLibrary = root.appendingPathComponent("stage/libraries/net/neoforged/runtime.jar")
        try write("new-library", to: sourceLibrary)

        let versionDestination = try layout.versionDirectory("neoforge-test")
        try write("old-profile", to: versionDestination.appendingPathComponent("profile.json"))
        let sourceVersion = root.appendingPathComponent("stage/version")
        try write("new-profile", to: sourceVersion.appendingPathComponent("profile.json"))

        let transaction = try NeoForgeFileTransaction(layout: layout)
        let backupRoot = transaction.backupRootForTesting
        try transaction.installLibraries(from: root.appendingPathComponent("stage/libraries"))
        try transaction.installVersion(from: sourceVersion, id: "neoforge-test")
        transaction.rollback()

        XCTAssertFalse(FileManager.default.fileExists(atPath: backupRoot.path))
        XCTAssertEqual(try Data(contentsOf: library), Data("old-library".utf8))
        XCTAssertEqual(
            try Data(contentsOf: versionDestination.appendingPathComponent("profile.json")),
            Data("old-profile".utf8)
        )
    }

    func testShaderFilenameConflictWithAnotherProjectIsRejected() throws {
        let repository = InstanceRepository(layout: layout)
        let instance = try repository.create(id: "shader-conflict", displayName: "Shader", versionID: "1.20.1")
        let store = ShaderPackRepository(layout: layout)
        let directory = store.shaderPacksDirectory(instance: instance)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try write("A", to: directory.appendingPathComponent("shared.zip"))
        let a = InstalledShaderPack(
            projectID: "project-a", title: "A", versionID: "a1", versionNumber: "1.0",
            fileName: "shared.zip", fileSize: 1, source: .modrinth
        )
        let b = InstalledShaderPack(
            projectID: "project-b", title: "B", versionID: "b1", versionNumber: "1.0",
            fileName: "b.zip", fileSize: 1, source: .modrinth
        )
        try store.saveRecords([a, b], instance: instance)
        let stage = root.appendingPathComponent("staged.zip")
        try write("B", to: stage)
        let attempted = InstalledShaderPack(
            projectID: "project-b", title: "B", versionID: "b2", versionNumber: "2.0",
            fileName: "shared.zip", fileSize: 1, source: .modrinth
        )
        XCTAssertThrowsError(try store.commit(
            instance: instance,
            stagedURL: stage,
            record: attempted,
            replacingFileName: "b.zip",
            allowReplace: true
        ))
        XCTAssertEqual(try Data(contentsOf: directory.appendingPathComponent("shared.zip")), Data("A".utf8))
        XCTAssertEqual(try store.loadRecords(instance: instance).count, 2)
    }

    func testUpdatePolicyNeverAutoDowngradesAcrossChannels() throws {
        let current = try decodeVersion(id: "current", number: "2.0.0", type: "beta")
        let releaseOlder = try decodeVersion(id: "release-old", number: "1.9.0", type: "release")
        let releaseNewer = try decodeVersion(id: "release-new", number: "2.1.0", type: "release")
        let betaNewer = try decodeVersion(id: "beta-new", number: "2.2.0", type: "beta")
        let alphaNewer = try decodeVersion(id: "alpha-new", number: "3.0.0", type: "alpha")

        let selected = ModrinthUpdatePolicy.selectUpdate(
            current: current,
            from: [releaseOlder, alphaNewer, releaseNewer, betaNewer]
        ) { $0.primaryJar }
        XCTAssertEqual(selected?.id, "beta-new", "beta may move to release/beta; alpha must not be selected")

        let releaseCurrent = try decodeVersion(id: "rel-current", number: "1.0.0", type: "release")
        let betaOnly = ModrinthUpdatePolicy.selectUpdate(current: releaseCurrent, from: [betaNewer]) { $0.primaryJar }
        XCTAssertNil(betaOnly)
    }

    private func decodeVersion(id: String, number: String, type: String) throws -> ModrinthVersion {
        let json = """
        {"id":"\(id)","project_id":"project-a","name":"\(id)","version_number":"\(number)",
         "dependencies":[],"game_versions":["1.20.1"],"version_type":"\(type)","loaders":["fabric"],
         "date_published":"2026-01-01T00:00:00Z","downloads":0,
         "files":[{"hashes":{"sha1":"aa","sha512":"bb"},"url":"https://cdn.modrinth.com/data/a.jar",
         "filename":"a.jar","primary":true,"size":10,"file_type":"jar"}]}
        """
        return try JSONDecoder().decode(ModrinthVersion.self, from: Data(json.utf8))
    }

    private func write(_ text: String, to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url)
    }
}
