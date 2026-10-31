import Foundation
#if canImport(Darwin)
#endif

public struct ResourcePackRecord: Codable, Sendable, Equatable, Identifiable {
    public let fileName: String
    public let projectID: String?
    public let versionID: String?
    public let versionNumber: String?
    public let versionType: String?
    public let title: String
    public let source: String
    public let sha1: String?
    public let sha512: String?
    public let byteCount: Int
    public let installedAt: Date
    public var enabled: Bool

    public var id: String { fileName }

    public init(
        fileName: String,
        projectID: String? = nil,
        versionID: String? = nil,
        versionNumber: String? = nil,
        versionType: String? = nil,
        title: String,
        source: String,
        sha1: String? = nil,
        sha512: String? = nil,
        byteCount: Int,
        installedAt: Date = Date(),
        enabled: Bool = false
    ) {
        self.fileName = fileName
        self.projectID = projectID
        self.versionID = versionID
        self.versionNumber = versionNumber
        self.versionType = versionType
        self.title = title
        self.source = source
        self.sha1 = sha1
        self.sha512 = sha512
        self.byteCount = byteCount
        self.installedAt = installedAt
        self.enabled = enabled
    }

    private enum CodingKeys: String, CodingKey {
        case fileName, projectID, versionID, versionNumber, versionType, title, source
        case sha1, sha512, byteCount, installedAt, enabled
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        fileName = try c.decode(String.self, forKey: .fileName)
        projectID = try c.decodeIfPresent(String.self, forKey: .projectID)
        versionID = try c.decodeIfPresent(String.self, forKey: .versionID)
        versionNumber = try c.decodeIfPresent(String.self, forKey: .versionNumber)
        versionType = try c.decodeIfPresent(String.self, forKey: .versionType)
        title = try c.decode(String.self, forKey: .title)
        source = try c.decodeIfPresent(String.self, forKey: .source) ?? "local"
        sha1 = try c.decodeIfPresent(String.self, forKey: .sha1)
        sha512 = try c.decodeIfPresent(String.self, forKey: .sha512)
        byteCount = try c.decodeIfPresent(Int.self, forKey: .byteCount) ?? 0
        installedAt = try c.decodeIfPresent(Date.self, forKey: .installedAt) ?? Date()
        enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? false
    }
}

public struct ResourcePackUpdate: Sendable, Equatable {
    public let current: ResourcePackRecord
    public let version: ModrinthVersion
}

private final class ResourcePackProcessLock {
    private let token: any FileLockToken

    init(layout: GameDataLayout, instanceID: String) throws {
        let directory = layout.dataRoot.appendingPathComponent("locks", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let safe = instanceID.replacingOccurrences(of: "/", with: "_")
        token = try PlatformRuntime.fileLock.acquireExclusive(
            at: directory.appendingPathComponent("resourcepack-\(safe).lock", isDirectory: false)
        )
    }

    deinit { token.release() }
}

public struct ResourcePackManager: Sendable {
    public let layout: GameDataLayout
    public let client: ModrinthClient
    public let transport: any DownloadTransport
    private let runtimeRegistry: InstanceRuntimeChecking
    private var fm: FileManager { FileManager.default }

    public init(
        layout: GameDataLayout,
        client: ModrinthClient = ModrinthClient(),
        transport: any DownloadTransport = URLSessionTransport(),
        runtimeRegistry: InstanceRuntimeChecking? = nil
    ) {
        self.layout = layout
        self.client = client
        self.transport = transport
        self.runtimeRegistry = runtimeRegistry ?? InstanceRuntimeRegistry(layout: layout)
    }

    public func search(
        query: String,
        gameVersion: String,
        sort: ModrinthSort = .relevance,
        offset: Int = 0,
        limit: Int = 20
    ) async throws -> ModrinthSearchResult {
        try await client.search(ModrinthSearchQuery(
            query: query,
            gameVersion: gameVersion,
            loader: "",
            sort: sort,
            offset: offset,
            limit: limit,
            projectType: "resourcepack",
            includeLoaderFacet: false
        ))
    }

    public func project(idOrSlug: String) async throws -> ModrinthProject {
        try await client.project(idOrSlug: idOrSlug)
    }

    public func compatibleVersions(instanceID: String, projectID: String) async throws -> [ModrinthVersion] {
        let instance = try loadInstance(instanceID)
        let version = try gameVersion(for: instance)
        return try await client.versions(projectID: projectID, gameVersion: version, loader: nil)
            .filter { $0.primaryZip != nil && $0.gameVersions.contains(version) }
    }

    public func list(instanceID: String) throws -> [ResourcePackRecord] {
        let instance = try loadInstance(instanceID)
        let url = metadataURL(instance)
        guard fm.fileExists(atPath: url.path) else { return [] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let records = try decoder.decode([ResourcePackRecord].self, from: Data(contentsOf: url))
        let enabled = try enabledNames(instance: instance)
        return records.map { record in
            var copy = record
            if let enabled { copy.enabled = enabled.contains("file/\(record.fileName)") }
            return copy
        }.sorted { $0.installedAt > $1.installedAt }
    }

    @discardableResult
    public func install(
        instanceID: String,
        projectID: String,
        versionID: String,
        allowReplace: Bool = false
    ) async throws -> ResourcePackRecord {
        let instance = try loadInstance(instanceID)
        try ensureNotRunning(instanceID)
        let project = try await client.project(idOrSlug: projectID)
        let version = try await client.version(id: versionID)
        let game = try gameVersion(for: instance)
        guard version.projectID == project.id,
              version.gameVersions.contains(game),
              version.status.map({ $0 == "listed" }) ?? true,
              let file = version.primaryZip,
              let url = file.downloadURL else {
            throw LauncherError(.usageError, "Resource pack version is not compatible with this instance")
        }
        try validateRemoteURL(url)
        let record = ResourcePackRecord(
            fileName: try safeFileName(file.filename),
            projectID: project.id,
            versionID: version.id,
            versionNumber: version.versionNumber,
            versionType: version.versionType.rawValue,
            title: project.title,
            source: "modrinth",
            sha1: file.hashes.sha1,
            sha512: file.hashes.sha512,
            byteCount: file.size
        )
        let temporary = try temporaryDirectory()
        defer { try? fm.removeItem(at: temporary) }
        let staged = temporary.appendingPathComponent(record.fileName)
        do {
            try await transport.download(from: url, to: staged)
        } catch {
            throw LauncherError(.downloadFailed, "Resource pack download failed: \(error.localizedDescription)")
        }
        let size = (try? staged.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        guard size == file.size else {
            throw LauncherError(.hashMismatch, "Resource pack size does not match Modrinth metadata")
        }
        if let expected = file.hashes.sha512, !expected.isEmpty {
            let actual = try SHA512Digest.hexDigest(ofFileAt: staged)
            guard actual.caseInsensitiveCompare(expected) == .orderedSame else {
                throw LauncherError(.hashMismatch, "Resource pack SHA-512 does not match Modrinth metadata")
            }
        } else if let expected = file.hashes.sha1, !expected.isEmpty {
            let actual = try SHA1.hexDigest(ofFileAt: staged)
            guard actual.caseInsensitiveCompare(expected) == .orderedSame else {
                throw LauncherError(.hashMismatch, "Resource pack SHA-1 does not match Modrinth metadata")
            }
        } else {
            throw LauncherError(.invalidMetadata, "Modrinth resource pack has no verifiable hash")
        }
        try ResourcePackArchiveValidator.validate(archive: staged)
        return try commit(record: record, staged: staged, instance: instance, allowReplace: allowReplace)
    }

    @discardableResult
    public func importLocal(instanceID: String, archiveURL: URL) throws -> ResourcePackRecord {
        let instance = try loadInstance(instanceID)
        try ensureNotRunning(instanceID)
        let values = try archiveURL.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
        guard values.isRegularFile == true, values.isSymbolicLink != true else {
            throw LauncherError(.ioFailure, "Resource pack must be a regular ZIP file")
        }
        let fileName = try safeFileName(archiveURL.lastPathComponent)
        let temporary = try temporaryDirectory()
        defer { try? fm.removeItem(at: temporary) }
        let staged = temporary.appendingPathComponent(fileName)
        try fm.copyItem(at: archiveURL, to: staged)
        try ResourcePackArchiveValidator.validate(archive: staged)
        let record = ResourcePackRecord(
            fileName: fileName,
            title: archiveURL.deletingPathExtension().lastPathComponent,
            source: "local",
            sha1: try SHA1.hexDigest(ofFileAt: staged),
            sha512: try SHA512Digest.hexDigest(ofFileAt: staged),
            byteCount: (try? staged.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        )
        return try commit(record: record, staged: staged, instance: instance, allowReplace: false)
    }

    public func delete(instanceID: String, fileName: String) throws {
        let lock = try ResourcePackProcessLock(layout: layout, instanceID: instanceID)
        _ = lock
        let instance = try loadInstance(instanceID)
        try ensureNotRunning(instanceID)
        let component = try safeFileName(fileName)
        var records = try list(instanceID: instanceID)
        guard let index = records.firstIndex(where: { $0.fileName == component }) else {
            throw LauncherError(.missingDependency, "Resource pack '\(component)' is not managed by LingXi")
        }
        let target = instance.gameDirectory.appendingPathComponent("resourcepacks", isDirectory: true)
            .appendingPathComponent(component, isDirectory: false)
        let options = instance.gameDirectory.appendingPathComponent("options.txt", isDirectory: false)
        let oldOptions = try? Data(contentsOf: options)
        let backup = target.appendingPathExtension("lingxi-delete-\(UUID().uuidString)")
        let hadTarget = fm.fileExists(atPath: target.path)
        if hadTarget { try fm.moveItem(at: target, to: backup) }
        records.remove(at: index)
        do {
            if let oldOptions, try gameVersion(for: instance).isEmpty == false,
               ResourcePackOptions.supportedVersions.contains(try gameVersion(for: instance)) {
                let updated = try ResourcePackOptions.set(data: oldOptions, fileName: component, enabled: false)
                try updated.write(to: options, options: [.atomic])
            }
            try writeMetadata(records, instance: instance)
            if hadTarget { try? fm.removeItem(at: backup) }
        } catch {
            if hadTarget, fm.fileExists(atPath: backup.path) {
                try? fm.removeItem(at: target)
                try? fm.moveItem(at: backup, to: target)
            }
            if let oldOptions { try? oldOptions.write(to: options, options: [.atomic]) }
            throw (error as? LauncherError) ?? LauncherError(.ioFailure, "Cannot delete resource pack: \(error.localizedDescription)")
        }
    }

    public func setUpdates(instanceID: String) async throws -> [ResourcePackUpdate] {
        let instance = try loadInstance(instanceID)
        let game = try gameVersion(for: instance)
        let records = try list(instanceID: instanceID)
            .filter { $0.source == "modrinth" && $0.projectID != nil && $0.versionID != nil }
        var result: [ResourcePackUpdate] = []
        for record in records {
            guard let projectID = record.projectID, let currentID = record.versionID else { continue }
            let versions = try await client.versions(projectID: projectID, gameVersion: game, loader: nil)
            guard let current = versions.first(where: { $0.id == currentID }),
                  let newer = ModrinthUpdatePolicy.selectUpdate(current: current, from: versions, file: { $0.primaryZip })
            else { continue }
            result.append(ResourcePackUpdate(current: record, version: newer))
        }
        return result
    }

    public func canEnableLauncherSide(instanceID: String) throws -> Bool {
        let instance = try loadInstance(instanceID)
        return ResourcePackOptions.supportedVersions.contains(try gameVersion(for: instance))
    }

    public func setEnabled(instanceID: String, fileName: String, enabled: Bool) throws {
        let lock = try ResourcePackProcessLock(layout: layout, instanceID: instanceID)
        _ = lock
        let instance = try loadInstance(instanceID)
        try ensureNotRunning(instanceID)
        let game = try gameVersion(for: instance)
        guard ResourcePackOptions.supportedVersions.contains(game) else {
            throw LauncherError(
                .unsupportedVersion,
                "This Minecraft version does not have a verified launcher-side resource pack format",
                suggestion: "Enable the resource pack inside Minecraft's Options → Resource Packs screen."
            )
        }
        let component = try safeFileName(fileName)
        var records = try list(instanceID: instanceID)
        guard let index = records.firstIndex(where: { $0.fileName == component }) else {
            throw LauncherError(.missingDependency, "Resource pack '\(component)' is not managed by LingXi")
        }
        let options = instance.gameDirectory.appendingPathComponent("options.txt", isDirectory: false)
        let original = try Data(contentsOf: options)
        let updated = try ResourcePackOptions.set(data: original, fileName: component, enabled: enabled)
        let backup = options.appendingPathExtension("lingxi-backup")
        try original.write(to: backup, options: [.atomic])
        do {
            try updated.write(to: options, options: [.atomic])
            guard try ResourcePackOptions.isEnabled(data: Data(contentsOf: options), fileName: component) == enabled else {
                throw LauncherError(.ioFailure, "Resource pack options verification failed")
            }
            records[index].enabled = enabled
            try writeMetadata(records, instance: instance)
            try? fm.removeItem(at: backup)
        } catch {
            try? original.write(to: options, options: [.atomic])
            throw (error as? LauncherError) ?? LauncherError(.ioFailure, "Cannot update options.txt: \(error.localizedDescription)")
        }
    }

    @discardableResult
    public func update(
        instanceID: String,
        projectID: String,
        versionID: String
    ) async throws -> ResourcePackRecord {
        let instance = try loadInstance(instanceID)
        try ensureNotRunning(instanceID)
        let records = try list(instanceID: instanceID)
        guard let existing = records.first(where: { $0.projectID == projectID }) else {
            throw LauncherError(.missingDependency, "No managed resource pack from this project is installed")
        }
        guard versionID != existing.versionID else { return existing }
        let version = try await client.version(id: versionID)
        let game = try gameVersion(for: instance)
        guard version.projectID == projectID,
              version.gameVersions.contains(game),
              version.status.map({ $0 == "listed" }) ?? true,
              let file = version.primaryZip,
              let url = file.downloadURL else {
            throw LauncherError(.usageError, "Resource pack version is not compatible with this instance")
        }
        try validateRemoteURL(url)
        let record = ResourcePackRecord(
            fileName: try safeFileName(file.filename),
            projectID: projectID,
            versionID: version.id,
            versionNumber: version.versionNumber,
            versionType: version.versionType.rawValue,
            title: existing.title,
            source: "modrinth",
            sha1: file.hashes.sha1,
            sha512: file.hashes.sha512,
            byteCount: file.size,
            enabled: existing.enabled
        )
        let temporary = try temporaryDirectory()
        defer { try? fm.removeItem(at: temporary) }
        let staged = temporary.appendingPathComponent(record.fileName)
        try await transport.download(from: url, to: staged)
        let size = (try? staged.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        guard size == file.size else {
            throw LauncherError(.hashMismatch, "Resource pack size does not match Modrinth metadata")
        }
        if let expected = file.hashes.sha512, !expected.isEmpty {
            guard try SHA512Digest.hexDigest(ofFileAt: staged).caseInsensitiveCompare(expected) == .orderedSame else {
                throw LauncherError(.hashMismatch, "Resource pack SHA-512 does not match Modrinth metadata")
            }
        } else if let expected = file.hashes.sha1, !expected.isEmpty {
            guard try SHA1.hexDigest(ofFileAt: staged).caseInsensitiveCompare(expected) == .orderedSame else {
                throw LauncherError(.hashMismatch, "Resource pack SHA-1 does not match Modrinth metadata")
            }
        } else {
            throw LauncherError(.invalidMetadata, "Modrinth resource pack has no verifiable hash")
        }
        try ResourcePackArchiveValidator.validate(archive: staged)
        return try commitReplacement(record: record, staged: staged, replacing: existing, instance: instance)
    }

    private func commitReplacement(
        record: ResourcePackRecord,
        staged: URL,
        replacing old: ResourcePackRecord,
        instance: Instance
    ) throws -> ResourcePackRecord {
        let lock = try ResourcePackProcessLock(layout: layout, instanceID: instance.id)
        _ = lock
        try ensureNotRunning(instance.id)
        let directory = instance.gameDirectory.appendingPathComponent("resourcepacks", isDirectory: true)
        try fm.createDirectory(at: directory, withIntermediateDirectories: true)
        let oldTarget = directory.appendingPathComponent(old.fileName, isDirectory: false)
        let newTarget = directory.appendingPathComponent(record.fileName, isDirectory: false)
        var records = try list(instanceID: instance.id)
        guard records.contains(where: { $0.fileName == old.fileName }) else {
            throw LauncherError(.missingDependency, "Resource pack ownership changed during update")
        }
        if newTarget != oldTarget, fm.fileExists(atPath: newTarget.path) {
            throw LauncherError(.usageError, "The new resource pack file name is already in use")
        }
        let options = instance.gameDirectory.appendingPathComponent("options.txt", isDirectory: false)
        let oldOptions = try? Data(contentsOf: options)
        let oldMetadata = try Data(contentsOf: metadataURL(instance))
        let backup = directory.appendingPathComponent(".lingxi-update-\(UUID().uuidString)", isDirectory: false)
        let hadOldTarget = fm.fileExists(atPath: oldTarget.path)
        if hadOldTarget { try fm.copyItem(at: oldTarget, to: backup) }
        do {
            if hadOldTarget { try fm.removeItem(at: oldTarget) }
            if fm.fileExists(atPath: newTarget.path) { try fm.removeItem(at: newTarget) }
            try fm.moveItem(at: staged, to: newTarget)
            records.removeAll { $0.fileName == old.fileName }
            var updated = record
            updated.enabled = old.enabled
            records.append(updated)
            if let oldOptions,
               ResourcePackOptions.supportedVersions.contains(try gameVersion(for: instance)) {
                var migrated = try ResourcePackOptions.set(data: oldOptions, fileName: old.fileName, enabled: false)
                migrated = try ResourcePackOptions.set(data: migrated, fileName: record.fileName, enabled: old.enabled)
                try migrated.write(to: options, options: [.atomic])
                guard try ResourcePackOptions.isEnabled(data: Data(contentsOf: options), fileName: record.fileName) == old.enabled else {
                    throw LauncherError(.ioFailure, "Resource pack options migration failed verification")
                }
            }
            try writeMetadata(records, instance: instance)
            try? fm.removeItem(at: backup)
            return updated
        } catch {
            if fm.fileExists(atPath: newTarget.path) { try? fm.removeItem(at: newTarget) }
            if hadOldTarget, fm.fileExists(atPath: backup.path) { try? fm.moveItem(at: backup, to: oldTarget) }
            try? oldMetadata.write(to: metadataURL(instance), options: [.atomic])
            if let oldOptions { try? oldOptions.write(to: options, options: [.atomic]) }
            throw (error as? LauncherError) ?? LauncherError(.ioFailure, "Cannot update resource pack: \(error.localizedDescription)")
        }
    }

    private func commit(
        record: ResourcePackRecord,
        staged: URL,
        instance: Instance,
        allowReplace: Bool
    ) throws -> ResourcePackRecord {
        let lock = try ResourcePackProcessLock(layout: layout, instanceID: instance.id)
        _ = lock
        try ensureNotRunning(instance.id)
        let directory = instance.gameDirectory.appendingPathComponent("resourcepacks", isDirectory: true)
        try fm.createDirectory(at: directory, withIntermediateDirectories: true)
        let target = directory.appendingPathComponent(record.fileName, isDirectory: false)
        var records = try list(instanceID: instance.id)
        let existing = records.first(where: { $0.fileName == record.fileName })
        if fm.fileExists(atPath: target.path), existing == nil {
            throw LauncherError(.usageError, "A resource pack with this file name already exists and is not managed by LingXi")
        }
        if existing != nil, !allowReplace {
            throw LauncherError(.usageError, "Resource pack is already installed")
        }
        let backup = staged.appendingPathExtension("old")
        let hadTarget = fm.fileExists(atPath: target.path)
        let oldRecords = records
        if hadTarget { try fm.copyItem(at: target, to: backup) }
        do {
            if hadTarget { try fm.removeItem(at: target) }
            try fm.moveItem(at: staged, to: target)
            if let index = records.firstIndex(where: { $0.fileName == record.fileName }) {
                records[index] = record
            } else {
                records.append(record)
            }
            try writeMetadata(records, instance: instance)
            try? fm.removeItem(at: backup)
            return record
        } catch {
            if hadTarget, fm.fileExists(atPath: backup.path) {
                try? fm.removeItem(at: target)
                try? fm.moveItem(at: backup, to: target)
            }
            try? writeMetadata(oldRecords, instance: instance)
            throw (error as? LauncherError) ?? LauncherError(.ioFailure, "Cannot commit resource pack: \(error.localizedDescription)")
        }
    }

    private func loadInstance(_ id: String) throws -> Instance {
        try InstanceRepository(layout: layout).load(id: id)
    }

    private func gameVersion(for instance: Instance) throws -> String {
        guard let versionID = instance.manifest.versionID else {
            throw LauncherError(.missingDependency, "Instance has no Minecraft version")
        }
        let version = try VersionResolver().resolve(versionID: versionID, from: layout.gameRoot)
        return version.inheritsFrom ?? version.id
    }

    private func metadataURL(_ instance: Instance) -> URL {
        instance.directory.appendingPathComponent("resourcepacks.json", isDirectory: false)
    }

    private func writeMetadata(_ records: [ResourcePackRecord], instance: Instance) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(records).write(to: metadataURL(instance), options: [.atomic])
    }

    private func enabledNames(instance: Instance) throws -> Set<String>? {
        let options = instance.gameDirectory.appendingPathComponent("options.txt", isDirectory: false)
        guard fm.fileExists(atPath: options.path) else { return [] }
        guard ResourcePackOptions.supportedVersions.contains(try gameVersion(for: instance)) else { return nil }
        return try ResourcePackOptions.enabledNames(data: Data(contentsOf: options))
    }

    private func ensureNotRunning(_ instanceID: String) throws {
        guard !runtimeRegistry.isRunning(instanceID: instanceID) else {
            throw LauncherError(.launchFailed, "Cannot modify resource packs while the game is running")
        }
    }

    private func safeFileName(_ raw: String) throws -> String {
        let name = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, name.count <= 180, name.hasSuffix(".zip"),
              !name.hasPrefix("."), !name.contains("/"), !name.contains("\\"), !name.contains("\0") else {
            throw LauncherError(.usageError, "Invalid resource pack file name")
        }
        return name
    }

    private func validateRemoteURL(_ url: URL) throws {
        guard url.scheme?.lowercased() == "https",
              url.host?.lowercased() == "cdn.modrinth.com",
              url.port == nil || url.port == 443,
              url.user == nil, url.password == nil else {
            throw LauncherError(.invalidMetadata, "Resource pack URL is not the official Modrinth CDN")
        }
    }

    private func temporaryDirectory() throws -> URL {
        let root = layout.dataRoot.appendingPathComponent("tmp", isDirectory: true)
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        let url = root.appendingPathComponent("resourcepack-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}

public enum ResourcePackArchiveValidator {
    public static func validate(archive: URL) throws {
        let attributes = try archive.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
        guard attributes.isRegularFile == true, let archiveSize = attributes.fileSize, archiveSize > 0 else {
            throw LauncherError(.invalidMetadata, "Resource pack is empty or not a regular file")
        }
        let limits = SafeZipExtractor.Limits(maxEntrySize: 64 * 1024 * 1024, maxTotalSize: 512 * 1024 * 1024, maxEntries: 20_000)
        let entries = try SafeZipExtractor.readEntries(Data(contentsOf: archive), limits: limits)
        guard let metaEntry = entries.first(where: { $0.name == "pack.mcmeta" && !$0.isDirectory }) else {
            throw LauncherError(.invalidMetadata, "Resource pack is missing pack.mcmeta")
        }
        guard entries.contains(where: { $0.name.hasPrefix("assets/") && !$0.isDirectory }) else {
            throw LauncherError(.invalidMetadata, "Resource pack has no assets")
        }
        let total = entries.reduce(0) { $0 + $1.data.count }
        guard total <= max(64 * 1024 * 1024, archiveSize * 200) else {
            throw LauncherError(.invalidMetadata, "Resource pack has an unsafe compression ratio")
        }
        guard let object = try JSONSerialization.jsonObject(with: metaEntry.data) as? [String: Any],
              let pack = object["pack"] as? [String: Any],
              pack["pack_format"] != nil else {
            throw LauncherError(.invalidMetadata, "Resource pack pack.mcmeta has no pack_format")
        }
    }
}

enum ResourcePackOptions {
    static let supportedVersions: Set<String> = ["1.20.1", "1.21.1"]

    static func enabledNames(data: Data) throws -> Set<String> {
        Set(try parse(data).names)
    }

    static func isEnabled(data: Data, fileName: String) throws -> Bool {
        try parse(data).names.contains("file/\(fileName)")
    }

    static func set(data: Data, fileName: String, enabled: Bool) throws -> Data {
        var parsed = try parse(data)
        let token = "file/\(fileName)"
        if enabled {
            if !parsed.names.contains(token) { parsed.names.append(token) }
        } else {
            parsed.names.removeAll { $0 == token }
        }
        let value = try JSONSerialization.data(withJSONObject: parsed.names, options: [])
        let string = String(decoding: value, as: UTF8.self).replacingOccurrences(of: "\\/", with: "/")
        if let range = parsed.lineRange {
            parsed.text.replaceSubrange(range, with: "resourcePacks:\(string)")
        } else {
            if !parsed.text.hasSuffix("\n") { parsed.text += "\n" }
            parsed.text += "resourcePacks:\(string)\n"
        }
        return Data(parsed.text.utf8)
    }

    private struct Parsed {
        var text: String
        var names: [String]
        var lineRange: Range<String.Index>?
    }

    private static func parse(_ data: Data) throws -> Parsed {
        guard let text = String(data: data, encoding: .utf8) else {
            throw LauncherError(.invalidMetadata, "options.txt is not UTF-8")
        }
        var names: [String] = []
        var lineRange: Range<String.Index>?
        var offset = text.startIndex
        while offset < text.endIndex {
            let end = text[offset...].firstIndex(of: "\n") ?? text.endIndex
            let line = String(text[offset..<end])
            if line.hasPrefix("resourcePacks:") {
                let raw = String(line.dropFirst("resourcePacks:".count))
                guard let parsed = try? JSONSerialization.jsonObject(with: Data(raw.utf8)) as? [String] else {
                    throw LauncherError(.invalidMetadata, "options.txt resourcePacks entry is not a JSON array")
                }
                names = parsed
                lineRange = offset..<end
                break
            }
            offset = end == text.endIndex ? end : text.index(after: end)
        }
        return Parsed(text: text, names: names, lineRange: lineRange)
    }
}
