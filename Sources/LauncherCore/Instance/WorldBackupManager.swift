import Foundation
#if canImport(Darwin)
import Darwin
#endif

public struct MinecraftWorld: Codable, Sendable, Equatable, Identifiable {
    public let name: String
    public let byteCount: Int
    public let modifiedAt: Date?

    public var id: String { name }

    public init(name: String, byteCount: Int, modifiedAt: Date?) {
        self.name = name
        self.byteCount = byteCount
        self.modifiedAt = modifiedAt
    }
}

public struct WorldBackupFile: Codable, Sendable, Equatable {
    public let relativePath: String
    public let byteCount: Int
    public let sha256: String

    public init(relativePath: String, byteCount: Int, sha256: String) {
        self.relativePath = relativePath
        self.byteCount = byteCount
        self.sha256 = sha256
    }
}

public struct WorldBackupManifest: Codable, Sendable, Equatable {
    public let schemaVersion: Int
    public let id: String
    public let instanceID: String
    public let worldName: String
    public let createdAt: Date
    public let fileCount: Int
    public let totalBytes: Int
    public let files: [WorldBackupFile]

    public init(
        schemaVersion: Int = 1,
        id: String,
        instanceID: String,
        worldName: String,
        createdAt: Date,
        files: [WorldBackupFile]
    ) {
        self.schemaVersion = schemaVersion
        self.id = id
        self.instanceID = instanceID
        self.worldName = worldName
        self.createdAt = createdAt
        self.fileCount = files.count
        self.totalBytes = files.reduce(0) { $0 + $1.byteCount }
        self.files = files
    }
}

public struct WorldBackupSummary: Codable, Sendable, Equatable, Identifiable {
    public let id: String
    public let instanceID: String
    public let worldName: String
    public let createdAt: Date
    public let fileCount: Int
    public let totalBytes: Int
    public let directory: URL

    public init(manifest: WorldBackupManifest, directory: URL) {
        self.id = manifest.id
        self.instanceID = manifest.instanceID
        self.worldName = manifest.worldName
        self.createdAt = manifest.createdAt
        self.fileCount = manifest.fileCount
        self.totalBytes = manifest.totalBytes
        self.directory = directory
    }
}

/// Creates, verifies, restores and deletes complete world snapshots outside the Minecraft game
/// directory. Every path is checked before mutation; symlinks are never followed.
public struct WorldBackupManager: Sendable {
    public let layout: GameDataLayout
    public let repository: InstanceRepository
    private let runtimeRegistry: InstanceRuntimeChecking

    public init(layout: GameDataLayout, runtimeRegistry: InstanceRuntimeChecking? = nil) {
        self.layout = layout
        self.repository = InstanceRepository(layout: layout)
        self.runtimeRegistry = runtimeRegistry ?? InstanceRuntimeRegistry(layout: layout)
    }

    public func listWorlds(instanceID: String) throws -> [MinecraftWorld] {
        let instance = try repository.load(id: instanceID)
        let saves = instance.gameDirectory.appendingPathComponent("saves", isDirectory: true)
        guard FileManager.default.fileExists(atPath: saves.path) else { return [] }
        guard PathSafety.isContainedResolvingSymlinks(saves, inBase: instance.gameDirectory) else {
            throw LauncherError(.pathEscapesRoot, "World saves directory resolves outside the instance")
        }
        let entries = try FileManager.default.contentsOfDirectory(
            at: saves,
            includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey, .contentModificationDateKey],
            options: []
        )
        return try entries.compactMap { url -> MinecraftWorld? in
            let values = try url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey, .contentModificationDateKey])
            guard values.isDirectory == true, values.isSymbolicLink != true else { return nil }
            try PathSafety.validatedPathComponent(url.lastPathComponent)
            guard PathSafety.isContainedResolvingSymlinks(url, inBase: saves) else { return nil }
            return MinecraftWorld(
                name: url.lastPathComponent,
                byteCount: try directorySize(url),
                modifiedAt: values.contentModificationDate
            )
        }.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    public func listBackups(instanceID: String) throws -> [WorldBackupSummary] {
        let root = try backupRoot(instanceID: instanceID)
        guard FileManager.default.fileExists(atPath: root.path) else { return [] }
        let entries = try FileManager.default.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
            options: [.skipsHiddenFiles]
        )
        return try entries.compactMap { url -> WorldBackupSummary? in
            let values = try url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            guard values.isDirectory == true, values.isSymbolicLink != true,
                  PathSafety.isContainedResolvingSymlinks(url, inBase: root) else { return nil }
            let manifestURL = url.appendingPathComponent("manifest.json", isDirectory: false)
            guard let manifest = try? loadManifest(at: manifestURL),
                  manifest.instanceID == instanceID, manifest.id == url.lastPathComponent else { return nil }
            return WorldBackupSummary(manifest: manifest, directory: url)
        }.sorted { $0.createdAt > $1.createdAt }
    }

    @discardableResult
    public func createBackup(instanceID: String, worldName: String) throws -> WorldBackupSummary {
        let instance = try repository.load(id: instanceID)
        let lock = try BackupInstanceLock(root: backupRoot(instanceID: instanceID))
        defer { withExtendedLifetime(lock) {} }
        let component = try PathSafety.validatedPathComponent(worldName)
        let saves = instance.gameDirectory.appendingPathComponent("saves", isDirectory: true)
        let world = saves.appendingPathComponent(component, isDirectory: true)
        let values = try? world.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        guard values?.isDirectory == true, values?.isSymbolicLink != true else {
            throw LauncherError(.missingDependency, "World '\(worldName)' is not a regular directory")
        }
        guard PathSafety.isContainedResolvingSymlinks(world, inBase: saves) else {
            throw LauncherError(.pathEscapesRoot, "World path escapes the instance saves directory")
        }
        guard !runtimeRegistry.isRunning(instanceID: instanceID) else {
            throw LauncherError(.launchFailed, "Cannot create a world backup while the game is running")
        }
        let root = try backupRoot(instanceID: instanceID)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let id = backupID()
        let temporary = root.appendingPathComponent(".tmp-\(UUID().uuidString)", isDirectory: true)
        let destination = root.appendingPathComponent(id, isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
            let copiedWorld = temporary.appendingPathComponent("world", isDirectory: true)
            let sourceBefore = try snapshotFiles(at: world)
            try copyDirectory(world, to: copiedWorld, sourceBase: saves)
            guard !runtimeRegistry.isRunning(instanceID: instanceID) else {
                throw LauncherError(.launchFailed, "The game started while the backup was being created")
            }
            let copiedFiles = try snapshotFiles(at: copiedWorld)
            let sourceAfter = try snapshotFiles(at: world)
            guard sourceBefore == sourceAfter, sourceBefore == copiedFiles else {
                throw LauncherError(
                    .ioFailure,
                    "The world changed while the backup was being created; the snapshot was rejected"
                )
            }
            let files = copiedFiles
            let manifest = WorldBackupManifest(
                id: id,
                instanceID: instanceID,
                worldName: component,
                createdAt: Date(),
                files: files
            )
            try writeManifest(manifest, to: temporary.appendingPathComponent("manifest.json", isDirectory: false))
            try FileManager.default.moveItem(at: temporary, to: destination)
            return WorldBackupSummary(manifest: manifest, directory: destination)
        } catch {
            try? FileManager.default.removeItem(at: temporary)
            try? FileManager.default.removeItem(at: destination)
            if let launcherError = error as? LauncherError { throw launcherError }
            throw LauncherError(.ioFailure, "Cannot create world backup: \(error.localizedDescription)")
        }
    }

    public func verifyBackup(instanceID: String, backupID: String) throws -> WorldBackupManifest {
        let root = try backupRoot(instanceID: instanceID)
        let component = try PathSafety.validatedPathComponent(backupID)
        let directory = root.appendingPathComponent(component, isDirectory: true)
        guard PathSafety.isContainedResolvingSymlinks(directory, inBase: root) else {
            throw LauncherError(.pathEscapesRoot, "Backup directory escapes the backup root")
        }
        let manifest = try loadManifest(at: directory.appendingPathComponent("manifest.json", isDirectory: false))
        guard manifest.instanceID == instanceID, manifest.id == component else {
            throw LauncherError(.invalidMetadata, "Backup manifest identity does not match its directory")
        }
        let world = directory.appendingPathComponent("world", isDirectory: true)
        guard FileManager.default.fileExists(atPath: world.path) else {
            throw LauncherError(.invalidMetadata, "Backup world directory is missing")
        }
        let actual = try snapshotFiles(at: world)
        let expected = Dictionary(uniqueKeysWithValues: manifest.files.map { ($0.relativePath, $0) })
        let actualMap = Dictionary(uniqueKeysWithValues: actual.map { ($0.relativePath, $0) })
        guard expected.keys.sorted() == actualMap.keys.sorted() else {
            throw LauncherError(.invalidMetadata, "Backup file list does not match manifest")
        }
        for (path, file) in expected {
            guard let found = actualMap[path], found.byteCount == file.byteCount, found.sha256 == file.sha256 else {
                throw LauncherError(.invalidMetadata, "Backup file failed checksum: \(path)")
            }
        }
        return manifest
    }

    @discardableResult
    public func restore(instanceID: String, backupID: String, worldName: String? = nil) throws -> URL {
        let lock = try BackupInstanceLock(root: backupRoot(instanceID: instanceID))
        defer { withExtendedLifetime(lock) {} }
        guard !runtimeRegistry.isRunning(instanceID: instanceID) else {
            throw LauncherError(.launchFailed, "Cannot restore a world while the game is running")
        }
        let instance = try repository.load(id: instanceID)
        let manifest = try verifyBackup(instanceID: instanceID, backupID: backupID)
        let component = try PathSafety.validatedPathComponent(worldName ?? manifest.worldName)
        guard component == manifest.worldName || worldName != nil else {
            throw LauncherError(.invalidMetadata, "Backup world name does not match the requested world")
        }
        let saves = instance.gameDirectory.appendingPathComponent("saves", isDirectory: true)
        let target = saves.appendingPathComponent(component, isDirectory: true)
        guard PathSafety.isContainedResolvingSymlinks(target, inBase: saves) else {
            throw LauncherError(.pathEscapesRoot, "Restore target escapes the instance saves directory")
        }
        let values = try? target.resourceValues(forKeys: [.isSymbolicLinkKey])
        guard values?.isSymbolicLink != true else {
            throw LauncherError(.pathEscapesRoot, "Refusing to restore over a symbolic link")
        }

        guard !runtimeRegistry.isRunning(instanceID: instanceID) else {
            throw LauncherError(.launchFailed, "Cannot restore a world while the game is running")
        }
        let root = try backupRoot(instanceID: instanceID)
        let staging = saves.appendingPathComponent(".lingxi-restore-\(UUID().uuidString)", isDirectory: true)
        let recovery = root.appendingPathComponent(".restore-\(UUID().uuidString)", isDirectory: true)
        let backupWorld = try backupRoot(instanceID: instanceID)
            .appendingPathComponent(try PathSafety.validatedPathComponent(backupID), isDirectory: true)
            .appendingPathComponent("world", isDirectory: true)
        do {
            guard !runtimeRegistry.isRunning(instanceID: instanceID) else {
                throw LauncherError(.launchFailed, "The game started while the world restore was being staged")
            }
            try copyDirectory(backupWorld, to: staging, sourceBase: backupWorld)
            let stagedFiles = try snapshotFiles(at: staging)
            let expected = Dictionary(uniqueKeysWithValues: manifest.files.map { ($0.relativePath, $0) })
            guard stagedFiles.count == expected.count,
                  stagedFiles.allSatisfy({ expected[$0.relativePath]?.sha256 == $0.sha256 && expected[$0.relativePath]?.byteCount == $0.byteCount })
            else {
                throw LauncherError(.invalidMetadata, "Staged restore copy failed verification")
            }
            if FileManager.default.fileExists(atPath: target.path) {
                try FileManager.default.moveItem(at: target, to: recovery)
            }
            do {
                try FileManager.default.moveItem(at: staging, to: target)
                let restored = try snapshotFiles(at: target)
                guard restored.count == expected.count,
                      restored.allSatisfy({ expected[$0.relativePath]?.sha256 == $0.sha256 })
                else {
                    throw LauncherError(.invalidMetadata, "Restored world failed verification")
                }
                try? FileManager.default.removeItem(at: recovery)
                return target
            } catch {
                try? FileManager.default.removeItem(at: target)
                if FileManager.default.fileExists(atPath: recovery.path) {
                    do {
                        try FileManager.default.moveItem(at: recovery, to: target)
                    } catch {
                        throw LauncherError(
                            .ioFailure,
                            "World restore failed and the original world could not be restored automatically",
                            suggestion: "The recovery copy is preserved at \(recovery.path). Do not delete it."
                        )
                    }
                }
                throw error
            }
        } catch {
            try? FileManager.default.removeItem(at: staging)
            if let launcherError = error as? LauncherError { throw launcherError }
            throw LauncherError(.ioFailure, "Cannot restore world: \(error.localizedDescription)")
        }
    }

    public func deleteBackup(instanceID: String, backupID: String) throws {
        let lock = try BackupInstanceLock(root: backupRoot(instanceID: instanceID))
        defer { withExtendedLifetime(lock) {} }
        guard !runtimeRegistry.isRunning(instanceID: instanceID) else {
            throw LauncherError(.launchFailed, "Cannot delete a backup while the game is running")
        }
        let root = try backupRoot(instanceID: instanceID)
        let component = try PathSafety.validatedPathComponent(backupID)
        let directory = root.appendingPathComponent(component, isDirectory: true)
        guard PathSafety.isContainedResolvingSymlinks(directory, inBase: root) else {
            throw LauncherError(.pathEscapesRoot, "Backup directory escapes the backup root")
        }
        guard FileManager.default.fileExists(atPath: directory.path) else {
            throw LauncherError(.missingDependency, "Backup '\(backupID)' does not exist")
        }
        do {
            try FileManager.default.removeItem(at: directory)
        } catch {
            throw LauncherError(.ioFailure, "Cannot delete backup: \(error.localizedDescription)")
        }
    }


/// Cross-process advisory lock. The file descriptor is intentionally held for the whole
/// create/restore/delete operation so two launcher processes cannot interleave mutations.
private final class BackupInstanceLock {
    private let descriptor: Int32

    init(root: URL) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        let path = root.appendingPathComponent(".lock", isDirectory: false).path
        descriptor = open(path, O_CREAT | O_RDWR, S_IRUSR | S_IWUSR)
        guard descriptor >= 0 else {
            throw LauncherError(.ioFailure, "Cannot open backup lock at \(path)")
        }
        #if canImport(Darwin)
        guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
            close(descriptor)
            throw LauncherError(.launchFailed, "Another launcher process is already operating on this instance's backups")
        }
        #endif
    }

    deinit {
        #if canImport(Darwin)
        _ = flock(descriptor, LOCK_UN)
        #endif
        _ = close(descriptor)
    }
}

    // MARK: - Safety and filesystem helpers

    private func backupRoot(instanceID: String) throws -> URL {
        let component = try PathSafety.validatedPathComponent(instanceID)
        let root = layout.backupsDirectory.appendingPathComponent(component, isDirectory: true)
        guard PathSafety.isContained(root, inBase: layout.backupsDirectory) else {
            throw LauncherError(.pathEscapesRoot, "Backup root escapes dataRoot/backups")
        }
        return root
    }

    private func backupID() -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return "\(formatter.string(from: Date()))-\(UUID().uuidString.prefix(8).lowercased())"
    }

    private func loadManifest(at url: URL) throws -> WorldBackupManifest {
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw LauncherError(.missingDependency, "Backup manifest is missing")
        }
        do {
            let data = try Data(contentsOf: url)
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            return try decoder.decode(WorldBackupManifest.self, from: data)
        } catch {
            throw LauncherError(.invalidMetadata, "Cannot read backup manifest: \(error.localizedDescription)")
        }
    }

    private func writeManifest(_ manifest: WorldBackupManifest, to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(manifest).write(to: url, options: [.atomic])
    }

    private func directorySize(_ directory: URL) throws -> Int {
        var total = 0
        let keys: [URLResourceKey] = [.isRegularFileKey, .isDirectoryKey, .isSymbolicLinkKey, .fileSizeKey]
        guard let enumerator = FileManager.default.enumerator(at: directory, includingPropertiesForKeys: keys, options: []) else {
            return 0
        }
        for case let url as URL in enumerator {
            let values = try url.resourceValues(forKeys: Set(keys))
            guard values.isSymbolicLink != true else {
                throw LauncherError(.pathEscapesRoot, "Symbolic link inside world: \(url.path)")
            }
            if values.isRegularFile == true { total += values.fileSize ?? 0 }
        }
        return total
    }

    private func copyDirectory(_ source: URL, to destination: URL, sourceBase: URL) throws {
        let fm = FileManager.default
        let keys: [URLResourceKey] = [.isRegularFileKey, .isDirectoryKey, .isSymbolicLinkKey]
        guard let enumerator = fm.enumerator(at: source, includingPropertiesForKeys: keys, options: []) else {
            throw LauncherError(.ioFailure, "Cannot enumerate \(source.path)")
        }
        try fm.createDirectory(at: destination, withIntermediateDirectories: true)
        for case let url as URL in enumerator {
            let values = try url.resourceValues(forKeys: Set(keys))
            guard values.isSymbolicLink != true else {
                throw LauncherError(.pathEscapesRoot, "Symbolic link inside world: \(url.path)")
            }
            guard PathSafety.isContainedResolvingSymlinks(url, inBase: sourceBase) else {
                throw LauncherError(.pathEscapesRoot, "World entry escapes its root: \(url.path)")
            }
            let relative = try relativePath(of: url, under: source)
            let target = destination.appendingPathComponent(relative, isDirectory: values.isDirectory == true)
            if values.isDirectory == true {
                try fm.createDirectory(at: target, withIntermediateDirectories: true)
            } else if values.isRegularFile == true {
                try fm.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
                if fm.fileExists(atPath: target.path) { try fm.removeItem(at: target) }
                try fm.copyItem(at: url, to: target)
            }
        }
    }

    private func relativePath(of url: URL, under root: URL) throws -> String {
        let base = root.resolvingSymlinksInPath().path
        let child = url.resolvingSymlinksInPath().path
        let prefix = base.hasSuffix("/") ? base : base + "/"
        guard child.hasPrefix(prefix) else {
            throw LauncherError(.pathEscapesRoot, "World entry escapes its root: \(url.path)")
        }
        let relative = String(child.dropFirst(prefix.count))
        guard !relative.isEmpty, !relative.hasPrefix("/"), !relative.contains("..") else {
            throw LauncherError(.pathEscapesRoot, "Invalid world entry path: \(url.path)")
        }
        return relative
    }

    private func snapshotFiles(at root: URL) throws -> [WorldBackupFile] {
        let fm = FileManager.default
        let keys: [URLResourceKey] = [.isRegularFileKey, .isDirectoryKey, .isSymbolicLinkKey, .fileSizeKey]
        guard let enumerator = fm.enumerator(at: root, includingPropertiesForKeys: keys, options: []) else {
            throw LauncherError(.ioFailure, "Cannot enumerate \(root.path)")
        }
        var files: [WorldBackupFile] = []
        for case let url as URL in enumerator {
            let values = try url.resourceValues(forKeys: Set(keys))
            guard values.isSymbolicLink != true else {
                throw LauncherError(.pathEscapesRoot, "Symbolic link inside backup: \(url.path)")
            }
            guard values.isRegularFile == true else { continue }
            let relative = try relativePath(of: url, under: root)
            _ = try PathSafety.safeJoin(base: root, relativePath: relative)
            files.append(WorldBackupFile(
                relativePath: relative,
                byteCount: values.fileSize ?? 0,
                sha256: try SHA256Digest.hexDigest(ofFileAt: url)
            ))
        }
        return files.sorted { $0.relativePath < $1.relativePath }
    }
}
