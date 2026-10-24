import Foundation

/// Parameters for a vanilla installation.
public struct InstallRequest: Sendable {
    public let versionID: String
    /// Stable instance id (also used as the display name unless `displayName` is set).
    public let instanceID: String
    public let displayName: String?
    public let sourcePolicy: DownloadSourcePolicy
    public let concurrency: Int
    /// Optional Java executable used only for a compatibility check after installation.
    public let javaExecutable: URL?

    public init(
        versionID: String,
        instanceID: String,
        displayName: String? = nil,
        sourcePolicy: DownloadSourcePolicy = .auto,
        concurrency: Int = 4,
        javaExecutable: URL? = nil
    ) {
        self.versionID = versionID
        self.instanceID = instanceID
        self.displayName = displayName
        self.sourcePolicy = sourcePolicy
        self.concurrency = concurrency
        self.javaExecutable = javaExecutable
    }
}

/// End-to-end vanilla installer: manifest → version metadata → dependencies → downloads →
/// native extraction → instance.json.
///
/// Deliberately independent of any account: downloading never requires a Microsoft login, and a
/// downloaded game is not a licence. Java installation is out of scope (the report includes a
/// compatibility check only).
public struct VanillaInstaller: Sendable {
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

    // MARK: - Version listing

    public func listVersions(
        type: VersionManifest.Entry.Kind?,
        policy: DownloadSourcePolicy
    ) async throws -> [VersionManifest.Entry] {
        let sourceResolver = try SourceResolver(policy: policy, mirror: mirror)
        let service = ManifestService(transport: transport, layout: layout, sourceResolver: sourceResolver)
        let manifest = try await service.fetchManifest()
        guard let type else { return manifest.versions }
        return manifest.versions.filter { $0.type == type }
    }

    // MARK: - Install

    public func install(
        _ request: InstallRequest,
        progress: @escaping @Sendable (InstallProgressEvent) -> Void
    ) async throws -> InstallReport {
        let sourceResolver = try SourceResolver(policy: request.sourcePolicy, mirror: mirror)
        let manifestService = ManifestService(transport: transport, layout: layout, sourceResolver: sourceResolver)
        let platform = try PlatformContext.current()
        let dependencyResolver = DependencyResolver(ruleEvaluator: RuleEvaluator())
        let registry = InstanceRepository(layout: layout)

        progress(.phase(.manifest, "Fetching the Mojang version manifest"))
        let manifest = try await manifestService.fetchManifest()
        guard let entry = manifest.entry(for: request.versionID) else {
            throw LauncherError(
                .missingDependency,
                "Version '\(request.versionID)' is not in the Mojang version manifest",
                suggestion: "Run `lingxi version list --type release` to choose an existing version."
            )
        }

        progress(.phase(.versionMetadata, "Fetching metadata for Minecraft \(request.versionID)"))
        let version = try await manifestService.fetchVersionMetadata(
            versionID: request.versionID,
            expectedSHA1: entry.sha1
        )

        progress(.phase(.assetIndex, "Fetching asset index \(version.assetIndexID)"))
        var assetIndex: AssetIndexDocument?
        if version.assetIndex != nil {
            assetIndex = try await manifestService.fetchAssetIndex(for: version)
        }

        let dependencies = try dependencyResolver.resolve(version: version, layout: layout, platform: platform)
        var diagnostics = dependencies.diagnostics

        if assetIndex?.virtual == true || assetIndex?.mapToResources == true {
            diagnostics.append(.warning(
                .unsupportedVersion,
                "Version \(version.id) uses a legacy virtual asset index; asset objects are downloaded but not mapped into resources/",
                suggestion: "Legacy asset trees are not supported yet; the game may miss sounds or language files."
            ))
        }

        var tasks = dependencies.missing.map {
            DownloadTask(
                destination: $0.path,
                officialURL: $0.downloadURL,
                sha1: $0.sha1,
                size: $0.size,
                kind: $0.kind
            )
        }

        var assetObjectCount = 0
        if let assetIndex {
            let objects = assetIndex.uniqueObjects()
            assetObjectCount = objects.count
            for object in objects {
                let destination = try layout.assetObjectURL(sha1: object.hash)
                guard let url = Self.assetObjectURL(hash: object.hash) else { continue }
                tasks.append(DownloadTask(
                    destination: destination,
                    officialURL: url,
                    sha1: object.hash,
                    size: object.size,
                    kind: .assetObject
                ))
            }
        }

        let downloader = Downloader(
            transport: transport,
            sourceResolver: sourceResolver,
            configuration: DownloadConfiguration(concurrency: request.concurrency)
        )
        progress(.phase(.downloading, "Downloading \(tasks.count) file(s) via \(request.sourcePolicy.displayName)"))
        let summary = try await downloader.download(tasks, progress: progress)

        if !summary.failures.isEmpty {
            let examples = summary.failures.prefix(3).map { "\($0.task.destination.lastPathComponent): \($0.message)" }
            throw LauncherError(
                .downloadFailed,
                "\(summary.failures.count) of \(tasks.count) file(s) failed to download",
                suggestion: "Retry the install (already verified files are reused). First failures — " + examples.joined(separator: " | ")
            )
        }

        // Legacy natives: extract into the version+arch scoped cache and rebuild it from scratch
        // so a stale extraction from another Java architecture can never be reused.
        progress(.phase(.extractingNatives, "Extracting native libraries"))
        let nativesDirectory = try layout.nativesDirectory(versionID: version.id, architecture: platform.architecture)
        try? FileManager.default.removeItem(at: nativesDirectory)
        try FileManager.default.createDirectory(at: nativesDirectory, withIntermediateDirectories: true)
        var extractedEntries = 0
        for native in dependencies.legacyNatives {
            guard FileManager.default.fileExists(atPath: native.file.path.path) else {
                throw LauncherError(
                    .missingDependency,
                    "Native archive is missing after download: \(native.file.path.path)"
                )
            }
            let extracted = try SafeZipExtractor.extract(
                archive: native.file.path,
                into: nativesDirectory,
                excluding: native.extractExclude
            )
            extractedEntries += extracted.count
        }

        progress(.phase(.finalizing, "Finalising instance \(request.instanceID)"))
        let instance: Instance
        if let existing = try? registry.load(id: request.instanceID) {
            instance = existing.manifest.versionID == version.id
                ? existing
                : try registry.assignVersion(id: request.instanceID, versionID: version.id)
        } else {
            instance = try registry.create(
                id: request.instanceID,
                displayName: request.displayName ?? request.instanceID,
                versionID: version.id
            )
        }

        // Post-install dependency check: every file the launch plan needs must now exist with the
        // expected size. (Full SHA-1 verification is `lingxi verify`.)
        let after = try dependencyResolver.resolve(version: version, layout: layout, platform: platform)
        diagnostics.append(contentsOf: after.diagnostics)
        diagnostics.append(contentsOf: javaDiagnostics(for: version, executable: request.javaExecutable))

        return InstallReport(
            versionID: version.id,
            instanceID: instance.id,
            gameDirectory: instance.gameDirectory,
            downloadedFiles: summary.downloaded.count,
            downloadedBytes: summary.downloadedBytes,
            cacheHits: summary.cacheHits,
            assetObjectCount: assetObjectCount,
            extractedNatives: extractedEntries,
            missingAfterInstall: after.missing,
            diagnostics: diagnostics,
            javaRequirement: version.javaRequirement,
            sourcePolicy: request.sourcePolicy
        )
    }

    // MARK: - Helpers

    /// Official asset object location. The hash is split into its two-character prefix directory.
    static func assetObjectURL(hash: String) -> URL? {
        let normalized = hash.lowercased()
        guard normalized.count >= 2 else { return nil }
        return URL(string: "https://resources.download.minecraft.net/\(normalized.prefix(2))/\(normalized)")
    }

    private func javaDiagnostics(
        for version: ResolvedVersion,
        executable: URL?
    ) -> [LaunchDiagnostic] {
        guard let required = version.javaRequirement.majorVersion else { return [] }
        // Downloading never requires Java, so the compatibility check only runs when the caller
        // explicitly names a runtime. `lingxi doctor` performs full Java discovery.
        guard let executable else {
            return [.info("Minecraft \(version.id) requires Java \(required)+; run `lingxi doctor` to check the local runtime.")]
        }
        guard let runtime = try? javaInspector.inspect(executable: executable) else {
            return [.warning(
                .javaNotFound,
                "Minecraft \(version.id) requires Java \(required)+ but '\(executable.path)' is not a usable runtime",
                suggestion: "Pass --java with a working Java \(required)+ executable, or run `lingxi doctor`."
            )]
        }
        if runtime.majorVersion < required {
            return [.error(
                .javaVersionMismatch,
                "Minecraft \(version.id) requires Java \(required)+ but \(runtime.executable.path) is \(runtime.displayDescription)",
                suggestion: "Install a Java \(required)+ runtime for Apple Silicon."
            )]
        }
        return [.info("Java check: \(runtime.displayDescription) satisfies Java \(required)+")]
    }
}
