import Foundation

/// A launcher instance: metadata plus one forced-isolation game directory.
///
/// The single `.minecraft` root lives at `<dataRoot>/.minecraft`; the instance's
/// `gameDirectory` is `<dataRoot>/.minecraft/versions/<instance-id>`. It is deliberately not
/// derived from `directory` (the metadata directory), so no second `.minecraft` can appear
/// under `instances/`.
public struct Instance: Sendable, Equatable, Identifiable {
    public let directory: URL
    public let gameDirectory: URL
    public var manifest: InstanceManifest

    public init(directory: URL, gameDirectory: URL, manifest: InstanceManifest) {
        self.directory = directory
        self.gameDirectory = gameDirectory
        self.manifest = manifest
    }

    public var id: String { manifest.id }
}

/// The contents of `instance.json`.
public struct InstanceManifest: Codable, Sendable, Equatable {
    /// Stable internal id, safe for use as a directory name.
    public let id: String
    /// Human display name; may contain spaces and Chinese characters. Never used as a path.
    public let displayName: String
    public let versionID: String?
    public let createdAt: Date
    public var lastLaunchedAt: Date?
    /// Which identity mode was last used, for display only.
    public var lastIdentityMode: IdentityMode?
    /// Manual JVM heap limit (`-Xmx<N>M`). Nil means automatic allocation based on physical
    /// memory; automatic never means "no -Xmx" at launch. See `InstanceMemory`.
    public var memoryMiB: Int?
    /// Reproducible Java selection/installation record (version + published checksum).
    public var javaRuntime: JavaRuntimeRecord?

    public init(
        id: String,
        displayName: String,
        versionID: String?,
        createdAt: Date = Date(),
        lastLaunchedAt: Date? = nil,
        lastIdentityMode: IdentityMode? = nil,
        memoryMiB: Int? = nil,
        javaRuntime: JavaRuntimeRecord? = nil
    ) {
        self.id = id
        self.displayName = displayName
        self.versionID = versionID
        self.createdAt = createdAt
        self.lastLaunchedAt = lastLaunchedAt
        self.lastIdentityMode = lastIdentityMode
        self.memoryMiB = memoryMiB
        self.javaRuntime = javaRuntime
    }
}

/// Creates, loads and lists instances under `<dataRoot>/instances`.
///
/// Instances own their `gameDir`; shared caches (versions/libraries/assets) stay outside and are
/// never modified here.
public struct InstanceRepository: Sendable {
    public let layout: GameDataLayout

    public init(layout: GameDataLayout) {
        self.layout = layout
    }

    /// Creates an instance with an explicit, caller-chosen id (used by the installer, where
    /// `--instance <id>` must remain stable).
    @discardableResult
    public func create(id: String, displayName: String, versionID: String?) throws -> Instance {
        let component = try PathSafety.validatedPathComponent(id)
        let directory = try layout.instanceDirectory(component)
        guard !FileManager.default.fileExists(atPath: directory.path) else {
            throw LauncherError(.ioFailure, "Instance '\(component)' already exists at \(directory.path)")
        }
        let trimmed = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        let manifest = InstanceManifest(id: component, displayName: trimmed.isEmpty ? component : trimmed, versionID: versionID)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let gameDirectory = try prepareGameDirectory(id: component, metadataDirectory: directory, allowMigration: false)
        try save(manifest, in: directory)
        return Instance(directory: directory, gameDirectory: gameDirectory, manifest: manifest)
    }

    @discardableResult
    public func create(displayName: String, versionID: String?) throws -> Instance {
        let trimmed = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw LauncherError(.usageError, "Instance display name must not be empty")
        }
        let id = try makeInstanceID(for: trimmed)
        let directory = try layout.instanceDirectory(id)
        let manifest = InstanceManifest(id: id, displayName: trimmed, versionID: versionID)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let gameDirectory = try prepareGameDirectory(id: id, metadataDirectory: directory, allowMigration: false)
        try save(manifest, in: directory)
        return Instance(directory: directory, gameDirectory: gameDirectory, manifest: manifest)
    }

    public func load(id: String) throws -> Instance {
        let directory = try layout.instanceDirectory(id)
        let manifestURL = directory.appendingPathComponent("instance.json", isDirectory: false)
        guard FileManager.default.fileExists(atPath: manifestURL.path) else {
            throw LauncherError(
                .missingDependency,
                "Instance '\(id)' not found at \(directory.path)",
                suggestion: "List instances with `lingxi instance list` or pass an existing --instance id."
            )
        }
        let data: Data
        do {
            data = try Data(contentsOf: manifestURL)
        } catch {
            throw LauncherError(.ioFailure, "Cannot read \(manifestURL.path): \(error.localizedDescription)")
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        do {
            let manifest = try decoder.decode(InstanceManifest.self, from: data)
            guard manifest.id == id else {
                throw LauncherError(.invalidMetadata, "instance.json id '\(manifest.id)' does not match directory '\(id)'")
            }
            let gameDirectory = try prepareGameDirectory(id: id, metadataDirectory: directory, allowMigration: true)
            return Instance(directory: directory, gameDirectory: gameDirectory, manifest: manifest)
        } catch let error as LauncherError {
            throw error
        } catch {
            throw LauncherError(.invalidMetadata, "Corrupted instance.json at \(manifestURL.path): \(error.localizedDescription)")
        }
    }

    public func list() throws -> [Instance] {
        let directory = layout.instancesDirectory
        guard FileManager.default.fileExists(atPath: directory.path) else { return [] }
        let urls = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.isDirectoryKey])
        return try urls
            .filter { $0.hasDirectoryPath || (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
            .compactMap { url in
                try? load(id: url.lastPathComponent)
            }
    }

    /// Points an existing instance at another version (used by `install vanilla`).
    @discardableResult
    public func assignVersion(id: String, versionID: String) throws -> Instance {
        var instance = try load(id: id)
        guard instance.manifest.versionID != versionID else { return instance }
        let updated = InstanceManifest(
            id: instance.manifest.id,
            displayName: instance.manifest.displayName,
            versionID: versionID,
            createdAt: instance.manifest.createdAt,
            lastLaunchedAt: instance.manifest.lastLaunchedAt,
            lastIdentityMode: instance.manifest.lastIdentityMode,
            memoryMiB: instance.manifest.memoryMiB,
            javaRuntime: instance.manifest.javaRuntime
        )
        try save(updated, in: instance.directory)
        instance.manifest = updated
        return instance
    }

    /// Updates the per-instance heap limit. Validates the range so a typo cannot create a
    /// 1 MiB heap or an absurd allocation.
    @discardableResult
    public func setMemory(id: String, memoryMiB: Int?) throws -> Instance {
        if let memoryMiB, !(256...65_536).contains(memoryMiB) {
            throw LauncherError(.usageError, "Memory must be between 256 and 65536 MiB")
        }
        var instance = try load(id: id)
        let updated = InstanceManifest(
            id: instance.manifest.id,
            displayName: instance.manifest.displayName,
            versionID: instance.manifest.versionID,
            createdAt: instance.manifest.createdAt,
            lastLaunchedAt: instance.manifest.lastLaunchedAt,
            lastIdentityMode: instance.manifest.lastIdentityMode,
            memoryMiB: memoryMiB,
            javaRuntime: instance.manifest.javaRuntime
        )
        try save(updated, in: instance.directory)
        instance.manifest = updated
        return instance
    }

    /// Deletes the metadata directory and the forced-isolation game directory. Callers must
    /// confirm with the user first; this removes worlds under the single `.minecraft` tree and
    /// is intentionally not exposed by the CLI.
    public func delete(id: String) throws {
        let instance = try load(id: id)
        guard PathSafety.isContainedResolvingSymlinks(instance.directory, inBase: layout.instancesDirectory) else {
            throw LauncherError(.pathEscapesRoot, "Instance '\(id)' resolves outside the instances directory")
        }
        guard PathSafety.isContainedResolvingSymlinks(instance.gameDirectory, inBase: layout.minecraftDirectory) else {
            throw LauncherError(.pathEscapesRoot, "Instance game directory '\(id)' resolves outside .minecraft")
        }
        do {
            if FileManager.default.fileExists(atPath: instance.gameDirectory.path) {
                try FileManager.default.removeItem(at: instance.gameDirectory)
            }
            try FileManager.default.removeItem(at: instance.directory)
        } catch {
            throw LauncherError(.ioFailure, "Cannot delete instance '\(id)': \(error.localizedDescription)")
        }
    }

    /// Creates the one shared `.minecraft` isolation tree for an instance. Legacy per-instance
    /// `.minecraft` folders are migrated once (move, never copy-and-delete) so existing worlds
    /// are not silently lost.
    private func prepareGameDirectory(id: String, metadataDirectory: URL, allowMigration: Bool) throws -> URL {
        let fm = FileManager.default
        let target = try layout.instanceGameDirectory(id)
        let legacy = metadataDirectory.appendingPathComponent(".minecraft", isDirectory: true)

        if allowMigration, fm.fileExists(atPath: legacy.path) {
            guard PathSafety.isContainedResolvingSymlinks(legacy, inBase: layout.instancesDirectory) else {
                throw LauncherError(.pathEscapesRoot, "Legacy instance .minecraft resolves outside the instances directory")
            }
            if fm.fileExists(atPath: target.path) {
                throw LauncherError(
                    .ioFailure,
                    "Both legacy and isolated game directories exist for instance '\(id)'; refusing to merge automatically",
                    suggestion: "Move or remove one of: \(legacy.path), \(target.path)"
                )
            }
            try fm.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
            do {
                try fm.moveItem(at: legacy, to: target)
            } catch {
                throw LauncherError(.ioFailure, "Cannot migrate legacy .minecraft for instance '\(id)': \(error.localizedDescription)")
            }
        }

        do {
            try fm.createDirectory(at: target, withIntermediateDirectories: true)
            try fm.createDirectory(at: target.appendingPathComponent("logs"), withIntermediateDirectories: true)
            try fm.createDirectory(at: target.appendingPathComponent("crash-reports"), withIntermediateDirectories: true)
        } catch {
            throw LauncherError(.ioFailure, "Cannot prepare isolated game directory \(target.path): \(error.localizedDescription)")
        }
        return target
    }

    /// Persists the actual Java runtime used by an instance. Callers should pass the record
    /// produced by `JavaManager.runtimeRecord(for:)` after a managed install or an explicit
    /// user selection.
    @discardableResult
    public func setJavaRuntime(id: String, record: JavaRuntimeRecord?) throws -> Instance {
        var instance = try load(id: id)
        guard instance.manifest.javaRuntime != record else { return instance }
        let updated = InstanceManifest(
            id: instance.manifest.id,
            displayName: instance.manifest.displayName,
            versionID: instance.manifest.versionID,
            createdAt: instance.manifest.createdAt,
            lastLaunchedAt: instance.manifest.lastLaunchedAt,
            lastIdentityMode: instance.manifest.lastIdentityMode,
            memoryMiB: instance.manifest.memoryMiB,
            javaRuntime: record
        )
        try save(updated, in: instance.directory)
        instance.manifest = updated
        return instance
    }

    /// Backs up only the small instance manifest before an explicit version update. Worlds,
    /// options, mods and logs are not touched by a version-pointer update.
    @discardableResult
    public func backupManifest(id: String) throws -> URL {
        let instance = try load(id: id)
        let source = instance.directory.appendingPathComponent("instance.json", isDirectory: false)
        let stamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")
        let nonce = UUID().uuidString.prefix(8).lowercased()
        let destination = instance.directory.appendingPathComponent("instance.json.backup-\(stamp)-\(nonce)", isDirectory: false)
        do {
            try FileManager.default.copyItem(at: source, to: destination)
            return destination
        } catch {
            throw LauncherError(.ioFailure, "Cannot back up instance manifest: \(error.localizedDescription)")
        }
    }

    /// Records a successful launch for display purposes.
    public func recordLaunch(id: String, identityMode: IdentityMode, at date: Date = Date()) throws {
        var instance = try load(id: id)
        instance.manifest.lastLaunchedAt = date
        instance.manifest.lastIdentityMode = identityMode
        try save(instance.manifest, in: instance.directory)
    }

    // MARK: - Helpers

    private func save(_ manifest: InstanceManifest, in directory: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let url = directory.appendingPathComponent("instance.json", isDirectory: false)
        do {
            let data = try encoder.encode(manifest)
            try data.write(to: url, options: [.atomic])
        } catch {
            throw LauncherError(.ioFailure, "Cannot write \(url.path): \(error.localizedDescription)")
        }
    }

    /// Display-name slug + short random suffix. The display name is never used as a path.
    private func makeInstanceID(for displayName: String) throws -> String {
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyz0123456789-")
        let slug = displayName.lowercased()
            .replacingOccurrences(of: " ", with: "-")
            .unicodeScalars
            .filter { allowed.contains($0) }
            .map(String.init)
            .joined()
            .prefix(24)
        let base = slug.isEmpty ? "instance" : String(slug)
        for _ in 0..<8 {
            let suffix = UUID().uuidString.prefix(8).lowercased()
            let candidate = "\(base)-\(suffix)"
            let directory = try layout.instanceDirectory(candidate)
            if !FileManager.default.fileExists(atPath: directory.path) {
                return candidate
            }
        }
        throw LauncherError(.ioFailure, "Could not allocate a unique instance id for '\(displayName)'")
    }
}
