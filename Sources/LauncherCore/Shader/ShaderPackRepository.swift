import Foundation

/// Instance-local shader pack storage. Files live in `<gameDir>/shaderpacks/`; provenance lives
/// outside the game directory in `<instance>/shaderpacks.json`, mirroring the existing mod
/// storage boundary. Shader packs are never placed in `mods/`.
struct ShaderPackRepository: Sendable {
    let layout: GameDataLayout
    private var fm: FileManager { FileManager.default }

    init(layout: GameDataLayout) {
        self.layout = layout
    }

    func shaderPacksDirectory(instance: Instance) -> URL {
        instance.gameDirectory.appendingPathComponent("shaderpacks", isDirectory: true)
    }

    func metadataURL(instance: Instance) -> URL {
        instance.directory.appendingPathComponent("shaderpacks.json", isDirectory: false)
    }

    func fileURL(instance: Instance, fileName: String) throws -> URL {
        let component = try Self.validatedFileName(fileName)
        return shaderPacksDirectory(instance: instance).appendingPathComponent(component, isDirectory: false)
    }

    // MARK: - Read / discover

    func list(instance: Instance) throws -> [InstalledShaderPack] {
        let directory = shaderPacksDirectory(instance: instance)
        do {
            try fm.createDirectory(at: directory, withIntermediateDirectories: true)
        } catch {
            throw LauncherError(.ioFailure, "无法创建光影目录: \(error.localizedDescription)")
        }
        var records = try loadRecords(instance: instance)
        var changed = false
        var kept: [InstalledShaderPack] = []
        for var record in records {
            _ = try Self.validatedFileName(record.fileName)
            let file = directory.appendingPathComponent(record.fileName, isDirectory: false)
            guard fm.fileExists(atPath: file.path) else {
                changed = true
                continue
            }
            let size = (try? fm.attributesOfItem(atPath: file.path)[.size] as? NSNumber)?.intValue ?? record.fileSize
            if record.fileSize != size {
                record.fileSize = size
                changed = true
            }
            kept.append(record)
        }
        records = kept

        let entries = (try? fm.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.fileSizeKey, .contentModificationDateKey],
            options: [.skipsHiddenFiles]
        )) ?? []
        var known = Set(records.map(\.fileName))
        for file in entries where file.pathExtension.lowercased() == "zip" {
            let name = file.lastPathComponent
            guard !known.contains(name) else { continue }
            do {
                _ = try Self.validatedFileName(name)
                let attributes = try? fm.attributesOfItem(atPath: file.path)
                let record = InstalledShaderPack(
                    title: file.deletingPathExtension().lastPathComponent,
                    fileName: name,
                    sha1: try? SHA1.hexDigest(ofFileAt: file),
                    sha512: try? SHA512Digest.hexDigest(ofFileAt: file),
                    fileSize: (attributes?[.size] as? NSNumber)?.intValue ?? 0,
                    source: .local,
                    installedAt: (attributes?[.modificationDate] as? Date) ?? Date()
                )
                records.append(record)
                known.insert(name)
                changed = true
            } catch {
                // A file with an unsafe name is never surfaced as manageable; list still works.
                continue
            }
        }

        if changed {
            try saveRecords(records, instance: instance)
        }
        return records.sorted {
            $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending
        }
    }

    func loadRecords(instance: Instance) throws -> [InstalledShaderPack] {
        let url = metadataURL(instance: instance)
        guard fm.fileExists(atPath: url.path) else { return [] }
        do {
            let data = try Data(contentsOf: url)
            return try JSONDecoder().decode([InstalledShaderPack].self, from: data)
        } catch {
            throw LauncherError(
                .invalidMetadata,
                "光影元数据损坏：\(url.path)",
                suggestion: "请先备份该文件，不要直接覆盖；光影 ZIP 本身不会被删除。"
            )
        }
    }

    func saveRecords(_ records: [InstalledShaderPack], instance: Instance) throws {
        do {
            let data = try JSONEncoder().encode(records)
            try fm.createDirectory(at: instance.directory, withIntermediateDirectories: true)
            try data.write(to: metadataURL(instance: instance), options: [.atomic])
        } catch {
            throw LauncherError(.ioFailure, "无法保存光影元数据: \(error.localizedDescription)")
        }
    }

    // MARK: - Commit

    /// Moves a fully verified staged ZIP into the instance and persists metadata. Every file
    /// that is replaced is backed up under a unique name and restored if metadata persistence
    /// fails, so a failed update cannot leave a missing or half-replaced shader pack.
    func commit(
        instance: Instance,
        stagedURL: URL,
        record: InstalledShaderPack,
        replacingFileName: String?,
        allowReplace: Bool
    ) throws -> InstalledShaderPack {
        _ = try Self.validatedFileName(record.fileName)
        let directory = shaderPacksDirectory(instance: instance)
        do {
            try fm.createDirectory(at: directory, withIntermediateDirectories: true)
        } catch {
            throw LauncherError(.ioFailure, "无法创建光影目录: \(error.localizedDescription)")
        }
        let metadataURL = self.metadataURL(instance: instance)
        var records = try loadRecords(instance: instance)
        let oldRecord = records.first { $0.fileName == replacingFileName }
        if let replacingFileName, oldRecord == nil {
            throw LauncherError(
                .usageError,
                "要替换的光影记录不存在：\(replacingFileName)",
                suggestion: "刷新已安装列表后重试，不会覆盖未知文件。"
            )
        }
        if let duplicate = records.first(where: {
            $0.fileName != replacingFileName
                && (($0.sha1 != nil && $0.sha1 == record.sha1) || ($0.sha512 != nil && $0.sha512 == record.sha512))
        }) {
            throw LauncherError(
                .usageError,
                "该光影包已安装为 \(duplicate.fileName)；不会重复复制。",
                suggestion: "请在已安装光影列表中管理它。"
            )
        }
        // A filename is an instance-wide namespace. Only the record explicitly selected for
        // replacement may own the destination; an untracked ZIP or another project's record is
        // never overwritten just because its bytes differ.
        if let conflictingRecord = records.first(where: {
            $0.fileName == record.fileName && $0.fileName != replacingFileName
        }) {
            throw LauncherError(
                .usageError,
                "光影文件名 \(record.fileName) 已被 \(conflictingRecord.title) 使用。",
                suggestion: "请选择更新已有光影，或先移走冲突文件。"
            )
        }
        let destination = directory.appendingPathComponent(record.fileName, isDirectory: false)
        let destinationExisted = fm.fileExists(atPath: destination.path)
        let ownsDestination = oldRecord?.fileName == record.fileName
        if destinationExisted && !ownsDestination {
            throw LauncherError(
                .usageError,
                "目标光影文件已存在且不属于当前更新：\(record.fileName)",
                suggestion: "不会覆盖其他项目或未知来源的文件；请先移走该文件或选择更新已安装光影。"
            )
        }
        if destinationExisted && !allowReplace {
            throw LauncherError(.usageError, "光影文件已存在：\(record.fileName)")
        }

        let backupDirectory = instance.directory.appendingPathComponent(
            ".shaderpacks-backup-\(UUID().uuidString)",
            isDirectory: true
        )
        var backups: [(original: URL, backup: URL)] = []
        var metadataBackup: URL?
        var movedStaged = false
        do {
            try fm.createDirectory(at: backupDirectory, withIntermediateDirectories: true)

            func backup(_ source: URL, name: String) throws {
                guard fm.fileExists(atPath: source.path) else { return }
                let target = backupDirectory.appendingPathComponent(name, isDirectory: false)
                try fm.moveItem(at: source, to: target)
                backups.append((source, target))
            }

            if let oldRecord, oldRecord.fileName != record.fileName {
                try backup(
                    directory.appendingPathComponent(oldRecord.fileName, isDirectory: false),
                    name: "old-\(oldRecord.fileName)"
                )
            }
            try backup(destination, name: "target-\(record.fileName)")
            if fm.fileExists(atPath: metadataURL.path) {
                let target = backupDirectory.appendingPathComponent("shaderpacks.json", isDirectory: false)
                try fm.copyItem(at: metadataURL, to: target)
                metadataBackup = target
            }

            try fm.moveItem(at: stagedURL, to: destination)
            movedStaged = true
            records.removeAll { $0.fileName == replacingFileName || $0.fileName == record.fileName }
            records.append(record)
            try saveRecords(records, instance: instance)
            try? fm.removeItem(at: backupDirectory)
            return record
        } catch {
            if movedStaged {
                try? fm.removeItem(at: destination)
            }
            for item in backups.reversed() {
                try? fm.createDirectory(at: item.original.deletingLastPathComponent(), withIntermediateDirectories: true)
                try? fm.moveItem(at: item.backup, to: item.original)
            }
            if let metadataBackup, fm.fileExists(atPath: metadataBackup.path) {
                try? fm.createDirectory(at: instance.directory, withIntermediateDirectories: true)
                try? fm.removeItem(at: metadataURL)
                try? fm.copyItem(at: metadataBackup, to: metadataURL)
            }
            try? fm.removeItem(at: backupDirectory)
            throw (error as? LauncherError) ?? LauncherError(
                .ioFailure,
                "无法提交光影文件: \(error.localizedDescription)"
            )
        }
    }

    func remove(fileName: String, instance: Instance) throws -> [InstalledShaderPack] {
        let name = try Self.validatedFileName(fileName)
        var records = try loadRecords(instance: instance)
        let file = shaderPacksDirectory(instance: instance).appendingPathComponent(name, isDirectory: false)
        let trash = instance.directory.appendingPathComponent(".shaderpacks-trash-\(UUID().uuidString)-\(name)")
        var moved = false
        if fm.fileExists(atPath: file.path) {
            do {
                try fm.moveItem(at: file, to: trash)
                moved = true
            } catch {
                throw LauncherError(.ioFailure, "无法删除光影文件: \(error.localizedDescription)")
            }
        }
        records.removeAll { $0.fileName == name }
        do {
            try saveRecords(records, instance: instance)
            if moved { try? fm.removeItem(at: trash) }
            return records
        } catch {
            if moved { try? fm.moveItem(at: trash, to: file) }
            throw error
        }
    }

    static func validatedFileName(_ raw: String) throws -> String {
        let name = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, name == (name as NSString).lastPathComponent,
              !name.contains("/"), !name.contains("\\"), !name.contains("\0"),
              name.lowercased().hasSuffix(".zip"),
              name.utf8.count <= 240,
              name != ".", name != ".." else {
            throw LauncherError(.usageError, "光影文件名不安全：\(raw)")
        }
        return name
    }
}
