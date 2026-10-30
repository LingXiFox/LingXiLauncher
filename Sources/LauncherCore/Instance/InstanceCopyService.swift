import Foundation

public struct InstanceCopyOptions: Sendable, Equatable {
    public var includeSaves: Bool

    public init(includeSaves: Bool = false) {
        self.includeSaves = includeSaves
    }

    private func relativePath(of url: URL, under root: URL) throws -> String {
        let base = root.resolvingSymlinksInPath().path
        let child = url.resolvingSymlinksInPath().path
        let prefix = base.hasSuffix("/") ? base : base + "/"
        guard child.hasPrefix(prefix) else {
            throw LauncherError(.pathEscapesRoot, "Copy entry escapes its root: \(url.path)")
        }
        let relative = String(child.dropFirst(prefix.count))
        guard !relative.isEmpty, !relative.hasPrefix("/"), !relative.contains("..") else {
            throw LauncherError(.pathEscapesRoot, "Invalid copy entry path: \(url.path)")
        }
        return relative
    }
}

public struct InstanceCopyReport: Sendable, Equatable {
    public let sourceID: String
    public let instance: Instance
    public let copiedPaths: [String]
    public let includeSaves: Bool

    public init(sourceID: String, instance: Instance, copiedPaths: [String], includeSaves: Bool) {
        self.sourceID = sourceID
        self.instance = instance
        self.copiedPaths = copiedPaths
        self.includeSaves = includeSaves
    }

    private func relativePath(of url: URL, under root: URL) throws -> String {
        let base = root.resolvingSymlinksInPath().path
        let child = url.resolvingSymlinksInPath().path
        let prefix = base.hasSuffix("/") ? base : base + "/"
        guard child.hasPrefix(prefix) else {
            throw LauncherError(.pathEscapesRoot, "Copy entry escapes its root: \(url.path)")
        }
        let relative = String(child.dropFirst(prefix.count))
        guard !relative.isEmpty, !relative.hasPrefix("/"), !relative.contains("..") else {
            throw LauncherError(.pathEscapesRoot, "Invalid copy entry path: \(url.path)")
        }
        return relative
    }
}

public struct InstanceIntegrityIssue: Codable, Sendable, Equatable, Identifiable {
    public let id: String
    public let message: String
    public let severity: String

    public init(id: String, message: String, severity: String) {
        self.id = id
        self.message = message
        self.severity = severity
    }

    private func relativePath(of url: URL, under root: URL) throws -> String {
        let base = root.resolvingSymlinksInPath().path
        let child = url.resolvingSymlinksInPath().path
        let prefix = base.hasSuffix("/") ? base : base + "/"
        guard child.hasPrefix(prefix) else {
            throw LauncherError(.pathEscapesRoot, "Copy entry escapes its root: \(url.path)")
        }
        let relative = String(child.dropFirst(prefix.count))
        guard !relative.isEmpty, !relative.hasPrefix("/"), !relative.contains("..") else {
            throw LauncherError(.pathEscapesRoot, "Invalid copy entry path: \(url.path)")
        }
        return relative
    }
}

public struct InstanceIntegrityReport: Codable, Sendable, Equatable {
    public let instanceID: String
    public let checkedAt: Date
    public let issues: [InstanceIntegrityIssue]

    public var isHealthy: Bool { issues.isEmpty }

    public init(instanceID: String, checkedAt: Date = Date(), issues: [InstanceIntegrityIssue]) {
        self.instanceID = instanceID
        self.checkedAt = checkedAt
        self.issues = issues
    }

    private func relativePath(of url: URL, under root: URL) throws -> String {
        let base = root.resolvingSymlinksInPath().path
        let child = url.resolvingSymlinksInPath().path
        let prefix = base.hasSuffix("/") ? base : base + "/"
        guard child.hasPrefix(prefix) else {
            throw LauncherError(.pathEscapesRoot, "Copy entry escapes its root: \(url.path)")
        }
        let relative = String(child.dropFirst(prefix.count))
        guard !relative.isEmpty, !relative.hasPrefix("/"), !relative.contains("..") else {
            throw LauncherError(.pathEscapesRoot, "Invalid copy entry path: \(url.path)")
        }
        return relative
    }
}

/// Copies only instance-owned data. Shared libraries/assets and global caches are intentionally
/// not duplicated. A failure removes the newly-created instance; the source is never modified.
public struct InstanceCopyService: Sendable {
    public let layout: GameDataLayout
    public let repository: InstanceRepository
    private let runtimeRegistry: InstanceRuntimeChecking

    public init(
        layout: GameDataLayout,
        runtimeRegistry: InstanceRuntimeChecking? = nil
    ) {
        self.layout = layout
        self.repository = InstanceRepository(layout: layout)
        self.runtimeRegistry = runtimeRegistry ?? InstanceRuntimeRegistry(layout: layout)
    }

    @discardableResult
    public func copy(
        instanceID: String,
        displayName: String,
        options: InstanceCopyOptions = InstanceCopyOptions()
    ) throws -> InstanceCopyReport {
        let source = try repository.load(id: instanceID)
        let trimmed = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw LauncherError(.usageError, "Copy display name must not be empty")
        }
        let saves = source.gameDirectory.appendingPathComponent("saves", isDirectory: true)
        let hasSaves = FileManager.default.fileExists(atPath: saves.path)
        if runtimeRegistry.isRunning(instanceID: source.id), options.includeSaves || hasSaves {
            throw LauncherError(
                .launchFailed,
                "Cannot copy an instance with saves while its game is running",
                suggestion: "Quit the game and retry; the source instance was not modified."
            )
        }

        let created = try repository.create(displayName: trimmed, versionID: source.manifest.versionID)
        do {
            _ = try repository.setPerformance(
                id: created.id,
                heapMiB: source.manifest.memoryMiB,
                jvmArguments: source.manifest.jvmArguments
            )
            if let runtime = source.manifest.javaRuntime {
                _ = try repository.setJavaRuntime(id: created.id, record: runtime)
            }
            var copied: [String] = []
            // Enabled mods and shader ZIPs live in the game directory; their provenance records
            // and disabled mod files live in the instance metadata directory.
            for name in ["mods", "shaderpacks", "config", "resourcepacks"] {
                let from = source.gameDirectory.appendingPathComponent(name, isDirectory: true)
                let to = created.gameDirectory.appendingPathComponent(name, isDirectory: true)
                if FileManager.default.fileExists(atPath: from.path) {
                    try copyTree(from, to: to, sourceBase: source.gameDirectory)
                    copied.append(name)
                }
            }
            for name in ["mods.json", "shaderpacks.json", "modpack.json"] {
                let from = source.directory.appendingPathComponent(name, isDirectory: false)
                let to = created.directory.appendingPathComponent(name, isDirectory: false)
                if FileManager.default.fileExists(atPath: from.path) {
                    try copyFile(from, to: to, sourceBase: source.directory)
                    copied.append(name)
                }
            }
            let disabled = source.directory.appendingPathComponent("mods-disabled", isDirectory: true)
            if FileManager.default.fileExists(atPath: disabled.path) {
                try copyTree(
                    disabled,
                    to: created.directory.appendingPathComponent("mods-disabled", isDirectory: true),
                    sourceBase: source.directory
                )
                copied.append("mods-disabled")
            }
            let optionsFile = source.gameDirectory.appendingPathComponent("options.txt", isDirectory: false)
            if FileManager.default.fileExists(atPath: optionsFile.path) {
                try copyFile(
                    optionsFile,
                    to: created.gameDirectory.appendingPathComponent("options.txt", isDirectory: false),
                    sourceBase: source.gameDirectory
                )
                copied.append("options.txt")
            }
            if options.includeSaves, hasSaves {
                try copyTree(saves, to: created.gameDirectory.appendingPathComponent("saves", isDirectory: true), sourceBase: source.gameDirectory)
                copied.append("saves")
            }
            return InstanceCopyReport(sourceID: source.id, instance: try repository.load(id: created.id), copiedPaths: copied, includeSaves: options.includeSaves)
        } catch {
            try? repository.delete(id: created.id)
            if let launcherError = error as? LauncherError { throw launcherError }
            throw LauncherError(.ioFailure, "Instance copy failed and the new instance was removed: \(error.localizedDescription)")
        }
    }

    public func inspect(instanceID: String) throws -> InstanceIntegrityReport {
        let instance = try repository.load(id: instanceID)
        var issues: [InstanceIntegrityIssue] = []
        let fm = FileManager.default
        guard fm.fileExists(atPath: instance.gameDirectory.path) else {
            issues.append(InstanceIntegrityIssue(id: "gameDir", message: "实例游戏目录不存在", severity: "error"))
            return InstanceIntegrityReport(instanceID: instanceID, issues: issues)
        }
        if let versionID = instance.manifest.versionID {
            let versionJSON = try layout.versionJSONURL(versionID)
            if !fm.fileExists(atPath: versionJSON.path) {
                issues.append(InstanceIntegrityIssue(id: "version", message: "版本元数据缺失：\(versionID)", severity: "error"))
            }
        }
        for name in ["mods", "mods-disabled", "shaderpacks", "config", "saves"] {
            let directory = instance.gameDirectory.appendingPathComponent(name, isDirectory: true)
            guard fm.fileExists(atPath: directory.path) else { continue }
            if let enumerator = fm.enumerator(at: directory, includingPropertiesForKeys: [.isSymbolicLinkKey], options: [.skipsHiddenFiles]) {
                for case let url as URL in enumerator {
                    if (try? url.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == true {
                        issues.append(InstanceIntegrityIssue(id: "symlink:\(url.lastPathComponent)", message: "发现指向实例外部的符号链接：\(url.lastPathComponent)", severity: "error"))
                        break
                    }
                }
            }
        }
        return InstanceIntegrityReport(instanceID: instanceID, issues: issues)
    }

    private func copyFile(_ source: URL, to destination: URL, sourceBase: URL) throws {
        guard PathSafety.isContainedResolvingSymlinks(source, inBase: sourceBase) else {
            throw LauncherError(.pathEscapesRoot, "Copy source escapes the instance: \(source.path)")
        }
        let values = try source.resourceValues(forKeys: [.isSymbolicLinkKey, .isRegularFileKey])
        guard values.isSymbolicLink != true, values.isRegularFile == true else {
            throw LauncherError(.ioFailure, "Copy source is not a regular file: \(source.path)")
        }
        try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: source, to: destination)
    }

    private func copyTree(_ source: URL, to destination: URL, sourceBase: URL) throws {
        let fm = FileManager.default
        guard PathSafety.isContainedResolvingSymlinks(source, inBase: sourceBase) else {
            throw LauncherError(.pathEscapesRoot, "Copy source escapes the instance: \(source.path)")
        }
        let keys: [URLResourceKey] = [.isRegularFileKey, .isDirectoryKey, .isSymbolicLinkKey]
        guard let enumerator = fm.enumerator(at: source, includingPropertiesForKeys: keys, options: []) else {
            throw LauncherError(.ioFailure, "Cannot enumerate \(source.path)")
        }
        try fm.createDirectory(at: destination, withIntermediateDirectories: true)
        for case let url as URL in enumerator {
            let values = try url.resourceValues(forKeys: Set(keys))
            guard values.isSymbolicLink != true else {
                throw LauncherError(.pathEscapesRoot, "Refusing to copy symbolic link: \(url.path)")
            }
            guard PathSafety.isContainedResolvingSymlinks(url, inBase: sourceBase) else {
                throw LauncherError(.pathEscapesRoot, "Copy entry escapes the instance: \(url.path)")
            }
            let relative = try relativePath(of: url, under: source)
            let target = destination.appendingPathComponent(relative, isDirectory: values.isDirectory == true)
            if values.isDirectory == true {
                try fm.createDirectory(at: target, withIntermediateDirectories: true)
            } else if values.isRegularFile == true {
                try fm.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
                try fm.copyItem(at: url, to: target)
            }
        }
    }

    private func relativePath(of url: URL, under root: URL) throws -> String {
        let base = root.resolvingSymlinksInPath().path
        let child = url.resolvingSymlinksInPath().path
        let prefix = base.hasSuffix("/") ? base : base + "/"
        guard child.hasPrefix(prefix) else {
            throw LauncherError(.pathEscapesRoot, "Copy entry escapes its root: \(url.path)")
        }
        let relative = String(child.dropFirst(prefix.count))
        guard !relative.isEmpty, !relative.hasPrefix("/"), !relative.contains("..") else {
            throw LauncherError(.pathEscapesRoot, "Invalid copy entry path: \(url.path)")
        }
        return relative
    }
}
