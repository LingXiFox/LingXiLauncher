import XCTest
import MacPlatform
@testable import LauncherCore

final class InstallerTests: XCTestCase {
    private var root: URL!
    private var layout: GameDataLayout!

    override func setUpWithError() throws {
        MacPlatform.install()
        root = try FixtureLoader.temporaryDirectory("lingxi-installer")
        layout = GameDataLayout(
            gameRoot: root.appendingPathComponent("mc", isDirectory: true),
            dataRoot: root.appendingPathComponent("data", isDirectory: true)
        )
    }

    override func tearDownWithError() throws {
        if let root { try? FileManager.default.removeItem(at: root) }
    }

    private func makeInstaller(
        _ transport: StubTransport,
        mirror: TrustedMirrorConfiguration? = nil
    ) -> VanillaInstaller {
        VanillaInstaller(
            layout: layout,
            transport: transport,
            mirror: mirror,
            javaInspector: JavaRuntimeInspector(timeout: 0.5)
        )
    }

    private func request(
        policy: DownloadSourcePolicy = .official,
        concurrency: Int = 2
    ) -> InstallRequest {
        InstallRequest(
            versionID: "test-version",
            instanceID: "dev-instance",
            displayName: "Dev Instance",
            sourcePolicy: policy,
            concurrency: concurrency
        )
    }

    // MARK: - End to end

    func testInstallsSyntheticVersionEndToEnd() async throws {
        let fixture = try SyntheticInstallation()
        let transport = StubTransport()
        await fixture.populate(transport)
        let recorder = EventRecorder()

        let report = try await makeInstaller(transport).install(request(), progress: { recorder.record($0) })

        XCTAssertTrue(report.isComplete, "missing: \(report.missingAfterInstall)")
        XCTAssertEqual(report.versionID, "test-version")
        XCTAssertEqual(report.instanceID, "dev-instance")
        // The asset index is fetched (and cached) by ManifestService before the download queue
        // runs, so the queue itself handles client + 2 libs + logging + 1 asset object.
        XCTAssertEqual(report.downloadedFiles, 5)
        XCTAssertEqual(report.cacheHits, 0)
        XCTAssertEqual(report.assetObjectCount, 1)
        XCTAssertEqual(report.javaRequirement.majorVersion, 17)
        XCTAssertEqual(report.sourcePolicy, .official)

        // Every expected file exists with the right bytes.
        let clientJar = try layout.clientJarURL("test-version")
        XCTAssertTrue(FileManager.default.fileExists(atPath: clientJar.path))
        for relative in fixture.libraryPaths {
            let url = try layout.libraryURL(relativePath: relative)
            XCTAssertTrue(FileManager.default.fileExists(atPath: url.path), relative)
        }
        let assetObject = try layout.assetObjectURL(sha1: fixture.assetObjectHash)
        XCTAssertEqual(try Data(contentsOf: assetObject), Data("synthetic-sound-bytes".utf8))
        XCTAssertTrue(FileManager.default.fileExists(atPath: try layout.assetIndexURL(id: "test-assets").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: try layout.loggingConfigURL(id: "client-test.xml").path))

        // Instance metadata written.
        let registry = InstanceRepository(layout: layout)
        let instance = try registry.load(id: "dev-instance")
        XCTAssertEqual(instance.manifest.versionID, "test-version")
        XCTAssertEqual(instance.manifest.displayName, "Dev Instance")
        XCTAssertTrue(FileManager.default.fileExists(atPath: instance.gameDirectory.path))

        // Progress pipeline reported the expected phases.
        let phases = recorder.events.compactMap { event -> InstallPhase? in
            if case let .phase(phase, _) = event { return phase }
            return nil
        }
        XCTAssertTrue(phases.contains(.manifest))
        XCTAssertTrue(phases.contains(.versionMetadata))
        XCTAssertTrue(phases.contains(.assetIndex))
        XCTAssertTrue(phases.contains(.downloading))
        XCTAssertTrue(phases.contains(.finalizing))
    }

    func testSecondInstallUsesCacheAndDoesNotRefetch() async throws {
        let fixture = try SyntheticInstallation()
        let transport = StubTransport()
        await fixture.populate(transport)
        _ = try await makeInstaller(transport).install(request(), progress: { _ in })
        let requestsAfterFirst = await transport.totalRequests

        let report = try await makeInstaller(transport).install(request(), progress: { _ in })
        XCTAssertTrue(report.isComplete)
        // Only the asset object goes through the download queue; manifest/version/index are
        // cached by ManifestService and the already-present files are not queued at all.
        XCTAssertEqual(report.cacheHits, 1)
        XCTAssertEqual(report.downloadedFiles, 0)
        let observed1 = await transport.totalRequests
        XCTAssertEqual(observed1, requestsAfterFirst, "manifest/version/asset-index must also be cached")
    }

    func testWrongSizeCachedFileIsRedownloaded() async throws {
        let fixture = try SyntheticInstallation()
        let transport = StubTransport()
        await fixture.populate(transport)
        _ = try await makeInstaller(transport).install(request(), progress: { _ in })

        let library = try layout.libraryURL(relativePath: fixture.libraryPaths[0])
        try Data("corrupted".utf8).write(to: library)

        let report = try await makeInstaller(transport).install(request(), progress: { _ in })
        XCTAssertTrue(report.isComplete)
        // A size mismatch is detected by the dependency resolver, so the corrupted file is
        // queued and replaced; same-size corruption is caught by `lingxi verify`, not install.
        XCTAssertEqual(report.cacheHits, 1)
        XCTAssertEqual(report.downloadedFiles, 1)
        XCTAssertNotEqual(try Data(contentsOf: library), Data("corrupted".utf8))
    }

    func testLocalCacheOnlyFailsWithoutNetwork() async throws {
        let transport = StubTransport()
        do {
            _ = try await makeInstaller(transport).install(request(policy: .localCacheOnly), progress: { _ in })
            XCTFail("expected install to fail without cache")
        } catch let error as LauncherError {
            XCTAssertEqual(error.code, .missingDependency)
            XCTAssertTrue(error.message.contains("local-cache-only"), error.message)
        }
        let observed2 = await transport.totalRequests
        XCTAssertEqual(observed2, 0)
    }

    func testMirrorOnlyInstallUsesMirrorHosts() async throws {
        let fixture = try SyntheticInstallation()
        let mirror = try fixture.mirrorConfiguration()
        let transport = StubTransport()
        await fixture.populateMirror(transport, configuration: mirror)

        let report = try await makeInstaller(transport, mirror: mirror)
            .install(request(policy: .mirror), progress: { _ in })

        XCTAssertTrue(report.isComplete)
        XCTAssertEqual(report.sourcePolicy, .mirror)
        let hosts = Set(await transport.requestedURLs.compactMap { URL(string: $0)?.host })
        XCTAssertEqual(hosts, ["mirror.example.com"])
    }

    func testVersionListingFiltersByType() async throws {
        let fixture = try SyntheticInstallation()
        let transport = StubTransport()
        await fixture.populate(transport)
        let installer = makeInstaller(transport)

        let releases = try await installer.listVersions(type: .release, policy: .official)
        XCTAssertEqual(releases.map(\.id), ["test-version"])
        let snapshots = try await installer.listVersions(type: .snapshot, policy: .official)
        XCTAssertEqual(snapshots.map(\.id), ["test-snapshot"])
        let all = try await installer.listVersions(type: nil, policy: .official)
        XCTAssertEqual(all.count, 2)
    }

    func testMissingVersionIsExplicitError() async throws {
        let fixture = try SyntheticInstallation()
        let transport = StubTransport()
        await fixture.populate(transport)
        do {
            _ = try await makeInstaller(transport).install(
                InstallRequest(versionID: "does-not-exist", instanceID: "x"),
                progress: { _ in }
            )
            XCTFail("expected error")
        } catch let error as LauncherError {
            XCTAssertEqual(error.code, .missingDependency)
            XCTAssertTrue(error.message.contains("does-not-exist"))
        }
    }

    // MARK: - Verification

    func testVerifierReportsCleanInstallAndDetectsCorruption() async throws {
        let fixture = try SyntheticInstallation()
        let transport = StubTransport()
        await fixture.populate(transport)
        _ = try await makeInstaller(transport).install(request(), progress: { _ in })

        let registry = InstanceRepository(layout: layout)
        let instance = try registry.load(id: "dev-instance")
        let verifier = InstallationVerifier(layout: layout)

        let clean = try verifier.verify(instance: instance)
        XCTAssertTrue(clean.isClean, "issues: \(clean.issues)")
        XCTAssertGreaterThanOrEqual(clean.checkedFiles, 6)

        let library = try layout.libraryURL(relativePath: fixture.libraryPaths[0])
        try Data("corrupted".utf8).write(to: library)
        let corrupted = try verifier.verify(instance: instance)
        XCTAssertFalse(corrupted.isClean)
        XCTAssertEqual(corrupted.mismatchCount, 1)
        XCTAssertEqual(corrupted.issues.first?.kind, .sizeMismatch)

        try FileManager.default.removeItem(at: library)
        let missing = try verifier.verify(instance: instance)
        XCTAssertEqual(missing.missingCount, 1)
    }

    func testVerifierDetectsSameSizeHashMismatch() async throws {
        let fixture = try SyntheticInstallation()
        let transport = StubTransport()
        await fixture.populate(transport)
        _ = try await makeInstaller(transport).install(request(), progress: { _ in })

        let library = try layout.libraryURL(relativePath: fixture.libraryPaths[0])
        let original = try Data(contentsOf: library)
        var tampered = original
        tampered[0] = tampered[0] &+ 1
        try tampered.write(to: library)

        let verifier = InstallationVerifier(layout: layout)
        let instance = try InstanceRepository(layout: layout).load(id: "dev-instance")
        let report = try verifier.verify(instance: instance)
        XCTAssertEqual(report.mismatchCount, 1)
        XCTAssertEqual(report.issues.first?.kind, .hashMismatch)
    }

    // MARK: - Native extraction

    func testLegacyNativeJarIsExtractedSafely() async throws {
        // 1.16.5 exercises the legacy natives path; build a metadata-only fixture where the
        // native archive is one of our real test ZIPs instead of a Minecraft download.
        let nativeURL = URL(string: "https://libraries.minecraft.net/com/example/native/1.0/native-1.0-natives-macos.jar")!
        let nativeData = try Data(contentsOf: try FixtureLoader.url("zip/native_normal.zip"))
        let nativeHash = SHA1.hexDigest(nativeData)

        let version: [String: Any] = [
            "id": "legacy-native-test",
            "type": "release",
            "mainClass": "net.minecraft.client.main.Main",
            "assets": "legacy",
            "assetIndex": [
                "id": "legacy",
                "sha1": SHA1.hexDigest(Data("{\"objects\":{}}".utf8)),
                "size": Data("{\"objects\":{}}".utf8).count,
                "url": "https://piston-meta.mojang.com/v1/packages/x/legacy.json"
            ],
            "downloads": ["client": ["sha1": SHA1.hexDigest(Data("client".utf8)), "size": 6, "url": "https://piston-data.mojang.com/v1/objects/c/client.jar"]],
            "javaVersion": ["majorVersion": 17],
            "libraries": [
                [
                    "name": "com.example:native:1.0",
                    "downloads": [
                        "artifact": [
                            "path": "com/example/native/1.0/native-1.0.jar",
                            "sha1": SHA1.hexDigest(Data("main".utf8)),
                            "size": 4,
                            "url": "https://libraries.minecraft.net/com/example/native/1.0/native-1.0.jar"
                        ],
                        "classifiers": [
                            "natives-macos": [
                                "path": "com/example/native/1.0/native-1.0-natives-macos.jar",
                                "sha1": nativeHash,
                                "size": nativeData.count,
                                "url": nativeURL.absoluteString
                            ]
                        ]
                    ],
                    "natives": ["osx": "natives-macos"],
                    "extract": ["exclude": ["META-INF/"]],
                    "rules": [["action": "allow", "os": ["name": "osx"]]]
                ]
            ],
            "arguments": ["game": ["--username", "${auth_player_name}"], "jvm": ["-cp", "${classpath}"]]
        ]
        let versionData = try JSONSerialization.data(withJSONObject: version, options: [.sortedKeys])
        let versionHash = SHA1.hexDigest(versionData)
        let manifest: [String: Any] = [
            "latest": ["release": "legacy-native-test", "snapshot": "legacy-native-test"],
            "versions": [[
                "id": "legacy-native-test", "type": "release",
                "url": "https://piston-meta.mojang.com/v1/packages/\(versionHash)/legacy-native-test.json",
                "sha1": versionHash
            ]]
        ]
        let manifestData = try JSONSerialization.data(withJSONObject: manifest, options: [.sortedKeys])

        let transport = StubTransport()
        await transport.setData(manifestData, for: ManifestService.manifestURL)
        await transport.setData(versionData, for: URL(string: "https://piston-meta.mojang.com/v1/packages/\(versionHash)/legacy-native-test.json")!)
        await transport.setData(Data("{\"objects\":{}}".utf8), for: URL(string: "https://piston-meta.mojang.com/v1/packages/x/legacy.json")!)
        await transport.setData(Data("client".utf8), for: URL(string: "https://piston-data.mojang.com/v1/objects/c/client.jar")!)
        await transport.setData(Data("main".utf8), for: URL(string: "https://libraries.minecraft.net/com/example/native/1.0/native-1.0.jar")!)
        await transport.setData(nativeData, for: nativeURL)

        let report = try await makeInstaller(transport).install(
            InstallRequest(versionID: "legacy-native-test", instanceID: "legacy-instance", sourcePolicy: .official),
            progress: { _ in }
        )

        XCTAssertTrue(report.isComplete)
        XCTAssertGreaterThan(report.extractedNatives, 0)
        let nativesDirectory = try layout.nativesDirectory(versionID: "legacy-native-test", architecture: PlatformContext.hostArchitecture())
        XCTAssertTrue(FileManager.default.fileExists(atPath: nativesDirectory.appendingPathComponent("lib/liblwjgl.dylib").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: nativesDirectory.appendingPathComponent("META-INF/MANIFEST.MF").path))
    }
}
