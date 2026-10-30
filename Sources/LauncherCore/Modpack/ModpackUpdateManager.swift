import Foundation
#if canImport(Darwin)
import Darwin
#endif

public enum ModpackUpdateAction: String, CaseIterable, Sendable, Codable {
    case replace
    case preserve
    case skip
}

public struct ModpackUpdateFileChange: Sendable, Equatable {
    public let kind: ModpackFileChange.Kind
    public let path: String
    public let oldSHA256: String?
    public let newSHA256: String?
    public let oldSize: Int?
    public let newSize: Int?
    public let userModified: Bool
    public let isOptional: Bool
    public let reason: String

    public init(
        kind: ModpackFileChange.Kind,
        path: String,
        oldSHA256: String?,
        newSHA256: String?,
        oldSize: Int?,
        newSize: Int?,
        userModified: Bool,
        isOptional: Bool,
        reason: String
    ) {
        self.kind = kind
        self.path = path
        self.oldSHA256 = oldSHA256
        self.newSHA256 = newSHA256
        self.oldSize = oldSize
        self.newSize = newSize
        self.userModified = userModified
        self.isOptional = isOptional
        self.reason = reason
    }
}

public struct ModpackUpdatePlan: Sendable, Equatable {
    public let instanceID: String
    public let currentVersionID: String
    public let targetVersionID: String
    public let targetVersionNumber: String
    public let targetMinecraftVersion: String
    public let targetLoaderKind: String
    public let targetLoaderVersion: String?
    public let requiresMinecraftChange: Bool
    public let requiresLoaderChange: Bool
    public let changes: [ModpackUpdateFileChange]
    public let totalDownloadBytes: Int
    public let archiveURL: URL
    public let archiveSHA256: String

    public var hasBlockingChanges: Bool {
        changes.contains { $0.kind == .conflict }
    }
}

public struct ModpackUpdateReport: Sendable, Equatable {
    public let applied: [String]
    public let preserved: [String]
    public let skipped: [String]
    public let removed: [String]
    public let transactionID: String
}

private struct ModpackUpdateTransactionState: Codable {
    let id: String
    let instanceID: String
    var status: String
    var affectedPaths: [String]
    var hadRecord: Bool
}

private final class ModpackUpdateLock {
    private let descriptor: Int32

    init(layout: GameDataLayout, instanceID: String) throws {
        let directory = layout.dataRoot.appendingPathComponent("locks", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let safe = instanceID.replacingOccurrences(of: "/", with: "_")
        let path = directory.appendingPathComponent("modpack-update-\(safe).lock").path
        descriptor = open(path, O_CREAT | O_RDWR, 0o600)
        guard descriptor >= 0 else {
            throw LauncherError(.ioFailure, "Cannot open modpack update lock")
        }
        guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
            close(descriptor)
            throw LauncherError(.ioFailure, "Another launcher is updating this instance")
        }
    }

    deinit {
        _ = flock(descriptor, LOCK_UN)
        close(descriptor)
    }
}

/// Downloads a target `.mrpack`, parses its real internal file list and applies a transactional
/// update. The target archive is never trusted by its Modrinth filename: its SHA-1/SHA-512 and
/// every internal file are verified before the instance is touched.
public struct ModpackUpdateManager: Sendable {
    public let layout: GameDataLayout
    private let transport: any DownloadTransport
    private let client: ModrinthClient
    private let runtime: any InstanceRuntimeChecking
    private var fm: FileManager { FileManager.default }

    private static let trustedHosts: Set<String> = [
        "cdn.modrinth.com", "github.com", "raw.githubusercontent.com", "gitlab.com"
    ]

    public init(
        layout: GameDataLayout,
        transport: any DownloadTransport = URLSessionTransport(),
        client: ModrinthClient? = nil,
        runtime: (any InstanceRuntimeChecking)? = nil
    ) {
        self.layout = layout
        self.transport = transport
        self.client = client ?? ModrinthClient(transport: transport)
        self.runtime = runtime ?? InstanceRuntimeRegistry(layout: layout)
    }

    public func record(instanceID: String) throws -> ModpackRecord {
        try ModpackLifecycleManager(layout: layout).record(instanceID: instanceID)
    }

    public func pendingTransaction(instanceID: String) -> Bool {
        (try? transactionRoots(instanceID: instanceID).contains { url in
            fm.fileExists(atPath: url.appendingPathComponent("state.json").path)
        }) ?? false
    }

    /// Recover an interrupted update before any new operation. Returns true if a transaction was
    /// rolled back.
    @discardableResult
    public func recover(instanceID: String) throws -> Bool {
        let lock = try ModpackUpdateLock(layout: layout, instanceID: instanceID)
        _ = lock
        guard let root = try transactionRoots(instanceID: instanceID).first(where: {
            fm.fileExists(atPath: $0.appendingPathComponent("state.json").path)
        }) else { return false }
        try restore(transactionRoot: root, instance: try loadInstance(instanceID))
        try? fm.removeItem(at: root)
        return true
    }

    public func latestUpdate(instanceID: String) async throws -> ModrinthVersion? {
        let value = try record(instanceID: instanceID)
        guard let projectID = value.modrinthProjectID ?? value.projectID,
              let currentID = value.modrinthVersionID else {
            throw LauncherError(.missingDependency, "Pack source is not trusted; update check is unavailable")
        }
        let current = try await client.version(id: currentID)
        let versions = try await client.versions(
            projectID: projectID,
            gameVersion: value.minecraftVersion,
            loader: value.loaderKind
        )
        return ModrinthUpdatePolicy.selectUpdate(current: current, from: versions) { $0.primaryArchive }
    }

    public func preview(instanceID: String, targetVersionID: String) async throws -> ModpackUpdatePlan {
        guard !pendingTransaction(instanceID: instanceID) else {
            throw LauncherError(.usageError, "An unfinished pack update exists", suggestion: "Recover the previous update first.")
        }
        let lock = try ModpackUpdateLock(layout: layout, instanceID: instanceID)
        _ = lock
        let instance = try loadInstance(instanceID)
        try ensureNotRunning(instanceID)
        let current = try record(instanceID: instanceID)
        let target = try await client.version(id: targetVersionID)
        guard target.projectID == (current.modrinthProjectID ?? current.projectID) else {
            throw LauncherError(.usageError, "The target version belongs to a different Modrinth project")
        }
        let context = try makeContext(instance: instance, current: current, target: target)
        defer { try? fm.removeItem(at: context.transactionRoot) }
        let (_, package) = try await downloadAndParse(context: context, target: target)
        return try makePlan(instance: instance, current: current, target: target, package: package, context: context)
    }

    public func apply(
        instanceID: String,
        targetVersionID: String,
        actions: [String: ModpackUpdateAction] = [:]
    ) async throws -> ModpackUpdateReport {
        guard !pendingTransaction(instanceID: instanceID) else {
            throw LauncherError(.usageError, "An unfinished pack update exists", suggestion: "Recover the previous update first.")
        }
        let lock = try ModpackUpdateLock(layout: layout, instanceID: instanceID)
        _ = lock
        let instance = try loadInstance(instanceID)
        try ensureNotRunning(instanceID)
        let current = try record(instanceID: instanceID)
        let target = try await client.version(id: targetVersionID)
        guard target.projectID == (current.modrinthProjectID ?? current.projectID) else {
            throw LauncherError(.usageError, "The target version belongs to a different Modrinth project")
        }
        let context = try makeContext(instance: instance, current: current, target: target)
        var succeeded = false
        defer {
            if !succeeded { try? restore(transactionRoot: context.transactionRoot, instance: instance) }
            try? fm.removeItem(at: context.transactionRoot)
        }
        let (archive, package) = try await downloadAndParse(context: context, target: target)
        let plan = try makePlan(instance: instance, current: current, target: target, package: package, context: context)
        try validate(plan: plan, current: current, instance: instance)
        let staged = try await stageFiles(plan: plan, package: package, context: context, archive: archive, actions: actions)
        let transaction = try prepareTransaction(instance: instance, plan: plan, current: current, context: context)
        do {
            var newRecord = current
            newRecord.versionID = package.versionID
            newRecord.packVersionID = package.versionID
            newRecord.modrinthVersionID = target.id
            newRecord.modrinthProjectID = target.projectID
            newRecord.projectID = target.projectID
            newRecord.minecraftVersion = package.minecraftVersion
            switch package.loader {
            case .vanilla:
                newRecord.loaderKind = "vanilla"
                newRecord.loaderVersion = nil
            case let .fabric(version):
                newRecord.loaderKind = "fabric"
                newRecord.loaderVersion = version
            case let .neoforge(version):
                newRecord.loaderKind = "neoforge"
                newRecord.loaderVersion = version
            }
            newRecord.archiveSHA256 = package.archiveSHA256
            newRecord.installedAt = Date()
            var records: [String: ModpackFileRecord] = [:]
            var applied: [String] = []
            var preserved: [String] = []
            var skipped: [String] = []
            var removed: [String] = []
            for change in plan.changes {
                let action = actions[change.path] ?? defaultAction(for: change)
                switch action {
                case .skip:
                    skipped.append(change.path)
                    if let old = current.files.first(where: { $0.path == change.path }) {
                        records[change.path] = old
                    }
                case .preserve:
                    preserved.append(change.path)
                    if let old = current.files.first(where: { $0.path == change.path }) {
                        records[change.path] = old
                    }
                case .replace:
                    if change.kind == .removed {
                        try removeManaged(path: change.path, instance: instance)
                        removed.append(change.path)
                        continue
                    }
                    guard let source = staged[change.path] else {
                        throw LauncherError(.ioFailure, "Missing staged file for \(change.path)")
                    }
                    let targetURL = try PathSafety.safeJoin(base: instance.gameDirectory, relativePath: change.path)
                    try fm.createDirectory(at: targetURL.deletingLastPathComponent(), withIntermediateDirectories: true)
                    if fm.fileExists(atPath: targetURL.path) { try fm.removeItem(at: targetURL) }
                    try fm.moveItem(at: source, to: targetURL)
                    let hash = try SHA256Digest.hexDigest(ofFileAt: targetURL)
                    records[change.path] = ModpackFileRecord(
                        path: change.path,
                        sha256: hash,
                        sha1: nil,
                        sha512: nil,
                        source: "modpack-update",
                        userModified: false
                    )
                    applied.append(change.path)
                }
            }
            let selectedPaths = Set(current.files.map(\.path))
            let conflictPaths = Set(plan.changes.filter { $0.kind == .conflict }.map(\.path))
            let selectedPackageFiles = package.selectedFiles(includingOptionalPaths: selectedPaths)
            for file in selectedPackageFiles where records[file.relativePath] == nil && !conflictPaths.contains(file.relativePath) {
                let url = try PathSafety.safeJoin(base: instance.gameDirectory, relativePath: file.relativePath)
                guard fm.fileExists(atPath: url.path) else {
                    throw LauncherError(.ioFailure, "Untouched target file is missing: \(file.relativePath)")
                }
                let actual = try SHA256Digest.hexDigest(ofFileAt: url)
                records[file.relativePath] = ModpackFileRecord(
                    path: file.relativePath,
                    sha256: actual,
                    sha1: file.sha1,
                    sha512: file.sha512,
                    source: "modrinth"
                )
            }
            for override in package.overrides where records[override.relativePath] == nil && !conflictPaths.contains(override.relativePath) {
                let url = try PathSafety.safeJoin(base: instance.gameDirectory, relativePath: override.relativePath)
                guard fm.fileExists(atPath: url.path) else {
                    throw LauncherError(.ioFailure, "Untouched override is missing: \(override.relativePath)")
                }
                records[override.relativePath] = ModpackFileRecord(
                    path: override.relativePath,
                    sha256: try SHA256Digest.hexDigest(ofFileAt: url),
                    source: "pack-override"
                )
            }
            for (path, value) in records {
                let url = try PathSafety.safeJoin(base: instance.gameDirectory, relativePath: path)
                guard fm.fileExists(atPath: url.path) else {
                    throw LauncherError(.ioFailure, "Updated file is missing: \(path)")
                }
                let actual = try SHA256Digest.hexDigest(ofFileAt: url)
                records[path] = ModpackFileRecord(
                    path: path,
                    sha256: actual,
                    sha1: value.sha1,
                    sha512: value.sha512,
                    source: value.source,
                    userModified: value.userModified || actual != value.sha256
                )
            }
            newRecord.files = records.values.sorted { $0.path < $1.path }
            try verify(record: newRecord, instance: instance)
            try ModpackLifecycleManager(layout: layout).save(newRecord, instanceID: instanceID)
            try markCommitted(transaction: transaction)
            succeeded = true
            return ModpackUpdateReport(
                applied: applied.sorted(),
                preserved: preserved.sorted(),
                skipped: skipped.sorted(),
                removed: removed.sorted(),
                transactionID: transaction.id
            )
        } catch {
            try? restore(transactionRoot: context.transactionRoot, instance: instance)
            throw (error as? LauncherError) ?? LauncherError(.ioFailure, "Pack update failed: \(error.localizedDescription)")
        }
    }

    // MARK: - Context / download

    private struct Context {
        let transactionRoot: URL
        let extractRoot: URL
        let stagingRoot: URL
        let backupRoot: URL
        let id: String
    }

    private func makeContext(instance: Instance, current: ModpackRecord, target: ModrinthVersion) throws -> Context {
        let id = UUID().uuidString
        let root = layout.dataRoot
            .appendingPathComponent("modpack-updates", isDirectory: true)
            .appendingPathComponent(try PathSafety.validatedPathComponent(instance.id), isDirectory: true)
            .appendingPathComponent(id, isDirectory: true)
        let extract = root.appendingPathComponent("extract", isDirectory: true)
        let staging = root.appendingPathComponent("staging", isDirectory: true)
        let backup = root.appendingPathComponent("backup", isDirectory: true)
        for url in [staging, backup] {
            try fm.createDirectory(at: url, withIntermediateDirectories: true)
        }
        _ = current
        _ = target
        return Context(transactionRoot: root, extractRoot: extract, stagingRoot: staging, backupRoot: backup, id: id)
    }

    private func downloadAndParse(context: Context, target: ModrinthVersion) async throws -> (URL, MrpackPackage) {
        guard let archive = target.primaryArchive,
              let url = archive.downloadURL,
              Self.trustedHosts.contains(url.host ?? "") else {
            throw LauncherError(.invalidMetadata, "Modpack target has no trusted .mrpack archive")
        }
        let archiveURL = context.transactionRoot.appendingPathComponent("target.mrpack", isDirectory: false)
        try await transport.download(from: url, to: archiveURL)
        let size = try fm.attributesOfItem(atPath: archiveURL.path)[.size] as? NSNumber
        guard size?.intValue == archive.size else {
            throw LauncherError(.invalidMetadata, "Downloaded .mrpack size does not match metadata")
        }
        if let expected = archive.hashes.sha512 {
            guard try SHA512Digest.hexDigest(ofFileAt: archiveURL) == expected.lowercased() else {
                throw LauncherError(.invalidMetadata, "Downloaded .mrpack SHA-512 mismatch")
            }
        } else if let expected = archive.hashes.sha1 {
            guard try SHA1.hexDigest(ofFileAt: archiveURL) == expected.lowercased() else {
                throw LauncherError(.invalidMetadata, "Downloaded .mrpack SHA-1 mismatch")
            }
        } else {
            throw LauncherError(.invalidMetadata, "Modpack archive has no checksum")
        }
        let package = try MrpackParser.parse(archive: archiveURL, extractionRoot: context.extractRoot)
        return (archiveURL, package)
    }

    // MARK: - Plan

    private func makePlan(
        instance: Instance,
        current: ModpackRecord,
        target: ModrinthVersion,
        package: MrpackPackage,
        context: Context
    ) throws -> ModpackUpdatePlan {
        let old = Dictionary(uniqueKeysWithValues: current.files.map { ($0.path, $0) })
        var targetEntries: [String: (sha256: String, sha1: String?, sha512: String?, size: Int, optional: Bool, source: String, stagedURL: URL?)] = [:]
        for file in package.files {
            let targetURL = try PathSafety.safeJoin(base: instance.gameDirectory, relativePath: file.relativePath)
            if targetURL.path.contains("/../") { throw LauncherError(.pathEscapesRoot, "Unsafe pack path") }
            targetEntries[file.relativePath] = (
                sha256: "", sha1: file.sha1, sha512: file.sha512, size: file.fileSize,
                optional: file.isOptional, source: "modrinth", stagedURL: nil
            )
        }
        for override in package.overrides {
            let targetURL = try PathSafety.safeJoin(base: instance.gameDirectory, relativePath: override.relativePath)
            guard PathSafety.isContainedResolvingSymlinks(targetURL.deletingLastPathComponent(), inBase: instance.gameDirectory) else {
                throw LauncherError(.pathEscapesRoot, "Override path escapes instance")
            }
            let sha = try SHA256Digest.hexDigest(ofFileAt: override.sourceURL)
            targetEntries[override.relativePath] = (
                sha256: sha, sha1: nil, sha512: nil,
                size: (try? fm.attributesOfItem(atPath: override.sourceURL.path)[.size] as? NSNumber)?.intValue ?? 0,
                optional: false, source: "pack-override", stagedURL: override.sourceURL
            )
        }
        let selectedOptional = Set(current.files.map(\.path))
        var changes: [ModpackUpdateFileChange] = []
        for (path, entry) in targetEntries {
            if entry.optional && !selectedOptional.contains(path) { continue }
            let targetURL = try PathSafety.safeJoin(base: instance.gameDirectory, relativePath: path)
            let actualHash = try? SHA256Digest.hexDigest(ofFileAt: targetURL)
            if let existing = old[path] {
                let modified = actualHash != existing.sha256
                let same = (!entry.sha256.isEmpty && entry.sha256 == existing.sha256)
                    || (entry.sha512 != nil && entry.sha512 == existing.sha512)
                    || (entry.sha1 != nil && entry.sha1 == existing.sha1)
                if same { continue }
                changes.append(ModpackUpdateFileChange(
                    kind: modified ? .userModified : .upgraded,
                    path: path,
                    oldSHA256: existing.sha256,
                    newSHA256: entry.sha256.isEmpty ? (entry.sha512 ?? entry.sha1) : entry.sha256,
                    oldSize: nil,
                    newSize: entry.size,
                    userModified: modified,
                    isOptional: entry.optional,
                    reason: modified ? "Local file differs from the managed version" : "New pack version"
                ))
            } else {
                if actualHash != nil {
                    changes.append(ModpackUpdateFileChange(
                        kind: .conflict, path: path, oldSHA256: actualHash, newSHA256: entry.sha256,
                        oldSize: nil, newSize: entry.size, userModified: true, isOptional: entry.optional,
                        reason: "An unmanaged file already exists at this path"
                    ))
                } else {
                    changes.append(ModpackUpdateFileChange(
                        kind: .added, path: path, oldSHA256: nil, newSHA256: entry.sha256,
                        oldSize: nil, newSize: entry.size, userModified: false, isOptional: entry.optional,
                        reason: "New file in pack"
                    ))
                }
            }
        }
        let targetPaths = Set(targetEntries.keys)
        for (path, existing) in old where !targetPaths.contains(path) {
            let targetURL = try PathSafety.safeJoin(base: instance.gameDirectory, relativePath: path)
            let actualHash = try? SHA256Digest.hexDigest(ofFileAt: targetURL)
            let modified = actualHash != existing.sha256
            changes.append(ModpackUpdateFileChange(
                kind: modified ? .userModified : .removed,
                path: path,
                oldSHA256: existing.sha256,
                newSHA256: nil,
                oldSize: nil,
                newSize: nil,
                userModified: modified,
                isOptional: false,
                reason: modified ? "Local file differs from the managed version" : "Removed in new pack version"
            ))
        }
        let loaderKind: String
        let loaderVersion: String?
        switch package.loader {
        case .vanilla: loaderKind = "vanilla"; loaderVersion = nil
        case let .fabric(v): loaderKind = "fabric"; loaderVersion = v
        case let .neoforge(v): loaderKind = "neoforge"; loaderVersion = v
        }
        let archiveURL = target.primaryArchive.flatMap(\.downloadURL)!
        return ModpackUpdatePlan(
            instanceID: instance.id,
            currentVersionID: current.packVersionID ?? current.versionID,
            targetVersionID: target.id,
            targetVersionNumber: target.versionNumber,
            targetMinecraftVersion: package.minecraftVersion,
            targetLoaderKind: loaderKind,
            targetLoaderVersion: loaderVersion,
            requiresMinecraftChange: package.minecraftVersion != current.minecraftVersion,
            requiresLoaderChange: loaderKind != current.loaderKind || loaderVersion != current.loaderVersion,
            changes: changes.sorted { $0.path < $1.path },
            totalDownloadBytes: changes.filter { $0.kind != .removed && $0.kind != .userModified }.reduce(0) { $0 + max(0, $1.newSize ?? 0) },
            archiveURL: archiveURL,
            archiveSHA256: package.archiveSHA256
        )
    }

    private func validate(plan: ModpackUpdatePlan, current: ModpackRecord, instance: Instance) throws {
        guard !plan.requiresMinecraftChange, !plan.requiresLoaderChange else {
            throw LauncherError(.usageError, "The target pack changes Minecraft/Loader; create a new instance instead")
        }
        let volume = try instance.gameDirectory.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]).volumeAvailableCapacityForImportantUsage ?? 0
        let required = Int64(plan.totalDownloadBytes) * 2
        guard volume > required else {
            throw LauncherError(.ioFailure, "Not enough free disk space for the pack update")
        }
        _ = current
    }

    private func stageFiles(
        plan: ModpackUpdatePlan,
        package: MrpackPackage,
        context: Context,
        archive: URL,
        actions: [String: ModpackUpdateAction]
    ) async throws -> [String: URL] {
        var result: [String: URL] = [:]
        _ = archive
        let policy = Set(plan.changes.filter { change in
            guard change.kind != .removed else { return false }
            let action = actions[change.path] ?? defaultAction(for: change)
            return action == .replace
        }.map(\.path))
        for file in package.files where policy.contains(file.relativePath) {
            let destination = try PathSafety.safeJoin(base: context.stagingRoot, relativePath: file.relativePath)
            try fm.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
            let url = file.downloadURL
            guard Self.trustedHosts.contains(url.host ?? "") else {
                throw LauncherError(.invalidMetadata, "Pack file has no trusted URL: \(file.relativePath)")
            }
            try await transport.download(from: url, to: destination)
            let size = (try fm.attributesOfItem(atPath: destination.path)[.size] as? NSNumber)?.intValue ?? -1
            guard size == file.fileSize else { throw LauncherError(.invalidMetadata, "Size mismatch for \(file.relativePath)") }
            if let sha512 = file.sha512 {
                guard try SHA512Digest.hexDigest(ofFileAt: destination) == sha512.lowercased() else {
                    throw LauncherError(.invalidMetadata, "SHA-512 mismatch for \(file.relativePath)")
                }
            } else if let sha1 = file.sha1 {
                guard try SHA1.hexDigest(ofFileAt: destination) == sha1.lowercased() else {
                    throw LauncherError(.invalidMetadata, "SHA-1 mismatch for \(file.relativePath)")
                }
            } else {
                throw LauncherError(.invalidMetadata, "Pack file has no checksum: \(file.relativePath)")
            }
            result[file.relativePath] = destination
        }
        for override in package.overrides where policy.contains(override.relativePath) {
            let destination = try PathSafety.safeJoin(base: context.stagingRoot, relativePath: override.relativePath)
            try fm.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
            try fm.copyItem(at: override.sourceURL, to: destination)
            result[override.relativePath] = destination
        }
        return result
    }

    // MARK: - Transaction

    private func prepareTransaction(
        instance: Instance,
        plan: ModpackUpdatePlan,
        current: ModpackRecord,
        context: Context
    ) throws -> ModpackUpdateTransactionState {
        let state = ModpackUpdateTransactionState(
            id: context.id,
            instanceID: instance.id,
            status: "prepared",
            affectedPaths: plan.changes.map(\.path),
            hadRecord: true
        )
        let recordURL = instance.directory.appendingPathComponent("modpack.json")
        try fm.copyItem(at: recordURL, to: context.backupRoot.appendingPathComponent("modpack.json"))
        for path in plan.changes.map(\.path) {
            let source = try PathSafety.safeJoin(base: instance.gameDirectory, relativePath: path)
            guard fm.fileExists(atPath: source.path) else { continue }
            let backup = try PathSafety.safeJoin(base: context.backupRoot.appendingPathComponent("files", isDirectory: true), relativePath: path)
            try fm.createDirectory(at: backup.deletingLastPathComponent(), withIntermediateDirectories: true)
            try fm.copyItem(at: source, to: backup)
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        try encoder.encode(state).write(to: context.transactionRoot.appendingPathComponent("state.json"), options: [.atomic])
        _ = current
        return state
    }

    private func markCommitted(transaction: ModpackUpdateTransactionState) throws {
        // The caller removes the transaction directory only after the new record and all files
        // have passed verification. No old files are deleted before that point.
        let stateURL = layout.dataRoot
            .appendingPathComponent("modpack-updates", isDirectory: true)
            .appendingPathComponent(try PathSafety.validatedPathComponent(transaction.instanceID), isDirectory: true)
            .appendingPathComponent(transaction.id, isDirectory: true)
            .appendingPathComponent("state.json")
        var committed = transaction
        committed.status = "committed"
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        try encoder.encode(committed).write(to: stateURL, options: [.atomic])
    }

    private func restore(transactionRoot: URL, instance: Instance) throws {
        let stateURL = transactionRoot.appendingPathComponent("state.json")
        guard let data = try? Data(contentsOf: stateURL),
              let state = try? JSONDecoder().decode(ModpackUpdateTransactionState.self, from: data) else {
            return
        }
        for path in state.affectedPaths {
            let target = try PathSafety.safeJoin(base: instance.gameDirectory, relativePath: path)
            if fm.fileExists(atPath: target.path) { try fm.removeItem(at: target) }
            let backup = try? PathSafety.safeJoin(
                base: transactionRoot.appendingPathComponent("backup/files", isDirectory: true),
                relativePath: path
            )
            if let backup, fm.fileExists(atPath: backup.path) {
                try fm.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
                try fm.copyItem(at: backup, to: target)
            }
        }
        if state.hadRecord {
            let recordBackup = transactionRoot.appendingPathComponent("backup/modpack.json")
            let record = instance.directory.appendingPathComponent("modpack.json")
            if fm.fileExists(atPath: recordBackup.path) {
                if fm.fileExists(atPath: record.path) { try fm.removeItem(at: record) }
                try fm.copyItem(at: recordBackup, to: record)
            }
        }
    }

    private func removeManaged(path: String, instance: Instance) throws {
        let target = try PathSafety.safeJoin(base: instance.gameDirectory, relativePath: path)
        guard PathSafety.isContainedResolvingSymlinks(target, inBase: instance.gameDirectory) else {
            throw LauncherError(.pathEscapesRoot, "Managed path escapes instance")
        }
        if fm.fileExists(atPath: target.path) { try fm.removeItem(at: target) }
    }

    private func verify(record: ModpackRecord, instance: Instance) throws {
        for file in record.files {
            let url = try PathSafety.safeJoin(base: instance.gameDirectory, relativePath: file.path)
            guard fm.fileExists(atPath: url.path) else { throw LauncherError(.ioFailure, "Missing updated file \(file.path)") }
            guard try SHA256Digest.hexDigest(ofFileAt: url) == file.sha256 else {
                throw LauncherError(.ioFailure, "Updated file failed verification: \(file.path)")
            }
        }
    }

    private func defaultAction(for change: ModpackUpdateFileChange) -> ModpackUpdateAction {
        switch change.kind {
        case .userModified, .conflict: return .preserve
        case .removed: return .replace
        default: return .replace
        }
    }

    private func ensureNotRunning(_ instanceID: String) throws {
        guard !runtime.isRunning(instanceID: instanceID) else {
            throw LauncherError(.usageError, "The game is running; pack updates are disabled")
        }
    }

    private func loadInstance(_ id: String) throws -> Instance {
        try InstanceRepository(layout: layout).load(id: id)
    }

    private func transactionRoots(instanceID: String) throws -> [URL] {
        let root = layout.dataRoot
            .appendingPathComponent("modpack-updates", isDirectory: true)
            .appendingPathComponent(try PathSafety.validatedPathComponent(instanceID), isDirectory: true)
        guard fm.fileExists(atPath: root.path) else { return [] }
        return try fm.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
    }
}
