import Foundation

/// `assets/indexes/<id>.json`: the asset object map used by modern Minecraft versions.
public struct AssetIndexDocument: Decodable, Sendable, Equatable {
    public struct Object: Decodable, Sendable, Equatable {
        public let hash: String
        public let size: Int
        /// Only present in legacy "virtual" indexes.
        public let isDirectory: Bool?

        public init(hash: String, size: Int, isDirectory: Bool? = nil) {
            self.hash = hash
            self.size = size
            self.isDirectory = isDirectory
        }
    }

    public let objects: [String: Object]
    /// Legacy pre-1.7 indexes need a virtual asset tree; modern versions do not.
    public let virtual: Bool?
    public let mapToResources: Bool?

    public init(objects: [String: Object], virtual: Bool? = nil, mapToResources: Bool? = nil) {
        self.objects = objects
        self.virtual = virtual
        self.mapToResources = mapToResources
    }

    /// Unique objects, de-duplicated by hash (many resource names can share one object).
    public func uniqueObjects() -> [Object] {
        var seen = Set<String>()
        var result: [Object] = []
        for object in objects.values where seen.insert(object.hash).inserted {
            result.append(object)
        }
        return result.sorted { $0.hash < $1.hash }
    }
}

/// Fetches and caches the version manifest, per-version metadata and asset indexes.
///
/// The manifest and per-version JSON are always verified against the SHA-1 published by the
/// level above them (manifest → version JSON; version metadata → asset index). An existing
/// cached copy is re-verified before use, so a corrupted cache is re-downloaded instead of
/// silently trusted.
public struct ManifestService: Sendable {
    public static let manifestURL = URL(string: "https://piston-meta.mojang.com/mc/game/version_manifest_v2.json")!

    private let transport: any DownloadTransport
    private let layout: GameDataLayout
    private let sourceResolver: SourceResolver

    public init(transport: any DownloadTransport, layout: GameDataLayout, sourceResolver: SourceResolver) {
        self.transport = transport
        self.layout = layout
        self.sourceResolver = sourceResolver
    }

    // MARK: - Manifest

    public func fetchManifest(forceRefresh: Bool = false) async throws -> VersionManifest {
        let cacheURL = layout.manifestsCacheDirectory.appendingPathComponent("version_manifest_v2.json", isDirectory: false)

        if !forceRefresh, let cached = try? Data(contentsOf: cacheURL), let manifest = try? VersionManifest.decode(from: cached) {
            return manifest
        }

        guard sourceResolver.allowsNetwork else {
            if let cached = try? Data(contentsOf: cacheURL) {
                return try VersionManifest.decode(from: cached, context: "cached version manifest")
            }
            throw LauncherError(
                .missingDependency,
                "local-cache-only: no cached version manifest at \(cacheURL.path)",
                suggestion: "Run once with --source official (or auto) to populate the cache."
            )
        }

        do {
            let data = try await fetchVerified(
                officialURL: Self.manifestURL,
                expectedSHA1: nil,
                expectedSize: nil,
                destination: cacheURL,
                label: "version manifest"
            )
            return try VersionManifest.decode(from: data, context: "version_manifest_v2.json")
        } catch {
            // Offline fallback: a previously cached manifest is still useful for local-cache-only
            // installs and for `version list`.
            if let cached = try? Data(contentsOf: cacheURL), let manifest = try? VersionManifest.decode(from: cached) {
                return manifest
            }
            throw error
        }
    }

    // MARK: - Version metadata

    @discardableResult
    public func fetchVersionMetadata(
        versionID: String,
        expectedSHA1: String?,
        expectedSize: Int? = nil
    ) async throws -> ResolvedVersion {
        let destination = try layout.versionJSONURL(versionID)

        if let data = try? Data(contentsOf: destination) {
            if expectedSHA1 == nil || (try? SHA1.hexDigest(ofFileAt: destination)) == expectedSHA1?.lowercased() {
                return try VersionResolver().resolve(versionID: versionID, from: layout.gameRoot)
            }
        }

        guard sourceResolver.allowsNetwork else {
            throw LauncherError(
                .missingDependency,
                "local-cache-only: version metadata for \(versionID) is not cached at \(destination.path)"
            )
        }

        guard let entry = try? await fetchManifest().entry(for: versionID) else {
            throw LauncherError(
                .missingDependency,
                "Version '\(versionID)' is not present in the Mojang version manifest",
                suggestion: "Run `lingxi version list` to see available version ids."
            )
        }
        guard let url = entry.url else {
            throw LauncherError(.invalidMetadata, "Manifest entry for '\(versionID)' has no valid URL")
        }

        _ = try await fetchVerified(
            officialURL: url,
            expectedSHA1: entry.sha1 ?? expectedSHA1,
            expectedSize: expectedSize,
            destination: destination,
            label: "version metadata \(versionID)"
        )
        return try VersionResolver().resolve(versionID: versionID, from: layout.gameRoot)
    }

    // MARK: - Asset index

    public func fetchAssetIndex(for version: ResolvedVersion) async throws -> AssetIndexDocument {
        guard let assetIndex = version.assetIndex else {
            throw LauncherError(
                .invalidMetadata,
                "Version \(version.id) has no assetIndex metadata; asset objects cannot be installed",
                suggestion: "Legacy versions without an asset index are not supported by the M2 installer."
            )
        }
        let destination = try layout.assetIndexURL(id: version.assetIndexID)

        if let data = try? Data(contentsOf: destination) {
            let matches = (assetIndex.sha1 == nil || (try? SHA1.hexDigest(ofFileAt: destination)) == assetIndex.sha1?.lowercased())
            if matches, let document = try? JSONDecoder().decode(AssetIndexDocument.self, from: data) {
                return document
            }
        }

        guard sourceResolver.allowsNetwork else {
            throw LauncherError(
                .missingDependency,
                "local-cache-only: asset index \(version.assetIndexID) is not cached at \(destination.path)"
            )
        }
        guard let url = assetIndex.url else {
            throw LauncherError(.invalidMetadata, "Asset index \(version.assetIndexID) has no download URL")
        }

        let data = try await fetchVerified(
            officialURL: url,
            expectedSHA1: assetIndex.sha1,
            expectedSize: assetIndex.size,
            destination: destination,
            label: "asset index \(version.assetIndexID)"
        )
        do {
            return try JSONDecoder().decode(AssetIndexDocument.self, from: data)
        } catch {
            throw LauncherError(.invalidMetadata, "Asset index \(version.assetIndexID) is not valid JSON: \(error.localizedDescription)")
        }
    }

    public func loadCachedAssetIndex(for version: ResolvedVersion) throws -> AssetIndexDocument? {
        let destination = try layout.assetIndexURL(id: version.assetIndexID)
        guard let data = try? Data(contentsOf: destination) else { return nil }
        return try? JSONDecoder().decode(AssetIndexDocument.self, from: data)
    }

    // MARK: - Shared verified fetch

    /// Downloads `officialURL` through the configured sources into `destination`, verifying
    /// size and SHA-1 before an atomic move. Returns the verified bytes.
    @discardableResult
    private func fetchVerified(
        officialURL: URL,
        expectedSHA1: String?,
        expectedSize: Int?,
        destination: URL,
        label: String
    ) async throws -> Data {
        let candidates = try sourceResolver.candidates(for: officialURL)
        guard !candidates.isEmpty else {
            throw LauncherError(.missingDependency, "local-cache-only: \(label) is not available in the local cache")
        }
        var lastError: LauncherError = LauncherError(.downloadFailed, "No source attempted for \(label)")
        for candidate in candidates {
            var attempt = 0
            while attempt < 3 {
                attempt += 1
                let partURL = destination.appendingPathExtension("part-\(UUID().uuidString.prefix(6))")
                do {
                    try await transport.download(from: candidate.url, to: partURL)
                    let size = try Self.fileSize(partURL)
                    if let expectedSize, size != expectedSize {
                        throw LauncherError(.sizeMismatch, "\(label) has size \(size), expected \(expectedSize)")
                    }
                    if let expectedSHA1 {
                        let actual = try SHA1.hexDigest(ofFileAt: partURL)
                        guard actual == expectedSHA1.lowercased() else {
                            throw LauncherError(.hashMismatch, "\(label) SHA-1 mismatch: expected \(expectedSHA1), got \(actual)")
                        }
                    }
                    try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
                    try? FileManager.default.removeItem(at: destination)
                    try FileManager.default.moveItem(at: partURL, to: destination)
                    return try Data(contentsOf: destination)
                } catch let error as TransportError {
                    try? FileManager.default.removeItem(at: partURL)
                    lastError = LauncherError(error.launcherCode, "\(label) from \(candidate.sourceLabel): \(error.description)")
                    if error.isRetryable, attempt < 3 {
                        try? await Task.sleep(nanoseconds: UInt64(attempt) * 500_000_000)
                        continue
                    }
                    break
                } catch let error as LauncherError {
                    try? FileManager.default.removeItem(at: partURL)
                    lastError = error
                    break
                } catch {
                    try? FileManager.default.removeItem(at: partURL)
                    lastError = LauncherError(.downloadFailed, "\(label): \(error.localizedDescription)")
                    break
                }
            }
        }
        throw lastError
    }

    private static func fileSize(_ url: URL) throws -> Int {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
              let size = (attributes[.size] as? NSNumber)?.intValue else {
            throw LauncherError(.ioFailure, "Cannot read downloaded file \(url.path)")
        }
        return size
    }
}
