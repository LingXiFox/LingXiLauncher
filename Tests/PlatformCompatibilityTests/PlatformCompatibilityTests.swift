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

    func testRuntimeServicesAreInstalled() {
        XCTAssertNotNil(PlatformRuntime.fileLock as Any)
        XCTAssertNotNil(PlatformRuntime.host as Any)
        XCTAssertNotNil(PlatformRuntime.credentials as Any)
    }
}
