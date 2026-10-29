import Foundation

/// Public, validated view of a Modrinth `.mrpack` (format version 1).
public struct MrpackPackage: Sendable, Equatable {
    public let archiveURL: URL
    public let archiveSHA256: String
    public let name: String
    public let versionID: String
    public let summary: String?
    public let minecraftVersion: String
    public let loader: InstallLoaderChoice
    public let files: [MrpackFile]
    public let overrides: [MrpackOverride]
    public let skippedClientUnsupported: Int
    public let extractionRoot: URL

    public var totalDownloadBytes: Int { files.reduce(0) { $0 + $1.fileSize } }
    public var totalFileCount: Int { files.count + overrides.count }

    public var optionalFiles: [MrpackFile] { files.filter(\.isOptional) }

    /// Required client files plus only the explicitly selected optional files. Optional files
    /// are never installed implicitly: their authors intend them to be an opt-in.
    public func selectedFiles(includingOptionalPaths paths: Set<String>) -> [MrpackFile] {
        files.filter { !$0.isOptional || paths.contains($0.relativePath) }
    }

    public func selectedDownloadBytes(includingOptionalPaths paths: Set<String>) -> Int {
        selectedFiles(includingOptionalPaths: paths).reduce(0) { $0 + $1.fileSize }
    }
}

public struct MrpackFile: Sendable, Equatable {
    public let relativePath: String
    public let sha1: String?
    public let sha512: String?
    public let downloadURL: URL
    public let fileSize: Int
    public let clientEnvironment: String

    public var isOptional: Bool { clientEnvironment == "optional" }

    public init(
        relativePath: String,
        sha1: String?,
        sha512: String?,
        downloadURL: URL,
        fileSize: Int,
        clientEnvironment: String
    ) {
        self.relativePath = relativePath
        self.sha1 = sha1
        self.sha512 = sha512
        self.downloadURL = downloadURL
        self.fileSize = fileSize
        self.clientEnvironment = clientEnvironment
    }
}

public struct MrpackOverride: Sendable, Equatable {
    /// Path relative to the Minecraft instance game directory.
    public let relativePath: String
    /// Extracted file under `MrpackPackage.extractionRoot`.
    public let sourceURL: URL

    public init(relativePath: String, sourceURL: URL) {
        self.relativePath = relativePath
        self.sourceURL = sourceURL
    }
}

/// Raw format-1 index. Unknown keys are ignored, but known security-relevant fields are strict.
struct MrpackIndex: Decodable {
    struct File: Decodable {
        struct Hashes: Decodable {
            let sha1: String?
            let sha512: String?
        }
        struct Environment: Decodable {
            let client: String?
            let server: String?
        }
        let path: String
        let hashes: Hashes?
        let downloads: [String]
        let fileSize: Int?
        let env: Environment?
    }

    let formatVersion: Int
    let game: String
    let versionId: String?
    let name: String
    let summary: String?
    let files: [File]
    let dependencies: [String: String]

    private enum CodingKeys: String, CodingKey {
        case formatVersion, game, versionId, name, summary, files, dependencies
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        formatVersion = try c.decode(Int.self, forKey: .formatVersion)
        game = try c.decode(String.self, forKey: .game)
        versionId = try c.decodeIfPresent(String.self, forKey: .versionId)
        name = try c.decode(String.self, forKey: .name)
        summary = try c.decodeIfPresent(String.self, forKey: .summary)
        files = try c.decodeIfPresent([File].self, forKey: .files) ?? []
        dependencies = try c.decodeIfPresent([String: String].self, forKey: .dependencies) ?? [:]
    }
}
