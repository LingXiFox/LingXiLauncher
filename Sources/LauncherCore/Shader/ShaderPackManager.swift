import Foundation

/// Modrinth shader-pack browsing, verified installation, local import, updates and Iris activation.
///
/// Shader packs are ZIP archives in the instance-local `shaderpacks/` directory. They are not
/// mods: no shader archive is ever written to `mods/`, and installing one never claims that Iris
/// has enabled it.
public struct ShaderPackManager: Sendable {
    public static let maximumArchiveBytes = 2 * 1024 * 1024 * 1024

    public let layout: GameDataLayout
    public let client: ModrinthClient
    let repository: ShaderPackRepository
    private let transport: any DownloadTransport
    private let allowedDownloadHosts: Set<String>
    private let irisConfiguration: IrisConfigurationStore

    public init(
        layout: GameDataLayout,
        transport: any DownloadTransport = URLSessionTransport(),
        client: ModrinthClient? = nil,
        allowedDownloadHosts: Set<String> = ["cdn.modrinth.com"]
    ) {
        self.layout = layout
        self.transport = transport
        self.client = client ?? ModrinthClient(transport: transport)
        self.repository = ShaderPackRepository(layout: layout)
        self.allowedDownloadHosts = Set(allowedDownloadHosts.map { $0.lowercased() })
        self.irisConfiguration = IrisConfigurationStore()
    }

    // MARK: - Compatibility

    public func compatibility(for instance: Instance) throws -> ShaderCompatibility {
        let base = try ModCompatibilityResolver.resolve(instance: instance, layout: layout)
        guard base.loader == .fabric else {
            throw LauncherError(
                .unsupportedVersion,
                "光影需要 Iris，而 Iris 只能安装在 Fabric 实例上；当前实例是 \(base.loader.rawValue)。",
                suggestion: "请选择 Fabric 实例，或先安装 Fabric Loader。"
            )
        }
        let loaderVersion = Self.fabricLoaderVersion(from: instance.manifest.versionID)
        return ShaderCompatibility(
            instanceID: instance.id,
            versionID: base.versionID,
            gameVersion: base.gameVersion,
            loader: base.loader,
            loaderVersion: loaderVersion
        )
    }

    // MARK: - Browse

    public func search(
        instanceID: String,
        query: String,
        categories: [String] = [],
        sort: ModrinthSort = .relevance,
        offset: Int = 0,
        limit: Int = 20
    ) async throws -> ModrinthSearchResult {
        let instance = try loadInstance(instanceID)
        let compatibility = try compatibility(for: instance)
        return try await client.search(
            ModrinthSearchQuery(
                query: query,
                gameVersion: compatibility.gameVersion,
                categories: categories,
                sort: sort,
                offset: offset,
                limit: limit,
                projectType: "shader",
                includeLoaderFacet: false
            )
        )
    }

    public func categories() async throws -> [ModrinthCategory] {
        try await client.categories(projectType: "shader")
    }

    public func project(idOrSlug: String) async throws -> ModrinthProject {
        let project = try await client.project(idOrSlug: idOrSlug)
        try Self.validateShaderProject(project)
        return project
    }

    public func compatibleVersions(instanceID: String, projectID: String) async throws -> [ModrinthVersion] {
        let instance = try loadInstance(instanceID)
        let compatibility = try compatibility(for: instance)
        return try await client.versions(
            projectID: projectID,
            gameVersion: compatibility.gameVersion,
            loader: nil
        ).filter { $0.isCompatibleForShader(gameVersion: compatibility.gameVersion) }
    }

    public func fetchIcon(from urlString: String?) async throws -> Data? {
        guard let urlString, let url = URL(string: urlString) else { return nil }
        return try await client.fetchIcon(from: url)
    }

    // MARK: - Installed records

    public func installed(instanceID: String) throws -> [InstalledShaderPack] {
        let instance = try loadInstance(instanceID)
        return try repository.list(instance: instance)
    }

    public func remove(fileName: String, instanceID: String) throws {
        let instance = try loadInstance(instanceID)
        _ = try repository.remove(fileName: fileName, instance: instance)
    }

    public func openDirectoryURL(instanceID: String) throws -> URL {
        let instance = try loadInstance(instanceID)
        let directory = repository.shaderPacksDirectory(instance: instance)
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            return directory
        } catch {
            throw LauncherError(.ioFailure, "无法创建光影目录: \(error.localizedDescription)")
        }
    }

    // MARK: - Install / import

    @discardableResult
    public func install(
        instanceID: String,
        projectIDOrSlug: String,
        versionID: String? = nil,
        replacingFileName: String? = nil,
        progress: @escaping @Sendable (ShaderPackProgress) -> Void
    ) async throws -> ShaderPackInstallReport {
        let instance = try loadInstance(instanceID)
        let compatibility = try compatibility(for: instance)
        progress(ShaderPackProgress(phase: .resolving, message: "查询 Modrinth 光影项目", completed: 0, total: 1))
        let project = try await client.project(idOrSlug: projectIDOrSlug)
        try Self.validateShaderProject(project)
        let versions = try await client.versions(
            projectID: project.id,
            gameVersion: compatibility.gameVersion,
            loader: nil
        ).filter { $0.isCompatibleForShader(gameVersion: compatibility.gameVersion) }
        guard !versions.isEmpty else {
            throw LauncherError(
                .unsupportedVersion,
                "\(project.title) 没有适用于 Minecraft \(compatibility.gameVersion) 的光影版本。",
                suggestion: "在 Modrinth 页面确认该光影包是否声明支持此 Minecraft 版本。"
            )
        }
        let selected: ModrinthVersion
        if let versionID {
            guard let match = versions.first(where: { $0.id == versionID }) else {
                throw LauncherError(.unsupportedVersion, "所选光影版本 \(versionID) 不适用于当前实例。")
            }
            selected = match
        } else {
            selected = versions[0]
        }
        guard let file = selected.primaryZip else {
            throw LauncherError(.invalidMetadata, "\(project.title) 的所选版本没有 ZIP 下载文件。")
        }
        try validateDownloadURL(file)
        let fileName = try ShaderPackRepository.validatedFileName(file.filename)
        try Task.checkCancellation()

        let existing = try repository.list(instance: instance)
        if let duplicate = existing.first(where: { $0.projectID == project.id && $0.fileName != replacingFileName }) {
            throw LauncherError(
                .usageError,
                "\(project.title) 已安装为 \(duplicate.versionNumber ?? duplicate.fileName)；不会自动覆盖。",
                suggestion: "请使用更新操作，或先在已安装光影中删除旧版本。"
            )
        }
        if let replacement = replacingFileName {
            guard let old = existing.first(where: { $0.fileName == replacement }) else {
                throw LauncherError(.usageError, "要替换的光影记录不存在：\(replacement)")
            }
            guard old.projectID == nil || old.projectID == project.id else {
                throw LauncherError(.usageError, "不能用一个项目的光影文件替换另一个项目的记录。")
            }
        }

        let staging = instance.directory.appendingPathComponent(".shaderpacks-stage-\(UUID().uuidString)", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        } catch {
            throw LauncherError(.ioFailure, "无法创建光影暂存目录: \(error.localizedDescription)")
        }
        defer { try? FileManager.default.removeItem(at: staging) }
        let staged = staging.appendingPathComponent(fileName, isDirectory: false)
        progress(ShaderPackProgress(phase: .downloading, message: "下载 \(project.title) \(selected.versionNumber)", completed: 0, total: 1, currentFile: fileName))
        do {
            try await transport.download(from: file.downloadURL!, to: staged)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw LauncherError(.downloadFailed, "\(project.title) 下载失败：\(error.localizedDescription)")
        }
        try Task.checkCancellation()
        progress(ShaderPackProgress(phase: .verifying, message: "校验 ZIP 与哈希", completed: 0, total: 1, currentFile: fileName))
        try Self.verify(file: file, at: staged)
        let record = InstalledShaderPack(
            projectID: project.id,
            slug: project.slug,
            title: project.title,
            versionID: selected.id,
            versionNumber: selected.versionNumber,
            fileName: fileName,
            sha1: file.hashes.sha1,
            sha512: file.hashes.sha512,
            fileSize: file.size,
            source: .modrinth,
            license: project.license?.displayName,
            iconURL: project.iconURL
        )
        try Task.checkCancellation()
        progress(ShaderPackProgress(phase: .committing, message: "提交光影文件", completed: 0, total: 1, currentFile: fileName))
        let committed = try repository.commit(
            instance: instance,
            stagedURL: staged,
            record: record,
            replacingFileName: replacingFileName,
            allowReplace: replacingFileName != nil
        )
        progress(ShaderPackProgress(phase: .done, message: "光影包已安装；是否启用取决于 Iris 配置", completed: 1, total: 1, currentFile: fileName))
        return ShaderPackInstallReport(installed: committed, downloadedBytes: file.size, downloadedFiles: 1)
    }

    @discardableResult
    public func importLocal(
        archiveURL: URL,
        instanceID: String,
        progress: @escaping @Sendable (ShaderPackProgress) -> Void
    ) throws -> ShaderPackInstallReport {
        let instance = try loadInstance(instanceID)
        _ = try compatibility(for: instance)
        let source = archiveURL.standardizedFileURL
        guard source.pathExtension.lowercased() == "zip" else {
            throw LauncherError(.usageError, "请选择 .zip 光影包。")
        }
        let attributes: [FileAttributeKey: Any]
        do {
            attributes = try FileManager.default.attributesOfItem(atPath: source.path)
        } catch {
            throw LauncherError(.ioFailure, "无法读取光影 ZIP: \(error.localizedDescription)")
        }
        let size = (attributes[.size] as? NSNumber)?.intValue ?? 0
        guard size > 0, size <= Self.maximumArchiveBytes else {
            throw LauncherError(.sizeMismatch, "光影 ZIP 大小无效或超过 2 GiB。")
        }
        let fileName = try ShaderPackRepository.validatedFileName(source.lastPathComponent)
        try Task.checkCancellation()
        progress(ShaderPackProgress(phase: .verifying, message: "校验本地光影 ZIP", completed: 0, total: 1, currentFile: fileName))
        try Self.validateZIP(at: source)
        let sha1 = try SHA1.hexDigest(ofFileAt: source)
        let sha512 = try SHA512Digest.hexDigest(ofFileAt: source)
        let staging = instance.directory.appendingPathComponent(".shaderpacks-stage-\(UUID().uuidString)", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
            try FileManager.default.copyItem(at: source, to: staging.appendingPathComponent(fileName))
        } catch {
            try? FileManager.default.removeItem(at: staging)
            throw LauncherError(.ioFailure, "无法暂存本地光影 ZIP: \(error.localizedDescription)")
        }
        defer { try? FileManager.default.removeItem(at: staging) }
        let record = InstalledShaderPack(
            title: source.deletingPathExtension().lastPathComponent,
            fileName: fileName,
            sha1: sha1,
            sha512: sha512,
            fileSize: size,
            source: .local
        )
        progress(ShaderPackProgress(phase: .committing, message: "提交本地光影 ZIP", completed: 0, total: 1, currentFile: fileName))
        let committed = try repository.commit(
            instance: instance,
            stagedURL: staging.appendingPathComponent(fileName),
            record: record,
            replacingFileName: nil,
            allowReplace: false
        )
        progress(ShaderPackProgress(phase: .done, message: "本地光影包已导入", completed: 1, total: 1, currentFile: fileName))
        return ShaderPackInstallReport(installed: committed, downloadedBytes: 0, downloadedFiles: 0)
    }

    // MARK: - Updates

    public func updates(instanceID: String) async throws -> [ShaderPackUpdate] {
        let instance = try loadInstance(instanceID)
        let compatibility = try compatibility(for: instance)
        let records = try repository.list(instance: instance)
        var result: [ShaderPackUpdate] = []
        for record in records {
            guard record.source == .modrinth,
                  let projectID = record.projectID,
                  let currentVersionID = record.versionID else { continue }
            let project = try await client.project(idOrSlug: projectID)
            guard project.projectType == nil || project.projectType == "shader" else { continue }
            let versions = try await client.versions(
                projectID: projectID,
                gameVersion: compatibility.gameVersion,
                loader: nil
            ).filter { $0.isCompatibleForShader(gameVersion: compatibility.gameVersion) }
            let latest = versions.max { $0.datePublished < $1.datePublished }
            guard let latest, latest.id != currentVersionID, let file = latest.primaryZip else { continue }
            result.append(ShaderPackUpdate(
                projectID: projectID,
                title: project.title,
                currentVersionID: currentVersionID,
                currentVersionNumber: record.versionNumber,
                latestVersionID: latest.id,
                latestVersionNumber: latest.versionNumber,
                latestFile: file,
                license: project.license?.displayName,
                iconURL: project.iconURL
            ))
        }
        return result
    }

    // MARK: - Iris activation

    /// Reads the actual `config/iris.properties`. Shader-pack installation is never reported as
    /// activation: this only reports enabled when the config and the installed ZIP agree.
    public func activationState(instanceID: String) throws -> ShaderActivationState {
        let instance = try loadInstance(instanceID)
        let records = try repository.list(instance: instance)
        let iris = try irisMod(instance: instance)
        let configURL = irisConfigurationURL(instance: instance)
        guard let iris else {
            return ShaderActivationState(kind: .notInstalled, shaderPack: nil, configURL: configURL, message: "尚未安装 Iris；先完成 Iris + Sodium 配置。")
        }
        guard Self.supportsIrisConfiguration(version: iris.versionNumber) else {
            return ShaderActivationState(kind: .unsupported, shaderPack: nil, configURL: configURL, message: "Iris \(iris.versionNumber ?? "未知版本") 的配置文件未经验证，本启动器不会自动改写；请在游戏内 Iris 设置中启用光影。")
        }
        guard let snapshot = try irisConfiguration.read(configURL) else {
            return ShaderActivationState(kind: .notConfigured, shaderPack: nil, configURL: configURL, message: "Iris 已安装，但还没有配置文件；可在游戏内启用，或安装光影后由启动器写入。")
        }
        guard let pack = snapshot.shaderPack else {
            return ShaderActivationState(kind: .disabled, shaderPack: nil, configURL: configURL, message: "Iris 配置未选择光影包。")
        }
        guard let record = records.first(where: { $0.fileName == pack }) else {
            return ShaderActivationState(kind: .disabled, shaderPack: pack, configURL: configURL, message: "配置引用的光影包不在已安装列表中。")
        }
        guard snapshot.isEnabled else {
            return ShaderActivationState(kind: .disabled, shaderPack: record.title, configURL: configURL, message: "已选择 \(record.title)，但 Iris 光影当前为关闭状态。")
        }
        return ShaderActivationState(kind: .enabled, shaderPack: record.title, configURL: configURL, message: "Iris 配置已启用 \(record.title)；实际渲染效果需进入世界验证。")
    }

    @discardableResult
    public func activate(
        fileName: String,
        instanceID: String,
        gameRunning: Bool
    ) throws -> ShaderActivationResult {
        guard !gameRunning else {
            throw LauncherError(.usageError, "游戏正在运行，不能覆盖 Iris 配置。", suggestion: "退出游戏后重试。")
        }
        let instance = try loadInstance(instanceID)
        _ = try compatibility(for: instance)
        guard let iris = try irisMod(instance: instance) else {
            throw LauncherError(.unsupportedVersion, "尚未安装 Iris，不能写入光影配置。")
        }
        guard Self.supportsIrisConfiguration(version: iris.versionNumber) else {
            throw LauncherError(.unsupportedVersion, "Iris \(iris.versionNumber ?? "未知版本") 的配置格式未经验证，拒绝自动修改。", suggestion: "请在游戏内 Iris 设置中启用光影。")
        }
        let records = try repository.list(instance: instance)
        guard let record = records.first(where: { $0.fileName == fileName }) else {
            throw LauncherError(.usageError, "光影包未安装：\(fileName)")
        }
        let file = try repository.fileURL(instance: instance, fileName: record.fileName)
        guard FileManager.default.fileExists(atPath: file.path) else {
            throw LauncherError(.missingDependency, "光影 ZIP 已丢失：\(fileName)")
        }
        if let expected = record.sha512 {
            let actual = try SHA512Digest.hexDigest(ofFileAt: file)
            guard actual.caseInsensitiveCompare(expected) == .orderedSame else {
                throw LauncherError(.hashMismatch, "光影 ZIP 与安装记录不一致，拒绝启用。")
            }
        } else if let expected = record.sha1 {
            let actual = try SHA1.hexDigest(ofFileAt: file)
            guard actual.caseInsensitiveCompare(expected) == .orderedSame else {
                throw LauncherError(.hashMismatch, "光影 ZIP 与安装记录不一致，拒绝启用。")
            }
        }
        let configURL = irisConfigurationURL(instance: instance)
        let result = try irisConfiguration.apply(shaderPack: record.fileName, enabled: true, to: configURL)
        return ShaderActivationResult(
            configURL: configURL,
            backupURL: result.backup,
            shaderPack: record.title,
            message: "已写入 Iris 配置；仅表示已选择并启用，实际渲染需进入世界验证。"
        )
    }

    @discardableResult
    public func deactivate(instanceID: String, gameRunning: Bool) throws -> ShaderActivationResult {
        guard !gameRunning else {
            throw LauncherError(.usageError, "游戏正在运行，不能覆盖 Iris 配置。", suggestion: "退出游戏后重试。")
        }
        let instance = try loadInstance(instanceID)
        _ = try compatibility(for: instance)
        guard let iris = try irisMod(instance: instance) else {
            throw LauncherError(.unsupportedVersion, "尚未安装 Iris。")
        }
        guard Self.supportsIrisConfiguration(version: iris.versionNumber) else {
            throw LauncherError(.unsupportedVersion, "Iris \(iris.versionNumber ?? "未知版本") 的配置格式未经验证，拒绝自动修改。")
        }
        let configURL = irisConfigurationURL(instance: instance)
        let result = try irisConfiguration.apply(shaderPack: "", enabled: false, to: configURL)
        return ShaderActivationResult(configURL: configURL, backupURL: result.backup, shaderPack: "", message: "已关闭 Iris 光影。")
    }

    // MARK: - Helpers

    func irisMod(instance: Instance) throws -> InstalledMod? {
        let mods = try ModRepository(layout: layout).list(instance: instance)
        return mods.first { mod in
            mod.projectID == GraphicsSetupManager.irisProjectID
                || (mod.slug ?? "").lowercased() == "iris"
        }
    }

    func irisConfigurationURL(instance: Instance) -> URL {
        instance.gameDirectory.appendingPathComponent("config/iris.properties", isDirectory: false)
    }

    static func supportsIrisConfiguration(version: String?) -> Bool {
        guard let version else { return false }
        let components = version.split(whereSeparator: { !$0.isNumber })
        guard components.count >= 2,
              let major = Int(components[0]),
              let minor = Int(components[1]) else { return false }
        return major == 1 && minor == 7
    }

    static func fabricLoaderVersion(from versionID: String?) -> String? {
        guard let versionID else { return nil }
        let prefix = "fabric-loader-"
        guard versionID.hasPrefix(prefix) else { return nil }
        let remainder = versionID.dropFirst(prefix.count)
        // Profile id format: fabric-loader-<loader>-<minecraft>; Minecraft versions can contain
        // dots but not dashes, so the final dash separates the loader version.
        guard let dash = remainder.lastIndex(of: "-") else { return nil }
        return String(remainder[..<dash])
    }

    private func loadInstance(_ id: String) throws -> Instance {
        try InstanceRepository(layout: layout).load(id: id)
    }

    private func validateDownloadURL(_ file: ModrinthFile) throws {
        guard let url = file.downloadURL,
              url.scheme?.lowercased() == "https",
              let host = url.host?.lowercased(),
              allowedDownloadHosts.contains(host),
              url.user == nil, url.password == nil,
              url.path.lowercased().hasSuffix(".zip") else {
            throw LauncherError(.networkFailure, "光影下载地址不是受信任的 HTTPS ZIP 源。")
        }
    }

    static func validateShaderProject(_ project: ModrinthProject) throws {
        guard project.projectType == nil || project.projectType == "shader" else {
            throw LauncherError(.usageError, "“\(project.title)”不是 Modrinth 光影项目。")
        }
    }

    static func verify(file: ModrinthFile, at url: URL) throws {
        let attributes: [FileAttributeKey: Any]
        do {
            attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        } catch {
            throw LauncherError(.missingDependency, "光影下载文件不存在：\(file.filename)")
        }
        let size = (attributes[.size] as? NSNumber)?.intValue ?? 0
        guard size == file.size else {
            try? FileManager.default.removeItem(at: url)
            throw LauncherError(.sizeMismatch, "\(file.filename)：文件大小不匹配")
        }
        guard size > 0, size <= maximumArchiveBytes else {
            throw LauncherError(.sizeMismatch, "\(file.filename)：文件大小超出限制")
        }
        try validateZIP(at: url)
        if let expected = file.hashes.sha512 {
            let actual = try SHA512Digest.hexDigest(ofFileAt: url)
            guard actual.caseInsensitiveCompare(expected) == .orderedSame else {
                try? FileManager.default.removeItem(at: url)
                throw LauncherError(.hashMismatch, "\(file.filename)：SHA-512 校验失败")
            }
        } else if let expected = file.hashes.sha1 {
            let actual = try SHA1.hexDigest(ofFileAt: url)
            guard actual.caseInsensitiveCompare(expected) == .orderedSame else {
                try? FileManager.default.removeItem(at: url)
                throw LauncherError(.hashMismatch, "\(file.filename)：SHA-1 校验失败")
            }
        } else {
            throw LauncherError(.invalidMetadata, "\(file.filename)：下载元数据没有哈希，拒绝安装")
        }
    }

    static func validateZIP(at url: URL) throws {
        guard let handle = try? FileHandle(forReadingFrom: url) else {
            throw LauncherError(.ioFailure, "无法打开光影 ZIP")
        }
        defer { try? handle.close() }
        let header = try? handle.read(upToCount: 4) ?? Data()
        guard let header, header.count == 4,
              header[0] == 0x50, header[1] == 0x4B,
              header[2] == 0x03 || header[2] == 0x05 || header[2] == 0x07,
              header[3] == 0x04 || header[3] == 0x06 || header[3] == 0x08 else {
            throw LauncherError(.invalidMetadata, "文件不是有效的 ZIP 光影包")
        }
    }
}
