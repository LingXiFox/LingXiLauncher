import XCTest
@testable import LauncherCore

final class DownloaderTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = try FixtureLoader.temporaryDirectory("lingxi-downloader")
    }

    override func tearDownWithError() throws {
        if let directory { try? FileManager.default.removeItem(at: directory) }
    }

    private func task(
        destination: String = "out/file.bin",
        url: URL? = URL(string: "https://piston-data.mojang.com/v1/objects/aa/file.bin"),
        sha1: String?,
        size: Int?,
        kind: MissingDependency.Kind = .library
    ) throws -> DownloadTask {
        DownloadTask(
            destination: directory.appendingPathComponent(destination),
            officialURL: url,
            sha1: sha1,
            size: size,
            kind: kind
        )
    }

    private func makeDownloader(
        _ transport: StubTransport,
        policy: DownloadSourcePolicy = .official,
        mirror: TrustedMirrorConfiguration? = nil,
        configuration: DownloadConfiguration = DownloadConfiguration(concurrency: 2, maxRetries: 3, retryDelay: 0.01, skipDiskSpaceCheck: true)
    ) throws -> Downloader {
        Downloader(
            transport: transport,
            sourceResolver: try SourceResolver(policy: policy, mirror: mirror),
            configuration: configuration
        )
    }

    private func partFiles(in directory: URL) throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: directory.path)
            .filter { $0.contains(".part-") }
    }

    func testSuccessfulDownloadVerifiesAndPlacesFile() async throws {
        let transport = StubTransport()
        let payload = Data("hello lingxi".utf8)
        let url = URL(string: "https://piston-data.mojang.com/v1/objects/aa/file.bin")!
        await transport.setData(payload, for: url)
        let item = try task(sha1: SHA1.hexDigest(payload), size: payload.count)
        let recorder = EventRecorder()

        let summary = try await makeDownloader(transport).download([item], progress: { recorder.record($0) })

        XCTAssertTrue(summary.failures.isEmpty)
        XCTAssertEqual(summary.downloaded.count, 1)
        XCTAssertEqual(summary.downloadedBytes, payload.count)
        XCTAssertEqual(try Data(contentsOf: item.destination), payload)
        XCTAssertEqual(try partFiles(in: item.destination.deletingLastPathComponent()), [])
        XCTAssertEqual(recorder.plan?.totalFiles, 1)
        XCTAssertEqual(recorder.plan?.cacheHits, 0)
    }

    func testHashMismatchRejectsFileAndLeavesNoPartialFile() async throws {
        let transport = StubTransport()
        let payload = Data("tampered".utf8)
        let url = URL(string: "https://piston-data.mojang.com/v1/objects/aa/file.bin")!
        await transport.setData(payload, for: url)
        let item = try task(sha1: SHA1.hexDigest(Data("expected".utf8)), size: payload.count)

        let summary = try await makeDownloader(transport).download([item], progress: { _ in })

        XCTAssertEqual(summary.failures.count, 1)
        XCTAssertEqual(summary.failures.first?.code, .hashMismatch)
        XCTAssertFalse(FileManager.default.fileExists(atPath: item.destination.path))
        XCTAssertEqual(try partFiles(in: item.destination.deletingLastPathComponent()), [])
    }

    func testSizeMismatchRejectsFile() async throws {
        let transport = StubTransport()
        let payload = Data("short".utf8)
        let url = URL(string: "https://piston-data.mojang.com/v1/objects/aa/file.bin")!
        await transport.setData(payload, for: url)
        let item = try task(sha1: SHA1.hexDigest(payload), size: payload.count + 100)

        let summary = try await makeDownloader(transport).download([item], progress: { _ in })
        XCTAssertEqual(summary.failures.first?.code, .sizeMismatch)
        XCTAssertFalse(FileManager.default.fileExists(atPath: item.destination.path))
    }

    func testEmptyPayloadIsRejected() async throws {
        let transport = StubTransport()
        let url = URL(string: "https://piston-data.mojang.com/v1/objects/aa/file.bin")!
        await transport.setData(Data(), for: url)
        let item = try task(sha1: nil, size: nil)
        let summary = try await makeDownloader(transport).download([item], progress: { _ in })
        XCTAssertEqual(summary.failures.first?.code, .sizeMismatch)
    }

    func testCacheHitDoesNotTouchTransport() async throws {
        let transport = StubTransport()
        let payload = Data("cached payload".utf8)
        let item = try task(sha1: SHA1.hexDigest(payload), size: payload.count)
        try FileManager.default.createDirectory(at: item.destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        try payload.write(to: item.destination)

        let summary = try await makeDownloader(transport).download([item], progress: { _ in })
        XCTAssertEqual(summary.cacheHits, 1)
        XCTAssertTrue(summary.downloaded.isEmpty)
        let observed1 = await transport.totalRequests
        XCTAssertEqual(observed1, 0)
    }

    func testStaleCacheIsReplaced() async throws {
        let transport = StubTransport()
        let good = Data("fresh bytes".utf8)
        let url = URL(string: "https://piston-data.mojang.com/v1/objects/aa/file.bin")!
        await transport.setData(good, for: url)
        let item = try task(sha1: SHA1.hexDigest(good), size: good.count)
        try FileManager.default.createDirectory(at: item.destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("stale".utf8).write(to: item.destination)

        let summary = try await makeDownloader(transport).download([item], progress: { _ in })
        XCTAssertEqual(summary.downloaded.count, 1)
        XCTAssertEqual(summary.cacheHits, 0)
        XCTAssertEqual(try Data(contentsOf: item.destination), good)
    }

    func testRetriesRetryableNetworkErrors() async throws {
        let transport = StubTransport()
        let payload = Data("eventually".utf8)
        let url = URL(string: "https://piston-data.mojang.com/v1/objects/aa/file.bin")!
        await transport.setData(payload, for: url)
        await transport.setFailure(.network("connection reset"), for: url, times: 2)
        let item = try task(sha1: SHA1.hexDigest(payload), size: payload.count)

        let summary = try await makeDownloader(transport).download([item], progress: { _ in })
        XCTAssertTrue(summary.failures.isEmpty)
        let observed2 = await transport.requestCounts[url.absoluteString]
        XCTAssertEqual(observed2, 3)
    }

    func testNotFoundIsNotRetried() async throws {
        let transport = StubTransport()
        let url = URL(string: "https://piston-data.mojang.com/v1/objects/aa/missing.bin")!
        await transport.setFailure(.httpStatus(404), for: url, times: 5)
        let item = try task(url: url, sha1: nil, size: nil)

        let summary = try await makeDownloader(transport).download([item], progress: { _ in })
        XCTAssertEqual(summary.failures.first?.code, .httpNotFound)
        let observed3 = await transport.requestCounts[url.absoluteString]
        XCTAssertEqual(observed3, 1)
    }

    func testAutoFallsBackToMirrorAfterOfficialFailure() async throws {
        let transport = StubTransport()
        let payload = Data("mirror payload".utf8)
        let officialURL = URL(string: "https://piston-data.mojang.com/v1/objects/aa/file.bin")!
        let mirrorConfiguration = try TrustedMirrorConfiguration(
            id: "mirror-test",
            displayName: "Mirror",
            rules: [MirrorHostRule(officialHost: "piston-data.mojang.com", mirrorBaseURL: URL(string: "https://mirror.example.com")!)]
        )
        let mirroredURL = URL(string: "https://mirror.example.com/v1/objects/aa/file.bin")!
        await transport.setFailure(.network("official down"), for: officialURL, times: 10)
        await transport.setData(payload, for: mirroredURL)
        let item = try task(url: officialURL, sha1: SHA1.hexDigest(payload), size: payload.count)

        let summary = try await makeDownloader(
            transport,
            policy: .auto,
            mirror: mirrorConfiguration,
            configuration: DownloadConfiguration(concurrency: 1, maxRetries: 2, retryDelay: 0.01, skipDiskSpaceCheck: true)
        ).download([item], progress: { _ in })

        XCTAssertTrue(summary.failures.isEmpty)
        XCTAssertEqual(summary.downloaded.first?.source, "mirror-test")
        let observed4 = await transport.requestCounts[officialURL.absoluteString]
        XCTAssertEqual(observed4, 2)
        let observed5 = await transport.requestCounts[mirroredURL.absoluteString]
        XCTAssertEqual(observed5, 1)
    }

    func testLocalCacheOnlyNeverTouchesTransport() async throws {
        let transport = StubTransport()
        let item = try task(sha1: nil, size: 10)
        let summary = try await makeDownloader(transport, policy: .localCacheOnly).download([item], progress: { _ in })
        XCTAssertEqual(summary.failures.count, 1)
        XCTAssertEqual(summary.failures.first?.code, .missingDependency)
        XCTAssertTrue(summary.failures.first?.message.contains("local-cache-only") ?? false)
        let observed6 = await transport.totalRequests
        XCTAssertEqual(observed6, 0)
    }

    func testMissingOfficialURLFailsWithoutNetwork() async throws {
        let transport = StubTransport()
        let item = try task(url: nil, sha1: nil, size: nil)
        let summary = try await makeDownloader(transport).download([item], progress: { _ in })
        XCTAssertEqual(summary.failures.first?.code, .missingDependency)
        let observed7 = await transport.totalRequests
        XCTAssertEqual(observed7, 0)
    }

    func testConcurrencyIsBounded() async throws {
        let transport = StubTransport(delay: 0.05)
        var tasks: [DownloadTask] = []
        for index in 0..<8 {
            let payload = Data("payload-\(index)".utf8)
            let url = URL(string: "https://piston-data.mojang.com/v1/objects/aa/\(index).bin")!
            await transport.setData(payload, for: url)
            tasks.append(try task(destination: "out/\(index).bin", url: url, sha1: SHA1.hexDigest(payload), size: payload.count))
        }

        let summary = try await makeDownloader(
            transport,
            configuration: DownloadConfiguration(concurrency: 2, maxRetries: 1, retryDelay: 0, skipDiskSpaceCheck: true)
        ).download(tasks, progress: { _ in })

        XCTAssertTrue(summary.failures.isEmpty)
        XCTAssertEqual(summary.downloaded.count, 8)
        let maxConcurrent = await transport.maxConcurrentRequests
        XCTAssertLessThanOrEqual(maxConcurrent, 2)
        XCTAssertGreaterThan(maxConcurrent, 1)
    }

    func testDuplicateDestinationsAreDownloadedOnce() async throws {
        let transport = StubTransport()
        let payload = Data("dedupe".utf8)
        let url = URL(string: "https://piston-data.mojang.com/v1/objects/aa/file.bin")!
        await transport.setData(payload, for: url)
        let first = try task(sha1: SHA1.hexDigest(payload), size: payload.count)
        let second = try task(sha1: SHA1.hexDigest(payload), size: payload.count)

        let summary = try await makeDownloader(transport).download([first, second], progress: { _ in })
        XCTAssertEqual(summary.downloaded.count, 1)
        let observed8 = await transport.totalRequests
        XCTAssertEqual(observed8, 1)
    }


    func testExistingFileIsAtomicallyReplacedAfterVerification() async throws {
        let transport = StubTransport()
        let newPayload = Data("new verified payload".utf8)
        let url = URL(string: "https://piston-data.mojang.com/v1/objects/aa/file.bin")!
        await transport.setData(newPayload, for: url)
        let item = try task(sha1: SHA1.hexDigest(newPayload), size: newPayload.count)
        try FileManager.default.createDirectory(at: item.destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("old payload".utf8).write(to: item.destination)

        let summary = try await makeDownloader(transport).download([item], progress: { _ in })
        XCTAssertTrue(summary.failures.isEmpty)
        XCTAssertEqual(try Data(contentsOf: item.destination), newPayload)
        XCTAssertEqual(try partFiles(in: item.destination.deletingLastPathComponent()), [])
    }

    func testFailedVerificationPreservesExistingCacheFile() async throws {
        let transport = StubTransport()
        let tampered = Data("tampered download".utf8)
        let url = URL(string: "https://piston-data.mojang.com/v1/objects/aa/file.bin")!
        await transport.setData(tampered, for: url)
        let item = try task(sha1: SHA1.hexDigest(Data("expected".utf8)), size: tampered.count)
        try FileManager.default.createDirectory(at: item.destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        let old = Data("previous complete file".utf8)
        try old.write(to: item.destination)

        let summary = try await makeDownloader(transport).download([item], progress: { _ in })
        XCTAssertEqual(summary.failures.first?.code, .hashMismatch)
        XCTAssertEqual(try Data(contentsOf: item.destination), old, "a rejected download must never replace an existing file")
        XCTAssertEqual(try partFiles(in: item.destination.deletingLastPathComponent()), [])
    }

    func testPlacementFailurePreservesExistingFile() async throws {
        let transport = StubTransport()
        let payload = Data("replacement".utf8)
        let url = URL(string: "https://piston-data.mojang.com/v1/objects/aa/immutable.bin")!
        await transport.setData(payload, for: url)
        let item = try task(destination: "out/immutable.bin", url: url, sha1: SHA1.hexDigest(payload), size: payload.count)
        try FileManager.default.createDirectory(at: item.destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        let old = Data("immutable original".utf8)
        try old.write(to: item.destination)
        try FileManager.default.setAttributes([.immutable: true], ofItemAtPath: item.destination.path)
        defer { try? FileManager.default.setAttributes([.immutable: false], ofItemAtPath: item.destination.path) }

        let summary = try await makeDownloader(transport).download([item], progress: { _ in })
        XCTAssertEqual(summary.failures.count, 1)
        XCTAssertEqual(try Data(contentsOf: item.destination), old, "a failed atomic replace must leave the existing file intact")
        XCTAssertEqual(try partFiles(in: item.destination.deletingLastPathComponent()), [])
    }

    func testPlanReportsCacheHitsBeforeDownloading() async throws {
        let transport = StubTransport()
        let cached = Data("cached".utf8)
        let cachedTask = try task(destination: "out/cached.bin", sha1: SHA1.hexDigest(cached), size: cached.count)
        try FileManager.default.createDirectory(at: cachedTask.destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        try cached.write(to: cachedTask.destination)

        let fresh = Data("fresh".utf8)
        let freshURL = URL(string: "https://piston-data.mojang.com/v1/objects/aa/fresh.bin")!
        await transport.setData(fresh, for: freshURL)
        let freshTask = try task(destination: "out/fresh.bin", url: freshURL, sha1: SHA1.hexDigest(fresh), size: fresh.count)

        let recorder = EventRecorder()
        _ = try await makeDownloader(transport).download([cachedTask, freshTask], progress: { recorder.record($0) })
        XCTAssertEqual(recorder.plan?.totalFiles, 2)
        XCTAssertEqual(recorder.plan?.cacheHits, 1)
        XCTAssertEqual(recorder.plan?.totalBytes, fresh.count)
    }
}
