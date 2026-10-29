import XCTest
@testable import LauncherCore

private actor ModrinthRoutingTransport: DownloadTransport {
    private var api: [String: Data] = [:]
    private var files: [String: Data] = [:]
    private(set) var requestedPaths: [String] = []
    private(set) var requestedURLs: [URL] = []
    private(set) var lastHeaders: [String: String] = [:]
    private(set) var postedBodies: [String: Data] = [:]

    func setAPI(path: String, data: Data) { api[path] = data }
    func setFile(path: String, data: Data) { files[path] = data }

    func fetch(from url: URL) async throws -> Data {
        try await fetch(from: url, headers: [:])
    }

    func fetch(from url: URL, headers: [String: String]) async throws -> Data {
        requestedPaths.append(url.path)
        requestedURLs.append(url)
        lastHeaders = headers
        guard let data = api[url.path] else { throw TransportError.httpStatus(404) }
        return data
    }

    func postJSON(from url: URL, body: Data, headers: [String: String]) async throws -> Data {
        requestedPaths.append(url.path)
        requestedURLs.append(url)
        lastHeaders = headers
        postedBodies[url.path] = body
        guard let data = api[url.path] else { throw TransportError.httpStatus(404) }
        return data
    }

    func download(from url: URL, to destination: URL) async throws {
        requestedPaths.append(url.path)
        guard let data = files[url.path] else { throw TransportError.httpStatus(404) }
        try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: destination)
    }
}

final class M6ModrinthTests: XCTestCase {
    private var root: URL!
    private var layout: GameDataLayout!

    override func setUpWithError() throws {
        root = try FixtureLoader.temporaryDirectory("lingxi-modrinth")
        layout = GameDataLayout(
            gameRoot: root.appendingPathComponent("mc", isDirectory: true),
            dataRoot: root.appendingPathComponent("data", isDirectory: true)
        )
    }

    override func tearDownWithError() throws {
        if let root { try? FileManager.default.removeItem(at: root) }
    }

    // MARK: - Official response parsing

    func testRealModrinthSearchProjectAndVersionsDecode() async throws {
        let transport = ModrinthRoutingTransport()
        await transport.setAPI(path: "/v2/search", data: try FixtureLoader.data("modrinth/search-sodium.json"))
        await transport.setAPI(path: "/v2/project/sodium", data: try FixtureLoader.data("modrinth/project-sodium.json"))
        await transport.setAPI(path: "/v2/project/sodium/version", data: try FixtureLoader.data("modrinth/versions-sodium.json"))

        let client = ModrinthClient(
            baseURL: URL(string: "https://api.modrinth.test/v2")!,
            transport: transport
        )
        let search = try await client.search(
            ModrinthSearchQuery(query: "sodium", gameVersion: "1.20.1", categories: ["optimization"], sort: .downloads)
        )
        XCTAssertFalse(search.hits.isEmpty)
        XCTAssertEqual(search.hits.first?.projectID, "AANobbMI")
        XCTAssertGreaterThan(search.totalHits, 0)
        let headers = await transport.lastHeaders
        XCTAssertTrue(headers["User-Agent"]?.contains("LingXiFox") == true)
        let urls = await transport.requestedURLs
        let searchURL = try XCTUnwrap(urls.first)
        let facets = try XCTUnwrap(URLComponents(url: searchURL, resolvingAgainstBaseURL: false)?
            .queryItems?.first(where: { $0.name == "facets" })?.value)
        XCTAssertTrue(facets.contains("project_type:mod"))
        XCTAssertTrue(facets.contains("categories:fabric"))
        XCTAssertTrue(facets.contains("versions:1.20.1"))
        XCTAssertTrue(facets.contains("categories:optimization"))

        let project = try await client.project(idOrSlug: "sodium")
        XCTAssertEqual(project.id, "AANobbMI")
        XCTAssertEqual(project.title, "Sodium")
        XCTAssertNotNil(project.license?.id)

        let versions = try await client.versions(projectID: "sodium", gameVersion: "1.20.1")
        XCTAssertFalse(versions.isEmpty)
        XCTAssertEqual(versions[0].files.first?.filename, "sodium-fabric-0.5.13+mc1.20.1.jar")
        XCTAssertNotNil(versions[0].files.first?.hashes.sha512)
        XCTAssertEqual(versions[0].primaryJar?.primary, true)
    }

    // MARK: - Local repository

    func testRepositoryEnableDisableAndDeleteKeepsInstanceData() throws {
        let instance = try makeFabricInstance()
        let repository = ModRepository(layout: layout)
        let staged = repository.stagingDirectory(instance: instance)
        try FileManager.default.createDirectory(at: staged, withIntermediateDirectories: true)
        let jar = staged.appendingPathComponent("local.jar")
        try Data("local-mod".utf8).write(to: jar)
        let record = InstalledMod(
            title: "Local",
            fileName: "local.jar",
            sha1: SHA1.hexDigest(Data("local-mod".utf8)),
            enabled: true,
            source: "local"
        )
        try repository.commitInstall(instance: instance, staged: [StagedModFile(temporaryURL: jar, record: record)])
        XCTAssertTrue(FileManager.default.fileExists(atPath: instance.gameDirectory.appendingPathComponent("mods/local.jar").path))

        let disabled = try repository.setEnabled(false, fileName: "local.jar", instance: instance)
        XCTAssertFalse(disabled.enabled)
        XCTAssertFalse(FileManager.default.fileExists(atPath: instance.gameDirectory.appendingPathComponent("mods/local.jar").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: instance.directory.appendingPathComponent("mods-disabled/local.jar").path))

        let enabled = try repository.setEnabled(true, fileName: "local.jar", instance: instance)
        XCTAssertTrue(enabled.enabled)
        try repository.remove(fileName: "local.jar", instance: instance)
        XCTAssertTrue(try repository.list(instance: instance).isEmpty)
        XCTAssertTrue(FileManager.default.fileExists(atPath: instance.gameDirectory.path))
    }

    // MARK: - Dependency/install/update integration

    func testInstallResolvesRequiredDependencyAndUpdatesAtomically() async throws {
        let instance = try makeFabricInstance()
        let transport = ModrinthRoutingTransport()
        let fixtures = SyntheticModAPI()
        await fixtures.populate(transport)
        let client = ModrinthClient(
            baseURL: URL(string: "https://api.modrinth.test/v2")!,
            transport: transport
        )
        let manager = ModManager(layout: layout, transport: transport, client: client)
        let compatibility = try manager.compatibility(for: instance)
        XCTAssertEqual(compatibility.gameVersion, "1.20.1")
        XCTAssertEqual(compatibility.loader, .fabric)

        let report = try await manager.install(
            ModInstallRequest(instanceID: instance.id, projectIDOrSlug: "testmod")
        ) { _ in }
        XCTAssertEqual(report.primary.projectID, "testmod")
        XCTAssertEqual(report.installed.filter { $0.source == "modrinth" }.count, 2)
        XCTAssertEqual(report.downloadedFiles, 2)
        let mods = try manager.installed(instanceID: instance.id)
        XCTAssertEqual(Set(mods.compactMap(\.projectID)), ["testmod", "dep"])
        XCTAssertTrue(FileManager.default.fileExists(atPath: instance.gameDirectory.appendingPathComponent("mods/testmod-v1.jar").path))

        // A required dependency is already present; a second install must reject with an
        // explicit duplicate message and must not duplicate the file.
        do {
            _ = try await manager.install(
                ModInstallRequest(instanceID: instance.id, projectIDOrSlug: "dep")
            ) { _ in }
            XCTFail("Expected duplicate-install rejection")
        } catch {
            XCTAssertEqual((error as? LauncherError)?.code, .usageError)
        }
        XCTAssertEqual(try manager.installed(instanceID: instance.id).filter { $0.projectID == "dep" }.count, 1)
    }

    func testIncompatibleDependencyDoesNotBlockWhenProjectIsAbsent() async throws {
        let instance = try makeFabricInstance()
        let transport = ModrinthRoutingTransport()
        let fixtures = SyntheticModAPI()
        await fixtures.populate(transport)
        await fixtures.setIncompatible(transport)
        let client = ModrinthClient(
            baseURL: URL(string: "https://api.modrinth.test/v2")!,
            transport: transport
        )
        let manager = ModManager(layout: layout, transport: transport, client: client)
        let report = try await manager.install(
            ModInstallRequest(instanceID: instance.id, projectIDOrSlug: "testmod")
        ) { _ in }
        XCTAssertEqual(report.installed.map(\.projectID), ["testmod"])
        XCTAssertEqual(try manager.installed(instanceID: instance.id).map(\.projectID), ["testmod"])
    }

    func testIncompatibleDependencyRejectsOnlyEnabledInstalledProject() async throws {
        let instance = try makeFabricInstance()
        let transport = ModrinthRoutingTransport()
        let fixtures = SyntheticModAPI()
        await fixtures.populate(transport)
        let client = ModrinthClient(
            baseURL: URL(string: "https://api.modrinth.test/v2")!,
            transport: transport
        )
        let manager = ModManager(layout: layout, transport: transport, client: client)
        _ = try await manager.install(
            ModInstallRequest(instanceID: instance.id, projectIDOrSlug: "dep")
        ) { _ in }
        await fixtures.setIncompatible(transport)
        do {
            _ = try await manager.install(
                ModInstallRequest(instanceID: instance.id, projectIDOrSlug: "testmod")
            ) { _ in }
            XCTFail("Expected enabled incompatible project to be rejected")
        } catch {
            XCTAssertEqual((error as? LauncherError)?.code, .usageError)
        }
        XCTAssertEqual(try manager.installed(instanceID: instance.id).filter { $0.projectID == "testmod" }.count, 0)
    }

    func testIncompatibleDependencyHonorsVersionConstraint() async throws {
        let instance = try makeFabricInstance()
        let transport = ModrinthRoutingTransport()
        let fixtures = SyntheticModAPI()
        await fixtures.populate(transport)
        let client = ModrinthClient(
            baseURL: URL(string: "https://api.modrinth.test/v2")!,
            transport: transport
        )
        let manager = ModManager(layout: layout, transport: transport, client: client)
        _ = try await manager.install(
            ModInstallRequest(instanceID: instance.id, projectIDOrSlug: "dep")
        ) { _ in }

        // A different pinned version is not a conflict.
        await fixtures.setIncompatibleConstraint(transport, versionID: "dep-v2")
        let report = try await manager.install(
            ModInstallRequest(instanceID: instance.id, projectIDOrSlug: "testmod")
        ) { _ in }
        XCTAssertEqual(report.primary.projectID, "testmod")
        try manager.remove(fileName: "testmod-v1.jar", instanceID: instance.id)

        // The installed version matches the constraint, so the install must be rejected.
        await fixtures.setIncompatibleConstraint(transport, versionID: "dep-v1")
        do {
            _ = try await manager.install(
                ModInstallRequest(instanceID: instance.id, projectIDOrSlug: "testmod")
            ) { _ in }
            XCTFail("Expected pinned incompatible version to be rejected")
        } catch {
            XCTAssertEqual((error as? LauncherError)?.code, .usageError)
        }
    }

    func testIncompatibleDependencyIsIgnoredWhenConflictIsDisabled() async throws {
        let instance = try makeFabricInstance()
        let transport = ModrinthRoutingTransport()
        let fixtures = SyntheticModAPI()
        await fixtures.populate(transport)
        let client = ModrinthClient(
            baseURL: URL(string: "https://api.modrinth.test/v2")!,
            transport: transport
        )
        let manager = ModManager(layout: layout, transport: transport, client: client)
        _ = try await manager.install(
            ModInstallRequest(instanceID: instance.id, projectIDOrSlug: "dep")
        ) { _ in }
        _ = try manager.setEnabled(false, fileName: "dep-v1.jar", instanceID: instance.id)
        await fixtures.setIncompatible(transport)
        let report = try await manager.install(
            ModInstallRequest(instanceID: instance.id, projectIDOrSlug: "testmod")
        ) { _ in }
        XCTAssertEqual(report.primary.projectID, "testmod")
        XCTAssertFalse(try manager.installed(instanceID: instance.id).first { $0.projectID == "dep" }?.enabled ?? true)
    }

    func testFailedUpdateLeavesOldJarAndMetadata() async throws {
        let instance = try makeFabricInstance()
        let transport = ModrinthRoutingTransport()
        let fixtures = SyntheticModAPI()
        await fixtures.populate(transport)
        let client = ModrinthClient(
            baseURL: URL(string: "https://api.modrinth.test/v2")!,
            transport: transport
        )
        let manager = ModManager(layout: layout, transport: transport, client: client)
        _ = try await manager.install(ModInstallRequest(instanceID: instance.id, projectIDOrSlug: "testmod")) { _ in }
        let old = try Data(contentsOf: instance.gameDirectory.appendingPathComponent("mods/testmod-v1.jar"))

        await fixtures.setBadUpdate(transport)
        do {
            _ = try await manager.install(
                ModInstallRequest(instanceID: instance.id, projectIDOrSlug: "testmod", versionID: "testmod-v2", allowReplace: true)
            ) { _ in }
            XCTFail("Expected hash failure")
        } catch {
            XCTAssertEqual((error as? LauncherError)?.code, .hashMismatch)
        }
        XCTAssertEqual(try Data(contentsOf: instance.gameDirectory.appendingPathComponent("mods/testmod-v1.jar")), old)
        let mods = try manager.installed(instanceID: instance.id)
        XCTAssertEqual(mods.first { $0.projectID == "testmod" }?.fileName, "testmod-v1.jar")
    }

    func testUpdatingDisabledModPreservesDisabledState() async throws {
        let instance = try makeFabricInstance()
        let transport = ModrinthRoutingTransport()
        let fixtures = SyntheticModAPI()
        await fixtures.populate(transport)
        let client = ModrinthClient(
            baseURL: URL(string: "https://api.modrinth.test/v2")!,
            transport: transport
        )
        let manager = ModManager(layout: layout, transport: transport, client: client)
        _ = try await manager.install(
            ModInstallRequest(instanceID: instance.id, projectIDOrSlug: "testmod")
        ) { _ in }
        _ = try manager.setEnabled(false, fileName: "testmod-v1.jar", instanceID: instance.id)
        await fixtures.setValidUpdate(transport)
        let report = try await manager.install(
            ModInstallRequest(
                instanceID: instance.id,
                projectIDOrSlug: "testmod",
                versionID: "testmod-v2",
                allowReplace: true
            )
        ) { _ in }
        XCTAssertFalse(report.primary.enabled)
        let all = try manager.installed(instanceID: instance.id)
        let updated = try XCTUnwrap(all.first { $0.projectID == "testmod" })
        XCTAssertEqual(updated.versionID, "testmod-v2")
        XCTAssertFalse(updated.enabled)
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: instance.directory.appendingPathComponent("mods-disabled/testmod-v2.jar").path
        ))
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: instance.gameDirectory.appendingPathComponent("mods/testmod-v2.jar").path
        ))
    }

    func testUpdateDetectionUsesChannelAndVersionNotDate() async throws {
        let instance = try makeFabricInstance()
        let transport = ModrinthRoutingTransport()
        let fixtures = SyntheticModAPI()
        await fixtures.populate(transport)
        let client = ModrinthClient(
            baseURL: URL(string: "https://api.modrinth.test/v2")!,
            transport: transport
        )
        let manager = ModManager(layout: layout, transport: transport, client: client)
        _ = try await manager.install(
            ModInstallRequest(instanceID: instance.id, projectIDOrSlug: "testmod")
        ) { _ in }

        // A newer date does not make a beta eligible for a release installation.
        await fixtures.setVersions(transport, versions: [fixtures.currentRelease, fixtures.newerBeta])
        let betaUpdates = try await manager.updates(instanceID: instance.id)
        XCTAssertTrue(betaUpdates.isEmpty)

        // A newer release is eligible.
        await fixtures.setVersions(transport, versions: [fixtures.currentRelease, fixtures.newerRelease])
        let updates = try await manager.updates(instanceID: instance.id)
        XCTAssertEqual(updates.count, 1)
        XCTAssertEqual(updates.first?.latestVersionID, "testmod-v2")
        XCTAssertEqual(updates.first?.latestVersionType, .release)

        // A release published later but carrying an older version number must not downgrade.
        await fixtures.setVersions(transport, versions: [fixtures.currentRelease, fixtures.olderRelease])
        let olderUpdates = try await manager.updates(instanceID: instance.id)
        XCTAssertTrue(olderUpdates.isEmpty)
    }

    func testMrpackTracerPromotesVerifiedHashesAndLeavesUnknownJarsLocal() async throws {
        let instance = try makeFabricInstance()
        let repository = ModRepository(layout: layout)
        let tracedData = Data("traced-mod".utf8)
        let unknownData = Data("unknown-mod".utf8)
        let staged = repository.stagingDirectory(instance: instance)
        try FileManager.default.createDirectory(at: staged, withIntermediateDirectories: true)
        let tracedURL = staged.appendingPathComponent("traced.jar")
        let unknownURL = staged.appendingPathComponent("unknown.jar")
        try tracedData.write(to: tracedURL)
        try unknownData.write(to: unknownURL)
        try repository.commitInstall(instance: instance, staged: [
            StagedModFile(
                temporaryURL: tracedURL,
                record: InstalledMod(title: "traced.jar", fileName: "traced.jar", sha1: SHA1.hexDigest(tracedData), enabled: true)
            ),
            StagedModFile(
                temporaryURL: unknownURL,
                record: InstalledMod(title: "unknown.jar", fileName: "unknown.jar", sha1: SHA1.hexDigest(unknownData), enabled: true)
            ),
        ])

        let transport = ModrinthRoutingTransport()
        let fixtures = SyntheticModAPI()
        await fixtures.populateTrace(transport, tracedData: tracedData)
        let client = ModrinthClient(
            baseURL: URL(string: "https://api.modrinth.test/v2")!,
            transport: transport
        )
        let files = [
            MrpackFile(
                relativePath: "mods/traced.jar",
                sha1: SHA1.hexDigest(tracedData),
                sha512: SHA512Digest.hexDigest(tracedData),
                downloadURL: URL(string: "https://cdn.modrinth.com/data/testmod/versions/traced-v1/traced.jar")!,
                fileSize: tracedData.count,
                clientEnvironment: "required"
            ),
            MrpackFile(
                relativePath: "mods/unknown.jar",
                sha1: SHA1.hexDigest(unknownData),
                sha512: SHA512Digest.hexDigest(unknownData),
                downloadURL: URL(string: "https://cdn.modrinth.com/data/unknown/versions/1/unknown.jar")!,
                fileSize: unknownData.count,
                clientEnvironment: "required"
            ),
        ]

        let tracer = MrpackSourceTracer(client: client)
        let summary = await tracer.trace(instance: instance, files: files, repository: repository)
        XCTAssertEqual(summary.identifiedFiles, 1)
        XCTAssertEqual(summary.localFiles, 1)
        XCTAssertTrue(summary.warnings.isEmpty)

        let records = try repository.list(instance: instance)
        let traced = try XCTUnwrap(records.first { $0.fileName == "traced.jar" })
        XCTAssertEqual(traced.source, "modrinth")
        XCTAssertEqual(traced.projectID, "testmod")
        XCTAssertEqual(traced.versionID, "traced-v1")
        XCTAssertEqual(records.first { $0.fileName == "unknown.jar" }?.source, "local")

        // A traced import must participate in the normal update flow.
        let manager = ModManager(layout: layout, transport: transport, client: client)
        let updates = try await manager.updates(instanceID: instance.id)
        XCTAssertEqual(updates.first?.projectID, "testmod")
        XCTAssertEqual(updates.first?.latestVersionID, "traced-v2")
        let posted = await transport.postedBodies["/v2/version_files"]
        XCTAssertNotNil(posted)
    }

    // MARK: - Fixtures

    private func makeFabricInstance() throws -> Instance {
        let parentID = "1.20.1"
        let profileID = "fabric-loader-0.20.1-1.20.1"
        for (id, fixture) in [
            (parentID, "versions/1.20.1.json"),
            (profileID, "versions/fabric-loader-0.20.1-1.20.1.json"),
        ] {
            let directory = layout.gameRoot.appendingPathComponent("versions/\(id)", isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try FileManager.default.copyItem(
                at: try FixtureLoader.url(fixture),
                to: directory.appendingPathComponent("\(id).json")
            )
        }
        return try InstanceRepository(layout: layout).create(
            id: "mod-instance",
            displayName: "Mod Test",
            versionID: profileID
        )
    }
}

private struct SyntheticModAPI {
    let testV1 = Data("testmod-v1".utf8)
    let testV2 = Data("testmod-v2".utf8)
    let depV1 = Data("dep-v1".utf8)

    func populate(_ transport: ModrinthRoutingTransport) async {
        await transport.setAPI(path: "/v2/project/testmod", data: json(project(id: "testmod", title: "Test Mod")))
        await transport.setAPI(path: "/v2/project/dep", data: json(project(id: "dep", title: "Test Dependency")))
        await transport.setAPI(path: "/v2/project/testmod/version", data: json([version])
        )
        await transport.setAPI(path: "/v2/project/dep/version", data: json([depVersion]))
        await transport.setAPI(path: "/v2/version/dep-v1", data: json(depVersion))
        await transport.setAPI(path: "/v2/version/testmod-v2", data: json(badUpdateVersion))
        await transport.setFile(path: "/testmod-v1.jar", data: testV1)
        await transport.setFile(path: "/dep-v1.jar", data: depV1)
    }

    func setIncompatible(_ transport: ModrinthRoutingTransport) async {
        await transport.setAPI(path: "/v2/project/testmod/version", data: json([incompatibleVersion]))
    }

    func setIncompatibleConstraint(_ transport: ModrinthRoutingTransport, versionID: String?) async {
        var value = version
        value["dependencies"] = [[
            "project_id": "dep",
            "version_id": versionID.map { $0 as Any } ?? NSNull(),
            "file_name": NSNull(), "dependency_type": "incompatible",
        ]]
        await transport.setAPI(path: "/v2/project/testmod/version", data: json([value]))
    }

    func setValidUpdate(_ transport: ModrinthRoutingTransport) async {
        await transport.setAPI(path: "/v2/project/testmod/version", data: json([goodUpdateVersion]))
        await transport.setAPI(path: "/v2/version/testmod-v2", data: json(goodUpdateVersion))
        await transport.setFile(path: "/testmod-v2.jar", data: testV2)
    }

    func setVersions(_ transport: ModrinthRoutingTransport, versions: [[String: Any]]) async {
        await transport.setAPI(path: "/v2/project/testmod/version", data: json(versions))
    }

    var currentRelease: [String: Any] { version }
    var newerBeta: [String: Any] { version(id: "testmod-beta", number: "2.0-beta", date: "2026-03-01T00:00:00Z", type: "beta", fileData: testV1, fileName: "testmod-beta.jar") }
    var newerRelease: [String: Any] { version(id: "testmod-v2", number: "2.0", date: "2026-02-01T00:00:00Z", type: "release", fileData: testV2, fileName: "testmod-v2.jar") }
    var olderRelease: [String: Any] { version(id: "testmod-old", number: "0.9", date: "2026-04-01T00:00:00Z", type: "release", fileData: testV1, fileName: "testmod-old.jar") }
    var goodUpdateVersion: [String: Any] { newerRelease }

    func setBadUpdate(_ transport: ModrinthRoutingTransport) async {
        await transport.setAPI(path: "/v2/project/testmod/version", data: json([badUpdateVersion]))
        await transport.setAPI(path: "/v2/version/testmod-v2", data: json(badUpdateVersion))
        await transport.setFile(path: "/testmod-v2.jar", data: Data("corrupt-v2".utf8))
    }

    func populateTrace(_ transport: ModrinthRoutingTransport, tracedData: Data) async {
        let current = tracedVersion(data: tracedData, id: "traced-v1", number: "1.0")
        let update = tracedVersion(data: Data("traced-v2".utf8), id: "traced-v2", number: "2.0")
        let hash = SHA1.hexDigest(tracedData)
        await transport.setAPI(path: "/v2/version_files", data: json([:]))
        await transport.setAPI(path: "/v2/version_files", data: json([hash: current]))
        await transport.setAPI(path: "/v2/project/testmod", data: json(project(id: "testmod", title: "Test Mod")))
        await transport.setAPI(path: "/v2/project/testmod/version", data: json([current, update]))
    }

    private func tracedVersion(data: Data, id: String, number: String) -> [String: Any] {
        [
            "id": id, "project_id": "testmod", "name": number, "version_number": number,
            "dependencies": [], "game_versions": ["1.20.1"], "version_type": "release", "loaders": ["fabric"],
            "date_published": "2026-01-01T00:00:00Z", "downloads": 1, "status": "listed",
            "files": [file(name: "traced-\(id).jar", data: data)],
        ]
    }

    private var version: [String: Any] {
        [
            "id": "testmod-v1", "project_id": "testmod", "name": "1.0", "version_number": "1.0",
            "dependencies": [["project_id": "dep", "version_id": "dep-v1", "file_name": NSNull(), "dependency_type": "required"]],
            "game_versions": ["1.20.1"], "version_type": "release", "loaders": ["fabric"],
            "date_published": "2026-01-01T00:00:00Z", "downloads": 1, "status": "listed",
            "files": [file(name: "testmod-v1.jar", data: testV1)],
        ]
    }

    private var incompatibleVersion: [String: Any] {
        var value = version
        value["dependencies"] = [["project_id": "dep", "version_id": NSNull(), "file_name": NSNull(), "dependency_type": "incompatible"]]
        return value
    }

    private var depVersion: [String: Any] {
        [
            "id": "dep-v1", "project_id": "dep", "name": "1.0", "version_number": "1.0",
            "dependencies": [], "game_versions": ["1.20.1"], "version_type": "release", "loaders": ["fabric"],
            "date_published": "2026-01-01T00:00:00Z", "downloads": 1, "status": "listed",
            "files": [file(name: "dep-v1.jar", data: depV1)],
        ]
    }

    private func version(
        id: String,
        number: String,
        date: String,
        type: String,
        fileData: Data,
        fileName: String
    ) -> [String: Any] {
        [
            "id": id, "project_id": "testmod", "name": number, "version_number": number,
            "dependencies": [], "game_versions": ["1.20.1"], "version_type": type, "loaders": ["fabric"],
            "date_published": date, "downloads": 1, "status": "listed",
            "files": [file(name: fileName, data: fileData)],
        ]
    }

    private var badUpdateVersion: [String: Any] {
        [
            "id": "testmod-v2", "project_id": "testmod", "name": "2.0", "version_number": "2.0",
            "dependencies": [], "game_versions": ["1.20.1"], "version_type": "release", "loaders": ["fabric"],
            "date_published": "2026-02-01T00:00:00Z", "downloads": 2, "status": "listed",
            "files": [file(name: "testmod-v2.jar", hashData: testV2)],
        ]
    }

    private func project(id: String, title: String) -> [String: Any] {
        [
            "id": id, "slug": id, "title": title, "description": "Synthetic test project", "body": "Body",
            "icon_url": NSNull(), "categories": ["fabric"], "game_versions": ["1.20.1"], "loaders": ["fabric"],
            "downloads": 1, "follows": 0, "versions": [id + "-v1"], "updated": "2026-01-01T00:00:00Z",
            "license": ["id": "MIT", "name": "MIT", "url": NSNull()],
        ]
    }

    private func file(name: String, data: Data) -> [String: Any] {
        ["hashes": ["sha1": SHA1.hexDigest(data), "sha512": SHA512Digest.hexDigest(data)],
         "url": "https://cdn.modrinth.com/\(name)", "filename": name, "primary": true,
         "size": data.count, "file_type": NSNull()]
    }

    private func file(name: String, hashData: Data) -> [String: Any] {
        // Deliberately publish hashes for different bytes: the update must fail verification.
        ["hashes": ["sha1": SHA1.hexDigest(hashData), "sha512": SHA512Digest.hexDigest(hashData)],
         "url": "https://cdn.modrinth.com/\(name)", "filename": name, "primary": true,
         "size": hashData.count, "file_type": NSNull()]
    }

    private func json(_ value: Any) -> Data {
        try! JSONSerialization.data(withJSONObject: value, options: [])
    }
}
