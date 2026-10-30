import Foundation

public struct ModpackFileRecord: Codable, Sendable, Equatable {
    public let path: String
    public let sha256: String
    public let sha1: String?
    public let sha512: String?
    public let source: String
    public var userModified: Bool

    public init(path: String, sha256: String, sha1: String? = nil, sha512: String? = nil, source: String, userModified: Bool = false) {
        self.path = path
        self.sha256 = sha256
        self.sha1 = sha1
        self.sha512 = sha512
        self.source = source
        self.userModified = userModified
    }
}

public struct ModpackRecord: Codable, Sendable, Equatable {
    public var schemaVersion: Int
    public var projectID: String?
    public var versionID: String
    public var minecraftVersion: String
    public var loaderKind: String
    public var loaderVersion: String?
    public var archiveSHA256: String
    public var installedAt: Date
    public var files: [ModpackFileRecord]

    public init(
        schemaVersion: Int = 1,
        projectID: String? = nil,
        versionID: String,
        minecraftVersion: String,
        loaderKind: String,
        loaderVersion: String?,
        archiveSHA256: String,
        files: [ModpackFileRecord]
    ) {
        self.schemaVersion = schemaVersion
        self.projectID = projectID
        self.versionID = versionID
        self.minecraftVersion = minecraftVersion
        self.loaderKind = loaderKind
        self.loaderVersion = loaderVersion
        self.archiveSHA256 = archiveSHA256
        self.installedAt = Date()
        self.files = files
    }
}

public struct ModpackFileChange: Sendable, Equatable {
    public enum Kind: String, Sendable { case added, upgraded, removed }
    public let kind: Kind
    public let path: String
    public let oldHash: String?
    public let newHash: String?
    public let userModified: Bool
}

public struct ModpackUpdatePreview: Sendable, Equatable {
    public let instanceID: String
    public let currentVersionID: String
    public let targetVersionID: String
    public let targetVersionNumber: String?
    public let requiresMinecraftChange: Bool
    public let requiresLoaderChange: Bool
    public let changes: [ModpackFileChange]
    public let preservedUserFiles: [String]
}

/// Lifecycle metadata for imported Modrinth packs. A project id is never guessed from a pack
/// name; it must be explicitly linked or supplied by a trusted Modrinth download.
public struct ModpackLifecycleManager: Sendable {
    public let layout: GameDataLayout
    public let client: ModrinthClient

    public init(layout: GameDataLayout, client: ModrinthClient = ModrinthClient()) {
        self.layout = layout
        self.client = client
    }

    public func record(instanceID: String) throws -> ModpackRecord {
        let instance = try InstanceRepository(layout: layout).load(id: instanceID)
        let url = instance.directory.appendingPathComponent("modpack.json", isDirectory: false)
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw LauncherError(.missingDependency, "This instance has no managed pack source")
        }
        return try JSONDecoder.iso8601.decode(ModpackRecord.self, from: Data(contentsOf: url))
    }

    public func linkProject(instanceID: String, projectID: String) throws {
        var value = try record(instanceID: instanceID)
        guard !projectID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw LauncherError(.usageError, "Project id must not be empty")
        }
        value.projectID = projectID
        try write(value, instanceID: instanceID)
    }

    public func save(_ value: ModpackRecord, instanceID: String) throws {
        try write(value, instanceID: instanceID)
    }

    public func checkUpdate(instanceID: String) async throws -> ModrinthVersion? {
        let value = try record(instanceID: instanceID)
        guard let projectID = value.projectID else {
            throw LauncherError(.missingDependency, "Pack source is unknown; refusing to guess a Modrinth project")
        }
        let versions = try await client.versions(
            projectID: projectID,
            gameVersion: value.minecraftVersion,
            loader: value.loaderKind
        )
        guard let current = versions.first(where: { $0.id == value.versionID }) else { return nil }
        return ModrinthUpdatePolicy.selectUpdate(current: current, from: versions, file: { $0.files.first })
    }

    public func preview(instanceID: String, target: ModrinthVersion) throws -> ModpackUpdatePreview {
        let current = try record(instanceID: instanceID)
        let newFiles = target.files.filter { $0.primary }
        var changes: [ModpackFileChange] = []
        var preserved: [String] = []
        let old = Dictionary(uniqueKeysWithValues: current.files.map { ($0.path, $0) })
        let new = Dictionary(uniqueKeysWithValues: newFiles.map { ($0.filename, $0) })
        for (path, file) in new {
            if let existing = old[path] {
                if (existing.sha512 != nil && existing.sha512 == file.hashes.sha512)
                    || (existing.sha1 != nil && existing.sha1 == file.hashes.sha1) {
                    continue
                }
                changes.append(ModpackFileChange(kind: .upgraded, path: path, oldHash: existing.sha256, newHash: file.hashes.sha512 ?? file.hashes.sha1, userModified: existing.userModified))
            } else {
                changes.append(ModpackFileChange(kind: .added, path: path, oldHash: nil, newHash: file.hashes.sha512 ?? file.hashes.sha1, userModified: false))
            }
        }
        for (path, file) in old where new[path] == nil {
            changes.append(ModpackFileChange(kind: .removed, path: path, oldHash: file.sha256, newHash: nil, userModified: file.userModified))
        }
        let loader = target.loaders.contains(current.loaderKind) ? current.loaderKind : (target.loaders.first ?? current.loaderKind)
        preserved = current.files.filter(\.userModified).map(\.path)
        return ModpackUpdatePreview(
            instanceID: instanceID,
            currentVersionID: current.versionID,
            targetVersionID: target.id,
            targetVersionNumber: target.versionNumber,
            requiresMinecraftChange: !target.gameVersions.contains(current.minecraftVersion),
            requiresLoaderChange: loader != current.loaderKind,
            changes: changes.sorted { $0.path < $1.path },
            preservedUserFiles: preserved
        )
    }

    private func write(_ value: ModpackRecord, instanceID: String) throws {
        let instance = try InstanceRepository(layout: layout).load(id: instanceID)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(value).write(to: instance.directory.appendingPathComponent("modpack.json"), options: [.atomic])
    }
}

private extension JSONDecoder {
    static var iso8601: JSONDecoder {
        let value = JSONDecoder()
        value.dateDecodingStrategy = .iso8601
        return value
    }
}
