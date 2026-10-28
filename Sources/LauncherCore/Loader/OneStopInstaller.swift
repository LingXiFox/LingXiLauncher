import Foundation

public enum InstallLoaderChoice: Sendable, Equatable {
    case vanilla
    case fabric(loaderVersion: String?)

    public var displayName: String {
        switch self {
        case .vanilla: return "Vanilla"
        case let .fabric(version): return version.map { "Fabric \($0)" } ?? "Fabric (latest compatible)"
        }
    }
}

public enum InstallTargetChoice: Sendable, Equatable {
    /// Default and safest mode: the target id must not exist before installation.
    case newInstance(id: String, displayName: String)
    /// Explicit update mode. The caller must present the risk and confirmation before this call.
    case existingInstance(id: String)

    public var isExisting: Bool {
        if case .existingInstance = self { return true }
        return false
    }
}

public struct OneStopInstallRequest: Sendable {
    public let minecraftVersionID: String
    public let loader: InstallLoaderChoice
    public let target: InstallTargetChoice
    public let javaExecutable: URL
    public let sourcePolicy: DownloadSourcePolicy
    public let concurrency: Int

    public init(
        minecraftVersionID: String,
        loader: InstallLoaderChoice,
        target: InstallTargetChoice,
        javaExecutable: URL,
        sourcePolicy: DownloadSourcePolicy = .auto,
        concurrency: Int = 4
    ) {
        self.minecraftVersionID = minecraftVersionID
        self.loader = loader
        self.target = target
        self.javaExecutable = javaExecutable
        self.sourcePolicy = sourcePolicy
        self.concurrency = concurrency
    }
}

public struct OneStopInstallReport: Sendable {
    public let instanceID: String
    public let minecraftVersionID: String
    public let installedVersionID: String
    public let loader: InstallLoaderChoice
    public let gameDirectory: URL
    public let backupManifest: URL?
    public let downloadedFiles: Int
    public let downloadedBytes: Int
}

/// Unified installation service used by the GUI wizard and CLI. The UI never orchestrates
/// downloads, metadata resolution or instance commits itself.
public struct OneStopInstaller: Sendable {
    private let layout: GameDataLayout
    private let transport: any DownloadTransport
    private let mirror: TrustedMirrorConfiguration?

    public init(
        layout: GameDataLayout,
        transport: any DownloadTransport,
        mirror: TrustedMirrorConfiguration? = nil
    ) {
        self.layout = layout
        self.transport = transport
        self.mirror = mirror
    }

    public func listFabricLoaders(for minecraftVersion: String) async throws -> [FabricLoaderVersion] {
        try await FabricInstaller(layout: layout, transport: transport, mirror: mirror)
            .listLoaderVersions(for: minecraftVersion)
    }

    /// Metadata-driven Java requirement, never a launcher-wide hardcoded Java 17.
    public func requiredJava(
        for minecraftVersionID: String,
        loader: InstallLoaderChoice
    ) async throws -> JavaVersionRequirement {
        let resolver = try SourceResolver(policy: .official, mirror: mirror)
        let manifests = ManifestService(transport: transport, layout: layout, sourceResolver: resolver)
        let vanilla = try await manifests.fetchVersionMetadata(
            versionID: minecraftVersionID,
            expectedSHA1: nil
        )
        var major = vanilla.javaRequirement.majorVersion ?? 8
        var component = vanilla.javaRequirement.component
        if case let .fabric(requested) = loader {
            let loaders = try await listFabricLoaders(for: minecraftVersionID)
            let selected = requested.flatMap { value in loaders.first { $0.version == value } }
                ?? loaders.first(where: \.stable)
                ?? loaders.first
            if let minimum = selected?.minimumJavaVersion, minimum > major {
                major = minimum
                component = nil
            }
        }
        return JavaVersionRequirement(component: component, majorVersion: major)
    }

    public func install(
        _ request: OneStopInstallRequest,
        progress: @escaping @Sendable (InstallProgressEvent) -> Void
    ) async throws -> OneStopInstallReport {
        try Task.checkCancellation()
        let registry = InstanceRepository(layout: layout)
        let targetID: String
        let displayName: String
        switch request.target {
        case let .newInstance(id, name):
            targetID = id
            displayName = name
            let directory = try layout.instanceDirectory(id)
            guard !FileManager.default.fileExists(atPath: directory.path) else {
                throw LauncherError(.usageError, "Instance '\(id)' already exists; choose update mode explicitly")
            }
        case let .existingInstance(id):
            targetID = id
            _ = try registry.load(id: id)
            displayName = ""
        }

        switch request.loader {
        case .vanilla:
            return try await installVanilla(
                request,
                targetID: targetID,
                displayName: displayName,
                progress: progress
            )
        case let .fabric(loaderVersion):
            let fabric = FabricInstaller(layout: layout, transport: transport, mirror: mirror)
            let report = try await fabric.install(
                FabricInstallRequest(
                    minecraftVersionID: request.minecraftVersionID,
                    loaderVersion: loaderVersion,
                    instanceID: targetID,
                    displayName: displayName.isEmpty ? nil : displayName,
                    updateExistingInstance: request.target.isExisting,
                    sourcePolicy: request.sourcePolicy,
                    concurrency: request.concurrency,
                    javaExecutable: request.javaExecutable
                ),
                progress: progress
            )
            recordJava(instanceID: report.instanceID, executable: request.javaExecutable)
            return OneStopInstallReport(
                instanceID: report.instanceID,
                minecraftVersionID: request.minecraftVersionID,
                installedVersionID: report.profileID,
                loader: request.loader,
                gameDirectory: report.gameDirectory,
                backupManifest: report.backupManifest,
                downloadedFiles: report.downloadedFiles,
                downloadedBytes: report.downloadedBytes
            )
        }
    }

    private func installVanilla(
        _ request: OneStopInstallRequest,
        targetID: String,
        displayName: String,
        progress: @escaping @Sendable (InstallProgressEvent) -> Void
    ) async throws -> OneStopInstallReport {
        let registry = InstanceRepository(layout: layout)
        let stageID = "vanilla-stage-\(UUID().uuidString.prefix(10).lowercased())"
        defer { try? registry.delete(id: stageID) }
        let vanilla = VanillaInstaller(layout: layout, transport: transport, mirror: mirror)
        let report = try await vanilla.install(
            InstallRequest(
                versionID: request.minecraftVersionID,
                instanceID: stageID,
                displayName: "Vanilla staging",
                sourcePolicy: request.sourcePolicy,
                concurrency: request.concurrency,
                javaExecutable: request.javaExecutable
            ),
            progress: progress
        )
        guard report.isComplete else {
            throw LauncherError(.missingDependency, "Vanilla staging install is incomplete")
        }
        try Task.checkCancellation()
        progress(.phase(.finalizing, "Committing instance \(targetID)"))
        var backup: URL?
        let target: Instance
        switch request.target {
        case .newInstance:
            target = try registry.create(id: targetID, displayName: displayName, versionID: request.minecraftVersionID)
        case .existingInstance:
            backup = try registry.backupManifest(id: targetID)
            target = try registry.assignVersion(id: targetID, versionID: request.minecraftVersionID)
        }
        recordJava(instanceID: target.id, executable: request.javaExecutable)
        return OneStopInstallReport(
            instanceID: target.id,
            minecraftVersionID: request.minecraftVersionID,
            installedVersionID: request.minecraftVersionID,
            loader: .vanilla,
            gameDirectory: target.gameDirectory,
            backupManifest: backup,
            downloadedFiles: report.downloadedFiles,
            downloadedBytes: report.downloadedBytes
        )
    }

    private func recordJava(instanceID: String, executable: URL) {
        guard let runtime = try? JavaRuntimeInspector().inspect(executable: executable) else { return }
        let record = JavaManager(layout: layout).runtimeRecord(for: runtime)
        try? InstanceRepository(layout: layout).setJavaRuntime(id: instanceID, record: record)
    }
}
