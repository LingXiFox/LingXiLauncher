import XCTest
@testable import LauncherCore

private struct FixedRuntime: InstanceRuntimeChecking {
    let running: Bool
    func isRunning(instanceID: String) -> Bool { running }
}

private actor GraphicsTransport: DownloadTransport {
    private var api: [String: Data] = [:]
    private var files: [String: Data] = [:]
    private(set) var requestedURLs: [URL] = []
    private(set) var postedBodies: [String: Data] = [:]
    private(set) var downloadCount = 0

    func setJSONData(_ path: String, _ data: Data) {
        api[path] = data
    }

    func setData(_ path: String, _ data: Data) { files[path] = data }

    func fetch(from url: URL) async throws -> Data {
        try await fetch(from: url, headers: [:])
    }

    func fetch(from url: URL, headers: [String: String]) async throws -> Data {
        requestedURLs.append(url)
        guard let data = api[url.path] else { throw TransportError.httpStatus(404) }
        return data
    }

    func postJSON(from url: URL, body: Data, headers: [String: String]) async throws -> Data {
        requestedURLs.append(url)
        postedBodies[url.path] = body
        guard let data = api[url.path] else { throw TransportError.httpStatus(404) }
        return data
    }

    func download(from url: URL, to destination: URL) async throws {
        requestedURLs.append(url)
        downloadCount += 1
        guard let data = files[url.absoluteString] else { throw TransportError.httpStatus(404) }
        try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: destination)
    }
}

final class M7GraphicsTests: XCTestCase {
    private var root: URL!
    private var layout: GameDataLayout!

    override func setUpWithError() throws {
        root = try FixtureLoader.temporaryDirectory("lingxi-m7-graphics")
        layout = GameDataLayout(
            gameRoot: root.appendingPathComponent("mc", isDirectory: true),
            dataRoot: root.appendingPathComponent("data", isDirectory: true)
        )
    }

    override func tearDownWithError() throws {
        if let root { try? FileManager.default.removeItem(at: root) }
    }

    func testGraphicsSetupInstallsPinnedIrisAndSodiumWithShaderFacets() async throws {
        let instance = try makeFabricInstance()
        let transport = GraphicsTransport()
        let api = GraphicsAPI()
        try await api.populate(transport)

        let client = ModrinthClient(baseURL: api.baseURL, transport: transport)
        let manager = GraphicsSetupManager(layout: layout, transport: transport, client: client)
        let environment = try await manager.environment(instanceID: instance.id)
        XCTAssertEqual(environment.gameVersion, "1.20.1")
        XCTAssertNil(environment.iris)
        XCTAssertEqual(environment.recommendedIris?.id, "iris-v1")
        XCTAssertEqual(environment.recommendedSodium?.id, "sodium-v1")
        XCTAssertFalse(environment.isReady)

        let shaderManager = ShaderPackManager(layout: layout, transport: transport, client: client)
        _ = try await shaderManager.search(instanceID: instance.id, query: "")
        let urls = await transport.requestedURLs
        let searchURL = try XCTUnwrap(urls.last {
            $0.path == "/v2/search" && $0.query?.contains("project_type") == true
        })
        let facets = try XCTUnwrap(URLComponents(url: searchURL, resolvingAgainstBaseURL: false)?
            .queryItems?.first(where: { $0.name == "facets" })?.value)
        XCTAssertTrue(facets.contains("project_type:shader"))
        XCTAssertFalse(facets.contains("categories:fabric"))

        let plan = try await manager.plan(instanceID: instance.id)
        XCTAssertFalse(plan.requiresReplacement)
        let report = try await manager.install(instanceID: instance.id, allowReplace: false) { _ in }
        XCTAssertEqual(report.installedIris.projectID, GraphicsSetupManager.irisProjectID)
        XCTAssertEqual(report.installedSodium.projectID, GraphicsSetupManager.sodiumProjectID)
        XCTAssertTrue(report.environment.isReady)

        let mods = try ModManager(layout: layout, transport: transport, client: client).installed(instanceID: instance.id)
        XCTAssertTrue(FileManager.default.fileExists(atPath: instance.gameDirectory.appendingPathComponent("mods/iris.jar").path))
        XCTAssertTrue(mods.contains { $0.projectID == GraphicsSetupManager.irisProjectID && $0.versionNumber == "1.7.6" })
    }

    func testExistingGraphicsPairRequiresExplicitReplacement() async throws {
        let instance = try makeFabricInstance()
        let transport = GraphicsTransport()
        let api = GraphicsAPI()
        try await api.populate(transport)
        let client = ModrinthClient(baseURL: api.baseURL, transport: transport)
        let manager = GraphicsSetupManager(layout: layout, transport: transport, client: client)
        _ = try await manager.install(instanceID: instance.id) { _ in }

        try await api.makeNewerPair(transport)
        let plan = try await manager.plan(instanceID: instance.id)
        XCTAssertTrue(plan.requiresReplacement)
        let before = await transport.downloadCount
        do {
            _ = try await manager.install(instanceID: instance.id, allowReplace: false) { _ in }
            XCTFail("expected explicit replacement consent")
        } catch let error as LauncherError {
            XCTAssertEqual(error.code, .usageError)
        }
        let after = await transport.downloadCount
        XCTAssertEqual(after, before, "refusal must happen before any download")
        let installed = try ModManager(layout: layout, transport: transport, client: client).installed(instanceID: instance.id)
        XCTAssertEqual(installed.first { $0.projectID == GraphicsSetupManager.irisProjectID }?.versionID, "iris-v1")
    }

    func testShaderInstallActivationPreservesConfigAndVerifiesZip() async throws {
        let instance = try makeFabricInstance()
        let transport = GraphicsTransport()
        let api = GraphicsAPI()
        try await api.populate(transport)
        let client = ModrinthClient(baseURL: api.baseURL, transport: transport)
        _ = try await GraphicsSetupManager(layout: layout, transport: transport, client: client)
            .install(instanceID: instance.id) { _ in }
        let manager = ShaderPackManager(layout: layout, transport: transport, client: client)

        let result = try await manager.install(instanceID: instance.id, projectIDOrSlug: "shader") { _ in }
        XCTAssertEqual(result.installed.projectID, "shader")
        let zip = instance.gameDirectory.appendingPathComponent("shaderpacks/complementary.zip")
        XCTAssertTrue(FileManager.default.fileExists(atPath: zip.path))
        XCTAssertEqual(try Data(contentsOf: zip), api.shaderData)

        let config = instance.gameDirectory.appendingPathComponent("config/iris.properties")
        try FileManager.default.createDirectory(at: config.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("shaderPack=old.zip\nenableShaders=false\n# keep me\nlanguage=zh\n".utf8).write(to: config)
        let activation = try manager.activate(fileName: "complementary.zip", instanceID: instance.id)
        XCTAssertNotNil(activation.backupURL)
        let text = try String(contentsOf: config, encoding: .utf8)
        XCTAssertTrue(text.contains("shaderPack=complementary.zip"))
        XCTAssertTrue(text.contains("enableShaders=true"))
        XCTAssertTrue(text.contains("language=zh"))
        XCTAssertEqual(try manager.activationState(instanceID: instance.id).kind, .enabled)
    }

    func testGraphicsUpgradeFailureRestoresBothOldMods() async throws {
        let instance = try makeFabricInstance()
        let transport = GraphicsTransport()
        let api = GraphicsAPI()
        try await api.populate(transport)
        let client = ModrinthClient(baseURL: api.baseURL, transport: transport)
        let manager = GraphicsSetupManager(layout: layout, transport: transport, client: client)
        _ = try await manager.install(instanceID: instance.id) { _ in }

        try await api.makeNewerPair(transport, failIrisDownload: true)
        do {
            _ = try await manager.install(instanceID: instance.id, allowReplace: true) { _ in }
            XCTFail("expected Iris download failure after Sodium replacement")
        } catch let error as LauncherError {
            XCTAssertEqual(error.code, .sizeMismatch)
        }

        let mods = try ModManager(layout: layout, transport: transport, client: client)
            .installed(instanceID: instance.id)
        XCTAssertEqual(mods.first { $0.projectID == GraphicsSetupManager.irisProjectID }?.versionID, "iris-v1")
        XCTAssertEqual(mods.first { $0.projectID == GraphicsSetupManager.sodiumProjectID }?.versionID, "sodium-v1")
        XCTAssertEqual(
            try Data(contentsOf: instance.gameDirectory.appendingPathComponent("mods/sodium.jar")),
            api.sodiumData
        )
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: instance.directory.path)
        XCTAssertFalse(leftovers.contains { $0.hasPrefix("mods-backup-") }, "snapshot staging must be cleaned")
    }

    func testShaderRepositoryRestoresOldFileWhenStagedCommitFails() async throws {
        let instance = try makeFabricInstance()
        let transport = GraphicsTransport()
        let api = GraphicsAPI()
        try await api.populate(transport)
        let client = ModrinthClient(baseURL: api.baseURL, transport: transport)
        _ = try await GraphicsSetupManager(layout: layout, transport: transport, client: client)
            .install(instanceID: instance.id) { _ in }
        let manager = ShaderPackManager(layout: layout, transport: transport, client: client)
        let old = try await manager.install(instanceID: instance.id, projectIDOrSlug: "shader") { _ in }.installed
        let repository = ShaderPackRepository(layout: layout)
        let missingStage = instance.directory.appendingPathComponent("missing-stage.zip")
        let replacement = InstalledShaderPack(
            projectID: old.projectID,
            slug: old.slug,
            title: old.title,
            versionID: "shader-v2",
            versionNumber: "2.0",
            fileName: old.fileName,
            sha1: old.sha1,
            sha512: old.sha512,
            fileSize: old.fileSize,
            source: .modrinth,
            license: old.license,
            iconURL: old.iconURL,
            installedAt: Date()
        )
        XCTAssertThrowsError(try repository.commit(
            instance: instance,
            stagedURL: missingStage,
            record: replacement,
            replacingFileName: old.fileName,
            allowReplace: true
        ))
        let zip = instance.gameDirectory.appendingPathComponent("shaderpacks/complementary.zip")
        XCTAssertEqual(try Data(contentsOf: zip), api.shaderData)
        XCTAssertEqual(try manager.installed(instanceID: instance.id).first?.versionID, "shader-v1")
    }

    func testShaderInstallHashFailureLeavesWorldsConfigsAndRecordsUntouched() async throws {
        let instance = try makeFabricInstance()
        let transport = GraphicsTransport()
        let api = GraphicsAPI()
        try await api.populate(transport, corruptShaderHash: true)
        let client = ModrinthClient(baseURL: api.baseURL, transport: transport)
        let manager = ShaderPackManager(layout: layout, transport: transport, client: client)
        let world = instance.gameDirectory.appendingPathComponent("saves/world/level.dat")
        let config = instance.gameDirectory.appendingPathComponent("config/client.txt")
        try FileManager.default.createDirectory(at: world.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: config.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("world".utf8).write(to: world)
        try Data("client-config".utf8).write(to: config)

        do {
            _ = try await manager.install(instanceID: instance.id, projectIDOrSlug: "shader") { _ in }
            XCTFail("expected hash failure")
        } catch let error as LauncherError {
            XCTAssertEqual(error.code, .hashMismatch)
        }
        XCTAssertEqual(try Data(contentsOf: world), Data("world".utf8))
        XCTAssertEqual(try Data(contentsOf: config), Data("client-config".utf8))
        XCTAssertFalse(FileManager.default.fileExists(atPath: instance.gameDirectory.appendingPathComponent("shaderpacks/complementary.zip").path))
        XCTAssertTrue(try manager.installed(instanceID: instance.id).isEmpty)
    }

    func testNonFabricInstanceIsRejectedBeforeNetworkOrFileWrite() async throws {
        let instance = try makeVanillaInstance()
        let transport = GraphicsTransport()
        let client = ModrinthClient(baseURL: GraphicsAPI().baseURL, transport: transport)
        let manager = ShaderPackManager(layout: layout, transport: transport, client: client)

        do {
            _ = try await manager.install(instanceID: instance.id, projectIDOrSlug: "shader") { _ in }
            XCTFail("vanilla instances must not install shader packs")
        } catch let error as LauncherError {
            XCTAssertEqual(error.code, .unsupportedVersion)
        }
        let downloads = await transport.downloadCount
        XCTAssertEqual(downloads, 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: instance.gameDirectory.appendingPathComponent("shaderpacks").path))
    }

    func testActivationIsBlockedWhileGameRunsAndDeactivationIsSafe() async throws {
        let instance = try makeFabricInstance()
        let transport = GraphicsTransport()
        let api = GraphicsAPI()
        try await api.populate(transport)
        let client = ModrinthClient(baseURL: api.baseURL, transport: transport)
        _ = try await GraphicsSetupManager(layout: layout, transport: transport, client: client)
            .install(instanceID: instance.id) { _ in }
        let manager = ShaderPackManager(
            layout: layout, transport: transport, client: client,
            runtime: FixedRuntime(running: false)
        )
        _ = try await manager.install(instanceID: instance.id, projectIDOrSlug: "shader") { _ in }
        _ = try manager.activate(fileName: "complementary.zip", instanceID: instance.id)

        let blockingManager = ShaderPackManager(
            layout: layout, transport: transport, client: client,
            runtime: FixedRuntime(running: true)
        )
        do {
            _ = try await blockingManager.install(instanceID: instance.id, projectIDOrSlug: "shader") { _ in }
            XCTFail("shader install/update must be blocked while the game runs")
        } catch let error as LauncherError {
            XCTAssertEqual(error.code, .usageError)
        }
        XCTAssertThrowsError(try blockingManager.activate(fileName: "complementary.zip", instanceID: instance.id)) { error in
            XCTAssertEqual((error as? LauncherError)?.code, .usageError)
        }
        XCTAssertThrowsError(try blockingManager.remove(fileName: "complementary.zip", instanceID: instance.id)) { error in
            XCTAssertEqual((error as? LauncherError)?.code, .usageError)
        }

        let result = try manager.deactivate(instanceID: instance.id)
        XCTAssertNotNil(result.backupURL)
        let config = try String(contentsOf: result.configURL, encoding: .utf8)
        XCTAssertTrue(config.contains("enableShaders=false"))
        XCTAssertTrue(config.contains("shaderPack="))
    }

    func testUnsupportedMacOpenGLPathWarnsWithoutClaimingMetalRayTracing() {
        let unavailable = GraphicsCapabilities(
            openGLVersion: nil,
            renderer: nil,
            shadingLanguageVersion: nil,
            isAppleSilicon: true,
            probeError: "CGLChoosePixelFormat failed"
        )
        XCTAssertTrue(unavailable.isLegacyOpenGL)
        XCTAssertNil(unavailable.openGLMajor)
        XCTAssertNotNil(unavailable.shaderCompatibilityWarning)
        XCTAssertEqual(unavailable.summary, "OpenGL 信息不可用")

        let legacy = GraphicsCapabilities(
            openGLVersion: "4.1 Metal - 91.7",
            renderer: "Apple M5",
            shadingLanguageVersion: "4.10",
            isAppleSilicon: true,
            probeError: nil
        )
        XCTAssertTrue(legacy.isLegacyOpenGL)
        XCTAssertEqual(legacy.openGLMajor, 4)
        XCTAssertEqual(legacy.openGLMinor, 1)
        let warning = try! XCTUnwrap(legacy.shaderCompatibilityWarning)
        XCTAssertTrue(warning.contains("OpenGL 4.1"))
        XCTAssertFalse(warning.lowercased().contains("rtx"))
    }

    func testMalformedLocalShaderIsRejectedWithoutMetadataOrFileCommit() throws {
        let instance = try makeFabricInstance()
        let transport = GraphicsTransport()
        let client = ModrinthClient(baseURL: GraphicsAPI().baseURL, transport: transport)
        let manager = ShaderPackManager(layout: layout, transport: transport, client: client)
        let bad = root.appendingPathComponent("not-a-zip.zip")
        try Data("not a zip".utf8).write(to: bad)

        XCTAssertThrowsError(try manager.importLocal(archiveURL: bad, instanceID: instance.id) { _ in }) { error in
            XCTAssertEqual((error as? LauncherError)?.code, .invalidMetadata)
        }
        XCTAssertTrue(try manager.installed(instanceID: instance.id).isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: instance.gameDirectory.appendingPathComponent("shaderpacks/not-a-zip.zip").path))
    }

    private func json(_ value: Any) throws -> Data {
        try JSONSerialization.data(withJSONObject: value)
    }

    private func makeVanillaInstance() throws -> Instance {
        let id = "1.20.1"
        let directory = layout.gameRoot.appendingPathComponent("versions/\(id)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try FileManager.default.copyItem(
            at: try FixtureLoader.url("versions/1.20.1.json"),
            to: directory.appendingPathComponent("\(id).json")
        )
        return try InstanceRepository(layout: layout).create(id: "vanilla-graphics", displayName: "Vanilla Graphics", versionID: id)
    }

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
        return try InstanceRepository(layout: layout).create(id: "graphics-instance", displayName: "Graphics Test", versionID: profileID)
    }
}

private struct GraphicsAPI {
    let baseURL = URL(string: "https://api.modrinth.test/v2")!
    let fileBase = "https://cdn.modrinth.com/data"
    let irisData = Data(repeating: 0x49, count: 64)
    let sodiumData = Data(repeating: 0x53, count: 64)
    var shaderData: Data { Data([0x50, 0x4B, 0x05, 0x06]) + Data(repeating: 0, count: 18) }

    func populate(_ transport: GraphicsTransport, corruptShaderHash: Bool = false) async throws {
        try await setProject(transport, id: "YL57xq9U", slug: "iris", title: "Iris", type: "mod")
        try await setProject(transport, id: "AANobbMI", slug: "sodium", title: "Sodium", type: "mod")
        try await setProject(transport, id: "shader", slug: "complementary", title: "Complementary", type: "shader")
        try await setVersionList(transport, project: "YL57xq9U", versions: [irisVersion])
        try await setVersionList(transport, project: "AANobbMI", versions: [sodiumVersion])
        try await setVersionList(transport, project: "shader", versions: [shaderVersion(corruptHash: corruptShaderHash)])
        await transport.setJSONData("/v2/version/sodium-v1", try graphicsJSON(sodiumVersion))
        await transport.setJSONData("/v2/version/iris-v1", try graphicsJSON(irisVersion))
        await transport.setJSONData("/v2/search", try graphicsJSON(searchResult))
        await transport.setData(fileBase + "/iris.jar", irisData)
        await transport.setData(fileBase + "/sodium.jar", sodiumData)
        await transport.setData(fileBase + "/shader.zip", shaderData)
    }

    func makeNewerPair(_ transport: GraphicsTransport, failIrisDownload: Bool = false) async throws {
        var newerIris = irisVersion
        newerIris["id"] = "iris-v2"
        newerIris["version_number"] = "1.7.7"
        newerIris["date_published"] = "2026-02-01T00:00:00Z"
        newerIris["files"] = [file(name: "iris-v2.jar", path: "iris-v2.jar", data: Data(repeating: 0x69, count: 64))]
        var newerSodium = sodiumVersion
        newerSodium["id"] = "sodium-v2"
        newerSodium["version_number"] = "0.6.0"
        newerSodium["date_published"] = "2026-02-01T00:00:00Z"
        newerSodium["files"] = [file(name: "sodium-v2.jar", path: "sodium-v2.jar", data: Data(repeating: 0x73, count: 64))]
        var irisDeps = newerIris["dependencies"] as? [[String: Any]] ?? []
        irisDeps[0]["version_id"] = "sodium-v2"
        newerIris["dependencies"] = irisDeps
        try await setVersionList(transport, project: "YL57xq9U", versions: [newerIris])
        try await setVersionList(transport, project: "AANobbMI", versions: [newerSodium])
        await transport.setJSONData("/v2/version/sodium-v2", try graphicsJSON(newerSodium))
        await transport.setJSONData("/v2/version/iris-v2", try graphicsJSON(newerIris))
        await transport.setData(fileBase + "/iris-v2.jar", failIrisDownload ? Data() : Data(repeating: 0x69, count: 64))
        await transport.setData(fileBase + "/sodium-v2.jar", Data(repeating: 0x73, count: 64))
    }

    private func setProject(_ transport: GraphicsTransport, id: String, slug: String, title: String, type: String) async throws {
        let project: [String: Any] = [
            "id": id, "slug": slug, "title": title, "description": "test", "project_type": type,
            "icon_url": "https://cdn.modrinth.com/data/\(id)/icon.png",
            "license": ["id": "MIT", "name": "MIT", "url": "https://example.com"],
            "game_versions": ["1.20.1"], "loaders": ["fabric"], "categories": ["shaders"],
        ]
        let encoded = try graphicsJSON(project)
        await transport.setJSONData("/v2/project/\(slug)", encoded)
        await transport.setJSONData("/v2/project/\(id)", encoded)
    }

    private func setVersionList(_ transport: GraphicsTransport, project: String, versions: [[String: Any]]) async throws {
        await transport.setJSONData("/v2/project/\(project)/version", try graphicsJSON(versions))
    }

    private var irisVersion: [String: Any] {
        [
            "id": "iris-v1", "project_id": "YL57xq9U", "name": "Iris 1.7.6", "version_number": "1.7.6",
            "game_versions": ["1.20.1"], "loaders": ["fabric"], "version_type": "release",
            "date_published": "2026-01-01T00:00:00Z",
            "dependencies": [[
                "project_id": "AANobbMI", "version_id": "sodium-v1",
                "file_name": NSNull(), "dependency_type": "required",
            ]],
            "files": [file(name: "iris.jar", path: "iris.jar", data: irisData)],
        ]
    }

    private var sodiumVersion: [String: Any] {
        [
            "id": "sodium-v1", "project_id": "AANobbMI", "name": "Sodium 0.5.13", "version_number": "0.5.13",
            "game_versions": ["1.20.1"], "loaders": ["fabric"], "version_type": "release",
            "date_published": "2026-01-01T00:00:00Z", "dependencies": [],
            "files": [file(name: "sodium.jar", path: "sodium.jar", data: sodiumData)],
        ]
    }

    private func shaderVersion(corruptHash: Bool) -> [String: Any] {
        let digest = SHA512Digest.hexDigest(shaderData)
        return [
            "id": "shader-v1", "project_id": "shader", "name": "Complementary 1", "version_number": "1.0",
            "game_versions": ["1.20.1"], "loaders": ["fabric"], "version_type": "release",
            "date_published": "2026-01-01T00:00:00Z", "dependencies": [],
            "files": [
                [
                    "hashes": ["sha512": corruptHash ? String(repeating: "0", count: 128) : digest, "sha1": SHA1.hexDigest(shaderData)],
                    "url": fileBase + "/shader.zip", "filename": "complementary.zip",
                    "primary": true, "size": shaderData.count,
                ] as [String: Any],
            ],
        ]
    }

    private func file(name: String, path: String, data: Data) -> [String: Any] {
        [
            "hashes": ["sha512": SHA512Digest.hexDigest(data), "sha1": SHA1.hexDigest(data)],
            "url": fileBase + "/" + path, "filename": name,
            "primary": true, "size": data.count,
        ]
    }

    private var searchResult: [String: Any] {
        [
            "hits": [[
                "project_id": "shader", "slug": "complementary", "title": "Complementary",
                "description": "test shader", "project_type": "shader", "categories": ["shaders"],
                "versions": ["1.20.1"], "downloads": 1, "follows": 1,
                "icon_url": "https://cdn.modrinth.com/data/shader/icon.png",
            ]],
            "offset": 0, "limit": 20, "total_hits": 1,
        ]
    }
}

private func graphicsJSON(_ value: Any) throws -> Data {
    try JSONSerialization.data(withJSONObject: value)
}
