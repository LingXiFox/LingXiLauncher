import Foundation
@testable import LauncherCore

/// In-memory transport used by installer/downloader tests. Never touches the network.
actor StubTransport: DownloadTransport {
    struct Response {
        var data: Data?
        var failures: [TransportError] = []
    }

    private var responses: [String: Response] = [:]
    private(set) var requestCounts: [String: Int] = [:]
    private(set) var requestedURLs: [String] = []
    private var activeRequests = 0
    private(set) var maxConcurrentRequests = 0
    private let delayNanoseconds: UInt64

    init(delay: TimeInterval = 0) {
        self.delayNanoseconds = UInt64(max(0, delay) * 1_000_000_000)
    }

    func setData(_ data: Data, for url: URL) {
        responses[url.absoluteString] = Response(data: data)
    }

    func setData(_ string: String, for url: URL) {
        setData(Data(string.utf8), for: url)
    }

    /// Injects `times` consecutive failures for a URL (consumed before the payload is served).
    func setFailure(_ error: TransportError, for url: URL, times: Int = 1) {
        var response = responses[url.absoluteString] ?? Response()
        response.failures.append(contentsOf: Array(repeating: error, count: max(1, times)))
        responses[url.absoluteString] = response
    }

    var totalRequests: Int {
        requestCounts.values.reduce(0, +)
    }

    func fetch(from url: URL) async throws -> Data {
        try await payload(for: url)
    }

    func download(from url: URL, to destination: URL) async throws {
        let data = try await payload(for: url)
        try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: destination)
    }

    private func payload(for url: URL) async throws -> Data {
        activeRequests += 1
        maxConcurrentRequests = max(maxConcurrentRequests, activeRequests)
        defer { activeRequests -= 1 }
        requestCounts[url.absoluteString, default: 0] += 1
        requestedURLs.append(url.absoluteString)
        if delayNanoseconds > 0 {
            try? await Task.sleep(nanoseconds: delayNanoseconds)
        }
        guard var response = responses[url.absoluteString] else {
            throw TransportError.httpStatus(404)
        }
        if !response.failures.isEmpty {
            let failure = response.failures.removeFirst()
            responses[url.absoluteString] = response
            throw failure
        }
        guard let data = response.data else {
            throw TransportError.httpStatus(404)
        }
        return data
    }
}

/// Thread-safe progress recorder.
final class EventRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [InstallProgressEvent] = []

    func record(_ event: InstallProgressEvent) {
        lock.lock()
        storage.append(event)
        lock.unlock()
    }

    var events: [InstallProgressEvent] {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }

    var plan: (totalFiles: Int, totalBytes: Int, cacheHits: Int)? {
        for event in events {
            if case let .plan(files, bytes, cacheHits) = event {
                return (files, bytes, cacheHits)
            }
        }
        return nil
    }

    var failedPaths: [String] {
        events.compactMap {
            if case let .fileFailed(path, _) = $0 { return path }
            return nil
        }
    }
}

/// Builds a tiny but complete synthetic Minecraft installation for installer end-to-end tests.
struct SyntheticInstallation {
    let versionID = "test-version"
    let versionJSON: Data
    let manifestJSON: Data
    let files: [URL: Data]
    let clientJarPath: String
    let libraryPaths: [String]
    let assetObjectHash: String

    init() throws {
        let clientJar = Data("synthetic-client-jar-payload".utf8)
        let libraryA = Data("synthetic-library-a".utf8)
        let libraryB = Data("synthetic-library-b".utf8)
        let logConfig = Data("<configuration/>".utf8)
        let assetObject = Data("synthetic-sound-bytes".utf8)

        let clientHash = SHA1.hexDigest(clientJar)
        let libraryAHash = SHA1.hexDigest(libraryA)
        let libraryBHash = SHA1.hexDigest(libraryB)
        let logHash = SHA1.hexDigest(logConfig)
        let assetHash = SHA1.hexDigest(assetObject)

        let assetIndex: [String: Any] = [
            "objects": [
                "minecraft/sounds/test.ogg": ["hash": assetHash, "size": assetObject.count]
            ]
        ]
        let assetIndexData = try JSONSerialization.data(withJSONObject: assetIndex, options: [.sortedKeys])
        let assetIndexHash = SHA1.hexDigest(assetIndexData)

        let libraryAPath = "com/example/liba/1.0/liba-1.0.jar"
        let libraryBPath = "com/example/libb/1.0/libb-1.0.jar"

        let version: [String: Any] = [
            "id": versionID,
            "type": "release",
            "mainClass": "net.minecraft.client.main.Main",
            "assets": "test-assets",
            "assetIndex": [
                "id": "test-assets",
                "sha1": assetIndexHash,
                "size": assetIndexData.count,
                "url": "https://piston-meta.mojang.com/v1/packages/\(assetIndexHash)/test-assets.json"
            ],
            "downloads": [
                "client": [
                    "sha1": clientHash,
                    "size": clientJar.count,
                    "url": "https://piston-data.mojang.com/v1/objects/\(clientHash)/client.jar"
                ]
            ],
            "javaVersion": ["component": "java-runtime-test", "majorVersion": 17],
            "libraries": [
                [
                    "name": "com.example:liba:1.0",
                    "downloads": [
                        "artifact": [
                            "path": libraryAPath,
                            "sha1": libraryAHash,
                            "size": libraryA.count,
                            "url": "https://libraries.minecraft.net/\(libraryAPath)"
                        ]
                    ]
                ],
                [
                    "name": "com.example:libb:1.0",
                    "downloads": [
                        "artifact": [
                            "path": libraryBPath,
                            "sha1": libraryBHash,
                            "size": libraryB.count,
                            "url": "https://libraries.minecraft.net/\(libraryBPath)"
                        ]
                    ]
                ]
            ],
            "logging": [
                "client": [
                    "argument": "-Dlog4j.configurationFile=${path}",
                    "file": [
                        "id": "client-test.xml",
                        "sha1": logHash,
                        "size": logConfig.count,
                        "url": "https://piston-data.mojang.com/v1/objects/\(logHash)/client-test.xml"
                    ]
                ]
            ],
            "arguments": [
                "game": ["--username", "${auth_player_name}"],
                "jvm": ["-cp", "${classpath}"]
            ]
        ]
        let versionData = try JSONSerialization.data(withJSONObject: version, options: [.sortedKeys])
        let versionHash = SHA1.hexDigest(versionData)

        let manifest: [String: Any] = [
            "latest": ["release": versionID, "snapshot": versionID],
            "versions": [
                [
                    "id": versionID,
                    "type": "release",
                    "url": "https://piston-meta.mojang.com/v1/packages/\(versionHash)/\(versionID).json",
                    "sha1": versionHash,
                    "releaseTime": "2026-01-01T00:00:00+00:00"
                ],
                [
                    "id": "test-snapshot",
                    "type": "snapshot",
                    "url": "https://piston-meta.mojang.com/v1/packages/\(versionHash)/\(versionID).json",
                    "sha1": versionHash
                ]
            ]
        ]
        let manifestData = try JSONSerialization.data(withJSONObject: manifest, options: [.sortedKeys])

        var files: [URL: Data] = [:]
        files[ManifestService.manifestURL] = manifestData
        files[URL(string: "https://piston-meta.mojang.com/v1/packages/\(versionHash)/\(versionID).json")!] = versionData
        files[URL(string: "https://piston-meta.mojang.com/v1/packages/\(assetIndexHash)/test-assets.json")!] = assetIndexData
        files[URL(string: "https://piston-data.mojang.com/v1/objects/\(clientHash)/client.jar")!] = clientJar
        files[URL(string: "https://libraries.minecraft.net/\(libraryAPath)")!] = libraryA
        files[URL(string: "https://libraries.minecraft.net/\(libraryBPath)")!] = libraryB
        files[URL(string: "https://piston-data.mojang.com/v1/objects/\(logHash)/client-test.xml")!] = logConfig
        files[URL(string: "https://resources.download.minecraft.net/\(assetHash.prefix(2))/\(assetHash)")!] = assetObject

        self.versionJSON = versionData
        self.manifestJSON = manifestData
        self.files = files
        self.clientJarPath = "versions/\(versionID)/\(versionID).jar"
        self.libraryPaths = [libraryAPath, libraryBPath]
        self.assetObjectHash = assetHash
    }

    func populate(_ transport: StubTransport) async {
        for (url, data) in files {
            await transport.setData(data, for: url)
        }
    }

    /// Mirror host rules covering every official host used by this fixture.
    func mirrorConfiguration(id: String = "test-mirror") throws -> TrustedMirrorConfiguration {
        try TrustedMirrorConfiguration(
            id: id,
            displayName: "Test mirror",
            rules: [
                MirrorHostRule(officialHost: "piston-meta.mojang.com", mirrorBaseURL: URL(string: "https://mirror.example.com")!),
                MirrorHostRule(officialHost: "piston-data.mojang.com", mirrorBaseURL: URL(string: "https://mirror.example.com")!),
                MirrorHostRule(officialHost: "libraries.minecraft.net", mirrorBaseURL: URL(string: "https://mirror.example.com")!),
                MirrorHostRule(officialHost: "resources.download.minecraft.net", mirrorBaseURL: URL(string: "https://mirror.example.com")!)
            ]
        )
    }

    /// The same fixture served only under the mirror host.
    func populateMirror(_ transport: StubTransport, configuration: TrustedMirrorConfiguration) async {
        for (url, data) in files {
            if let mirrored = SourceResolver.map(url, through: configuration) {
                await transport.setData(data, for: mirrored)
            }
        }
        // The manifest URL is not part of version metadata but is still fetched.
        if let mirroredManifest = SourceResolver.map(ManifestService.manifestURL, through: configuration) {
            await transport.setData(manifestJSON, for: mirroredManifest)
        }
    }
}
