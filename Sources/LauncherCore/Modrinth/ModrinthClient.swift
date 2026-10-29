import Foundation

/// Thin, testable client for the official Modrinth v2 API.
///
/// Usage policy implemented here:
/// - a unique `User-Agent` is always supplied (required by Modrinth);
/// - only the official HTTPS API/CDN is contacted;
/// - no API token is embedded or logged;
/// - requests are deliberately small and paginated (300 requests/minute per IP).
public struct ModrinthClient: Sendable {
    public static let defaultBaseURL = URL(string: "https://api.modrinth.com/v2")!
    public static let userAgent = "LingXiFox/LingXiLauncher/\(LauncherInfo.version) (https://github.com/LingXiFox/LingXiLauncher)"

    public let baseURL: URL
    public let transport: any DownloadTransport
    public let userAgent: String

    public init(
        baseURL: URL = ModrinthClient.defaultBaseURL,
        transport: any DownloadTransport = URLSessionTransport(),
        userAgent: String = ModrinthClient.userAgent
    ) {
        self.baseURL = baseURL
        self.transport = transport
        self.userAgent = userAgent
    }

    // MARK: - Search

    public func search(_ query: ModrinthSearchQuery) async throws -> ModrinthSearchResult {
        var components = URLComponents(url: baseURL.appendingPathComponent("search"), resolvingAgainstBaseURL: false)!
        var items: [URLQueryItem] = []
        if !query.query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            items.append(URLQueryItem(name: "query", value: query.query))
        }

        var facets: [[String]] = [
            ["project_type:\(query.projectType)"],
            ["versions:\(query.gameVersion)"],
        ]
        if query.includeLoaderFacet {
            facets.insert(["categories:\(query.loader)"], at: 1)
        }
        for category in query.categories where !category.isEmpty {
            facets.append(["categories:\(category)"])
        }
        if let encoded = Self.encode(facets) {
            items.append(URLQueryItem(name: "facets", value: encoded))
        }
        items.append(URLQueryItem(name: "index", value: query.sort.rawValue))
        items.append(URLQueryItem(name: "offset", value: String(max(0, query.offset))))
        items.append(URLQueryItem(name: "limit", value: String(min(100, max(1, query.limit)))))
        components.queryItems = items

        let data = try await get(components.url!, label: "Modrinth search")
        return try decode(ModrinthSearchResult.self, from: data, context: "Modrinth search")
    }

    public func categories(projectType: String = "mod") async throws -> [ModrinthCategory] {
        let url = baseURL.appendingPathComponent("tag/category")
        let data = try await get(url, label: "Modrinth categories")
        let all = try decode([ModrinthCategory].self, from: data, context: "Modrinth categories")
        return all.filter { $0.projectType == nil || $0.projectType == projectType }
    }

    // MARK: - Projects and versions

    public func project(idOrSlug: String) async throws -> ModrinthProject {
        let url = baseURL.appendingPathComponent("project").appendingPathComponent(idOrSlug)
        let data = try await get(url, label: "Modrinth project")
        return try decode(ModrinthProject.self, from: data, context: "Modrinth project '\(idOrSlug)'")
    }

    public func versions(
        projectID: String,
        gameVersion: String,
        loader: String? = "fabric"
    ) async throws -> [ModrinthVersion] {
        var components = URLComponents(
            url: baseURL.appendingPathComponent("project").appendingPathComponent(projectID).appendingPathComponent("version"),
            resolvingAgainstBaseURL: false
        )!
        var items = [
            URLQueryItem(name: "game_versions", value: Self.encode([gameVersion])),
            URLQueryItem(name: "include_changelog", value: "false"),
        ]
        if let loader {
            items.append(URLQueryItem(name: "loaders", value: Self.encode([loader])))
        }
        components.queryItems = items
        let data = try await get(components.url!, label: "Modrinth versions")
        return try decode([ModrinthVersion].self, from: data, context: "Modrinth versions for '\(projectID)'")
    }

    public func version(id: String) async throws -> ModrinthVersion {
        let url = baseURL.appendingPathComponent("version").appendingPathComponent(id)
        let data = try await get(url, label: "Modrinth version")
        return try decode(ModrinthVersion.self, from: data, context: "Modrinth version '\(id)'")
    }

    /// Looks up versions by SHA-1/SHA-512 using Modrinth's batch endpoint.
    ///
    /// The API accepts up to 500 hashes per request; this implementation keeps a conservative
    /// chunk size so a single request cannot become oversized or monopolize the rate limit.
    /// Unknown hashes are simply absent from the result.
    public func versions(
        forHashes hashes: [String],
        algorithm: ModrinthHashAlgorithm = .sha1
    ) async throws -> [String: ModrinthVersion] {
        let unique = Array(Set(hashes.map { $0.lowercased() }))
            .filter { Self.isValidHash($0, algorithm: algorithm) }
            .sorted()
        guard !unique.isEmpty else { return [:] }
        let url = baseURL.appendingPathComponent("version_files")
        var result: [String: ModrinthVersion] = [:]
        for start in stride(from: 0, to: unique.count, by: 100) {
            let chunk = Array(unique[start..<min(start + 100, unique.count)])
            let request = HashLookupRequest(hashes: chunk, algorithm: algorithm.rawValue)
            let body: Data
            do {
                body = try JSONEncoder().encode(request)
            } catch {
                throw LauncherError.metadata(error, context: "Could not encode Modrinth hash lookup")
            }
            let data = try await post(url, body: body, label: "Modrinth hash lookup")
            let decoded = try decode(
                [String: ModrinthVersion].self,
                from: data,
                context: "Modrinth hash lookup"
            )
            for (hash, version) in decoded {
                result[hash.lowercased()] = version
            }
        }
        return result
    }

    /// Icon downloads are performed in Core, never by SwiftUI. The URL must be HTTPS.
    public func fetchIcon(from url: URL) async throws -> Data {
        guard url.scheme?.lowercased() == "https",
              let host = url.host?.lowercased(),
              host == "cdn.modrinth.com" || host.hasSuffix(".modrinth.com") else {
            throw LauncherError(.invalidMetadata, "Refusing a non-Modrinth icon URL")
        }
        do {
            return try await transport.fetch(from: url, headers: [
                "User-Agent": userAgent,
                "Accept": "image/png,image/jpeg,image/webp",
            ])
        } catch let error as TransportError {
            throw Self.map(error, label: "Modrinth icon")
        }
    }

    // MARK: - Transport / decoding

    private func get(_ url: URL, label: String) async throws -> Data {
        guard url.scheme?.lowercased() == "https", url.host != nil else {
            throw LauncherError(.invalidMetadata, "Refusing a non-HTTPS Modrinth API URL")
        }
        do {
            return try await transport.fetch(from: url, headers: [
                "User-Agent": userAgent,
                "Accept": "application/json",
            ])
        } catch let error as TransportError {
            throw Self.map(error, label: label)
        }
    }

    private func post(_ url: URL, body: Data, label: String) async throws -> Data {
        guard url.scheme?.lowercased() == "https", url.host != nil else {
            throw LauncherError(.invalidMetadata, "Refusing a non-HTTPS Modrinth API URL")
        }
        do {
            return try await transport.postJSON(from: url, body: body, headers: [
                "User-Agent": userAgent,
                "Accept": "application/json",
            ])
        } catch let error as TransportError {
            throw Self.map(error, label: label)
        }
    }

    private static func isValidHash(_ hash: String, algorithm: ModrinthHashAlgorithm) -> Bool {
        hash.count == algorithm.expectedLength && hash.allSatisfy(\.isHexDigit)
    }

    private func decode<T: Decodable>(_ type: T.Type, from data: Data, context: String) throws -> T {
        do {
            return try JSONDecoder().decode(type, from: data)
        } catch {
            throw LauncherError.metadata(error, context: "Invalid \(context) response")
        }
    }

    private struct HashLookupRequest: Encodable {
        let hashes: [String]
        let algorithm: String
    }

    private static func encode<T: Encodable>(_ value: T) -> String? {
        guard let data = try? JSONEncoder().encode(value) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    private static func map(_ error: TransportError, label: String) -> LauncherError {
        switch error {
        case .httpStatus(404):
            return LauncherError(.httpNotFound, "\(label): project or version not found")
        case .httpStatus(403):
            return LauncherError(.httpForbidden, "\(label): Modrinth refused the request")
        case .httpStatus(429):
            return LauncherError(
                .networkFailure,
                "\(label): Modrinth rate limit reached (300 requests/minute per IP)",
                suggestion: "Wait a minute and retry; the launcher keeps requests paginated and sequential."
            )
        case .cancelled:
            return LauncherError(.networkFailure, "\(label): request cancelled")
        case let .network(message):
            return LauncherError(.networkFailure, "\(label): \(message)")
        case let .httpStatus(status):
            return LauncherError(.networkFailure, "\(label): HTTP \(status)")
        case let .invalidResponse(message):
            return LauncherError(.invalidMetadata, "\(label): \(message)")
        case let .localIO(message):
            return LauncherError(.ioFailure, "\(label): \(message)")
        }
    }
}
