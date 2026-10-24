import XCTest
@testable import LauncherCore

final class SourceResolverTests: XCTestCase {
    private let official = URL(string: "https://libraries.minecraft.net/com/example/lib/1.0/lib-1.0.jar")!

    private func mirror(prefix: String? = nil) throws -> TrustedMirrorConfiguration {
        try TrustedMirrorConfiguration(
            id: "mirror-test",
            displayName: "Test mirror",
            rules: [
                MirrorHostRule(
                    officialHost: "libraries.minecraft.net",
                    mirrorBaseURL: URL(string: "https://mirror.example.com/maven")!,
                    pathPrefix: prefix
                ),
                MirrorHostRule(
                    officialHost: "piston-meta.mojang.com",
                    mirrorBaseURL: URL(string: "https://mirror.example.com")!
                )
            ]
        )
    }

    func testOfficialOnlyKeepsOfficialURL() throws {
        let resolver = try SourceResolver(policy: .official)
        let candidates = try resolver.candidates(for: official)
        XCTAssertEqual(candidates.count, 1)
        XCTAssertEqual(candidates[0].url, official)
        XCTAssertEqual(candidates[0].sourceLabel, "official")
        XCTAssertTrue(resolver.allowsNetwork)
    }

    func testAutoOrderIsOfficialThenMirror() throws {
        let resolver = try SourceResolver(policy: .auto, mirror: try mirror())
        let candidates = try resolver.candidates(for: official)
        XCTAssertEqual(candidates.map(\.sourceLabel), ["official", "mirror-test"])
        XCTAssertEqual(candidates[0].url.host, "libraries.minecraft.net")
        XCTAssertEqual(candidates[1].url.host, "mirror.example.com")
        XCTAssertEqual(candidates[1].url.path, "/maven/com/example/lib/1.0/lib-1.0.jar")
    }

    func testMirrorMappingPreservesPathAndQuery() throws {
        let url = URL(string: "https://libraries.minecraft.net/com/example/a.jar?checksum=abc")!
        let resolver = try SourceResolver(policy: .mirror, mirror: try mirror())
        let candidates = try resolver.candidates(for: url)
        XCTAssertEqual(candidates.count, 1)
        XCTAssertEqual(candidates[0].url.absoluteString, "https://mirror.example.com/maven/com/example/a.jar?checksum=abc")
        XCTAssertEqual(candidates[0].sourceLabel, "mirror-test")
    }

    func testMirrorPathPrefixIsExplicit() throws {
        let resolver = try SourceResolver(policy: .mirror, mirror: try mirror(prefix: "v2"))
        let candidates = try resolver.candidates(for: official)
        XCTAssertEqual(candidates[0].url.path, "/maven/v2/com/example/lib/1.0/lib-1.0.jar")
    }

    func testMirrorRejectsUnmappedHost() throws {
        let resolver = try SourceResolver(policy: .mirror, mirror: try mirror())
        let unmapped = URL(string: "https://unknown.example.org/file.jar")!
        XCTAssertThrowsError(try resolver.candidates(for: unmapped)) { error in
            XCTAssertEqual((error as? LauncherError)?.code, .usageError)
        }
    }

    func testMirrorPolicyRequiresConfiguration() {
        XCTAssertThrowsError(try SourceResolver(policy: .mirror)) { error in
            XCTAssertEqual((error as? LauncherError)?.code, .usageError)
        }
    }

    func testLocalCacheOnlyHasNoCandidatesAndNoNetwork() throws {
        let resolver = try SourceResolver(policy: .localCacheOnly)
        XCTAssertFalse(resolver.allowsNetwork)
        XCTAssertEqual(try resolver.candidates(for: official), [])
    }

    func testNonHTTPSURLIsRejected() throws {
        let resolver = try SourceResolver(policy: .official)
        let insecure = URL(string: "http://libraries.minecraft.net/file.jar")!
        XCTAssertThrowsError(try resolver.candidates(for: insecure)) { error in
            XCTAssertEqual((error as? LauncherError)?.code, .invalidMetadata)
        }
    }

    func testMirrorConfigurationRejectsNonHTTPSBase() {
        XCTAssertThrowsError(try TrustedMirrorConfiguration(
            id: "bad",
            displayName: "Bad mirror",
            rules: [MirrorHostRule(officialHost: "libraries.minecraft.net", mirrorBaseURL: URL(string: "http://mirror.example.com")!)]
        )) { error in
            XCTAssertEqual((error as? LauncherError)?.code, .invalidMetadata)
        }
    }

    func testMirrorConfigurationLoadsFromJSON() throws {
        let directory = try FixtureLoader.temporaryDirectory("lingxi-mirror")
        defer { try? FileManager.default.removeItem(at: directory) }
        let json = """
        {
          "id": "example",
          "displayName": "Example mirror",
          "rules": [
            { "officialHost": "piston-meta.mojang.com", "mirrorBaseURL": "https://mirror.example.com" },
            { "officialHost": "libraries.minecraft.net", "mirrorBaseURL": "https://mirror.example.com/maven", "pathPrefix": "v2" }
          ]
        }
        """
        let url = directory.appendingPathComponent("mirror.json")
        try Data(json.utf8).write(to: url)
        let configuration = try TrustedMirrorConfiguration.load(from: url)
        XCTAssertEqual(configuration.id, "example")
        XCTAssertEqual(configuration.mirroredHosts, ["libraries.minecraft.net", "piston-meta.mojang.com"])
        XCTAssertEqual(configuration.rule(forHost: "LIBRARIES.MINECRAFT.NET")?.pathPrefix, "v2")
    }

    func testMalformedMirrorConfigurationFailsExplicitly() throws {
        let directory = try FixtureLoader.temporaryDirectory("lingxi-mirror")
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("mirror.json")
        try Data("{\"id\":\"x\"}".utf8).write(to: url)
        XCTAssertThrowsError(try TrustedMirrorConfiguration.load(from: url)) { error in
            XCTAssertEqual((error as? LauncherError)?.code, .invalidMetadata)
        }
    }
}
