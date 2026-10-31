import Foundation

/// A Fabric Loader version compatible with a concrete Minecraft version.
public struct FabricLoaderVersion: Codable, Sendable, Equatable, Identifiable {
    public let version: String
    public let stable: Bool
    public let minimumJavaVersion: Int?

    public var id: String { version }

    public init(version: String, stable: Bool, minimumJavaVersion: Int? = nil) {
        self.version = version
        self.stable = stable
        self.minimumJavaVersion = minimumJavaVersion
    }
}

public struct FabricInstallRequest: Sendable {
    public let minecraftVersionID: String
    /// Nil selects the newest stable compatible loader.
    public let loaderVersion: String?
    public let instanceID: String
    public let displayName: String?
    /// New-instance installs must not touch an existing instance unless the caller explicitly
    /// selected update mode after presenting a confirmation and backup.
    public let updateExistingInstance: Bool
    public let sourcePolicy: DownloadSourcePolicy
    public let concurrency: Int
    public let javaExecutable: URL

    public init(
        minecraftVersionID: String,
        loaderVersion: String? = nil,
        instanceID: String,
        displayName: String? = nil,
        updateExistingInstance: Bool = false,
        sourcePolicy: DownloadSourcePolicy = .auto,
        concurrency: Int = 4,
        javaExecutable: URL
    ) {
        self.minecraftVersionID = minecraftVersionID
        self.loaderVersion = loaderVersion
        self.instanceID = instanceID
        self.displayName = displayName
        self.updateExistingInstance = updateExistingInstance
        self.sourcePolicy = sourcePolicy
        self.concurrency = concurrency
        self.javaExecutable = javaExecutable
    }
}

public struct FabricInstallReport: Sendable {
    public let profileID: String
    public let minecraftVersionID: String
    public let loaderVersion: String
    public let instanceID: String
    public let gameDirectory: URL
    public let downloadedFiles: Int
    public let downloadedBytes: Int
    public let cacheHits: Int
    public let backupManifest: URL?
}

/// Installs Fabric Loader on top of a vanilla version. Vanilla assets, libraries and the client
/// JAR remain in the shared game root; only the loader profile and its Maven libraries are added.
///
/// Safety model:
/// - all downloads happen before the target instance is created or updated;
/// - the target instance is never used as a staging directory;
/// - an existing target is only updated when explicitly requested, and its instance.json is
///   backed up first;
/// - failures/cancellation remove the temporary staging instance and leave the target untouched.
public struct FabricInstaller: Sendable {
    private let layout: GameDataLayout
    private let transport: any DownloadTransport
    private let mirror: TrustedMirrorConfiguration?
    private let javaInspector: JavaRuntimeInspector

    public init(
        layout: GameDataLayout,
        transport: any DownloadTransport,
        mirror: TrustedMirrorConfiguration? = nil,
        javaInspector: JavaRuntimeInspector = JavaRuntimeInspector()
    ) {
        self.layout = layout
        self.transport = transport
        self.mirror = mirror
        self.javaInspector = javaInspector
    }

    // MARK: - Fabric metadata

    /// Uses Fabric's official compatibility endpoint, which only returns loaders validated
    /// against the requested Minecraft version.
    public func listLoaderVersions(for minecraftVersion: String) async throws -> [FabricLoaderVersion] {
        guard let url = URL(string: "https://meta.fabricmc.net/v2/versions/loader/\(Self.pathComponent(minecraftVersion))") else {
            throw LauncherError(.usageError, "Invalid Minecraft version id '\(minecraftVersion)'")
        }
        let data = try await fetch(url, label: "Fabric loader list")
        let entries: [LoaderEntry]
        do {
            entries = try JSONDecoder().decode([LoaderEntry].self, from: data)
        } catch {
            throw LauncherError(.invalidMetadata, "Fabric loader metadata is invalid: \(error.localizedDescription)")
        }
        let versions = entries.map {
            FabricLoaderVersion(
                version: $0.loader.version,
                stable: $0.loader.stable,
                minimumJavaVersion: $0.launcherMeta?.minJavaVersion
            )
        }
        guard !versions.isEmpty else {
            throw LauncherError(
                .unsupportedVersion,
                "Fabric has no loader compatible with Minecraft \(minecraftVersion)",
                suggestion: "Choose a Minecraft release supported by Fabric."
            )
        }
        return versions.sorted {
            if $0.stable != $1.stable { return $0.stable }
            return $0.version.localizedStandardCompare($1.version) == .orderedDescending
        }
    }

    public func install(
        _ request: FabricInstallRequest,
        progress: @escaping @Sendable (InstallProgressEvent) -> Void
    ) async throws -> FabricInstallReport {
        try Task.checkCancellation()
        let registry = InstanceRepository(layout: layout)
        let targetDirectory = try layout.instanceDirectory(request.instanceID)
        let targetExists = FileManager.default.fileExists(atPath: targetDirectory.path)
        let existingTarget: Instance?
        if targetExists {
            // Load/validate before any network or staging work. A corrupt manifest must fail
            // closed instead of being mistaken for an absent instance.
            existingTarget = try registry.load(id: request.instanceID)
        } else {
            existingTarget = nil
        }
        if targetExists && !request.updateExistingInstance {
            throw LauncherError(
                .usageError,
                "Instance '\(request.instanceID)' already exists; choose update mode explicitly",
                suggestion: "Select “更新现有实例” after reviewing the backup warning, or create a new instance."
            )
        }
        if !targetExists && request.updateExistingInstance {
            throw LauncherError(.missingDependency, "The instance selected for update no longer exists")
        }

        let javaRuntime: JavaRuntime
        do {
            javaRuntime = try javaInspector.inspect(executable: request.javaExecutable)
        } catch {
            throw LauncherError(.javaNotFound, "Fabric installation requires Java: \(JavaRuntimeInspector.describe(error: error))")
        }
        let platform = try PlatformContext.forJVM(javaRuntime)

        progress(.phase(.loaderMetadata, "Querying compatible Fabric Loader versions"))
        let loaders = try await listLoaderVersions(for: request.minecraftVersionID)
        let selectedLoader: FabricLoaderVersion
        if let requested = request.loaderVersion {
            guard let match = loaders.first(where: { $0.version == requested }) else {
                throw LauncherError(
                    .unsupportedVersion,
                    "Fabric Loader \(requested) is not compatible with Minecraft \(request.minecraftVersionID)",
                    suggestion: "Pick a loader version from the compatibility list."
                )
            }
            selectedLoader = match
        } else if let stable = loaders.first(where: \.stable) {
            selectedLoader = stable
        } else {
            selectedLoader = loaders[0]
        }

        let minimumJava = max(
            (try? VersionResolver().resolve(versionID: request.minecraftVersionID, from: layout.gameRoot).javaRequirement.majorVersion) ?? 0,
            selectedLoader.minimumJavaVersion ?? 0
        )
        if minimumJava > 0, javaRuntime.majorVersion < minimumJava {
            throw LauncherError(
                .javaVersionMismatch,
                "Fabric Loader \(selectedLoader.version) requires Java \(minimumJava)+, but \(javaRuntime.displayDescription) was selected"
            )
        }

        let stageID = "fabric-stage-\(UUID().uuidString.prefix(10).lowercased())"
        // Set before calling VanillaInstaller: it may create the staging instance and then fail
        // during a download, in which case the defer must still clean it up.
        let stageCreated = true
        defer {
            if stageCreated { try? registry.delete(id: stageID) }
        }

        try Task.checkCancellation()
        progress(.phase(.manifest, "Installing Minecraft \(request.minecraftVersionID) base files"))
        let vanilla = VanillaInstaller(layout: layout, transport: transport, mirror: mirror)
        let vanillaReport = try await vanilla.install(
            InstallRequest(
                versionID: request.minecraftVersionID,
                instanceID: stageID,
                displayName: "Fabric staging",
                sourcePolicy: request.sourcePolicy,
                concurrency: request.concurrency,
                javaExecutable: request.javaExecutable
            ),
            progress: progress
        )
        guard vanillaReport.isComplete else {
            throw LauncherError(.missingDependency, "Vanilla base installation is incomplete; refusing to install Fabric")
        }
        try Task.checkCancellation()

        progress(.phase(.loaderProfile, "Fetching Fabric profile \(selectedLoader.version)"))
        let profileID = "fabric-loader-\(selectedLoader.version)-\(request.minecraftVersionID)"
        guard let profileURL = URL(string: "https://meta.fabricmc.net/v2/versions/loader/\(Self.pathComponent(request.minecraftVersionID))/\(Self.pathComponent(selectedLoader.version))/profile/json") else {
            throw LauncherError(.usageError, "Invalid Fabric profile request")
        }
        let profileData = try await fetch(profileURL, label: "Fabric profile")
        let profile = try VersionMetadata.decode(from: profileData, context: "Fabric profile \(profileID)")
        guard profile.id == profileID, profile.inheritsFrom == request.minecraftVersionID else {
            throw LauncherError(
                .invalidMetadata,
                "Fabric profile id/parent mismatch: expected \(profileID) inheriting \(request.minecraftVersionID)"
            )
        }
        guard !profile.mainClass.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw LauncherError(.invalidMetadata, "Fabric profile declares no mainClass")
        }
        try writeProfile(profileData, id: profileID)
        let version = try VersionResolver().resolve(versionID: profileID, from: layout.gameRoot)
        guard version.compatibility == .modern else {
            throw LauncherError(.unsupportedVersion, "Fabric profile did not resolve to a modern launch configuration")
        }
        let requiredJava = max(version.javaRequirement.majorVersion ?? 0, selectedLoader.minimumJavaVersion ?? 0)
        if requiredJava > 0, javaRuntime.majorVersion < requiredJava {
            throw LauncherError(
                .javaVersionMismatch,
                "Minecraft + Fabric requires Java \(requiredJava)+, but \(javaRuntime.displayDescription) was selected"
            )
        }

        progress(.phase(.loaderLibraries, "Resolving Fabric libraries"))
        let dependencies = try DependencyResolver(ruleEvaluator: RuleEvaluator())
            .resolve(version: version, layout: layout, platform: platform)
        // All files may already be cached (for example on retry); download only the missing set.
        let sourceResolver = try SourceResolver(policy: request.sourcePolicy, mirror: mirror)
        let tasks = dependencies.missing.map {
            DownloadTask(
                destination: $0.path,
                officialURL: $0.downloadURL,
                sha1: $0.sha1,
                size: $0.size,
                kind: $0.kind
            )
        }
        let downloader = Downloader(
            transport: transport,
            sourceResolver: sourceResolver,
            configuration: DownloadConfiguration(concurrency: request.concurrency)
        )
        progress(.phase(.downloading, "Downloading \(tasks.count) Fabric file(s)"))
        let summary = try await downloader.download(tasks, progress: progress)
        try Task.checkCancellation()
        if !summary.failures.isEmpty {
            let detail = summary.failures.prefix(3).map { "\($0.task.destination.lastPathComponent): \($0.message)" }.joined(separator: " | ")
            throw LauncherError(.downloadFailed, "\(summary.failures.count) Fabric file(s) failed to download: \(detail)")
        }

        let after = try DependencyResolver(ruleEvaluator: RuleEvaluator())
            .resolve(version: version, layout: layout, platform: platform)
        guard after.missing.isEmpty else {
            throw LauncherError(.missingDependency, "Fabric installation is incomplete after download (\(after.missing.count) missing file(s))")
        }

        try Task.checkCancellation()
        progress(.phase(.finalizing, "Committing Fabric instance"))
        let target: Instance
        var backup: URL?
        if let existing = existingTarget {
            guard request.updateExistingInstance else {
                throw LauncherError(.usageError, "Instance appeared during installation; refusing to overwrite it")
            }
            backup = try registry.backupManifest(id: existing.id)
            target = try registry.assignVersion(id: existing.id, versionID: profileID)
        } else {
            target = try registry.create(
                id: request.instanceID,
                displayName: request.displayName ?? request.instanceID,
                versionID: profileID
            )
        }

        return FabricInstallReport(
            profileID: profileID,
            minecraftVersionID: request.minecraftVersionID,
            loaderVersion: selectedLoader.version,
            instanceID: target.id,
            gameDirectory: target.gameDirectory,
            downloadedFiles: summary.downloaded.count,
            downloadedBytes: summary.downloadedBytes,
            cacheHits: summary.cacheHits,
            backupManifest: backup
        )
    }

    // MARK: - Helpers

    private func fetch(_ url: URL, label: String) async throws -> Data {
        do {
            return try await transport.fetch(from: url)
        } catch let error as TransportError {
            throw LauncherError(.downloadFailed, "\(label) failed: \(error.description)")
        } catch {
            throw LauncherError(.downloadFailed, "\(label) failed: \(error.localizedDescription)")
        }
    }

    private func writeProfile(_ data: Data, id: String) throws {
        let destination = try layout.versionJSONURL(id)
        let directory = destination.deletingLastPathComponent()
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let temporary = destination.appendingPathExtension("part-\(UUID().uuidString.prefix(6))")
            try data.write(to: temporary, options: [.atomic])
            if FileManager.default.fileExists(atPath: destination.path) {
                try PlatformRuntime.replacer.replaceItem(at: destination, with: temporary)
            } else {
                try FileManager.default.moveItem(at: temporary, to: destination)
            }
        } catch {
            throw LauncherError(.ioFailure, "Cannot write Fabric profile \(destination.path): \(error.localizedDescription)")
        }
    }

    private static func pathComponent(_ raw: String) -> String {
        raw.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? raw
    }

    private struct LoaderEntry: Decodable {
        struct Loader: Decodable {
            let version: String
            let stable: Bool
        }
        struct LauncherMeta: Decodable {
            let minJavaVersion: Int?
            enum CodingKeys: String, CodingKey {
                case minJavaVersion = "min_java_version"
            }
        }
        let loader: Loader
        let launcherMeta: LauncherMeta?
    }
}

private extension JavaRuntimeInspector {
    static func describe(error: Error) -> String {
        (error as? LauncherError)?.description ?? error.localizedDescription
    }
}
