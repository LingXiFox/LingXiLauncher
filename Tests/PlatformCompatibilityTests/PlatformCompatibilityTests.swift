import XCTest
@testable import LauncherCore
#if canImport(MacPlatform)
@testable import MacPlatform
#elseif canImport(WindowsPlatform)
@testable import WindowsPlatform
#endif

final class PlatformCompatibilityTests: XCTestCase {
    override func setUp() {
        super.setUp()
        #if canImport(MacPlatform)
        MacPlatform.install()
        #elseif canImport(WindowsPlatform)
        WindowsPlatform.install()
        #endif
    }

    func testHostContextIsAvailable() {
        let context = PlatformRuntime.host.context
        XCTAssertFalse(context.osVersion.isEmpty)
    }

    func testHostArchitectureIsKnown() {
        #if arch(arm64)
        XCTAssertEqual(PlatformRuntime.host.context.architecture, .arm64)
        #elseif arch(x86_64)
        XCTAssertEqual(PlatformRuntime.host.context.architecture, .x86_64)
        #endif
    }

    func testPathListSeparatorMatchesPlatform() {
        #if os(Windows)
        XCTAssertEqual(PlatformRuntime.host.pathListSeparator, ";")
        #else
        XCTAssertEqual(PlatformRuntime.host.pathListSeparator, ":")
        #endif
    }

    func testDefaultDataRootIsAbsolute() {
        XCTAssertTrue(PlatformRuntime.host.defaultDataRoot.path.hasPrefix("/")
            || PlatformRuntime.host.defaultDataRoot.path.contains(":"))
    }

    func testSystemProfileReportsMemoryAndCores() {
        let hardware = PlatformRuntime.system.hardware()
        XCTAssertGreaterThan(hardware.memoryBytes, 0)
        XCTAssertGreaterThan(hardware.logicalCores, 0)
    }

    func testProcessInspectorFindsCurrentProcess() {
        XCTAssertTrue(PlatformRuntime.process.isRunning(pid: ProcessInfo.processInfo.processIdentifier))
    }

    func testProcessInspectorRejectsInvalidPID() {
        XCTAssertFalse(PlatformRuntime.process.isRunning(pid: -1))
    }


    func testAtomicFileReplacementReplacesExistingAndNewTargets() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("lingxi-replace-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let destination = root.appendingPathComponent("state.json")
        let first = root.appendingPathComponent("first.json")
        let second = root.appendingPathComponent("second.json")
        try Data("one".utf8).write(to: first)
        try PlatformRuntime.replacer.replaceItem(at: destination, with: first)
        XCTAssertEqual(try String(contentsOf: destination, encoding: .utf8), "one")
        try Data("two".utf8).write(to: second)
        try PlatformRuntime.replacer.replaceItem(at: destination, with: second)
        XCTAssertEqual(try String(contentsOf: destination, encoding: .utf8), "two")
        XCTAssertFalse(FileManager.default.fileExists(atPath: second.path))
    }

    func testFileLockIsExclusive() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("lingxi-lock-\(UUID().uuidString)")
        let first = try PlatformRuntime.fileLock.acquireExclusive(at: url)
        XCTAssertThrowsError(try PlatformRuntime.fileLock.acquireExclusive(at: url))
        first.release()
        let second = try PlatformRuntime.fileLock.acquireExclusive(at: url)
        second.release()
    }

    func testFileLockCanBeReacquiredAfterRelease() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("lingxi-lock-\(UUID().uuidString)")
        let token = try PlatformRuntime.fileLock.acquireExclusive(at: url)
        token.release()
        let again = try PlatformRuntime.fileLock.acquireExclusive(at: url)
        again.release()
    }

    func testGraphicsProbeDoesNotCrash() {
        _ = PlatformRuntime.graphics.current()
    }

    func testCredentialStoreRoundTrip() throws {
        let id = UUID()
        let store = PlatformRuntime.credentials
        try store.save(refreshToken: "value", for: id)
        XCTAssertEqual(try store.loadRefreshToken(for: id), "value")
        try store.deleteRefreshToken(for: id)
    }

    func testProcessIdentityCanBeSampled() {
        let pid = ProcessInfo.processInfo.processIdentifier
        guard let identity = PlatformRuntime.system.processIdentity(pid: pid) else {
            #if os(Windows)
            return
            #else
            return XCTFail("No process identity")
            #endif
        }
        XCTAssertEqual(identity.processIdentifier, pid)
    }

    func testPlatformContextDescribesHost() {
        XCTAssertEqual(PlatformRuntime.host.context.hostArchitecture, PlatformRuntime.host.context.architecture)
    }

    func testPathSafetyRejectsTraversalOnAllPlatforms() {
        XCTAssertThrowsError(try PathSafety.validatedPathComponent("../escape"))
    }

    func testArchiveLimitsArePositive() {
        XCTAssertGreaterThan(ArchiveLimits().maxEntrySize, 0)
    }


    func testZIPReadEntriesAndSafeExtraction() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("lingxi-zip-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let archive = directory.appendingPathComponent("sample.zip")
        try makeStoredZIP(name: "hello.txt", content: "hello").write(to: archive)
        let entries = try PlatformRuntime.archive.readEntries(try Data(contentsOf: archive), limits: ArchiveLimits())
        XCTAssertEqual(entries.map(\.name), ["hello.txt"])
        XCTAssertEqual(entries.first?.data, Data("hello".utf8))
        let output = directory.appendingPathComponent("out")
        _ = try PlatformRuntime.archive.extract(archive: archive, into: output, excluding: [], limits: ArchiveLimits())
        XCTAssertEqual(try String(contentsOf: output.appendingPathComponent("hello.txt"), encoding: .utf8), "hello")
    }

    func testZIPTraversalIsRejectedBeforeExtraction() throws {
        let archive = FileManager.default.temporaryDirectory
            .appendingPathComponent("lingxi-evil-\(UUID().uuidString).zip")
        defer { try? FileManager.default.removeItem(at: archive) }
        try makeStoredZIP(name: "../evil.txt", content: "x").write(to: archive)
        XCTAssertThrowsError(try PlatformRuntime.archive.readEntries(try Data(contentsOf: archive), limits: ArchiveLimits()))
    }

    private func crc32(_ bytes: [UInt8]) -> Int {
        var crc = 0xFFFF_FFFF
        for byte in bytes {
            crc ^= Int(byte)
            for _ in 0..<8 {
                crc = (crc >> 1) ^ (0xEDB8_8320 & (0 - (crc & 1)))
            }
        }
        return crc ^ 0xFFFF_FFFF
    }

    private func makeStoredZIP(name: String, content: String) -> Data {
        let nameBytes = Array(name.utf8)
        let contentBytes = Array(content.utf8)
        func u16(_ value: Int) -> [UInt8] { [UInt8(value & 0xff), UInt8((value >> 8) & 0xff)] }
        func u32(_ value: Int) -> [UInt8] { [UInt8(value & 0xff), UInt8((value >> 8) & 0xff), UInt8((value >> 16) & 0xff), UInt8((value >> 24) & 0xff)] }
        var local: [UInt8] = [0x50, 0x4b, 0x03, 0x04]
        local += u16(20) + u16(0) + u16(0) + u16(0) + u16(0)
        let crc = crc32(contentBytes)
        local += u32(crc) + u32(contentBytes.count) + u32(contentBytes.count)
        local += u16(nameBytes.count) + u16(0) + nameBytes + contentBytes
        let centralOffset = local.count
        var central: [UInt8] = [0x50, 0x4b, 0x01, 0x02]
        central += u16(20) + u16(20) + u16(0) + u16(0) + u16(0) + u16(0)
        central += u32(crc) + u32(contentBytes.count) + u32(contentBytes.count)
        central += u16(nameBytes.count) + u16(0) + u16(0) + u16(0) + u16(0)
        central += u32(0) + u32(0) + nameBytes
        var end: [UInt8] = [0x50, 0x4b, 0x05, 0x06]
        end += u16(0) + u16(0) + u16(1) + u16(1)
        end += u32(central.count) + u32(centralOffset) + u16(0)
        return Data(local + central + end)
    }


#if canImport(WindowsPlatform)
    func testDPAPIRefreshTokenPersistsAndDeletes() throws {
        let store = WindowsCredentialStore()
        let id = UUID()
        defer { try? store.deleteRefreshToken(for: id) }
        XCTAssertNil(try store.loadRefreshToken(for: id))
        try store.save(refreshToken: "dpapi-test-token", for: id)
        XCTAssertEqual(try store.loadRefreshToken(for: id), "dpapi-test-token")
        try store.deleteRefreshToken(for: id)
        XCTAssertNil(try store.loadRefreshToken(for: id))
    }
#endif

    func testRuntimeServicesAreInstalled() {
        XCTAssertNotNil(PlatformRuntime.fileLock as Any)
        XCTAssertNotNil(PlatformRuntime.host as Any)
        XCTAssertNotNil(PlatformRuntime.credentials as Any)
    }
}
