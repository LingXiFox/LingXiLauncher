import Foundation

/// `version_manifest_v2.json`.
public struct VersionManifest: Decodable, Sendable, Equatable {
    public struct Latest: Decodable, Sendable, Equatable {
        public let release: String
        public let snapshot: String

        public init(release: String, snapshot: String) {
            self.release = release
            self.snapshot = snapshot
        }
    }

    public struct Entry: Decodable, Sendable, Equatable {
        public enum Kind: String, Decodable, Sendable, Equatable {
            case release
            case snapshot
            case oldBeta = "old_beta"
            case oldAlpha = "old_alpha"
        }

        public let id: String
        public let type: Kind
        public let urlString: String
        public let sha1: String?
        public let releaseTime: String?
        public let time: String?
        public let complianceLevel: Int?

        public init(
            id: String,
            type: Kind,
            urlString: String,
            sha1: String? = nil,
            releaseTime: String? = nil,
            time: String? = nil,
            complianceLevel: Int? = nil
        ) {
            self.id = id
            self.type = type
            self.urlString = urlString
            self.sha1 = sha1
            self.releaseTime = releaseTime
            self.time = time
            self.complianceLevel = complianceLevel
        }

        public var url: URL? {
            URL(string: urlString)
        }

        private enum CodingKeys: String, CodingKey {
            case id, type, url, sha1, releaseTime, time, complianceLevel
        }

        public init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            self.id = try container.decode(String.self, forKey: .id)
            self.type = try container.decode(Kind.self, forKey: .type)
            self.urlString = try container.decode(String.self, forKey: .url)
            self.sha1 = try container.decodeIfPresent(String.self, forKey: .sha1)
            self.releaseTime = try container.decodeIfPresent(String.self, forKey: .releaseTime)
            self.time = try container.decodeIfPresent(String.self, forKey: .time)
            self.complianceLevel = try container.decodeIfPresent(Int.self, forKey: .complianceLevel)
        }
    }

    public let latest: Latest
    public let versions: [Entry]

    public init(latest: Latest, versions: [Entry]) {
        self.latest = latest
        self.versions = versions
    }

    public func entry(for id: String) -> Entry? {
        versions.first { $0.id == id }
    }

    public func latestRelease() -> Entry? {
        entry(for: latest.release)
    }

    public static func decode(from data: Data, context: String = "version manifest") throws -> VersionManifest {
        try data.decodeLauncherJSON(VersionManifest.self, context: context)
    }
}
