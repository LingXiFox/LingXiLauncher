import XCTest
#if !os(Windows)
@testable import LauncherCore

final class JavaManagerSafetyTests: XCTestCase {
    func testSafeReplaceRestoresOldJDKWhenFinalValidationFails() throws {
        let root = try FixtureLoader.temporaryDirectory("lingxi-java-swap")
        defer { try? FileManager.default.removeItem(at: root) }
        let prepared = root.appendingPathComponent("prepared", isDirectory: true)
        let destination = root.appendingPathComponent("current", isDirectory: true)
        try FileManager.default.createDirectory(at: prepared, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        try Data("new".utf8).write(to: prepared.appendingPathComponent("new.marker"))
        try Data("old".utf8).write(to: destination.appendingPathComponent("old.marker"))

        XCTAssertThrowsError(
            try JavaManager.safeReplaceDirectory(prepared: prepared, destination: destination) { candidate in
                if candidate.lastPathComponent == "current", !FileManager.default.fileExists(atPath: candidate.appendingPathComponent("old.marker").path) {
                    throw LauncherError(.ioFailure, "simulated final probe failure")
                }
            }
        )
        XCTAssertEqual(try Data(contentsOf: destination.appendingPathComponent("old.marker")), Data("old".utf8))
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.appendingPathComponent("new.marker").path))
        let backups = try FileManager.default.contentsOfDirectory(atPath: root.path).filter { $0.hasPrefix(".backup-") }
        XCTAssertTrue(backups.isEmpty, "rollback must consume the temporary backup")
    }

    func testSafeReplaceCommitsPreparedTreeAndRemovesBackup() throws {
        let root = try FixtureLoader.temporaryDirectory("lingxi-java-swap-ok")
        defer { try? FileManager.default.removeItem(at: root) }
        let prepared = root.appendingPathComponent("prepared", isDirectory: true)
        let destination = root.appendingPathComponent("current", isDirectory: true)
        try FileManager.default.createDirectory(at: prepared, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        try Data("new".utf8).write(to: prepared.appendingPathComponent("new.marker"))
        try Data("old".utf8).write(to: destination.appendingPathComponent("old.marker"))

        try JavaManager.safeReplaceDirectory(prepared: prepared, destination: destination) { candidate in
            XCTAssertTrue(FileManager.default.fileExists(atPath: candidate.appendingPathComponent("new.marker").path))
        }
        XCTAssertEqual(try Data(contentsOf: destination.appendingPathComponent("new.marker")), Data("new".utf8))
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.appendingPathComponent("old.marker").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: prepared.path))
        let backups = try FileManager.default.contentsOfDirectory(atPath: root.path).filter { $0.hasPrefix(".backup-") }
        XCTAssertTrue(backups.isEmpty)
    }

    func testRuntimeRecordIncludesPublishedArtifactAndExecutableHash() throws {
        let root = try FixtureLoader.temporaryDirectory("lingxi-java-record")
        defer { try? FileManager.default.removeItem(at: root) }
        let layout = GameDataLayout(
            gameRoot: root.appendingPathComponent("mc", isDirectory: true),
            dataRoot: root.appendingPathComponent("data", isDirectory: true)
        )
        let jdkRoot = layout.dataRoot.appendingPathComponent("java/mojang-java-runtime-gamma/Contents/Home", isDirectory: true)
        let bin = jdkRoot.appendingPathComponent("bin", isDirectory: true)
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        let java = bin.appendingPathComponent("java")
        try """
        #!/bin/sh
        cat >&2 <<'EOF'
        Property settings:
            java.version = 17.0.15
            java.vendor = Mojang
            os.arch = aarch64
            os.name = Mac OS X
        EOF
        """.write(to: java, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: java.path)
        let source: [String: Any] = [
            "vendor": "Mojang java-runtime",
            "version": "17.0.15",
            "downloadURL": "https://piston-meta.mojang.com/manifest.json",
            "checksum": "manifest-sha1",
            "license": "Mojang Java Runtime / OpenJDK terms",
            "checksumSHA1": "manifest-sha1",
            "component": "java-runtime-gamma",
        ]
        try JSONSerialization.data(withJSONObject: source).write(
            to: jdkRoot.deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("source.json")
        )
        let manager = JavaManager(layout: layout, transport: StubTransport())
        let managed = manager.managedRuntimes()
        XCTAssertFalse(managed.isEmpty)
        XCTAssertEqual(
            managed.first?.runtime.executable.resolvingSymlinksInPath().path,
            java.resolvingSymlinksInPath().path
        )
        XCTAssertEqual(managed.first?.source, "Mojang java-runtime")
        let runtime = try manager.inspectCustom(java)
        let record = manager.runtimeRecord(for: runtime)
        XCTAssertEqual(record.source, "Mojang java-runtime")
        XCTAssertEqual(record.component, "java-runtime-gamma")
        XCTAssertEqual(record.version, "17.0.15")
        XCTAssertEqual(record.artifactSHA1, "manifest-sha1")
        XCTAssertNotNil(record.executableSHA256)
    }

    func testMojangRuntimeIsPreferredAndRecorded() async throws {
        let root = try FixtureLoader.temporaryDirectory("lingxi-java-mojang")
        defer { try? FileManager.default.removeItem(at: root) }
        let layout = GameDataLayout(
            gameRoot: root.appendingPathComponent("mc", isDirectory: true),
            dataRoot: root.appendingPathComponent("data", isDirectory: true)
        )
        let script = """
        #!/bin/sh
        cat >&2 <<'EOF'
        Property settings:
            java.version = 17.0.15
            java.vendor = Mojang
            os.arch = aarch64
            os.name = Mac OS X
        EOF
        """
        let scriptData = Data(script.utf8)
        let rawURL = URL(string: "https://piston-data.mojang.com/v1/objects/fake/java")!
        let manifestObject: [String: Any] = [
            "files": [
                "jre.bundle/Contents/Home/bin/java": [
                    "type": "file", "executable": true,
                    "downloads": ["raw": ["sha1": SHA1.hexDigest(scriptData), "size": scriptData.count, "url": rawURL.absoluteString]],
                ],
            ],
        ]
        let manifestData = try JSONSerialization.data(withJSONObject: manifestObject)
        let manifestURL = URL(string: "https://piston-meta.mojang.com/v1/packages/fake/manifest.json")!
        let indexObject: [String: Any] = [
            "mac-os-arm64": ["java-runtime-gamma": [[
                "manifest": ["sha1": SHA1.hexDigest(manifestData), "size": manifestData.count, "url": manifestURL.absoluteString],
                "version": ["name": "17.0.15"],
                "availability": ["progress": 100],
            ]]],
        ]
        let indexData = try JSONSerialization.data(withJSONObject: indexObject)
        let transport = StubTransport()
        await transport.setData(indexData, for: JavaManager.mojangJavaRuntimeIndex)
        await transport.setData(manifestData, for: manifestURL)
        await transport.setData(scriptData, for: rawURL)
        let manager = JavaManager(layout: layout, transport: transport)
        let installed = try await manager.installManagedJava(
            requirement: JavaVersionRequirement(component: "java-runtime-gamma", majorVersion: 17),
            minecraftVersionID: "1.20.1",
            progress: { _ in }
        )
        XCTAssertEqual(installed.source, "Mojang java-runtime")
        XCTAssertEqual(installed.component, "java-runtime-gamma")
        XCTAssertEqual(installed.versionName, "17.0.15")
        XCTAssertEqual(installed.artifactSHA1, SHA1.hexDigest(manifestData))
        XCTAssertTrue(FileManager.default.isExecutableFile(atPath: installed.runtime.executable.path))
        let record = manager.runtimeRecord(for: installed.runtime)
        XCTAssertEqual(record.source, "Mojang java-runtime")
        XCTAssertEqual(record.component, "java-runtime-gamma")
    }

    func testJavaCompatibilityUsesMetadataRequirement() throws {
        let runtime = JavaRuntime(
            executable: URL(fileURLWithPath: "/fake/java"),
            versionString: "17.0.21",
            majorVersion: 17,
            architecture: .arm64,
            vendor: "Test"
        )
        let root = try FixtureLoader.temporaryDirectory("lingxi-java-compat")
        defer { try? FileManager.default.removeItem(at: root) }
        let manager = JavaManager(
            layout: GameDataLayout(
                gameRoot: root.appendingPathComponent("mc", isDirectory: true),
                dataRoot: root.appendingPathComponent("data", isDirectory: true)
            ),
            transport: StubTransport()
        )
        XCTAssertTrue(manager.isCompatible(runtime, requirement: JavaVersionRequirement(majorVersion: 17)))
        XCTAssertFalse(manager.isCompatible(runtime, requirement: JavaVersionRequirement(majorVersion: 21)))
    }
}
#endif
