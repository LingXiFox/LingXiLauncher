import XCTest
import MacPlatform
@testable import LauncherCore

final class SafeZipExtractorTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        MacPlatform.install()
        directory = try FixtureLoader.temporaryDirectory("lingxi-zip")
    }

    override func tearDownWithError() throws {
        if let directory { try? FileManager.default.removeItem(at: directory) }
    }

    private func archive(_ name: String) throws -> URL {
        try FixtureLoader.url("zip/\(name).zip")
    }

    func testExtractsNormalArchive() throws {
        let extracted = try SafeZipExtractor.extract(
            archive: try archive("native_normal"),
            into: directory
        )
        XCTAssertEqual(extracted.count, 4)
        XCTAssertEqual(
            try String(contentsOf: directory.appendingPathComponent("lib/README.txt"), encoding: .utf8),
            "native docs\n"
        )
        XCTAssertTrue(FileManager.default.fileExists(atPath: directory.appendingPathComponent("lib/liblwjgl.dylib").path))
    }

    func testExcludesPrefixes() throws {
        let extracted = try SafeZipExtractor.extract(
            archive: try archive("native_normal"),
            into: directory,
            excluding: ["META-INF/"]
        )
        XCTAssertFalse(extracted.contains { $0.name.hasPrefix("META-INF/") })
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.appendingPathComponent("META-INF/MANIFEST.MF").path))
    }

    func testStoredEntriesAreSupported() throws {
        _ = try SafeZipExtractor.extract(archive: try archive("native_stored"), into: directory)
        XCTAssertEqual(
            try String(contentsOf: directory.appendingPathComponent("lib/stored.txt"), encoding: .utf8),
            "stored-content-1234"
        )
    }

    func testParentTraversalIsRejectedWithoutWritingOutside() throws {
        XCTAssertThrowsError(try SafeZipExtractor.extract(archive: try archive("native_traversal"), into: directory)) { error in
            XCTAssertEqual((error as? LauncherError)?.code, .pathEscapesRoot)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.deletingLastPathComponent().appendingPathComponent("evil.txt").path))
    }

    func testNestedTraversalIsRejected() throws {
        XCTAssertThrowsError(try SafeZipExtractor.extract(archive: try archive("native_nested_traversal"), into: directory)) { error in
            XCTAssertEqual((error as? LauncherError)?.code, .pathEscapesRoot)
        }
    }

    func testAbsolutePathEntryIsRejected() throws {
        XCTAssertThrowsError(try SafeZipExtractor.extract(archive: try archive("native_absolute"), into: directory)) { error in
            XCTAssertEqual((error as? LauncherError)?.code, .pathEscapesRoot)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: "/tmp/lingxi-evil.txt"))
    }

    func testSymlinkEntryIsRejected() throws {
        XCTAssertThrowsError(try SafeZipExtractor.extract(archive: try archive("native_symlink"), into: directory)) { error in
            XCTAssertEqual((error as? LauncherError)?.code, .pathEscapesRoot)
            XCTAssertTrue(((error as? LauncherError)?.message ?? "").contains("symlink"))
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.appendingPathComponent("link").path))
    }

    func testCorruptArchiveIsRejected() throws {
        XCTAssertThrowsError(try SafeZipExtractor.extract(archive: try archive("native_corrupt"), into: directory)) { error in
            XCTAssertEqual((error as? LauncherError)?.code, .invalidMetadata)
        }
    }

    func testEntrySizeLimitIsEnforced() throws {
        var limits = SafeZipExtractor.Limits()
        limits.maxEntrySize = 1
        XCTAssertThrowsError(
            try SafeZipExtractor.extract(archive: try archive("native_normal"), into: directory, limits: limits)
        ) { error in
            XCTAssertEqual((error as? LauncherError)?.code, .invalidMetadata)
        }
    }

    func testMaximumEntryCountIsEnforced() throws {
        var limits = SafeZipExtractor.Limits()
        limits.maxEntries = 1
        XCTAssertThrowsError(
            try SafeZipExtractor.extract(archive: try archive("native_normal"), into: directory, limits: limits)
        ) { error in
            XCTAssertEqual((error as? LauncherError)?.code, .invalidMetadata)
        }
    }
}
