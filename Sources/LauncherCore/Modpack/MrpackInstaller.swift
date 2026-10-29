import Foundation

public enum MrpackInstallPhase: String, Sendable, Equatable {
    case downloading
    case verifying
    case installing
    case committing
    case done
}

public struct MrpackInstallProgress: Sendable, Equatable {
    public let phase: MrpackInstallPhase
    public let message: String
    public let completed: Int
    public let total: Int
    public let currentFile: String?

    public init(
        phase: MrpackInstallPhase,
        message: String,
        completed: Int,
        total: Int,
        currentFile: String? = nil
    ) {
        self.phase = phase
        self.message = message
        self.completed = completed
        self.total = total
        self.currentFile = currentFile
    }
}

public struct MrpackInstallRequest: Sendable {
    public let package: MrpackPackage
    public let displayName: String?
    public let javaExecutable: URL
    public let sourcePolicy: DownloadSourcePolicy
    public let concurrency: Int
    /// Optional client files explicitly chosen by the user. An empty set installs required files
    /// only; optional files are never selected implicitly.
    public let selectedOptionalPaths: Set<String>
    /// Best-effort Modrinth hash lookup after import. Failure never fails the installation.
    public let traceModrinthSources: Bool

    public init(
        package: MrpackPackage,
        displayName: String? = nil,
        javaExecutable: URL,
        sourcePolicy: DownloadSourcePolicy = .auto,
        concurrency: Int = 4,
        selectedOptionalPaths: Set<String> = [],
        traceModrinthSources: Bool = false
    ) {
        self.package = package
        self.displayName = displayName
        self.javaExecutable = javaExecutable
        self.sourcePolicy = sourcePolicy
        self.concurrency = max(1, min(concurrency, 8))
        self.selectedOptionalPaths = Set(package.optionalFiles.map(\.relativePath))
            .intersection(selectedOptionalPaths)
        self.traceModrinthSources = traceModrinthSources
    }
}

public struct MrpackInstallReport: Sendable {
    public let instanceID: String
    public let displayName: String
    public let minecraftVersionID: String
    public let installedVersionID: String
    public let loader: InstallLoaderChoice
    public let gameDirectory: URL
    public let downloadedFiles: Int
    public let downloadedBytes: Int
    public let cacheHits: Int
    public let installedFiles: Int
    public let javaRuntime: JavaRuntime
    public let identifiedMods: Int
    public let localMods: Int
    public let sourceWarnings: [String]
}

/// Installs a validated `.mrpack` as a brand-new isolated instance.
///
/// External files are downloaded through `Downloader` into a persistent verified cache, then
/// copied into a pack staging tree. Minecraft and its Fabric/NeoForge loader are installed through `OneStopInstaller`
/// only after every external file has passed size/SHA verification. Pack files are then moved
/// into the new game directory without overwriting anything. Any failure after instance creation
/// removes that newly created instance; existing instances/worlds are never touched.
public struct MrpackInstaller: Sendable {
    private let layout: GameDataLayout
    private let transport: any DownloadTransport
    private let mirror: TrustedMirrorConfiguration?
    private let modrinthClient: ModrinthClient?
    private var fm: FileManager { FileManager.default }

    public init(
        layout: GameDataLayout,
        transport: any DownloadTransport,
        mirror: TrustedMirrorConfiguration? = nil,
        modrinthClient: ModrinthClient? = nil
    ) {
        self.layout = layout
        self.transport = transport
        self.mirror = mirror
        self.modrinthClient = modrinthClient
    }

    public func requiredJava(for package: MrpackPackage) async throws -> JavaVersionRequirement {
        try await OneStopInstaller(layout: layout, transport: transport, mirror: mirror)
            .requiredJava(for: package.minecraftVersion, loader: package.loader)
    }

    public func install(
        _ request: MrpackInstallRequest,
        progress: @escaping @Sendable (MrpackInstallProgress) -> Void
    ) async throws -> MrpackInstallReport {
        try Task.checkCancellation()
        let package = request.package
        let displayName = (request.displayName ?? package.name)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !displayName.isEmpty else {
            throw LauncherError(.usageError, "整合包实例名称不能为空")
        }
        let instanceID = try makeInstanceID(from: displayName)
        let selectedFiles = package.selectedFiles(includingOptionalPaths: request.selectedOptionalPaths)
        let selectedBytes = selectedFiles.reduce(0) { $0 + $1.fileSize }
        let cacheRoot = layout.dataRoot
            .appendingPathComponent("cache/mrpack", isDirectory: true)
            .appendingPathComponent(package.archiveSHA256, isDirectory: true)
        let stageRoot = layout.dataRoot
            .appendingPathComponent("cache/mrpack-staging", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        // The package owns the extracted tree. The GUI/CLI must be able to retry after a failure,
        // so the installer never deletes it; only an explicit user re-parse/close may clean it.
        guard fm.fileExists(atPath: package.extractionRoot.path) else {
            throw LauncherError(
                .missingDependency,
                "整合包临时文件已失效",
                suggestion: "请重新解析整合包后再试。"
            )
        }
        var createdInstance = false
        defer {
            try? fm.removeItem(at: stageRoot)
            if createdInstance {
                try? InstanceRepository(layout: layout).delete(id: instanceID)
            }
        }

        progress(MrpackInstallProgress(
            phase: .downloading,
            message: "准备下载 \(selectedFiles.count) 个整合包文件",
            completed: 0,
            total: selectedFiles.count
        ))
        let cacheHits = try await downloadFiles(
            files: selectedFiles,
            overrides: package.overrides,
            cacheRoot: cacheRoot,
            stageRoot: stageRoot,
            sourcePolicy: request.sourcePolicy,
            concurrency: request.concurrency,
            progress: progress
        )
        try Task.checkCancellation()

        progress(MrpackInstallProgress(
            phase: .installing,
            message: "安装 Minecraft \(package.minecraftVersion) 与 \(package.loader.displayName)",
            completed: 0,
            total: 1
        ))
        let oneStop = OneStopInstaller(layout: layout, transport: transport, mirror: mirror)
        let oneStopReport: OneStopInstallReport
        do {
            oneStopReport = try await oneStop.install(
                OneStopInstallRequest(
                    minecraftVersionID: package.minecraftVersion,
                    loader: package.loader,
                    target: .newInstance(id: instanceID, displayName: displayName),
                    javaExecutable: request.javaExecutable,
                    sourcePolicy: request.sourcePolicy,
                    concurrency: request.concurrency
                ),
                progress: { event in
                    if case let .phase(_, message) = event {
                        progress(MrpackInstallProgress(
                            phase: .installing,
                            message: message,
                            completed: 0,
                            total: 1
                        ))
                    }
                }
            )
        } catch {
            try? InstanceRepository(layout: layout).delete(id: instanceID)
            throw error
        }
        createdInstance = true
        try Task.checkCancellation()

        progress(MrpackInstallProgress(
            phase: .committing,
            message: "提交整合包文件到新实例",
            completed: 0,
            total: selectedFiles.count + package.overrides.count
        ))
        do {
            let instance = try InstanceRepository(layout: layout).load(id: oneStopReport.instanceID)
            let committed = try commitStage(stageRoot: stageRoot, to: instance)
            let javaRuntime = try JavaRuntimeInspector().inspect(executable: request.javaExecutable)
            try Task.checkCancellation()

            var trace = MrpackSourceTraceSummary.empty
            if request.traceModrinthSources {
                progress(MrpackInstallProgress(
                    phase: .committing,
                    message: "识别整合包模组的 Modrinth 来源",
                    completed: committed,
                    total: committed
                ))
                let repository = ModRepository(layout: layout)
                let tracer = MrpackSourceTracer(
                    client: modrinthClient ?? ModrinthClient(transport: transport)
                )
                trace = await tracer.trace(
                    instance: instance,
                    files: selectedFiles,
                    repository: repository
                )
                try Task.checkCancellation()
            }

            progress(MrpackInstallProgress(
                phase: .done,
                message: "整合包安装完成",
                completed: committed,
                total: committed
            ))
            // Success ends the package's lifetime. Failure/cancellation deliberately keeps the
            // extraction root so the same validated package can be retried by the caller.
            try? fm.removeItem(at: package.extractionRoot)
            createdInstance = false
            return MrpackInstallReport(
                instanceID: oneStopReport.instanceID,
                displayName: displayName,
                minecraftVersionID: package.minecraftVersion,
                installedVersionID: oneStopReport.installedVersionID,
                loader: package.loader,
                gameDirectory: instance.gameDirectory,
                downloadedFiles: selectedFiles.count,
                downloadedBytes: selectedBytes,
                cacheHits: cacheHits,
                installedFiles: committed,
                javaRuntime: javaRuntime,
                identifiedMods: trace.identifiedFiles,
                localMods: trace.localFiles,
                sourceWarnings: trace.warnings
            )
        } catch {
            try? InstanceRepository(layout: layout).delete(id: oneStopReport.instanceID)
            throw (error as? LauncherError) ?? LauncherError(.ioFailure, "整合包文件提交失败：\(error.localizedDescription)")
        }
    }

    /// Kept public for GUI/CLI inspection without duplicating path logic.
    public func cacheDirectory(for package: MrpackPackage) -> URL {
        layout.dataRoot
            .appendingPathComponent("cache/mrpack", isDirectory: true)
            .appendingPathComponent(package.archiveSHA256, isDirectory: true)
    }

    // MARK: - Download / stage

    private final class ProgressCounter: @unchecked Sendable {
        private let lock = NSLock()
        private var value = 0
        func next() -> Int {
            lock.lock(); defer { lock.unlock() }
            value += 1
            return value
        }
    }

    private func downloadFiles(
        files: [MrpackFile],
        overrides: [MrpackOverride],
        cacheRoot: URL,
        stageRoot: URL,
        sourcePolicy: DownloadSourcePolicy,
        concurrency: Int,
        progress: @escaping @Sendable (MrpackInstallProgress) -> Void
    ) async throws -> Int {
        try fm.createDirectory(at: cacheRoot, withIntermediateDirectories: true)
        var tasks: [DownloadTask] = []
        var cacheHits = 0
        for file in files {
            let destination = try PathSafety.safeJoin(base: cacheRoot, relativePath: file.relativePath)
            if fm.fileExists(atPath: destination.path), try cacheFileMatches(file, at: destination) {
                cacheHits += 1
            } else if fm.fileExists(atPath: destination.path) {
                try? fm.removeItem(at: destination)
            }
            tasks.append(DownloadTask(
                destination: destination,
                officialURL: file.downloadURL,
                sha1: file.sha1,
                size: file.fileSize,
                kind: .modpackFile
            ))
        }

        let resolver = try SourceResolver(policy: sourcePolicy, mirror: mirror)
        let downloader = Downloader(
            transport: transport,
            sourceResolver: resolver,
            configuration: DownloadConfiguration(concurrency: concurrency)
        )
        let counter = ProgressCounter()
        let summary: DownloadSummary
        do {
            summary = try await downloader.download(tasks, progress: { event in
                switch event {
                case let .fileFinished(path, _, _):
                    let completed = counter.next()
                    progress(MrpackInstallProgress(
                        phase: .verifying,
                        message: "已下载并校验 \(path)",
                        completed: completed,
                        total: files.count,
                        currentFile: path
                    ))
                case let .fileFailed(path, message):
                    progress(MrpackInstallProgress(
                        phase: .downloading,
                        message: "下载失败：\(path) — \(message)",
                        completed: 0,
                        total: files.count,
                        currentFile: path
                    ))
                case let .phase(_, message):
                    progress(MrpackInstallProgress(
                        phase: .downloading,
                        message: message,
                        completed: 0,
                        total: files.count
                    ))
                default:
                    break
                }
            })
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw (error as? LauncherError) ?? LauncherError(.downloadFailed, "下载整合包文件失败：\(error.localizedDescription)")
        }
        if Task.isCancelled { throw CancellationError() }
        guard summary.failures.isEmpty else {
            let details = summary.failures.prefix(5)
                .map { "\($0.task.destination.lastPathComponent): \($0.message)" }
                .joined(separator: "；")
            throw LauncherError(
                .downloadFailed,
                "整合包文件下载/校验失败（\(summary.failures.count) 个）：\(details)",
                suggestion: "网络恢复后重试；已验证缓存会保留，损坏文件不会被使用。"
            )
        }

        progress(MrpackInstallProgress(
            phase: .verifying,
            message: "校验所有下载文件",
            completed: 0,
            total: files.count
        ))
        for (index, file) in files.enumerated() {
            let destination = try PathSafety.safeJoin(base: cacheRoot, relativePath: file.relativePath)
            try verify(file, at: destination)
            progress(MrpackInstallProgress(
                phase: .verifying,
                message: "已验证 \(file.relativePath)",
                completed: index + 1,
                total: files.count,
                currentFile: file.relativePath
            ))
        }

        try fm.createDirectory(at: stageRoot, withIntermediateDirectories: true)
        let overridesByPath = Dictionary(uniqueKeysWithValues: overrides.map { ($0.relativePath, $0) })
        for file in files {
            let source = try PathSafety.safeJoin(base: cacheRoot, relativePath: file.relativePath)
            let destination = try PathSafety.safeJoin(base: stageRoot, relativePath: file.relativePath)
            try fm.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
            if overridesByPath[file.relativePath] != nil {
                // client-overrides takes precedence; it is copied below.
                continue
            }
            try fm.copyItem(at: source, to: destination)
        }
        for override in overrides {
            let destination = try PathSafety.safeJoin(base: stageRoot, relativePath: override.relativePath)
            try fm.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
            if fm.fileExists(atPath: destination.path) { try fm.removeItem(at: destination) }
            try fm.copyItem(at: override.sourceURL, to: destination)
        }
        return cacheHits
    }

    private func cacheFileMatches(_ file: MrpackFile, at url: URL) throws -> Bool {
        guard let attributes = try? fm.attributesOfItem(atPath: url.path),
              (attributes[.size] as? NSNumber)?.intValue == file.fileSize else { return false }
        if let sha512 = file.sha512 {
            return try SHA512Digest.hexDigest(ofFileAt: url).caseInsensitiveCompare(sha512) == .orderedSame
        }
        if let sha1 = file.sha1 {
            return try SHA1.hexDigest(ofFileAt: url).caseInsensitiveCompare(sha1) == .orderedSame
        }
        return false
    }

    private func verify(_ file: MrpackFile, at url: URL) throws {
        guard let attributes = try? fm.attributesOfItem(atPath: url.path) else {
            throw LauncherError(.missingDependency, "整合包文件缺失：\(file.relativePath)")
        }
        guard (attributes[.size] as? NSNumber)?.intValue == file.fileSize else {
            try? fm.removeItem(at: url)
            throw LauncherError(.sizeMismatch, "\(file.relativePath)：文件大小不匹配")
        }
        if let sha512 = file.sha512 {
            let actual = try SHA512Digest.hexDigest(ofFileAt: url)
            guard actual.caseInsensitiveCompare(sha512) == .orderedSame else {
                try? fm.removeItem(at: url)
                throw LauncherError(.hashMismatch, "\(file.relativePath)：SHA-512 校验失败")
            }
        }
        if let sha1 = file.sha1 {
            let actual = try SHA1.hexDigest(ofFileAt: url)
            guard actual.caseInsensitiveCompare(sha1) == .orderedSame else {
                try? fm.removeItem(at: url)
                throw LauncherError(.hashMismatch, "\(file.relativePath)：SHA-1 校验失败")
            }
        }
    }

    // MARK: - Commit

    private func commitStage(stageRoot: URL, to instance: Instance) throws -> Int {
        guard let enumerator = fm.enumerator(at: stageRoot, includingPropertiesForKeys: [.isRegularFileKey]) else {
            return 0
        }
        var files: [(source: URL, relative: String)] = []
        for case let source as URL in enumerator {
            let values = try source.resourceValues(forKeys: [.isRegularFileKey])
            guard values.isRegularFile == true else { continue }
            let canonicalRoot = stageRoot.resolvingSymlinksInPath().path
            let canonicalSource = source.resolvingSymlinksInPath().path
            guard canonicalSource.hasPrefix(canonicalRoot + "/") else {
                throw LauncherError(.pathEscapesRoot, "整合包 staging 文件逃逸：\(source.path)")
            }
            let relative = String(canonicalSource.dropFirst(canonicalRoot.count + 1))
            _ = try PathSafety.safeJoin(base: instance.gameDirectory, relativePath: relative)
            files.append((source, relative))
        }
        files.sort { $0.relative < $1.relative }
        for file in files {
            let target = try PathSafety.safeJoin(base: instance.gameDirectory, relativePath: file.relative)
            guard !fm.fileExists(atPath: target.path) else {
                throw LauncherError(
                    .usageError,
                    "目标实例已存在文件 \(file.relative)；为避免覆盖世界/配置/模组，安装已中止",
                    suggestion: "请使用全新的实例名称重试。"
                )
            }
        }

        var installed: [URL] = []
        do {
            for file in files {
                let target = try PathSafety.safeJoin(base: instance.gameDirectory, relativePath: file.relative)
                try fm.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
                try fm.moveItem(at: file.source, to: target)
                installed.append(target)
            }
            return installed.count
        } catch {
            for target in installed.reversed() { try? fm.removeItem(at: target) }
            throw error
        }
    }

    private func makeInstanceID(from displayName: String) throws -> String {
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyz0123456789-")
        var base = displayName.lowercased()
            .replacingOccurrences(of: " ", with: "-")
            .unicodeScalars.filter { allowed.contains($0) }
            .map(String.init).joined()
            .prefix(24)
        if base.isEmpty { base = "modpack" }
        for _ in 0..<8 {
            let candidate = "\(base)-\(UUID().uuidString.prefix(8).lowercased())"
            let directory = try layout.instanceDirectory(candidate)
            if !fm.fileExists(atPath: directory.path) { return candidate }
        }
        throw LauncherError(.ioFailure, "无法生成唯一的整合包实例 id")
    }
}
