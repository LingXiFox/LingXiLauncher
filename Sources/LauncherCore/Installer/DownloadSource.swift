import Foundation

/// How the installer chooses where to fetch files from.
///
/// - `official`: only Mojang endpoints from the version metadata.
/// - `mirror`: only an explicitly configured trusted mirror; every official host the mirror
///   serves must be declared in the configuration. There is no implicit or wildcard rewriting.
/// - `auto`: official first, then the configured mirror for the same file after an explicit
///   failure (network error, 5xx, hash/size mismatch).
/// - `localCacheOnly`: never touches the network; only already-cached files may be used.
public enum DownloadSourcePolicy: String, Sendable, Codable, CaseIterable {
    case official
    case mirror
    case auto
    case localCacheOnly = "local-cache-only"

    public var displayName: String {
        switch self {
        case .official: return "official"
        case .mirror: return "mirror"
        case .auto: return "auto"
        case .localCacheOnly: return "local-cache-only"
        }
    }
}

/// One explicit mapping: requests for `officialHost` are served by `mirrorBaseURL`.
///
/// The mirror base URL must be HTTPS. An optional `pathPrefix` is inserted between the mirror
/// base path and the official path (some mirrors mount Mojang content under a sub-path).
public struct MirrorHostRule: Codable, Sendable, Equatable {
    public let officialHost: String
    public let mirrorBaseURL: URL
    public let pathPrefix: String?

    public init(officialHost: String, mirrorBaseURL: URL, pathPrefix: String? = nil) {
        self.officialHost = officialHost.lowercased()
        self.mirrorBaseURL = mirrorBaseURL
        self.pathPrefix = pathPrefix
    }
}

/// A trusted mirror configuration loaded from a JSON file supplied by the user/administrator.
///
/// Example:
/// ```json
/// {
///   "id": "example-mirror",
///   "displayName": "Example trusted mirror",
///   "rules": [
///     { "officialHost": "piston-meta.mojang.com", "mirrorBaseURL": "https://mirror.example.com" },
///     { "officialHost": "piston-data.mojang.com", "mirrorBaseURL": "https://mirror.example.com" },
///     { "officialHost": "libraries.minecraft.net", "mirrorBaseURL": "https://mirror.example.com/maven" },
///     { "officialHost": "resources.download.minecraft.net", "mirrorBaseURL": "https://mirror.example.com/objects" }
///   ]
/// }
/// ```
///
/// Nothing is bundled by default: using a mirror is an explicit operator decision. A public
/// file host is not "Mojang-authorized" just because it mirrors Mojang files — verify its terms
/// and current API before configuring it.
public struct TrustedMirrorConfiguration: Codable, Sendable, Equatable {
    public let id: String
    public let displayName: String
    public let rules: [MirrorHostRule]

    public init(id: String, displayName: String, rules: [MirrorHostRule]) throws {
        guard !id.isEmpty, !displayName.isEmpty else {
            throw LauncherError(.invalidMetadata, "Mirror configuration needs a non-empty id and displayName")
        }
        guard !rules.isEmpty else {
            throw LauncherError(.invalidMetadata, "Mirror configuration '\(id)' declares no host rules")
        }
        for rule in rules {
            guard rule.mirrorBaseURL.scheme?.lowercased() == "https", rule.mirrorBaseURL.host != nil else {
                throw LauncherError(
                    .invalidMetadata,
                    "Mirror '\(id)' maps \(rule.officialHost) to a non-HTTPS URL: \(rule.mirrorBaseURL.absoluteString)",
                    suggestion: "Trusted mirrors must be served over HTTPS."
                )
            }
        }
        self.id = id
        self.displayName = displayName
        self.rules = rules
    }

    public static func load(from url: URL) throws -> TrustedMirrorConfiguration {
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            throw LauncherError(.ioFailure, "Cannot read mirror configuration \(url.path): \(error.localizedDescription)")
        }
        do {
            let decoder = JSONDecoder()
            let raw = try decoder.decode(TrustedMirrorConfiguration.self, from: data)
            return try TrustedMirrorConfiguration(id: raw.id, displayName: raw.displayName, rules: raw.rules)
        } catch let error as LauncherError {
            throw error
        } catch {
            throw LauncherError(.invalidMetadata, "Invalid mirror configuration \(url.path): \(error.localizedDescription)")
        }
    }

    public func rule(forHost host: String) -> MirrorHostRule? {
        let normalized = host.lowercased()
        return rules.first { $0.officialHost == normalized }
    }

    public var mirroredHosts: [String] {
        rules.map(\.officialHost).sorted()
    }
}

/// The result of mapping an official metadata URL through a source policy.
public struct DownloadCandidate: Sendable, Equatable {
    /// The URL to request (official or mirror).
    public let url: URL
    /// Human label for progress output: `official` or the mirror id.
    public let sourceLabel: String

    public init(url: URL, sourceLabel: String) {
        self.url = url
        self.sourceLabel = sourceLabel
    }
}

/// Resolves official metadata URLs into an ordered list of download candidates.
///
/// Guarantees:
/// - Only HTTPS URLs are ever requested.
/// - Mirror URLs are produced solely from explicit host rules; the official path and query are
///   preserved verbatim and the result must still be HTTPS.
/// - `localCacheOnly` yields no candidates (the downloader must fail instead of reaching out).
public struct SourceResolver: Sendable {
    public let policy: DownloadSourcePolicy
    public let mirror: TrustedMirrorConfiguration?

    public init(policy: DownloadSourcePolicy, mirror: TrustedMirrorConfiguration? = nil) throws {
        if policy == .mirror, mirror == nil {
            throw LauncherError(
                .usageError,
                "--source mirror requires a trusted mirror configuration",
                suggestion: "Pass --mirror-config <path-to-json> with explicit host mappings."
            )
        }
        self.policy = policy
        self.mirror = mirror
    }

    public var allowsNetwork: Bool {
        policy != .localCacheOnly
    }

    public func candidates(for officialURL: URL) throws -> [DownloadCandidate] {
        guard policy != .localCacheOnly else { return [] }
        guard officialURL.scheme?.lowercased() == "https", officialURL.host != nil else {
            throw LauncherError(
                .invalidMetadata,
                "Refusing to download from a non-HTTPS URL: \(officialURL.absoluteString)",
                suggestion: "Only HTTPS metadata URLs are accepted; the version metadata may be corrupt."
            )
        }
        switch policy {
        case .official:
            return [DownloadCandidate(url: officialURL, sourceLabel: "official")]
        case .mirror:
            guard let mirror else {
                throw LauncherError(.usageError, "--source mirror requires --mirror-config")
            }
            guard let mapped = Self.map(officialURL, through: mirror) else {
                throw LauncherError(
                    .usageError,
                    "Mirror '\(mirror.id)' has no explicit mapping for host '\(officialURL.host ?? "?")'",
                    suggestion: "Add a mirror rule for this host or use --source official/auto."
                )
            }
            return [DownloadCandidate(url: mapped, sourceLabel: mirror.id)]
        case .auto:
            var candidates = [DownloadCandidate(url: officialURL, sourceLabel: "official")]
            if let mirror, let mapped = Self.map(officialURL, through: mirror) {
                candidates.append(DownloadCandidate(url: mapped, sourceLabel: mirror.id))
            }
            return candidates
        case .localCacheOnly:
            return []
        }
    }

    /// Explicit host mapping only: `mirrorBase + pathPrefix + official path`.
    static func map(_ officialURL: URL, through mirror: TrustedMirrorConfiguration) -> URL? {
        guard let host = officialURL.host?.lowercased(),
              let rule = mirror.rule(forHost: host) else {
            return nil
        }
        var mapped = URLComponents()
        mapped.scheme = rule.mirrorBaseURL.scheme
        mapped.host = rule.mirrorBaseURL.host
        mapped.port = rule.mirrorBaseURL.port

        let basePath = rule.mirrorBaseURL.path
        let prefix = rule.pathPrefix ?? ""
        var path = basePath
        if !prefix.isEmpty {
            path = path.hasSuffix("/") ? path + prefix.drop(while: { $0 == "/" }) : path + (prefix.hasPrefix("/") ? prefix : "/" + prefix)
        }
        let officialPath = officialURL.path
        if path.hasSuffix("/"), officialPath.hasPrefix("/") {
            path += officialPath.dropFirst()
        } else {
            path += officialPath
        }
        mapped.path = path
        mapped.query = URLComponents(url: officialURL, resolvingAgainstBaseURL: false)?.query
        guard let url = mapped.url, url.scheme?.lowercased() == "https" else { return nil }
        return url
    }
}
