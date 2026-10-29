import Foundation

public enum ModInstallPhase: String, Sendable, Equatable {
    case resolving = "resolving"
    case downloading = "downloading"
    case verifying = "verifying"
    case committing = "committing"
    case done = "done"
}

public struct ModInstallProgress: Sendable, Equatable {
    public let phase: ModInstallPhase
    public let message: String
    public let completed: Int
    public let total: Int
    public let currentFile: String?

    public init(phase: ModInstallPhase, message: String, completed: Int, total: Int, currentFile: String? = nil) {
        self.phase = phase
        self.message = message
        self.completed = completed
        self.total = total
        self.currentFile = currentFile
    }
}

public struct ModDependencyInfo: Sendable, Equatable {
    public let projectID: String
    public let title: String
    public let versionID: String?
    public let versionNumber: String?

    public init(projectID: String, title: String, versionID: String?, versionNumber: String?) {
        self.projectID = projectID
        self.title = title
        self.versionID = versionID
        self.versionNumber = versionNumber
    }
}

public struct ModInstallReport: Sendable {
    public let primary: InstalledMod
    public let installed: [InstalledMod]
    public let optionalDependencies: [ModDependencyInfo]
    public let embeddedDependencies: [ModDependencyInfo]
    public let alreadyInstalledDependencies: [String]
    public let downloadedBytes: Int
    public let downloadedFiles: Int
}

public struct ModUpdate: Sendable, Equatable {
    public let projectID: String
    public let title: String
    public let currentVersionID: String?
    public let currentVersionNumber: String?
    public let latestVersionID: String
    public let latestVersionNumber: String
    public let latestFile: ModrinthFile
    public let license: String?
    public let iconURL: String?
    public let latestVersionType: ModrinthVersionType

    public init(
        projectID: String,
        title: String,
        currentVersionID: String?,
        currentVersionNumber: String?,
        latestVersionID: String,
        latestVersionNumber: String,
        latestFile: ModrinthFile,
        license: String?,
        iconURL: String?,
        latestVersionType: ModrinthVersionType = .unknown
    ) {
        self.projectID = projectID
        self.title = title
        self.currentVersionID = currentVersionID
        self.currentVersionNumber = currentVersionNumber
        self.latestVersionID = latestVersionID
        self.latestVersionNumber = latestVersionNumber
        self.latestFile = latestFile
        self.license = license
        self.iconURL = iconURL
        self.latestVersionType = latestVersionType
    }
}

public struct ModInstallRequest: Sendable {
    public let instanceID: String
    public let projectIDOrSlug: String
    /// Nil selects the newest version returned by the filtered Modrinth endpoint.
    public let versionID: String?
    public let includeOptionalDependencies: Bool
    /// Required for an explicit update. Initial installs reject an already-installed project.
    public let allowReplace: Bool

    public init(
        instanceID: String,
        projectIDOrSlug: String,
        versionID: String? = nil,
        includeOptionalDependencies: Bool = false,
        allowReplace: Bool = false
    ) {
        self.instanceID = instanceID
        self.projectIDOrSlug = projectIDOrSlug
        self.versionID = versionID
        self.includeOptionalDependencies = includeOptionalDependencies
        self.allowReplace = allowReplace
    }
}

/// Orchestrates Modrinth browsing, dependency resolution, verification and local mod storage.
/// The GUI only talks to this Core service; it never constructs API URLs or writes mod files.
public struct ModManager: Sendable {
    public let layout: GameDataLayout
    public let client: ModrinthClient
    public let repository: ModRepository
    private let transport: any DownloadTransport
    private let allowedDownloadHosts: Set<String>

    public init(
        layout: GameDataLayout,
        transport: any DownloadTransport = URLSessionTransport(),
        client: ModrinthClient? = nil,
        allowedDownloadHosts: Set<String> = ["cdn.modrinth.com"]
    ) {
        self.layout = layout
        self.transport = transport
        self.client = client ?? ModrinthClient(transport: transport)
        self.repository = ModRepository(layout: layout)
        self.allowedDownloadHosts = Set(allowedDownloadHosts.map { $0.lowercased() })
    }

    public func compatibility(for instance: Instance) throws -> ModCompatibility {
        let compatibility = try ModCompatibilityResolver.resolve(instance: instance, layout: layout)
        guard compatibility.loader == .fabric || compatibility.loader == .neoforge else {
            throw LauncherError(
                .unsupportedVersion,
                "Instance '\(instance.id)' is \(compatibility.loader.rawValue); NeoForge and Fabric mods require a modded instance",
                suggestion: "Install/select a Fabric or NeoForge instance before opening mod management."
            )
        }
        return compatibility
    }

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
                loader: compatibility.loader.rawValue,
                categories: categories,
                sort: sort,
                offset: offset,
                limit: limit
            )
        )
    }

    public func categories() async throws -> [ModrinthCategory] {
        try await client.categories(projectType: "mod")
    }

    public func project(idOrSlug: String) async throws -> ModrinthProject {
        try await client.project(idOrSlug: idOrSlug)
    }

    public func compatibleVersions(instanceID: String, projectID: String) async throws -> [ModrinthVersion] {
        let instance = try loadInstance(instanceID)
        let compatibility = try compatibility(for: instance)
        return try await client.versions(
            projectID: projectID,
            gameVersion: compatibility.gameVersion,
            loader: compatibility.loader.rawValue
        ).filter { $0.isCompatible(gameVersion: compatibility.gameVersion, loader: compatibility.loader.rawValue) }
    }

    public func installed(instanceID: String) throws -> [InstalledMod] {
        let instance = try loadInstance(instanceID)
        return try repository.list(instance: instance)
    }

    @discardableResult
    public func setEnabled(_ enabled: Bool, fileName: String, instanceID: String) throws -> InstalledMod {
        let instance = try loadInstance(instanceID)
        return try repository.setEnabled(enabled, fileName: fileName, instance: instance)
    }

    public func remove(fileName: String, instanceID: String) throws {
        let instance = try loadInstance(instanceID)
        try repository.remove(fileName: fileName, instance: instance)
    }

    // MARK: - Install

    public func install(
        _ request: ModInstallRequest,
        progress: @escaping @Sendable (ModInstallProgress) -> Void
    ) async throws -> ModInstallReport {
        let instance = try loadInstance(request.instanceID)
        let compatibility = try compatibility(for: instance)
        try Task.checkCancellation()

        progress(ModInstallProgress(phase: .resolving, message: "读取 Modrinth 项目", completed: 0, total: 1))
        let project = try await client.project(idOrSlug: request.projectIDOrSlug)
        let versions = try await client.versions(
            projectID: project.id,
            gameVersion: compatibility.gameVersion,
            loader: compatibility.loader.rawValue
        ).filter { $0.isCompatible(gameVersion: compatibility.gameVersion, loader: compatibility.loader.rawValue) }
        guard !versions.isEmpty else {
            throw LauncherError(
                .unsupportedVersion,
                "\(project.title) has no version compatible with Minecraft \(compatibility.gameVersion) / \(compatibility.loader.displayName)",
                suggestion: "Choose another project or switch the instance to a supported \(compatibility.loader.displayName) version."
            )
        }
        let selected: ModrinthVersion
        if let requestedVersion = request.versionID {
            guard let match = versions.first(where: { $0.id == requestedVersion }) else {
                throw LauncherError(.unsupportedVersion, "Selected version \(requestedVersion) is not compatible with this instance")
            }
            selected = match
        } else {
            selected = versions[0]
        }
        guard selected.primaryJar != nil else {
            throw LauncherError(.invalidMetadata, "\(project.title) version \(selected.versionNumber) has no downloadable JAR")
        }

        let records = try repository.list(instance: instance)
        let primaryRecord = records.first { $0.projectID == project.id }
        if let primaryRecord, !request.allowReplace {
            throw LauncherError(
                .usageError,
                "\(project.title) is already installed (\(primaryRecord.versionNumber ?? primaryRecord.fileName))",
                suggestion: "Use 更新 to replace it after downloading and verifying the new file."
            )
        }

        // Resolve required dependencies before downloading anything.
        let dependencyPlan = try await resolveDependencies(
            selected: selected,
            project: project,
            compatibility: compatibility,
            installed: records,
            includeOptional: request.includeOptionalDependencies
        )
        try Task.checkCancellation()

        let allPlans = [(project, selected)] + dependencyPlan.required.map { ($0.project, $0.version) }
        var plansByProject: [String: (ModrinthProject, ModrinthVersion)] = [:]
        for plan in allPlans {
            if let previous = plansByProject[plan.0.id], previous.1.id != plan.1.id {
                throw LauncherError(.usageError, "Conflicting required dependency versions for \(plan.0.title)")
            }
            plansByProject[plan.0.id] = plan
        }
        let plans = Array(plansByProject.values)
        guard let primaryPlan = plans.first(where: { $0.0.id == project.id }) else {
            throw LauncherError(.invalidMetadata, "Primary project disappeared during dependency resolution")
        }

        let staging = repository.stagingDirectory(instance: instance)
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: staging) }

        var staged: [StagedModFile] = []
        var bytes = 0
        let total = plans.count
        for (index, plan) in plans.enumerated() {
            try Task.checkCancellation()
            let (modProject, version) = plan
            guard let file = version.primaryJar, let url = file.downloadURL else {
                throw LauncherError(.invalidMetadata, "\(modProject.title) has no downloadable primary JAR")
            }
            try validateDownloadURL(url, project: modProject.title)
            let fileName = try safeFileName(file.filename)
            let destination = staging.appendingPathComponent(fileName)
            progress(ModInstallProgress(
                phase: .downloading,
                message: "下载 \(modProject.title) \(version.versionNumber)",
                completed: index,
                total: total,
                currentFile: fileName
            ))
            do {
                try await transport.download(from: url, to: destination)
            } catch {
                throw LauncherError(.downloadFailed, "\(modProject.title): \(error.localizedDescription)")
            }
            progress(ModInstallProgress(phase: .verifying, message: "校验 \(fileName)", completed: index, total: total, currentFile: fileName))
            try verify(file: file, at: destination)
            // An explicit update must not silently re-enable a disabled mod. Dependencies
            // that are newly added remain enabled; the primary keeps its previous state.
            let keepDisabled = primaryRecord?.enabled == false && modProject.id == project.id
            let record = InstalledMod(
                projectID: modProject.id,
                slug: modProject.slug,
                title: modProject.title,
                versionID: version.id,
                versionNumber: version.versionNumber,
                fileName: fileName,
                sha1: file.hashes.sha1,
                sha512: file.hashes.sha512,
                enabled: !keepDisabled,
                source: "modrinth",
                license: modProject.license?.displayName,
                iconURL: modProject.iconURL
            )
            staged.append(StagedModFile(temporaryURL: destination, record: record))
            bytes += file.size
        }

        try Task.checkCancellation()
        progress(ModInstallProgress(phase: .committing, message: "提交模组文件", completed: total, total: total))
        let replacingProjectIDs: Set<String> = primaryRecord.map { [$0.projectID ?? project.id] } ?? []
        let replacingFileNames: Set<String> = primaryRecord.map { [$0.fileName] } ?? []
        let committedRecords: [InstalledMod]
        do {
            committedRecords = try repository.commitInstall(
                instance: instance,
                staged: staged,
                replacingProjectIDs: replacingProjectIDs,
                replacingFileNames: replacingFileNames
            )
        } catch {
            throw (error as? LauncherError) ?? LauncherError(.ioFailure, "Cannot commit mods: \(error.localizedDescription)")
        }
        let newKeys = Set(staged.map { $0.record.projectID ?? $0.record.fileName })
        let installedRecords = committedRecords.filter { newKeys.contains($0.projectID ?? $0.fileName) }
        guard let primary = installedRecords.first(where: { $0.projectID == primaryPlan.0.id }) else {
            throw LauncherError(.ioFailure, "Primary mod was not committed")
        }
        progress(ModInstallProgress(phase: .done, message: "安装完成", completed: total, total: total))
        return ModInstallReport(
            primary: primary,
            installed: installedRecords,
            optionalDependencies: dependencyPlan.optional,
            embeddedDependencies: dependencyPlan.embedded,
            alreadyInstalledDependencies: dependencyPlan.alreadyInstalled,
            downloadedBytes: bytes,
            downloadedFiles: staged.count
        )
    }

    // MARK: - Updates

    public func updates(instanceID: String) async throws -> [ModUpdate] {
        let instance = try loadInstance(instanceID)
        let compatibility = try compatibility(for: instance)
        let records = try repository.list(instance: instance)
        var updates: [ModUpdate] = []
        for record in records {
            guard record.source == "modrinth",
                  let projectID = record.projectID,
                  let currentVersionID = record.versionID else { continue }
            let project = try await client.project(idOrSlug: projectID)
            let versions = try await client.versions(
                projectID: project.id,
                gameVersion: compatibility.gameVersion,
                loader: compatibility.loader.rawValue
            ).filter { $0.isCompatible(gameVersion: compatibility.gameVersion, loader: compatibility.loader.rawValue) }
            // The current version must itself be present in the compatible set. If it vanished
            // or is no longer compatible, we cannot make a reliable comparison and deliberately
            // report no update rather than guessing from dates.
            guard let current = versions.first(where: { $0.id == currentVersionID }),
                  let latest = selectUpdate(current: current, from: versions),
                  let file = latest.primaryJar else { continue }
            updates.append(ModUpdate(
                projectID: project.id,
                title: project.title,
                currentVersionID: currentVersionID,
                currentVersionNumber: record.versionNumber,
                latestVersionID: latest.id,
                latestVersionNumber: latest.versionNumber,
                latestFile: file,
                license: project.license?.displayName,
                iconURL: project.iconURL,
                latestVersionType: latest.versionType
            ))
        }
        return updates
    }

    public func fetchIcon(from urlString: String?) async throws -> Data? {
        guard let urlString, let url = URL(string: urlString) else { return nil }
        return try await client.fetchIcon(from: url)
    }

    // MARK: - Dependency resolution

    private struct DependencyPlan {
        var required: [(project: ModrinthProject, version: ModrinthVersion)] = []
        var optional: [ModDependencyInfo] = []
        var embedded: [ModDependencyInfo] = []
        var alreadyInstalled: [String] = []
    }

    private func resolveDependencies(
        selected: ModrinthVersion,
        project: ModrinthProject,
        compatibility: ModCompatibility,
        installed: [InstalledMod],
        includeOptional: Bool
    ) async throws -> DependencyPlan {
        var plan = DependencyPlan()
        var visited: Set<String> = [project.id]
        var resolved: [String: ModrinthVersion] = [project.id: selected]
        var queue: [(ModrinthDependency, String)] = selected.dependencies.map { ($0, project.title) }
        var installedByProject: [String: InstalledMod] = [:]
        for record in installed {
            guard let projectID = record.projectID, installedByProject[projectID] == nil else { continue }
            installedByProject[projectID] = record
        }

        while !queue.isEmpty {
            try Task.checkCancellation()
            let (dependency, parent) = queue.removeFirst()
            switch dependency.type {
            case .incompatible:
                // Modrinth lists incompatible projects/versions as metadata, not as a
                // mandatory dependency. Only an actually active (enabled) installed or
                // planned version that matches the constraint blocks the install.
                if let conflict = activeIncompatibility(
                    dependency,
                    installed: installed,
                    planned: resolved
                ) {
                    throw LauncherError(
                        .usageError,
                        "\(parent) 与已启用的 \(conflict.title) \(conflict.versionNumber ?? conflict.fileName) 不兼容",
                        suggestion: "先禁用或移除冲突模组，或改用与之兼容的版本。"
                    )
                }
            case .embedded:
                if let id = dependency.projectID {
                    plan.embedded.append(ModDependencyInfo(projectID: id, title: id, versionID: dependency.versionID, versionNumber: nil))
                }
            case .optional, .unknown:
                guard includeOptional else {
                    if let id = dependency.projectID {
                        plan.optional.append(ModDependencyInfo(projectID: id, title: id, versionID: dependency.versionID, versionNumber: nil))
                    }
                    continue
                }
                if let id = dependency.projectID {
                    plan.optional.append(ModDependencyInfo(projectID: id, title: id, versionID: dependency.versionID, versionNumber: nil))
                }
            case .required:
                var dependencyProjectID: String
                var dependencyVersion: ModrinthVersion
                if let explicitVersionID = dependency.versionID {
                    let version = try await client.version(id: explicitVersionID)
                    guard version.isCompatible(gameVersion: compatibility.gameVersion, loader: compatibility.loader.rawValue) else {
                        throw LauncherError(.unsupportedVersion, "\(parent) requires an incompatible dependency version \(explicitVersionID)")
                    }
                    dependencyProjectID = version.projectID
                    if let existing = installedByProject[dependencyProjectID] {
                        if existing.versionID == version.id {
                            plan.alreadyInstalled.append(dependencyProjectID)
                            continue
                        }
                        throw LauncherError(
                            .usageError,
                            "\(parent) requires \(dependencyProjectID) \(version.versionNumber), but \(existing.versionNumber ?? existing.fileName) is installed",
                            suggestion: "Update the dependency explicitly before installing the parent mod."
                        )
                    }
                    dependencyVersion = version
                } else if let projectID = dependency.projectID {
                    dependencyProjectID = projectID
                    if let existing = installedByProject[projectID] {
                        plan.alreadyInstalled.append(projectID)
                        _ = existing
                        continue
                    }
                    let dependencyProject = try await client.project(idOrSlug: projectID)
                    let versions = try await client.versions(
                        projectID: dependencyProject.id,
                        gameVersion: compatibility.gameVersion,
                        loader: compatibility.loader.rawValue
                    ).filter { $0.isCompatible(gameVersion: compatibility.gameVersion, loader: compatibility.loader.rawValue) }
                    guard let latest = versions.first else {
                        throw LauncherError(
                            .missingDependency,
                            "Missing required dependency \(dependencyProject.title) for \(parent)",
                            suggestion: "No version of the dependency supports this Minecraft \(compatibility.loader.displayName) combination."
                        )
                    }
                    dependencyProjectID = dependencyProject.id
                    dependencyVersion = latest
                } else if let fileName = dependency.fileName {
                    throw LauncherError(
                        .missingDependency,
                        "\(parent) requires bundled file \(fileName), but Modrinth has no downloadable version id",
                        suggestion: "Install the dependency manually from the project page."
                    )
                } else {
                    throw LauncherError(.missingDependency, "\(parent) has an unresolved required dependency")
                }

                if let previous = resolved[dependencyProjectID] {
                    guard previous.id == dependencyVersion.id else {
                        throw LauncherError(
                            .usageError,
                            "Conflicting required versions for \(dependencyProjectID): \(previous.versionNumber) vs \(dependencyVersion.versionNumber)"
                        )
                    }
                    continue
                }
                resolved[dependencyProjectID] = dependencyVersion
                if visited.insert(dependencyProjectID).inserted {
                    let dependencyProject = try await client.project(idOrSlug: dependencyProjectID)
                    guard let existing = plan.required.first(where: { $0.project.id == dependencyProjectID }) else {
                        plan.required.append((dependencyProject, dependencyVersion))
                        queue.append(contentsOf: dependencyVersion.dependencies.map { ($0, dependencyProject.title) })
                        continue
                    }
                    _ = existing
                }
            }
        }
        return plan
    }

    private func activeIncompatibility(
        _ dependency: ModrinthDependency,
        installed: [InstalledMod],
        planned: [String: ModrinthVersion]
    ) -> InstalledMod? {
        let configuredProject = dependency.projectID
        let configuredVersion = dependency.versionID
        let configuredFile = dependency.fileName
        // A constraint with no target cannot safely identify a conflict. Let it through
        // rather than rejecting an install based on incomplete metadata.
        guard configuredProject != nil || configuredVersion != nil || configuredFile != nil else {
            return nil
        }

        for record in installed where record.enabled {
            guard configuredProject == nil || record.projectID == configuredProject else { continue }
            if let configuredVersion {
                guard record.versionID == configuredVersion else { continue }
            }
            if let configuredFile, record.fileName != configuredFile { continue }
            return record
        }

        for (projectID, version) in planned {
            guard configuredProject == nil || projectID == configuredProject else { continue }
            if let configuredVersion, version.id != configuredVersion { continue }
            if let configuredFile, version.primaryJar?.filename != configuredFile { continue }
            let record = InstalledMod(
                projectID: projectID,
                title: projectID,
                versionID: version.id,
                versionNumber: version.versionNumber,
                fileName: version.primaryJar?.filename ?? version.id,
                enabled: true,
                source: "modrinth"
            )
            return record
        }
        return nil
    }

    private func compareVersionNumbers(_ lhs: String, _ rhs: String) -> Int {
        ModrinthUpdatePolicy.compareVersionNumbers(lhs, rhs)
    }

    private func allowedVersionTypes(for current: ModrinthVersion) -> Set<ModrinthVersionType> {
        ModrinthUpdatePolicy.allowedVersionTypes(for: current.versionType)
    }

    private func selectUpdate(
        current: ModrinthVersion,
        from versions: [ModrinthVersion]
    ) -> ModrinthVersion? {
        ModrinthUpdatePolicy.selectUpdate(current: current, from: versions) { $0.primaryJar }
    }

    // MARK: - Verification / paths

    private func verify(file: ModrinthFile, at url: URL) throws {
        let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
        let actualSize = (attributes?[.size] as? NSNumber)?.intValue
        guard actualSize == file.size else {
            try? FileManager.default.removeItem(at: url)
            throw LauncherError(.sizeMismatch, "\(file.filename): expected \(file.size) bytes, got \(actualSize ?? -1)")
        }
        if let sha512 = file.hashes.sha512, !sha512.isEmpty {
            let actual = try SHA512Digest.hexDigest(ofFileAt: url)
            guard actual.caseInsensitiveCompare(sha512) == .orderedSame else {
                try? FileManager.default.removeItem(at: url)
                throw LauncherError(.hashMismatch, "\(file.filename): SHA-512 mismatch")
            }
        } else if let sha1 = file.hashes.sha1, !sha1.isEmpty {
            let actual = try SHA1.hexDigest(ofFileAt: url)
            guard actual.caseInsensitiveCompare(sha1) == .orderedSame else {
                try? FileManager.default.removeItem(at: url)
                throw LauncherError(.hashMismatch, "\(file.filename): SHA-1 mismatch")
            }
        } else {
            try? FileManager.default.removeItem(at: url)
            throw LauncherError(.invalidMetadata, "\(file.filename) has no published checksum")
        }
    }

    private func validateDownloadURL(_ url: URL, project: String) throws {
        guard url.scheme?.lowercased() == "https",
              let host = url.host?.lowercased(),
              allowedDownloadHosts.contains(host),
              url.user == nil,
              url.password == nil,
              url.port == nil || url.port == 443 else {
            throw LauncherError(
                .invalidMetadata,
                "\(project) file is not hosted on an allowed Modrinth CDN URL",
                suggestion: "Only HTTPS files from cdn.modrinth.com are accepted."
            )
        }
    }

    private func safeFileName(_ raw: String) throws -> String {
        let name = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, name != ".", name != "..",
              !name.contains("/"), !name.contains("\\"), !name.contains("\0"),
              name.lowercased().hasSuffix(".jar") else {
            throw LauncherError(.pathEscapesRoot, "Invalid Modrinth file name '\(raw)'")
        }
        return name
    }

    private func loadInstance(_ id: String) throws -> Instance {
        try InstanceRepository(layout: layout).load(id: id)
    }
}
