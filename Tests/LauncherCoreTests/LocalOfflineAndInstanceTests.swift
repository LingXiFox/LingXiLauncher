import XCTest
@testable import LauncherCore

/// T09 — LocalOffline identity. These tests pin the Java-compatible UUID algorithm with
/// cross-language vectors (computed independently in Python with hashlib + uuid).
final class LocalOfflineIdentityTests: XCTestCase {
    func testKnownOfflineUUIDVectors() {
        let vectors: [(String, String)] = [
            ("Notch", "b50ad385-829d-3141-a216-7e7d7539ba7f"),
            ("jeb_", "a762f560-4fce-3236-812a-b80efff0b62b"),
            ("TestPlayer", "bb77495a-a740-3169-a238-69654c8bd2c1"),
            ("a_b", "e5e0a3fa-0c16-3cfc-aabd-e74e340edaae"),
            ("Player_1234567890", "c5061033-daf9-3f22-a45b-9df19b68dfea"),
        ]
        for (name, expected) in vectors {
            XCTAssertEqual(
                LocalOfflineIdentity.offlineUUID(forName: name).uuidString.lowercased(),
                expected,
                "offline UUID mismatch for \(name)"
            )
        }
    }

    func testUUIDIsVersion3AndRFC4122Variant() throws {
        let uuid = LocalOfflineIdentity.offlineUUID(forName: "TestPlayer")
        let bytes = withUnsafeBytes(of: uuid.uuid) { Array($0) }
        XCTAssertEqual((bytes[6] & 0xF0) >> 4, 3)
        XCTAssertEqual(bytes[8] & 0xC0, 0x80)
    }

    func testUUIDIsDeterministicAndCaseSensitive() {
        XCTAssertEqual(
            LocalOfflineIdentity.offlineUUID(forName: "Notch"),
            LocalOfflineIdentity.offlineUUID(forName: "Notch")
        )
        XCTAssertNotEqual(
            LocalOfflineIdentity.offlineUUID(forName: "Notch"),
            LocalOfflineIdentity.offlineUUID(forName: "notch")
        )
    }

    func testNameValidationBoundaries() throws {
        XCTAssertEqual(try LocalOfflineIdentity.validatedName("abc"), "abc")
        XCTAssertEqual(try LocalOfflineIdentity.validatedName("A123456789012345"), "A123456789012345") // 16 chars
        XCTAssertEqual(try LocalOfflineIdentity.validatedName("___"), "___")
    }

    func testNameValidationRejectsInvalidNames() {
        let invalid = [
            "ab",                    // too short
            "a".padding(toLength: 17, withPad: "a", startingAt: 0), // too long
            "has space",
            "has-dash",
            "中文名字",
            "",
            "name!",
        ]
        for name in invalid {
            XCTAssertThrowsError(try LocalOfflineIdentity.validatedName(name), "expected rejection: \(name)") { error in
                XCTAssertEqual((error as? LauncherError)?.code, .invalidProfileName)
            }
        }
    }

    func testProfileUsesStableUUIDAndArgumentForm() throws {
        let profile = try LocalOfflineIdentity.makeProfile(playerName: "TestPlayer")
        XCTAssertEqual(profile.playerName, "TestPlayer")
        XCTAssertEqual(profile.stableOfflineUUID.uuidString.lowercased(), "bb77495a-a740-3169-a238-69654c8bd2c1")
        XCTAssertEqual(LocalOfflineIdentity.uuidArgument(for: profile), "bb77495aa7403169a23869654c8bd2c1")
        XCTAssertEqual(profile.unverifiedProfile.name, "TestPlayer")
    }

    func testNoTokenFieldsInPersistedAccount() throws {
        let root = try FixtureLoader.temporaryDirectory("lingxi-accounts")
        defer { try? FileManager.default.removeItem(at: root) }
        let layout = GameDataLayout(gameRoot: root.appendingPathComponent("mc"), dataRoot: root.appendingPathComponent("data"))
        let store = LocalAccountStore(layout: layout)
        let account = try store.create(playerName: "TestPlayer")
        XCTAssertEqual(account.identityMode, .localOffline)
        XCTAssertTrue(account.unverified)

        let fileURL = layout.localAccountsDirectory.appendingPathComponent("TestPlayer.json")
        let raw = try String(contentsOf: fileURL, encoding: .utf8).lowercased()
        XCTAssertFalse(raw.contains("token"))
        XCTAssertFalse(raw.contains("access"))
        XCTAssertFalse(raw.contains("microsoft"))
        XCTAssertTrue(raw.contains("\"unverified\""))
        XCTAssertTrue(raw.contains("\"local-offline\""))
    }

    func testCreateIsIdempotentAndLoadable() throws {
        let root = try FixtureLoader.temporaryDirectory("lingxi-accounts")
        defer { try? FileManager.default.removeItem(at: root) }
        let layout = GameDataLayout(gameRoot: root.appendingPathComponent("mc"), dataRoot: root.appendingPathComponent("data"))
        let store = LocalAccountStore(layout: layout)
        let first = try store.create(playerName: "TestPlayer")
        let second = try store.create(playerName: "TestPlayer")
        XCTAssertEqual(first.offlineUUID, second.offlineUUID)
        XCTAssertEqual(try store.load(playerName: "TestPlayer").offlineUUID, first.offlineUUID)
        XCTAssertEqual(try store.list().count, 1)
        XCTAssertEqual(try store.profile(forName: "TestPlayer").stableOfflineUUID, first.offlineUUID)
    }

    func testUnknownAccountIsExplicitError() throws {
        let root = try FixtureLoader.temporaryDirectory("lingxi-accounts")
        defer { try? FileManager.default.removeItem(at: root) }
        let layout = GameDataLayout(gameRoot: root.appendingPathComponent("mc"), dataRoot: root.appendingPathComponent("data"))
        XCTAssertThrowsError(try LocalAccountStore(layout: layout).load(playerName: "Nobody")) { error in
            XCTAssertEqual((error as? LauncherError)?.code, .missingDependency)
        }
    }
}

final class InstanceRepositoryTests: XCTestCase {
    private func makeRepository() throws -> (InstanceRepository, URL) {
        let root = try FixtureLoader.temporaryDirectory("lingxi-instances")
        let layout = GameDataLayout(gameRoot: root.appendingPathComponent("mc"), dataRoot: root.appendingPathComponent("data"))
        return (InstanceRepository(layout: layout), root)
    }

    func testCreateInstanceCreatesIsolatedDirectories() throws {
        let (repository, root) = try makeRepository()
        defer { try? FileManager.default.removeItem(at: root) }
        let instance = try repository.create(displayName: "生存 世界", versionID: "26.3")
        XCTAssertTrue(FileManager.default.fileExists(atPath: instance.gameDirectory.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: instance.gameDirectory.appendingPathComponent("logs").path))
        XCTAssertFalse(instance.id.contains(" "))
        XCTAssertEqual(instance.manifest.displayName, "生存 世界")
        XCTAssertEqual(instance.manifest.versionID, "26.3")
        // gameDir must resolve inside the instance directory
        XCTAssertTrue(PathSafety.isContained(instance.gameDirectory, inBase: instance.directory))
    }

    func testListAndLoadInstances() throws {
        let (repository, root) = try makeRepository()
        defer { try? FileManager.default.removeItem(at: root) }
        let first = try repository.create(displayName: "Vanilla", versionID: nil)
        let second = try repository.create(displayName: "Vanilla", versionID: nil)
        XCTAssertNotEqual(first.id, second.id, "duplicate display names must get distinct ids")
        XCTAssertEqual(try repository.list().count, 2)
        let loaded = try repository.load(id: first.id)
        XCTAssertEqual(loaded.manifest.displayName, "Vanilla")
    }

    func testRecordLaunchPersistsIdentityMode() throws {
        let (repository, root) = try makeRepository()
        defer { try? FileManager.default.removeItem(at: root) }
        let instance = try repository.create(displayName: "Test", versionID: "1.20.1")
        try repository.recordLaunch(id: instance.id, identityMode: .localOffline)
        let reloaded = try repository.load(id: instance.id)
        XCTAssertEqual(reloaded.manifest.lastIdentityMode, .localOffline)
        XCTAssertNotNil(reloaded.manifest.lastLaunchedAt)
    }


    func testMemorySettingAndInstanceDeletion() throws {
        let (repository, root) = try makeRepository()
        defer { try? FileManager.default.removeItem(at: root) }
        let instance = try repository.create(displayName: "Memory Test", versionID: "1.20.1")
        let updated = try repository.setMemory(id: instance.id, memoryMiB: 4096)
        XCTAssertEqual(updated.manifest.memoryMiB, 4096)
        XCTAssertEqual(try repository.load(id: instance.id).manifest.memoryMiB, 4096)
        XCTAssertThrowsError(try repository.setMemory(id: instance.id, memoryMiB: 64)) { error in
            XCTAssertEqual((error as? LauncherError)?.code, .usageError)
        }
        try repository.delete(id: instance.id)
        XCTAssertTrue(try repository.list().isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: instance.directory.path))
    }

    func testUnknownInstanceIsExplicitError() throws {
        let (repository, root) = try makeRepository()
        defer { try? FileManager.default.removeItem(at: root) }
        XCTAssertThrowsError(try repository.load(id: "does-not-exist")) { error in
            XCTAssertEqual((error as? LauncherError)?.code, .missingDependency)
        }
    }

    func testInstanceIDCannotEscapeDataRoot() throws {
        let (repository, root) = try makeRepository()
        defer { try? FileManager.default.removeItem(at: root) }
        XCTAssertThrowsError(try repository.load(id: "../../../etc")) { error in
            XCTAssertEqual((error as? LauncherError)?.code, .pathEscapesRoot)
        }
    }
}

final class PathSafetyTests: XCTestCase {
    func testSafeJoinRejectsEscapes() {
        let base = URL(fileURLWithPath: "/tmp/lingxi-base", isDirectory: true)
        XCTAssertNoThrow(try PathSafety.safeJoin(base: base, relativePath: "com/example/lib.jar"))
        for bad in ["../evil.jar", "/etc/passwd", "a/../../b", "..", "", "a\\b"] {
            XCTAssertThrowsError(try PathSafety.safeJoin(base: base, relativePath: bad), "expected rejection: \(bad)")
        }
    }

    func testArchiveEntryValidation() {
        XCTAssertNoThrow(try PathSafety.validatedArchiveEntry("META-INF/MANIFEST.MF"))
        XCTAssertNoThrow(try PathSafety.validatedArchiveEntry("lib/liblwjgl.dylib"))
        for bad in ["../evil", "/absolute", "C:/windows", "a\\b", "a/../../b"] {
            XCTAssertThrowsError(try PathSafety.validatedArchiveEntry(bad), "expected rejection: \(bad)")
        }
    }

    func testContainmentCheck() {
        let base = URL(fileURLWithPath: "/tmp/base", isDirectory: true)
        XCTAssertTrue(PathSafety.isContained(base.appendingPathComponent("a/b"), inBase: base))
        XCTAssertFalse(PathSafety.isContained(URL(fileURLWithPath: "/tmp/base2/a"), inBase: base))
        XCTAssertFalse(PathSafety.isContained(URL(fileURLWithPath: "/etc/passwd"), inBase: base))
    }

    func testValidatedPathComponent() {
        XCTAssertEqual(try PathSafety.validatedPathComponent("26.3"), "26.3")
        for bad in ["..", ".", "", "a/b", "a\\b"] {
            XCTAssertThrowsError(try PathSafety.validatedPathComponent(bad))
        }
    }
}

final class GameDataLayoutTests: XCTestCase {
    func testDefaultPaths() throws {
        let layout = GameDataLayout(gameRoot: URL(fileURLWithPath: "/tmp/mc"), dataRoot: URL(fileURLWithPath: "/tmp/data"))
        XCTAssertEqual(try layout.versionJSONURL("26.3").path, "/tmp/mc/versions/26.3/26.3.json")
        XCTAssertEqual(try layout.clientJarURL("26.3").path, "/tmp/mc/versions/26.3/26.3.jar")
        XCTAssertEqual(try layout.libraryURL(relativePath: "a/b/c.jar").path, "/tmp/mc/libraries/a/b/c.jar")
        XCTAssertEqual(try layout.assetIndexURL(id: "34").path, "/tmp/mc/assets/indexes/34.json")
        XCTAssertEqual(try layout.assetObjectURL(sha1: "ABCDEF12").path, "/tmp/mc/assets/objects/ab/abcdef12")
        XCTAssertEqual(try layout.nativesDirectory(versionID: "26.3", architecture: .arm64).path, "/tmp/data/natives/26.3/arm64")
        XCTAssertEqual(try layout.instanceGameDirectory("abc").path, "/tmp/data/instances/abc/.minecraft")
        XCTAssertEqual(layout.loggingConfigsDirectory.path, "/tmp/mc/assets/log_configs")
    }

    func testPathTraversalIsRejected() {
        let layout = GameDataLayout(gameRoot: URL(fileURLWithPath: "/tmp/mc"), dataRoot: URL(fileURLWithPath: "/tmp/data"))
        XCTAssertThrowsError(try layout.versionJSONURL("../../etc/passwd"))
        XCTAssertThrowsError(try layout.libraryURL(relativePath: "../../evil.jar"))
        XCTAssertThrowsError(try layout.assetIndexURL(id: "../x"))
    }

    func testStandardisesRootPaths() {
        let layout = GameDataLayout(gameRoot: URL(fileURLWithPath: "/tmp/mc/./versions/.."))
        XCTAssertEqual(layout.gameRoot.path, "/tmp/mc")
    }
}

final class PlatformContextTests: XCTestCase {
    func testCurrentPlatformDescribesAppleSiliconMac() throws {
        let platform = try PlatformContext.current()
        XCTAssertEqual(platform.os, .macOS)
        XCTAssertEqual(platform.architecture, .arm64)
        XCTAssertTrue(platform.osVersion.hasPrefix("1") || platform.osVersion.hasPrefix("2") || platform.osVersion.hasPrefix("3"))
        XCTAssertFalse(platform.featureEnabled("is_demo_user"))
    }

    func testArchitectureAliases() {
        let arm = PlatformContext(os: .macOS, architecture: .arm64, osVersion: "14.4.1")
        XCTAssertEqual(arm.architectureAliases, ["arm64", "aarch64"])
        let intel = PlatformContext(os: .macOS, architecture: .x86_64, osVersion: "14.4.1")
        XCTAssertTrue(intel.architectureAliases.contains("x86_64"))
        XCTAssertTrue(intel.architectureAliases.contains("amd64"))
    }

    func testFeaturesDefaultToDisabled() {
        let platform = PlatformContext(os: .macOS, architecture: .arm64, osVersion: "14.4.1", features: ["is_demo_user": true])
        XCTAssertTrue(platform.featureEnabled("is_demo_user"))
        XCTAssertFalse(platform.featureEnabled("has_custom_resolution"))
    }
}
