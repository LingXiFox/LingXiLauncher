import Foundation

public enum ModrinthSort: String, Codable, CaseIterable, Sendable {
    case relevance
    case downloads
    case follows
    case newest
    case updated

    public var displayName: String {
        switch self {
        case .relevance: return "相关度"
        case .downloads: return "下载量"
        case .follows: return "关注数"
        case .newest: return "最新发布"
        case .updated: return "最近更新"
        }
    }
}

public struct ModrinthSearchQuery: Sendable, Equatable {
    public var query: String
    public var gameVersion: String
    public var loader: String
    public var categories: [String]
    public var sort: ModrinthSort
    public var offset: Int
    public var limit: Int

    public init(
        query: String = "",
        gameVersion: String,
        loader: String = "fabric",
        categories: [String] = [],
        sort: ModrinthSort = .relevance,
        offset: Int = 0,
        limit: Int = 20
    ) {
        self.query = query
        self.gameVersion = gameVersion
        self.loader = loader
        self.categories = categories
        self.sort = sort
        self.offset = max(0, offset)
        self.limit = min(100, max(1, limit))
    }
}

public struct ModrinthSearchResult: Decodable, Sendable, Equatable {
    public let hits: [ModrinthProjectHit]
    public let offset: Int
    public let limit: Int
    public let totalHits: Int

    private enum CodingKeys: String, CodingKey {
        case hits, offset, limit
        case totalHits = "total_hits"
    }

    public init(hits: [ModrinthProjectHit], offset: Int, limit: Int, totalHits: Int) {
        self.hits = hits
        self.offset = offset
        self.limit = limit
        self.totalHits = totalHits
    }
}

public struct ModrinthProjectHit: Decodable, Sendable, Equatable, Identifiable {
    public let projectID: String
    public let slug: String?
    public let title: String
    public let description: String
    public let author: String?
    public let categories: [String]
    public let versions: [String]
    public let downloads: Int
    public let follows: Int
    public let iconURL: String?
    public let dateModified: String?
    public let latestVersion: String?
    public let license: String?
    public let projectType: String?

    public var id: String { projectID }

    private enum CodingKeys: String, CodingKey {
        case slug, title, description, author, categories, versions, downloads, follows, license
        case projectID = "project_id"
        case iconURL = "icon_url"
        case dateModified = "date_modified"
        case latestVersion = "latest_version"
        case projectType = "project_type"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.projectID = try c.decode(String.self, forKey: .projectID)
        self.slug = try c.decodeIfPresent(String.self, forKey: .slug)
        self.title = try c.decode(String.self, forKey: .title)
        self.description = try c.decodeIfPresent(String.self, forKey: .description) ?? ""
        self.author = try c.decodeIfPresent(String.self, forKey: .author)
        self.categories = try c.decodeIfPresent([String].self, forKey: .categories) ?? []
        self.versions = try c.decodeIfPresent([String].self, forKey: .versions) ?? []
        self.downloads = try c.decodeIfPresent(Int.self, forKey: .downloads) ?? 0
        self.follows = try c.decodeIfPresent(Int.self, forKey: .follows) ?? 0
        self.iconURL = try c.decodeIfPresent(String.self, forKey: .iconURL)
        self.dateModified = try c.decodeIfPresent(String.self, forKey: .dateModified)
        self.latestVersion = try c.decodeIfPresent(String.self, forKey: .latestVersion)
        self.license = try c.decodeIfPresent(String.self, forKey: .license)
        self.projectType = try c.decodeIfPresent(String.self, forKey: .projectType)
    }
}

public struct ModrinthLicense: Decodable, Sendable, Equatable {
    public let id: String?
    public let name: String?
    public let url: String?

    public var displayName: String {
        if let name, !name.isEmpty { return name }
        return id ?? "未声明"
    }
}

public struct ModrinthProject: Decodable, Sendable, Equatable, Identifiable {
    public let id: String
    public let slug: String?
    public let title: String
    public let description: String
    public let body: String?
    public let iconURL: String?
    public let author: String?
    public let categories: [String]
    public let gameVersions: [String]
    public let loaders: [String]
    public let downloads: Int
    public let follows: Int
    public let license: ModrinthLicense?
    public let versions: [String]
    public let dateModified: String?
    public let projectType: String?

    private enum CodingKeys: String, CodingKey {
        case id, slug, title, description, body, author, categories, downloads, follows, license, versions
        case gameVersions = "game_versions"
        case loaders
        case projectType = "project_type"
        case iconURL = "icon_url"
        case dateModified = "updated"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try c.decode(String.self, forKey: .id)
        self.slug = try c.decodeIfPresent(String.self, forKey: .slug)
        self.title = try c.decode(String.self, forKey: .title)
        self.description = try c.decodeIfPresent(String.self, forKey: .description) ?? ""
        self.body = try c.decodeIfPresent(String.self, forKey: .body)
        self.iconURL = try c.decodeIfPresent(String.self, forKey: .iconURL)
        self.author = try c.decodeIfPresent(String.self, forKey: .author)
        self.categories = try c.decodeIfPresent([String].self, forKey: .categories) ?? []
        self.gameVersions = try c.decodeIfPresent([String].self, forKey: .gameVersions) ?? []
        self.loaders = try c.decodeIfPresent([String].self, forKey: .loaders) ?? []
        self.downloads = try c.decodeIfPresent(Int.self, forKey: .downloads) ?? 0
        self.follows = try c.decodeIfPresent(Int.self, forKey: .follows) ?? 0
        self.license = try c.decodeIfPresent(ModrinthLicense.self, forKey: .license)
        self.versions = try c.decodeIfPresent([String].self, forKey: .versions) ?? []
        self.dateModified = try c.decodeIfPresent(String.self, forKey: .dateModified)
        self.projectType = try c.decodeIfPresent(String.self, forKey: .projectType)
    }
}

public enum ModrinthDependencyType: String, Sendable, Codable {
    case required
    case optional
    case incompatible
    case embedded
    case unknown

    public init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = ModrinthDependencyType(rawValue: raw) ?? .unknown
    }
}

public struct ModrinthDependency: Decodable, Sendable, Equatable {
    public let versionID: String?
    public let projectID: String?
    public let fileName: String?
    public let type: ModrinthDependencyType

    private enum CodingKeys: String, CodingKey {
        case versionID = "version_id"
        case projectID = "project_id"
        case fileName = "file_name"
        case type = "dependency_type"
    }

    public init(versionID: String? = nil, projectID: String? = nil, fileName: String? = nil, type: ModrinthDependencyType) {
        self.versionID = versionID
        self.projectID = projectID
        self.fileName = fileName
        self.type = type
    }
}

public struct ModrinthFileHashes: Decodable, Sendable, Equatable {
    public let sha1: String?
    public let sha512: String?

    public init(sha1: String? = nil, sha512: String? = nil) {
        self.sha1 = sha1
        self.sha512 = sha512
    }
}

public struct ModrinthFile: Decodable, Sendable, Equatable {
    public let hashes: ModrinthFileHashes
    public let url: String
    public let filename: String
    public let primary: Bool
    public let size: Int
    public let fileType: String?

    private enum CodingKeys: String, CodingKey {
        case hashes, url, filename, primary, size
        case fileType = "file_type"
    }

    public var isJar: Bool { filename.lowercased().hasSuffix(".jar") }
    public var downloadURL: URL? { URL(string: url) }
}

public enum ModrinthVersionType: String, Decodable, Sendable {
    case release, beta, alpha, unknown

    public init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = ModrinthVersionType(rawValue: raw) ?? .unknown
    }
}

public struct ModrinthVersion: Decodable, Sendable, Equatable, Identifiable {
    public let id: String
    public let projectID: String
    public let name: String
    public let versionNumber: String
    public let changelog: String?
    public let dependencies: [ModrinthDependency]
    public let gameVersions: [String]
    public let versionType: ModrinthVersionType
    public let loaders: [String]
    public let datePublished: String
    public let downloads: Int
    public let files: [ModrinthFile]
    public let status: String?

    private enum CodingKeys: String, CodingKey {
        case id, name, changelog, dependencies, loaders, downloads, files, status
        case gameVersions = "game_versions"
        case versionType = "version_type"
        case datePublished = "date_published"
        case projectID = "project_id"
        case versionNumber = "version_number"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try c.decode(String.self, forKey: .id)
        self.projectID = try c.decode(String.self, forKey: .projectID)
        self.name = try c.decodeIfPresent(String.self, forKey: .name) ?? ""
        self.versionNumber = try c.decodeIfPresent(String.self, forKey: .versionNumber) ?? ""
        self.changelog = try c.decodeIfPresent(String.self, forKey: .changelog)
        self.dependencies = try c.decodeIfPresent([ModrinthDependency].self, forKey: .dependencies) ?? []
        self.gameVersions = try c.decodeIfPresent([String].self, forKey: .gameVersions) ?? []
        self.versionType = try c.decodeIfPresent(ModrinthVersionType.self, forKey: .versionType) ?? .unknown
        self.loaders = try c.decodeIfPresent([String].self, forKey: .loaders) ?? []
        self.datePublished = try c.decodeIfPresent(String.self, forKey: .datePublished) ?? ""
        self.downloads = try c.decodeIfPresent(Int.self, forKey: .downloads) ?? 0
        self.files = try c.decodeIfPresent([ModrinthFile].self, forKey: .files) ?? []
        self.status = try c.decodeIfPresent(String.self, forKey: .status)
    }

    /// Only listed/downloadable versions whose declared game/loader compatibility contains the
    /// instance context are considered.
    public func isCompatible(gameVersion: String, loader: String) -> Bool {
        let listed = status.map { $0 == "listed" } ?? true
        return listed
            && gameVersions.contains(gameVersion)
            && loaders.map { $0.lowercased() }.contains(loader.lowercased())
    }

    public var primaryJar: ModrinthFile? {
        let jars = files.filter(\.isJar)
        return jars.first(where: \.primary) ?? jars.first
    }
}

public struct ModrinthCategory: Decodable, Sendable, Equatable, Identifiable {
    public let name: String
    public let projectType: String?
    public let header: String?
    public let icon: String?

    public var id: String { "\(projectType ?? "all"):\(name)" }

    private enum CodingKeys: String, CodingKey {
        case name, header, icon
        case projectType = "project_type"
    }
}
