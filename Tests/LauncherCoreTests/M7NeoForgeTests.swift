import XCTest
@testable import LauncherCore

final class M7NeoForgeTests: XCTestCase {
    private var root: URL!
    private var layout: GameDataLayout!

    override func setUpWithError() throws {
        root = try FixtureLoader.temporaryDirectory("lingxi-neoforge")
        layout = GameDataLayout(
            gameRoot: root.appendingPathComponent("mc", isDirectory: true),
            dataRoot: root.appendingPathComponent("data", isDirectory: true)
        )
    }

    override func tearDownWithError() throws {
        if let root { try? FileManager.default.removeItem(at: root) }
    }

    func testMavenMetadataParsesAndMapsNeoForgeVersions() {
        let xml = """
        <metadata><versioning><versions>
          <version>21.1.265</version>
          <version>21.1.100</version>
          <version>20.2.88</version>
          <version>garbage</version>
        </versions></versioning></metadata>
        """
        let versions = NeoForgeInstaller.parseMavenVersions(Data(xml.utf8))
        XCTAssertEqual(versions, ["21.1.265", "21.1.100", "20.2.88", "garbage"])
        XCTAssertEqual(NeoForgeInstaller.minecraftVersion(for: "21.1.265"), "1.21.1")
        XCTAssertEqual(NeoForgeInstaller.minecraftVersion(for: "20.2.88"), "1.20.2")
        XCTAssertNil(NeoForgeInstaller.minecraftVersion(for: "garbage"))
        XCTAssertNil(NeoForgeInstaller.minecraftVersion(for: "19.4.0"))
    }

    func testCompatibleVersionListFiltersByMinecraftVersion() async throws {
        let xml = """
        <metadata><versioning><versions>
          <version>21.1.265</version>
          <version>21.1.100</version>
          <version>20.2.88</version>
        </versions></versioning></metadata>
        """
        let transport = StubTransport()
        await transport.setData(
            Data(xml.utf8),
            for: URL(string: "https://maven.neoforged.net/releases/net/neoforged/neoforge/maven-metadata.xml")!
        )
        let installer = NeoForgeInstaller(layout: layout, transport: transport)
        let versions = try await installer.listLoaderVersions(for: "1.21.1")
        XCTAssertEqual(versions.map(\.version), ["21.1.265", "21.1.100"])
        XCTAssertTrue(versions.allSatisfy { $0.minecraftVersion == "1.21.1" })
    }

    func testDetectsNeoForgeProfileForModrinthFiltering() throws {
        let parentID = "1.21.11"
        let profileID = "neoforge-21.1.265"
        for (id, fixture) in [(parentID, "versions/1.21.11.json"), (profileID, "versions/fabric-loader-0.20.1-1.21.11.json")] {
            let directory = layout.gameRoot.appendingPathComponent("versions/\(id)", isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try FileManager.default.copyItem(
                at: try FixtureLoader.url(fixture),
                to: directory.appendingPathComponent("\(id).json")
            )
        }
        let profileURL = layout.gameRoot.appendingPathComponent("versions/\(profileID)/\(profileID).json")
        let object: [String: Any] = [
            "id": profileID,
            "inheritsFrom": parentID,
            "mainClass": "cpw.mods.bootstraplauncher.BootstrapLauncher",
            "type": "release",
            "libraries": [["name": "net.neoforged:neoforge:21.1.265"]]
        ]
        try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]).write(to: profileURL, options: .atomic)
        let instance = try InstanceRepository(layout: layout).create(
            id: "nf-modrinth",
            displayName: "NeoForge Modrinth",
            versionID: profileID
        )
        let compatibility = try ModCompatibilityResolver.resolve(instance: instance, layout: layout)
        XCTAssertEqual(compatibility.loader, .neoforge)
        XCTAssertEqual(compatibility.gameVersion, parentID)
        XCTAssertEqual(compatibility.loader.displayName, "NeoForge")
    }

    func testExistingInstanceRequiresExplicitUpdateBeforeNetwork() async throws {
        let repository = InstanceRepository(layout: layout)
        _ = try repository.create(id: "nf-existing", displayName: "NeoForge Test", versionID: "1.21.1")
        let transport = StubTransport()
        let installer = NeoForgeInstaller(layout: layout, transport: transport)
        do {
            _ = try await installer.install(
                NeoForgeInstallRequest(
                    minecraftVersionID: "1.21.1",
                    instanceID: "nf-existing",
                    javaExecutable: URL(fileURLWithPath: "/usr/bin/java")
                ),
                progress: { _ in }
            )
            XCTFail("existing instance must not be replaced without explicit update mode")
        } catch let error as LauncherError {
            XCTAssertEqual(error.code, .usageError)
        }
        XCTAssertTrue(try repository.list().contains { $0.id == "nf-existing" })
    }
}
