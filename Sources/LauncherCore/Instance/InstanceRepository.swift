import Foundation

/// A launcher instance: one isolated game directory plus the metadata describing it.
public struct Instance: Sendable, Equatable {
    public let directory: URL
    public var manifest: InstanceManifest

    public init(directory: URL, manifest: InstanceManifest) {
        self.directory = directory
        self.manifest = manifest
    }

    /// `<instance>/.minecraft` — the only working directory the game may write saves into.
    public var gameDirectory: URL {
        directory.appendingPathComponent(".minecraft", isDirectory: true)
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

    public init(
        id: String,
        displayName: String,
        versionID: String?,
        createdAt: Date = Date(),
        lastLaunchedAt: Date? = nil,
        lastIdentityMode: IdentityMode? = nil
    ) {
        self.id = id
        self.displayName = displayName
        self.versionID = versionID
        self.createdAt = createdAt
        self.lastLaunchedAt = lastLaunchedAt
        self.lastIdentityMode = lastIdentityMode
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
        try FileManager.default.createDirectory(
            at: directory.appendingPathComponent(".minecraft", isDirectory: true),
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(
            at: directory.appendingPathComponent(".minecraft/logs", isDirectory: true),
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(
            at: directory.appendingPathComponent(".minecraft/crash-reports", isDirectory: true),
            withIntermediateDirectories: true
        )
        try save(manifest, in: directory)
        return Instance(directory: directory, manifest: manifest)
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
        try FileManager.default.createDirectory(
            at: directory.appendingPathComponent(".minecraft", isDirectory: true),
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(
            at: directory.appendingPathComponent(".minecraft/logs", isDirectory: true),
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(
            at: directory.appendingPathComponent(".minecraft/crash-reports", isDirectory: true),
            withIntermediateDirectories: true
        )
        try save(manifest, in: directory)
        return Instance(directory: directory, manifest: manifest)
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
            return Instance(directory: directory, manifest: manifest)
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
            lastIdentityMode: instance.manifest.lastIdentityMode
        )
        try save(updated, in: instance.directory)
        instance.manifest = updated
        return instance
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
