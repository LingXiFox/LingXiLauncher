import Foundation

/// State of the Iris/Sodium pair for one Fabric instance.
public struct GraphicsSetupEnvironment: Sendable, Equatable {
    public let instanceID: String
    public let gameVersion: String
    public let loaderVersion: String?
    public let javaDescription: String?
    public let iris: InstalledMod?
    public let sodium: InstalledMod?
    public let recommendedIris: ModrinthVersion?
    public let recommendedSodium: ModrinthVersion?
    public let warnings: [String]

    public init(
        instanceID: String,
        gameVersion: String,
        loaderVersion: String?,
        javaDescription: String?,
        iris: InstalledMod?,
        sodium: InstalledMod?,
        recommendedIris: ModrinthVersion?,
        recommendedSodium: ModrinthVersion?,
        warnings: [String]
    ) {
        self.instanceID = instanceID
        self.gameVersion = gameVersion
        self.loaderVersion = loaderVersion
        self.javaDescription = javaDescription
        self.iris = iris
        self.sodium = sodium
        self.recommendedIris = recommendedIris
        self.recommendedSodium = recommendedSodium
        self.warnings = warnings
    }

    public var isReady: Bool { iris != nil && sodium != nil }
    public var hasUpdate: Bool {
        guard let iris else { return false }
        return recommendedIris.map { $0.id != iris.versionID } ?? false
    }
}

/// A resolved, user-reviewable Iris/Sodium installation plan. Nothing is downloaded until
/// `install` is called; an existing mismatched mod is never replaced without explicit consent.
public struct GraphicsSetupPlan: Sendable, Equatable {
    public let environment: GraphicsSetupEnvironment
    public let irisVersion: ModrinthVersion
    public let sodiumVersion: ModrinthVersion
    public let notes: [String]
    public let requiresReplacement: Bool

    public init(
        environment: GraphicsSetupEnvironment,
        irisVersion: ModrinthVersion,
        sodiumVersion: ModrinthVersion,
        notes: [String],
        requiresReplacement: Bool
    ) {
        self.environment = environment
        self.irisVersion = irisVersion
        self.sodiumVersion = sodiumVersion
        self.notes = notes
        self.requiresReplacement = requiresReplacement
    }
}

public struct GraphicsSetupReport: Sendable, Equatable {
    public let environment: GraphicsSetupEnvironment
    public let installedIris: InstalledMod
    public let installedSodium: InstalledMod
    public let changedProjectIDs: [String]

    public init(
        environment: GraphicsSetupEnvironment,
        installedIris: InstalledMod,
        installedSodium: InstalledMod,
        changedProjectIDs: [String]
    ) {
        self.environment = environment
        self.installedIris = installedIris
        self.installedSodium = installedSodium
        self.changedProjectIDs = changedProjectIDs
    }
}

/// Resolves and installs the Iris + Sodium pair using Modrinth version metadata and the existing
/// `ModManager` download/hash/commit path. It never installs a shader pack and never calls a
/// loader installer: Iris is a graphics mod for Fabric, not a new Minecraft loader.
public struct GraphicsSetupManager: Sendable {
    public static let irisProjectID = "YL57xq9U"
    public static let sodiumProjectID = "AANobbMI"

    public let layout: GameDataLayout
    public let client: ModrinthClient
    private let modManager: ModManager
    private let transport: any DownloadTransport

    public init(
        layout: GameDataLayout,
        transport: any DownloadTransport = URLSessionTransport(),
        client: ModrinthClient? = nil
    ) {
        self.layout = layout
        self.transport = transport
        self.client = client ?? ModrinthClient(transport: transport)
        self.modManager = ModManager(layout: layout, transport: transport, client: self.client)
    }

    public func environment(instanceID: String) async throws -> GraphicsSetupEnvironment {
        let instance = try loadInstance(instanceID)
        let compatibility = try shaderCompatibility(instance: instance)
        let installed = try modManager.installed(instanceID: instanceID)
        let iris = Self.find(Self.irisProjectID, slug: "iris", in: installed)
        let sodium = Self.find(Self.sodiumProjectID, slug: "sodium", in: installed)
        var warnings: [String] = []
        if let iris, iris.enabled == false {
            warnings.append("Iris 已安装但处于禁用状态，请先在模组管理中启用。")
        }
        if let sodium, sodium.enabled == false {
            warnings.append("Sodium 已安装但处于禁用状态，请先在模组管理中启用。")
        }
        let recommended = try await resolveVersions(
            compatibility: compatibility,
            installedIris: iris,
            installedSodium: sodium
        )
        if recommended.notes.isEmpty == false {
            warnings.append(contentsOf: recommended.notes)
        }
        return GraphicsSetupEnvironment(
            instanceID: instanceID,
            gameVersion: compatibility.gameVersion,
            loaderVersion: compatibility.loaderVersion,
            javaDescription: javaDescription(instance),
            iris: iris,
            sodium: sodium,
            recommendedIris: recommended.iris,
            recommendedSodium: recommended.sodium,
            warnings: warnings
        )
    }

    public func plan(instanceID: String) async throws -> GraphicsSetupPlan {
        let instance = try loadInstance(instanceID)
        let compatibility = try shaderCompatibility(instance: instance)
        let installed = try modManager.installed(instanceID: instanceID)
        let iris = Self.find(Self.irisProjectID, slug: "iris", in: installed)
        let sodium = Self.find(Self.sodiumProjectID, slug: "sodium", in: installed)
        let resolved = try await resolveVersions(
            compatibility: compatibility,
            installedIris: iris,
            installedSodium: sodium
        )
        var notes = resolved.notes
        var replacement = false
        if let iris, iris.versionID != resolved.iris.id {
            replacement = true
            notes.append("Iris 当前为 \(iris.versionNumber ?? iris.fileName)，计划使用 \(resolved.iris.versionNumber)。")
        }
        if let sodium, sodium.versionID != resolved.sodium.id {
            replacement = true
            notes.append("Sodium 当前为 \(sodium.versionNumber ?? sodium.fileName)，计划使用 \(resolved.sodium.versionNumber)。")
        }
        if replacement {
            notes.append("需要你确认后才会替换已有模组；不会在未确认时覆盖。")
        }
        let environment = GraphicsSetupEnvironment(
            instanceID: instanceID,
            gameVersion: compatibility.gameVersion,
            loaderVersion: compatibility.loaderVersion,
            javaDescription: javaDescription(instance),
            iris: iris,
            sodium: sodium,
            recommendedIris: resolved.iris,
            recommendedSodium: resolved.sodium,
            warnings: notes
        )
        return GraphicsSetupPlan(
            environment: environment,
            irisVersion: resolved.iris,
            sodiumVersion: resolved.sodium,
            notes: notes,
            requiresReplacement: replacement
        )
    }

    /// Installs the reviewed pair. `allowReplace` must be true when the plan reports
    /// `requiresReplacement`; otherwise the operation fails before downloading anything.
    @discardableResult
    public func install(
        instanceID: String,
        allowReplace: Bool = false,
        progress: @escaping @Sendable (ModInstallProgress) -> Void
    ) async throws -> GraphicsSetupReport {
        _ = try loadInstance(instanceID)
        let plan = try await plan(instanceID: instanceID)
        guard !plan.requiresReplacement || allowReplace else {
            throw LauncherError(
                .usageError,
                "Iris/Sodium 已有不同版本，未自动覆盖。",
                suggestion: "确认计划中的版本变化后再执行更新。"
            )
        }
        let snapshot = try ModsSnapshot(instanceID: instanceID, layout: layout)
        var changed: [String] = []
        do {
            // Sodium first gives Iris a valid dependency target. ModManager still resolves any
            // required dependency declared by the selected Iris version itself.
            if plan.environment.sodium == nil || plan.environment.sodium?.versionID != plan.sodiumVersion.id {
                try Task.checkCancellation()
                _ = try await modManager.install(
                    ModInstallRequest(
                        instanceID: instanceID,
                        projectIDOrSlug: Self.sodiumProjectID,
                        versionID: plan.sodiumVersion.id,
                        allowReplace: plan.environment.sodium != nil
                    ),
                    progress: progress
                )
                changed.append(Self.sodiumProjectID)
            }
            try Task.checkCancellation()
            if plan.environment.iris == nil || plan.environment.iris?.versionID != plan.irisVersion.id {
                _ = try await modManager.install(
                    ModInstallRequest(
                        instanceID: instanceID,
                        projectIDOrSlug: Self.irisProjectID,
                        versionID: plan.irisVersion.id,
                        allowReplace: plan.environment.iris != nil
                    ),
                    progress: progress
                )
                changed.append(Self.irisProjectID)
            }
            let installed = try modManager.installed(instanceID: instanceID)
            guard let iris = Self.find(Self.irisProjectID, slug: "iris", in: installed),
                  let sodium = Self.find(Self.sodiumProjectID, slug: "sodium", in: installed) else {
                throw LauncherError(.ioFailure, "Iris/Sodium 安装后未找到完整记录。")
            }
            let refreshed = try await environment(instanceID: instanceID)
            try snapshot.discard()
            return GraphicsSetupReport(
                environment: refreshed,
                installedIris: iris,
                installedSodium: sodium,
                changedProjectIDs: changed
            )
        } catch {
            do {
                try snapshot.restore()
            } catch {
                throw LauncherError(
                    .ioFailure,
                    "Iris/Sodium 安装失败，且无法完整回滚：\(error.localizedDescription)",
                    suggestion: "请检查实例目录权限和磁盘空间；原有模组文件仍保留在快照目录中。"
                )
            }
            throw (error as? LauncherError) ?? LauncherError(.ioFailure, "Iris/Sodium 安装失败：\(error.localizedDescription)")
        }
    }

    public func remove(instanceID: String) throws {
        let snapshot = try ModsSnapshot(instanceID: instanceID, layout: layout)
        do {
            let installed = try modManager.installed(instanceID: instanceID)
            for mod in installed {
                guard mod.projectID == Self.irisProjectID || mod.projectID == Self.sodiumProjectID else { continue }
                try modManager.remove(fileName: mod.fileName, instanceID: instanceID)
            }
            try snapshot.discard()
        } catch {
            try? snapshot.restore()
            throw error
        }
    }

    // MARK: - Resolution

    private struct Resolved {
        let iris: ModrinthVersion
        let sodium: ModrinthVersion
        var notes: [String]
    }

    private func resolveVersions(
        compatibility: ShaderCompatibility,
        installedIris: InstalledMod?,
        installedSodium: InstalledMod?
    ) async throws -> Resolved {
        let irisVersions = try await client.versions(
            projectID: Self.irisProjectID,
            gameVersion: compatibility.gameVersion,
            loader: compatibility.loader.rawValue
        ).filter { $0.isCompatible(gameVersion: compatibility.gameVersion, loader: compatibility.loader.rawValue) }
        guard let iris = Self.preferredVersion(irisVersions) else {
            throw LauncherError(
                .unsupportedVersion,
                "Iris 没有适用于 Minecraft \(compatibility.gameVersion) / \(compatibility.loader.rawValue) 的版本。",
                suggestion: "请确认该 Minecraft 版本有 Iris/Sodium 的 Modrinth 构建。"
            )
        }
        var notes: [String] = []
        var sodium: ModrinthVersion?
        if let dependency = iris.dependencies.first(where: {
            $0.type == .required && $0.projectID == Self.sodiumProjectID
        }) {
            if let versionID = dependency.versionID {
                let pinned = try await client.version(id: versionID)
                guard pinned.projectID == Self.sodiumProjectID,
                      pinned.isCompatible(gameVersion: compatibility.gameVersion, loader: compatibility.loader.rawValue) else {
                    throw LauncherError(.unsupportedVersion, "Iris \(iris.versionNumber) 所需的 Sodium 版本不适用于当前实例。")
                }
                sodium = pinned
                notes.append("Iris \(iris.versionNumber) 的元数据固定依赖 Sodium \(pinned.versionNumber)。")
            } else {
                notes.append("Iris \(iris.versionNumber) 声明需要 Sodium，但未固定具体版本；将选择最新的兼容版本。")
            }
        }
        if sodium == nil {
            let versions = try await client.versions(
                projectID: Self.sodiumProjectID,
                gameVersion: compatibility.gameVersion,
                loader: compatibility.loader.rawValue
            ).filter { $0.isCompatible(gameVersion: compatibility.gameVersion, loader: compatibility.loader.rawValue) }
            sodium = Self.preferredVersion(versions)
        }
        guard let sodium else {
            throw LauncherError(
                .unsupportedVersion,
                "Sodium 没有适用于 Minecraft \(compatibility.gameVersion) / \(compatibility.loader.rawValue) 的版本。"
            )
        }
        if let installedIris, installedIris.versionID == iris.id,
           let installedSodium, installedSodium.versionID == sodium.id {
            notes.append("Iris 与 Sodium 已是目标版本。")
        }
        return Resolved(iris: iris, sodium: sodium, notes: notes)
    }

    /// Newest release wins; beta/alpha are used only when no release exists. Modrinth usually
    /// returns newest-first, but this makes the preference explicit instead of relying on it.
    static func preferredVersion(_ versions: [ModrinthVersion]) -> ModrinthVersion? {
        versions.first(where: { $0.versionType == .release }) ?? versions.first
    }

    static func find(_ projectID: String, slug: String, in mods: [InstalledMod]) -> InstalledMod? {
        mods.first {
            $0.projectID == projectID || ($0.slug ?? "").lowercased() == slug
        }
    }

    private func shaderCompatibility(instance: Instance) throws -> ShaderCompatibility {
        try ShaderPackManager(layout: layout, transport: transport).compatibility(for: instance)
    }

    private func loadInstance(_ id: String) throws -> Instance {
        try InstanceRepository(layout: layout).load(id: id)
    }

    private func javaDescription(_ instance: Instance) -> String? {
        guard let record = instance.manifest.javaRuntime else { return nil }
        return "\(record.source) · \(record.version)"
    }

}

/// A full, instance-local snapshot of mod files and their metadata. `ModManager` replaces
/// individual files transactionally, but a multi-mod graphics setup needs a single rollback
/// boundary: a failure after Sodium commits but before Iris does must restore both.
private struct ModsSnapshot {
    private let instance: Instance
    private let root: URL
    private let hadMods: Bool
    private let hadDisabled: Bool
    private let hadMetadata: Bool
    private var fileManager: FileManager { FileManager.default }

    init(instanceID: String, layout: GameDataLayout) throws {
        let instance = try InstanceRepository(layout: layout).load(id: instanceID)
        let repository = ModRepository(layout: layout)
        let root = instance.directory.appendingPathComponent(
            ".mods-snapshot-\(UUID().uuidString)",
            isDirectory: true
        )
        let mods = repository.modsDirectory(instance: instance)
        let disabled = repository.disabledDirectory(instance: instance)
        let metadata = repository.metadataURL(instance: instance)
        do {
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            if FileManager.default.fileExists(atPath: mods.path) {
                try FileManager.default.copyItem(at: mods, to: root.appendingPathComponent("mods", isDirectory: true))
            }
            if FileManager.default.fileExists(atPath: disabled.path) {
                try FileManager.default.copyItem(at: disabled, to: root.appendingPathComponent("mods-disabled", isDirectory: true))
            }
            if FileManager.default.fileExists(atPath: metadata.path) {
                try FileManager.default.copyItem(at: metadata, to: root.appendingPathComponent("mods.json", isDirectory: false))
            }
        } catch {
            try? FileManager.default.removeItem(at: root)
            throw LauncherError(.ioFailure, "无法创建模组事务快照：\(error.localizedDescription)")
        }
        self.instance = instance
        self.root = root
        self.hadMods = FileManager.default.fileExists(atPath: root.appendingPathComponent("mods").path)
        self.hadDisabled = FileManager.default.fileExists(atPath: root.appendingPathComponent("mods-disabled").path)
        self.hadMetadata = FileManager.default.fileExists(atPath: root.appendingPathComponent("mods.json").path)
    }

    func restore() throws {
        let repository = ModRepository(layout: GameDataLayout(
            gameRoot: instance.gameDirectory,
            dataRoot: instance.directory
        ))
        let mods = instance.gameDirectory.appendingPathComponent("mods", isDirectory: true)
        let disabled = instance.directory.appendingPathComponent("mods-disabled", isDirectory: true)
        let metadata = instance.directory.appendingPathComponent("mods.json", isDirectory: false)
        _ = repository
        if fileManager.fileExists(atPath: mods.path) { try fileManager.removeItem(at: mods) }
        if fileManager.fileExists(atPath: disabled.path) { try fileManager.removeItem(at: disabled) }
        if fileManager.fileExists(atPath: metadata.path) { try fileManager.removeItem(at: metadata) }
        if hadMods {
            try fileManager.copyItem(at: root.appendingPathComponent("mods"), to: mods)
        }
        if hadDisabled {
            try fileManager.copyItem(at: root.appendingPathComponent("mods-disabled"), to: disabled)
        }
        if hadMetadata {
            try fileManager.copyItem(at: root.appendingPathComponent("mods.json"), to: metadata)
        }
        try? fileManager.removeItem(at: root)
    }

    func discard() throws {
        if fileManager.fileExists(atPath: root.path) {
            try fileManager.removeItem(at: root)
        }
    }
}
