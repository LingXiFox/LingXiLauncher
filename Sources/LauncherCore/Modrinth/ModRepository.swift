import Foundation

/// A persisted mod record. The file itself lives in `mods/` (enabled) or
/// the instance's `mods-disabled/` directory; the record is never placed inside the game dir.
public struct InstalledMod: Codable, Sendable, Equatable, Identifiable {
    public var projectID: String?
    public var slug: String?
    public var title: String
    public var versionID: String?
    public var versionNumber: String?
    public var fileName: String
    public var sha1: String?
    public var sha512: String?
    public var enabled: Bool
    /// `modrinth` or `local`.
    public var source: String
    public var license: String?
    public var iconURL: String?
    public var installedAt: Date

    public var id: String { projectID ?? sha1 ?? fileName }

    public init(
        projectID: String? = nil,
        slug: String? = nil,
        title: String,
        versionID: String? = nil,
        versionNumber: String? = nil,
        fileName: String,
        sha1: String? = nil,
        sha512: String? = nil,
        enabled: Bool,
        source: String = "local",
        license: String? = nil,
        iconURL: String? = nil,
        installedAt: Date = Date()
    ) {
        self.projectID = projectID
        self.slug = slug
        self.title = title
        self.versionID = versionID
        self.versionNumber = versionNumber
        self.fileName = fileName
        self.sha1 = sha1
        self.sha512 = sha512
        self.enabled = enabled
        self.source = source
        self.license = license
        self.iconURL = iconURL
        self.installedAt = installedAt
    }
}

public struct StagedModFile: Sendable, Equatable {
    public let temporaryURL: URL
    public let record: InstalledMod

    public init(temporaryURL: URL, record: InstalledMod) {
        self.temporaryURL = temporaryURL
        self.record = record
    }
}

/// Local mod storage for one isolated instance. Install files are staged outside `mods/` and
/// only moved in after every download has passed hash/size verification.
public struct ModRepository: Sendable {
    private let layout: GameDataLayout
    private var fm: FileManager { FileManager.default }

    public init(layout: GameDataLayout) {
        self.layout = layout
    }

    public func modsDirectory(instance: Instance) -> URL {
        instance.gameDirectory.appendingPathComponent("mods", isDirectory: true)
    }

    public func disabledDirectory(instance: Instance) -> URL {
        instance.directory.appendingPathComponent("mods-disabled", isDirectory: true)
    }

    public func metadataURL(instance: Instance) -> URL {
        instance.directory.appendingPathComponent("mods.json", isDirectory: false)
    }

    public func stagingDirectory(instance: Instance) -> URL {
        instance.directory.appendingPathComponent("mods-staging-\(UUID().uuidString)", isDirectory: true)
    }

    // MARK: - Read / discover

    public func list(instance: Instance) throws -> [InstalledMod] {
        let mods = modsDirectory(instance: instance)
        let disabled = disabledDirectory(instance: instance)
        try fm.createDirectory(at: mods, withIntermediateDirectories: true)
        var records = try loadRecords(instance: instance)
        var changed = false
        var kept: [InstalledMod] = []
        for var record in records {
            _ = try Self.validatedFileName(record.fileName)
            let enabledURL = mods.appendingPathComponent(record.fileName)
            let disabledURL = disabled.appendingPathComponent(record.fileName)
            let enabledExists = fm.fileExists(atPath: enabledURL.path)
            let disabledExists = fm.fileExists(atPath: disabledURL.path)
            if enabledExists && disabledExists {
                throw LauncherError(.ioFailure, "Mod '\\(record.fileName)' exists in both enabled and disabled directories")
            }
            guard enabledExists || disabledExists else { continue }
            let actualEnabled = enabledExists
            if record.enabled != actualEnabled {
                record.enabled = actualEnabled
                changed = true
            }
            kept.append(record)
        }
        records = kept
        var byName: [String: Int] = [:]
        for (index, record) in records.enumerated() {
            if byName[record.fileName] == nil { byName[record.fileName] = index }
        }

        // Discover jars the user copied into the instance manually. They remain manageable
        // without inventing Modrinth metadata.
        for (directory, enabled) in [(mods, true), (disabled, false)] {
            let entries = (try? fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.fileSizeKey, .contentModificationDateKey])) ?? []
            for file in entries where file.pathExtension.lowercased() == "jar" {
                let name = file.lastPathComponent
                guard byName[name] == nil, !records.contains(where: { $0.fileName == name }) else { continue }
                let attributes = try? fm.attributesOfItem(atPath: file.path)
                let record = InstalledMod(
                    title: name,
                    fileName: name,
                    sha1: try? SHA1.hexDigest(ofFileAt: file),
                    enabled: enabled,
                    source: "local",
                    installedAt: (attributes?[.modificationDate] as? Date) ?? Date()
                )
                records.append(record)
                byName[name] = records.count - 1
                changed = true
            }
        }

        if changed {
            try saveRecords(records, instance: instance)
        }
        return records.sorted { lhs, rhs in
            lhs.title.localizedCaseInsensitiveCompare(rhs.title) == .orderedAscending
        }
    }

    /// Attaches verified Modrinth provenance to an already installed local jar. This is used
    /// after `.mrpack` import: the file bytes are re-hashed and must match the API metadata, so
    /// a stale or forged record can never be promoted to `modrinth` accidentally.
    @discardableResult
    public func attachSource(
        instance: Instance,
        fileName: String,
        projectID: String,
        slug: String?,
        title: String,
        versionID: String,
        versionNumber: String?,
        sha1 expectedSHA1: String?,
        sha512 expectedSHA512: String?,
        license: String?,
        iconURL: String?
    ) throws -> InstalledMod {
        _ = try Self.validatedFileName(fileName)
        guard !projectID.isEmpty, !versionID.isEmpty else {
            throw LauncherError(.invalidMetadata, "Modrinth source identity is incomplete")
        }
        var records = try loadRecords(instance: instance)
        guard let index = records.firstIndex(where: { $0.fileName == fileName }) else {
            throw LauncherError(.missingDependency, "Mod '\(fileName)' is not tracked for this instance")
        }
        let enabledURL = modsDirectory(instance: instance).appendingPathComponent(fileName)
        let disabledURL = disabledDirectory(instance: instance).appendingPathComponent(fileName)
        let fileURL: URL
        let enabled: Bool
        if fm.fileExists(atPath: enabledURL.path) && !fm.fileExists(atPath: disabledURL.path) {
            fileURL = enabledURL
            enabled = true
        } else if fm.fileExists(atPath: disabledURL.path) && !fm.fileExists(atPath: enabledURL.path) {
            fileURL = disabledURL
            enabled = false
        } else {
            throw LauncherError(.ioFailure, "Cannot trace mod '\(fileName)': file is missing or duplicated")
        }

        let actualSHA1 = try SHA1.hexDigest(ofFileAt: fileURL)
        let actualSHA512 = try? SHA512Digest.hexDigest(ofFileAt: fileURL)
        let sha1Matches = expectedSHA1.map { $0.lowercased() == actualSHA1.lowercased() }
        let sha512Matches = expectedSHA512.map { $0.lowercased() == actualSHA512?.lowercased() }
        guard sha1Matches == true || sha512Matches == true else {
            throw LauncherError(.hashMismatch, "Cannot trace mod '\(fileName)': hash no longer matches")
        }

        records[index].projectID = projectID
        records[index].slug = slug
        records[index].title = title
        records[index].versionID = versionID
        records[index].versionNumber = versionNumber
        records[index].sha1 = actualSHA1
        records[index].sha512 = actualSHA512
        records[index].enabled = enabled
        records[index].source = "modrinth"
        records[index].license = license
        records[index].iconURL = iconURL
        try saveRecords(records, instance: instance)
        return records[index]
    }

    // MARK: - Enable / disable / delete

    @discardableResult
    public func setEnabled(_ enabled: Bool, fileName: String, instance: Instance) throws -> InstalledMod {
        var records = try loadRecords(instance: instance)
        guard let index = records.firstIndex(where: { $0.fileName == fileName }) else {
            throw LauncherError(.missingDependency, "Mod '\\(fileName)' is not tracked for this instance")
        }
        let record = records[index]
        let source = record.enabled
            ? modsDirectory(instance: instance).appendingPathComponent(fileName)
            : disabledDirectory(instance: instance).appendingPathComponent(fileName)
        let targetDirectory = enabled ? modsDirectory(instance: instance) : disabledDirectory(instance: instance)
        let target = targetDirectory.appendingPathComponent(fileName)
        guard fm.fileExists(atPath: source.path) else {
            throw LauncherError(.missingDependency, "Mod file is missing: \\(source.path)")
        }
        if source.path == target.path {
            records[index].enabled = enabled
            try saveRecords(records, instance: instance)
            return records[index]
        }
        guard !fm.fileExists(atPath: target.path) else {
            throw LauncherError(.usageError, "Cannot move mod: '\\(fileName)' already exists in the target directory")
        }
        try fm.createDirectory(at: targetDirectory, withIntermediateDirectories: true)
        do {
            try fm.moveItem(at: source, to: target)
            records[index].enabled = enabled
            do {
                try saveRecords(records, instance: instance)
            } catch {
                try? fm.moveItem(at: target, to: source)
                throw error
            }
            return records[index]
        } catch {
            throw (error as? LauncherError) ?? LauncherError(.ioFailure, "Cannot change mod state: \\(error.localizedDescription)")
        }
    }

    public func remove(fileName: String, instance: Instance) throws {
        var records = try loadRecords(instance: instance)
        guard let index = records.firstIndex(where: { $0.fileName == fileName }) else {
            throw LauncherError(.missingDependency, "Mod '\\(fileName)' is not tracked for this instance")
        }
        let enabledURL = modsDirectory(instance: instance).appendingPathComponent(fileName)
        let disabledURL = disabledDirectory(instance: instance).appendingPathComponent(fileName)
        let existing = [enabledURL, disabledURL].first { fm.fileExists(atPath: $0.path) }
        guard let existing else {
            records.remove(at: index)
            try saveRecords(records, instance: instance)
            return
        }
        let trash = existing.deletingLastPathComponent()
            .appendingPathComponent(".delete-\\(UUID().uuidString)-\\(fileName)")
        do {
            try fm.moveItem(at: existing, to: trash)
            records.remove(at: index)
            do {
                try saveRecords(records, instance: instance)
            } catch {
                try? fm.moveItem(at: trash, to: existing)
                throw error
            }
            try? fm.removeItem(at: trash)
        } catch {
            throw (error as? LauncherError) ?? LauncherError(.ioFailure, "Cannot delete mod: \\(error.localizedDescription)")
        }
    }

    // MARK: - Atomic install / update

    /// Commits all staged files after verification. New files are moved into `mods/`; replaced
    /// projects' old files are moved aside. Any failure rolls files back before returning.
    @discardableResult
    public func commitInstall(
        instance: Instance,
        staged: [StagedModFile],
        replacingProjectIDs: Set<String> = [],
        replacingFileNames: Set<String> = []
    ) throws -> [InstalledMod] {
        guard !staged.isEmpty else { return try list(instance: instance) }
        let mods = modsDirectory(instance: instance)
        let disabled = disabledDirectory(instance: instance)
        try fm.createDirectory(at: mods, withIntermediateDirectories: true)
        var records = try loadRecords(instance: instance)
        let oldRecords = records
        var backups: [(original: URL, backup: URL)] = []
        var installed: [URL] = []
        let replacementIDs = replacingProjectIDs
        let replacementNames = replacingFileNames

        // Ensure unique incoming names and validate every source before touching the mods tree.
        var incomingNames = Set<String>()
        for file in staged {
            let name = try Self.validatedFileName(file.record.fileName)
            guard incomingNames.insert(name).inserted else {
                throw LauncherError(.usageError, "Two mod files would use the same name '\\(name)'")
            }
            guard fm.fileExists(atPath: file.temporaryURL.path) else {
                throw LauncherError(.missingDependency, "Staged mod is missing: \\(file.temporaryURL.path)")
            }
        }

        do {
            for file in staged {
                let name = try Self.validatedFileName(file.record.fileName)
                let targetDirectory = file.record.enabled ? mods : disabled
                let otherDirectory = file.record.enabled ? disabled : mods
                try fm.createDirectory(at: targetDirectory, withIntermediateDirectories: true)
                let target = targetDirectory.appendingPathComponent(name)
                let otherTarget = otherDirectory.appendingPathComponent(name)
                let old = records.first(where: {
                    $0.fileName == name || ($0.projectID != nil && $0.projectID == file.record.projectID)
                })
                let shouldReplace = old != nil
                    && (replacementNames.contains(name)
                        || (file.record.projectID != nil && replacementIDs.contains(file.record.projectID!)))
                if fm.fileExists(atPath: target.path) && !shouldReplace {
                    throw LauncherError(.usageError, "A mod already uses the file name '\(name)' in the target state")
                }
                if fm.fileExists(atPath: otherTarget.path) {
                    // A tracked file in the other state was moved above. Anything left is
                    // untracked and must not be shadowed or overwritten by an update.
                    throw LauncherError(.usageError, "A mod already uses the file name '\(name)' in the other state")
                }

                if let old {
                    let oldURL = old.enabled
                        ? mods.appendingPathComponent(old.fileName)
                        : disabled.appendingPathComponent(old.fileName)
                    if old.fileName != name || old.enabled != file.record.enabled {
                        if fm.fileExists(atPath: oldURL.path) {
                            let backup = instance.directory.appendingPathComponent(".mods-backup-\(UUID().uuidString)")
                            try fm.moveItem(at: oldURL, to: backup)
                            backups.append((oldURL, backup))
                        }
                        records.removeAll { $0.fileName == old.fileName }
                    } else if shouldReplace {
                        let backup = instance.directory.appendingPathComponent(".mods-backup-\(UUID().uuidString)")
                        try fm.moveItem(at: target, to: backup)
                        backups.append((target, backup))
                        records.removeAll { $0.fileName == old.fileName }
                    }
                }
                if fm.fileExists(atPath: target.path) {
                    // The old same-state file should have been moved above; a remaining file is
                    // an untracked conflict and must never be overwritten.
                    throw LauncherError(.usageError, "A file already exists at \(target.path)")
                }

                try fm.moveItem(at: file.temporaryURL, to: target)
                installed.append(target)
                records.removeAll { $0.fileName == name || ($0.projectID != nil && $0.projectID == file.record.projectID) }
                records.append(file.record)
            }

            do {
                try saveRecords(records, instance: instance)
            } catch {
                throw error
            }
            for backup in backups { try? fm.removeItem(at: backup.backup) }
            return records.sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
        } catch {
            for target in installed.reversed() { try? fm.removeItem(at: target) }
            for backup in backups.reversed() {
                if fm.fileExists(atPath: backup.backup.path) {
                    try? fm.moveItem(at: backup.backup, to: backup.original)
                }
            }
            try? saveRecords(oldRecords, instance: instance)
            throw (error as? LauncherError) ?? LauncherError(.ioFailure, "Cannot commit mod installation: \\(error.localizedDescription)")
        }
    }

    // MARK: - Helpers

    private static func validatedFileName(_ raw: String) throws -> String {
        let name = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, name != ".", name != "..",
              !name.contains("/"), !name.contains("\\"), !name.contains("\0") else {
            throw LauncherError(.pathEscapesRoot, "Invalid mod file name '\\(raw)'")
        }
        guard name.lowercased().hasSuffix(".jar") else {
            throw LauncherError(.invalidMetadata, "Mod file '\\(name)' is not a JAR")
        }
        return name
    }

    private struct MetadataFile: Codable {
        var version: Int
        var mods: [InstalledMod]
    }

    private func loadRecords(instance: Instance) throws -> [InstalledMod] {
        let url = metadataURL(instance: instance)
        guard fm.fileExists(atPath: url.path) else { return [] }
        do {
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            return try decoder.decode(MetadataFile.self, from: Data(contentsOf: url)).mods
        } catch {
            throw LauncherError(.invalidMetadata, "Cannot read \\(url.path): \\(error.localizedDescription)")
        }
    }

    private func saveRecords(_ records: [InstalledMod], instance: Instance) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        do {
            try fm.createDirectory(at: instance.directory, withIntermediateDirectories: true)
            let data = try encoder.encode(MetadataFile(version: 1, mods: records))
            try data.write(to: metadataURL(instance: instance), options: [.atomic])
        } catch {
            throw LauncherError(.ioFailure, "Cannot write mod metadata: \\(error.localizedDescription)")
        }
    }
}
