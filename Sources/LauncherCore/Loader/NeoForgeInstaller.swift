import Foundation

/// One NeoForge Maven version compatible with a concrete Minecraft release.
public struct NeoForgeLoaderVersion: Codable, Sendable, Equatable, Identifiable {
    public let version: String
    public let minecraftVersion: String
    public let stable: Bool

    public var id: String { version }

    public init(version: String, minecraftVersion: String, stable: Bool = true) {
        self.version = version
        self.minecraftVersion = minecraftVersion
        self.stable = stable
    }
}

public struct NeoForgeInstallRequest: Sendable {
    public let minecraftVersionID: String
    /// Nil selects the newest compatible NeoForge version.
    public let loaderVersion: String?
    public let instanceID: String
    public let displayName: String?
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

public struct NeoForgeInstallReport: Sendable {
    public let profileID: String
    public let minecraftVersionID: String
    public let loaderVersion: String
    public let instanceID: String
    public let gameDirectory: URL
    public let downloadedFiles: Int
    public let downloadedBytes: Int
    public let backupManifest: URL?
}

/// Installs NeoForge through its official installer in an isolated staging Minecraft root.
///
/// The official installer is treated as an untrusted local process: it receives no arbitrary
/// arguments, runs in a temporary directory with a timeout, and its generated version profile and
/// libraries are validated before they are merged into the shared game root. The target instance
/// is never used as the installer's working directory.
public struct NeoForgeInstaller: Sendable {
    private let layout: GameDataLayout
    private let transport: any DownloadTransport
    private let mirror: TrustedMirrorConfiguration?
    private let javaInspector: JavaRuntimeInspector
    private let metadataURL = URL(string: "https://maven.neoforged.net/releases/net/neoforged/neoforge/maven-metadata.xml")!
    private let maximumInstallerBytes = 32 * 1024 * 1024

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

    // MARK: - Metadata

    public func listLoaderVersions(for minecraftVersion: String) async throws -> [NeoForgeLoaderVersion] {
        let data: Data
        do {
            data = try await transport.fetch(from: metadataURL)
        } catch {
            throw LauncherError(.downloadFailed, "NeoForge metadata download failed: \(error.localizedDescription)")
        }
        let versions = Self.parseMavenVersions(data).compactMap { version -> NeoForgeLoaderVersion? in
            guard let mapped = Self.minecraftVersion(for: version), mapped == minecraftVersion else { return nil }
            return NeoForgeLoaderVersion(version: version, minecraftVersion: mapped)
        }
        guard !versions.isEmpty else {
            throw LauncherError(
                .unsupportedVersion,
                "NeoForge has no release compatible with Minecraft \(minecraftVersion)",
                suggestion: "NeoForge supports selected modern Minecraft releases; check the official version list."
            )
        }
        return versions.sorted { $0.version.localizedStandardCompare($1.version) == .orderedDescending }
    }

    static func parseMavenVersions(_ data: Data) -> [String] {
        guard let text = String(data: data, encoding: .utf8) else { return [] }
        let pattern = "<version>([^<]+)</version>"
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        return regex.matches(in: text, range: range).compactMap { match in
            guard let valueRange = Range(match.range(at: 1), in: text) else { return nil }
            return String(text[valueRange])
        }
    }

    /// NeoForge's version scheme is `<minecraft major>.<minecraft minor>.<build>` for modern
    /// releases (`21.1.265` → Minecraft `1.21.1`). It is deliberately strict: an unrecognised
    /// version must never be guessed onto a different Minecraft release.
    static func minecraftVersion(for neoForgeVersion: String) -> String? {
        let parts = neoForgeVersion.split(separator: ".")
        guard parts.count >= 2,
              let major = Int(parts[0]),
              let minor = Int(parts[1]),
              major >= 20 else { return nil }
        return minor == 0 ? "1.\(major)" : "1.\(major).\(minor)"
    }

    // MARK: - Installation

    public func install(
        _ request: NeoForgeInstallRequest,
        progress: @escaping @Sendable (InstallProgressEvent) -> Void
    ) async throws -> NeoForgeInstallReport {
        try Task.checkCancellation()
        let registry = InstanceRepository(layout: layout)
        let targetDirectory = try layout.instanceDirectory(request.instanceID)
        let targetExists = FileManager.default.fileExists(atPath: targetDirectory.path)
        let existingTarget: Instance?
        if targetExists {
            existingTarget = try registry.load(id: request.instanceID)
        } else {
            existingTarget = nil
        }
        if targetExists && !request.updateExistingInstance {
            throw LauncherError(.usageError, "Instance '\(request.instanceID)' already exists; choose update mode explicitly")
        }
        if !targetExists && request.updateExistingInstance {
            throw LauncherError(.missingDependency, "The instance selected for update no longer exists")
        }

        let javaRuntime: JavaRuntime
        do {
            javaRuntime = try javaInspector.inspect(executable: request.javaExecutable)
        } catch {
            throw LauncherError(.javaNotFound, "NeoForge installation requires Java: \((error as? LauncherError)?.description ?? error.localizedDescription)")
        }
        guard javaRuntime.majorVersion >= 21 else {
            throw LauncherError(
                .javaVersionMismatch,
                "NeoForge for Minecraft \(request.minecraftVersionID) requires Java 21+, but \(javaRuntime.displayDescription) was selected"
            )
        }

        progress(.phase(.loaderMetadata, "Querying compatible NeoForge versions"))
        let versions = try await listLoaderVersions(for: request.minecraftVersionID)
        let selected: NeoForgeLoaderVersion
        if let requested = request.loaderVersion {
            guard let match = versions.first(where: { $0.version == requested }) else {
                throw LauncherError(.unsupportedVersion, "NeoForge \(requested) is not compatible with Minecraft \(request.minecraftVersionID)")
            }
            selected = match
        } else {
            selected = versions[0]
        }
        let profileID = "neoforge-\(selected.version)"
        progress(.phase(.manifest, "Preparing isolated NeoForge staging root"))
        let stageRoot = layout.dataRoot
            .appendingPathComponent("tmp", isDirectory: true)
            .appendingPathComponent("neoforge-stage-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: stageRoot) }
        do {
            try FileManager.default.createDirectory(at: stageRoot.appendingPathComponent("versions", isDirectory: true), withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: stageRoot.appendingPathComponent("libraries", isDirectory: true), withIntermediateDirectories: true)
            try Data("{\"profiles\":{},\"settings\":{},\"version\":3}".utf8)
                .write(to: stageRoot.appendingPathComponent("launcher_profiles.json"), options: .atomic)
        } catch {
            throw LauncherError(.ioFailure, "Cannot create NeoForge staging root: \(error.localizedDescription)")
        }

        try await ensureVanillaBase(
            minecraftVersionID: request.minecraftVersionID,
            stageRoot: stageRoot,
            request: request,
            progress: progress
        )
        try Task.checkCancellation()

        progress(.phase(.loaderProfile, "Downloading NeoForge \(selected.version) installer"))
        let installerURL = URL(string: "https://maven.neoforged.net/releases/net/neoforged/neoforge/\(selected.version)/neoforge-\(selected.version)-installer.jar")!
        let installerData = try await fetchLimited(installerURL, limit: maximumInstallerBytes, label: "NeoForge installer")
        let installerPath = stageRoot.appendingPathComponent("neoforge-installer.jar")
        do {
            try installerData.write(to: installerPath, options: .atomic)
        } catch {
            throw LauncherError(.ioFailure, "Cannot write NeoForge installer: \(error.localizedDescription)")
        }
        try await verifyInstaller(installerURL: installerURL, data: installerData)

        progress(.phase(.loaderLibraries, "Running official NeoForge installer"))
        try await runInstaller(
            java: request.javaExecutable,
            installer: installerPath,
            root: stageRoot,
            timeout: 900
        )
        try Task.checkCancellation()

        let profileURL = stageRoot.appendingPathComponent("versions/\(profileID)/\(profileID).json")
        guard FileManager.default.fileExists(atPath: profileURL.path), let profileData = try? Data(contentsOf: profileURL) else {
            throw LauncherError(.missingDependency, "NeoForge installer did not produce \(profileID).json")
        }
        var profile = try VersionMetadata.decode(from: profileData, context: "NeoForge profile \(profileID)")
        guard profile.id == profileID, profile.inheritsFrom == request.minecraftVersionID,
              !profile.mainClass.isEmpty else {
            throw LauncherError(.invalidMetadata, "NeoForge profile id/parent/mainClass validation failed")
        }

        // The official installer writes the patched client as a library but omits it from the
        // version profile's `downloads.client`. Without this the launcher appends the vanilla
        // client jar too, and ModLauncher sees two modules exporting net.minecraft.*. Promote the
        // patched client to the profile's client jar so exactly one game jar is on the classpath.
        let clientJarSource = stageRoot
            .appendingPathComponent("libraries/net/neoforged/neoforge/\(selected.version)/neoforge-\(selected.version)-client.jar")
        guard FileManager.default.fileExists(atPath: clientJarSource.path),
              let clientJarData = try? Data(contentsOf: clientJarSource) else {
            throw LauncherError(.missingDependency, "NeoForge installer did not produce the patched client jar")
        }
        let versionDirectory = stageRoot.appendingPathComponent("versions/\(profileID)", isDirectory: true)
        do {
            let clientJarURL = versionDirectory.appendingPathComponent("\(profileID).jar")
            try clientJarData.write(to: clientJarURL, options: .atomic)
            var object = try JSONSerialization.jsonObject(with: profileData) as? [String: Any] ?? [:]
            object["downloads"] = [
                "client": [
                    "url": "https://maven.neoforged.net/releases/net/neoforged/neoforge/\(selected.version)/neoforge-\(selected.version)-client.jar",
                    "sha1": SHA1.hexDigest(clientJarData),
                    "size": clientJarData.count
                ]
            ]
            let updated = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
            try updated.write(to: profileURL, options: .atomic)
            profile = try VersionMetadata.decode(from: updated, context: "NeoForge profile \(profileID)")
        } catch {
            throw LauncherError(.ioFailure, "Cannot prepare NeoForge client jar: \(error.localizedDescription)")
        }

        progress(.phase(.finalizing, "Committing NeoForge files"))
        let transaction = try NeoForgeFileTransaction(layout: layout)
        var runtimeDownloadedFiles = 0
        var runtimeDownloadedBytes = 0
        do {
            try transaction.installLibraries(from: stageRoot.appendingPathComponent("libraries"))
            try transaction.installVersion(from: stageRoot.appendingPathComponent("versions/\(profileID)"), id: profileID)

            // The official installer only downloads its build-time processors. Runtime
            // libraries declared by the generated profile still need the normal verified
            // dependency resolution, exactly like a Fabric profile.
            progress(.phase(.loaderLibraries, "Resolving NeoForge runtime libraries"))
            let platform = try PlatformContext.forJVM(javaRuntime)
            let version = try VersionResolver().resolve(versionID: profileID, from: layout.gameRoot)
            let dependencies = try DependencyResolver(ruleEvaluator: RuleEvaluator())
                .resolve(version: version, layout: layout, platform: platform)
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
            if !tasks.isEmpty {
                progress(.phase(.downloading, "Downloading \(tasks.count) NeoForge runtime file(s)"))
                let downloader = Downloader(
                    transport: transport,
                    sourceResolver: sourceResolver,
                    configuration: DownloadConfiguration(concurrency: request.concurrency)
                )
                let summary = try await downloader.download(tasks, progress: progress)
                try Task.checkCancellation()
                guard summary.failures.isEmpty else {
                    let detail = summary.failures.prefix(3).map { "\($0.task.destination.lastPathComponent): \($0.message)" }.joined(separator: " | ")
                    throw LauncherError(.downloadFailed, "\(summary.failures.count) NeoForge runtime file(s) failed: \(detail)")
                }
                runtimeDownloadedFiles = summary.downloaded.count
                runtimeDownloadedBytes = summary.downloadedBytes
            }
            let after = try DependencyResolver(ruleEvaluator: RuleEvaluator())
                .resolve(version: version, layout: layout, platform: platform)
            guard after.missing.isEmpty else {
                throw LauncherError(.missingDependency, "NeoForge runtime is incomplete after download (\(after.missing.count) missing file(s))")
            }
        } catch {
            transaction.rollback()
            throw error
        }

        let target: Instance
        var backup: URL?
        do {
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
        } catch {
            transaction.rollback()
            throw error
        }

        // Metadata is the source of truth for the instance. Only once the instance has been
        // created/updated successfully is it safe to discard the file backups.
        transaction.commit()

        return NeoForgeInstallReport(
            profileID: profileID,
            minecraftVersionID: request.minecraftVersionID,
            loaderVersion: selected.version,
            instanceID: target.id,
            gameDirectory: target.gameDirectory,
            downloadedFiles: runtimeDownloadedFiles,
            downloadedBytes: installerData.count + runtimeDownloadedBytes,
            backupManifest: backup
        )
    }

    private func ensureVanillaBase(
        minecraftVersionID: String,
        stageRoot: URL,
        request: NeoForgeInstallRequest,
        progress: @escaping @Sendable (InstallProgressEvent) -> Void
    ) async throws {
        let registry = InstanceRepository(layout: layout)
        let stageID = "neoforge-vanilla-\(UUID().uuidString.prefix(10).lowercased())"
        defer { try? registry.delete(id: stageID) }
        let vanilla = VanillaInstaller(layout: layout, transport: transport, mirror: mirror)
        let report = try await vanilla.install(
            InstallRequest(
                versionID: minecraftVersionID,
                instanceID: stageID,
                displayName: "NeoForge vanilla staging",
                sourcePolicy: request.sourcePolicy,
                concurrency: request.concurrency,
                javaExecutable: request.javaExecutable
            ),
            progress: progress
        )
        guard report.isComplete else {
            throw LauncherError(.missingDependency, "Vanilla base installation is incomplete; refusing to install NeoForge")
        }
        let source = try layout.versionDirectory(minecraftVersionID)
        let destination = stageRoot.appendingPathComponent("versions/\(minecraftVersionID)", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
            try FileManager.default.copyItem(at: source, to: destination)
        } catch {
            throw LauncherError(.ioFailure, "Cannot stage vanilla files for NeoForge: \(error.localizedDescription)")
        }
    }

    private func fetchLimited(_ url: URL, limit: Int, label: String) async throws -> Data {
        let data: Data
        do {
            data = try await transport.fetch(from: url)
        } catch {
            throw LauncherError(.downloadFailed, "\(label) download failed: \(error.localizedDescription)")
        }
        guard data.count > 0, data.count <= limit else {
            throw LauncherError(.sizeMismatch, "\(label) has an invalid size")
        }
        return data
    }

    private func verifyInstaller(installerURL: URL, data: Data) async throws {
        let base = installerURL.absoluteString
        let sha512URL = URL(string: base + ".sha512")!
        if let expected = try? await transport.fetch(from: sha512URL),
           let text = String(data: expected, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
           !text.isEmpty {
            let actual = SHA512Digest.hexDigest(data)
            guard actual.caseInsensitiveCompare(text) == .orderedSame else {
                throw LauncherError(.hashMismatch, "NeoForge installer SHA-512 verification failed")
            }
            return
        }
        let sha1URL = URL(string: base + ".sha1")!
        guard let expected = try? await transport.fetch(from: sha1URL),
              let text = String(data: expected, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !text.isEmpty else {
            throw LauncherError(.invalidMetadata, "NeoForge installer has no published checksum")
        }
        let actual = SHA1.hexDigest(data)
        guard actual.caseInsensitiveCompare(text) == .orderedSame else {
            throw LauncherError(.hashMismatch, "NeoForge installer SHA-1 verification failed")
        }
    }

    private func runInstaller(java: URL, installer: URL, root: URL, timeout: TimeInterval) async throws {
        let process = Process()
        process.executableURL = java
        process.arguments = ["-jar", installer.path, "--install-client", root.path]
        process.currentDirectoryURL = root
        let logURL = root.appendingPathComponent("installer.log")
        FileManager.default.createFile(atPath: logURL.path, contents: nil)
        guard let log = try? FileHandle(forWritingTo: logURL) else {
            throw LauncherError(.ioFailure, "Cannot create NeoForge installer log")
        }
        process.standardOutput = log
        process.standardError = log
        do {
            try process.run()
        } catch {
            try? log.close()
            throw LauncherError(.launchFailed, "Cannot start NeoForge installer: \(error.localizedDescription)")
        }
        let deadline = Date().addingTimeInterval(timeout)
        while process.isRunning {
            if Task.isCancelled {
                process.terminate()
                try? log.close()
                throw CancellationError()
            }
            if Date() > deadline {
                process.terminate()
                try? log.close()
                throw LauncherError(.downloadFailed, "NeoForge installer timed out after \(Int(timeout)) seconds")
            }
            try await Task.sleep(nanoseconds: 300_000_000)
        }
        process.waitUntilExit()
        try? log.close()
        guard process.terminationStatus == 0 else {
            let tail = (try? String(contentsOf: logURL, encoding: .utf8).suffix(4000)) ?? ""
            throw LauncherError(.launchFailed, "NeoForge installer failed (exit \(process.terminationStatus)): \(tail)")
        }
    }
}

/// File-level transaction for merging a staged NeoForge installation into the shared root.
/// Existing files are copied to a backup directory first; rollback restores every backup and
/// removes newly created files. Nothing is deleted until commit completes.
final class NeoForgeFileTransaction {
    private struct Backup {
        let original: URL
        let backup: URL
        let existed: Bool
    }
    private let layout: GameDataLayout
    private let backupRoot: URL
    private var backups: [Backup] = []

    /// Test-only visibility for asserting that no large staging directory survives.
    var backupRootForTesting: URL { backupRoot }

    init(layout: GameDataLayout) throws {
        self.layout = layout
        self.backupRoot = layout.dataRoot
            .appendingPathComponent("tmp", isDirectory: true)
            .appendingPathComponent("neoforge-backup-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: backupRoot, withIntermediateDirectories: true)
    }

    func installLibraries(from source: URL) throws {
        let files = try allFiles(under: source)
        for file in files {
            let relative = try relativePath(of: file, under: source)
            let destination = layout.librariesDirectory.appendingPathComponent(relative)
            guard PathSafety.isContained(destination, inBase: layout.librariesDirectory) else {
                throw LauncherError(.pathEscapesRoot, "NeoForge library escapes the libraries directory: \(relative)")
            }
            try install(file, to: destination)
        }
    }

    func installVersion(from source: URL, id: String) throws {
        let destination = try layout.versionDirectory(id)
        try install(source, to: destination)
    }

    /// Drops only this transaction's private backup directory. The installed files and instance
    /// metadata are already committed at this point; unrelated game files must never be touched.
    func commit() {
        try? FileManager.default.removeItem(at: backupRoot)
        backups.removeAll()
    }

    func rollback() {
        for backup in backups.reversed() {
            if backup.existed {
                try? FileManager.default.removeItem(at: backup.original)
                try? FileManager.default.createDirectory(at: backup.original.deletingLastPathComponent(), withIntermediateDirectories: true)
                try? FileManager.default.copyItem(at: backup.backup, to: backup.original)
            } else {
                try? FileManager.default.removeItem(at: backup.original)
            }
        }
        try? FileManager.default.removeItem(at: backupRoot)
        backups.removeAll()
    }

    private func install(_ source: URL, to destination: URL) throws {
        let existed = FileManager.default.fileExists(atPath: destination.path)
        let backup = backupRoot.appendingPathComponent(UUID().uuidString)
        if existed {
            try FileManager.default.copyItem(at: destination, to: backup)
        }
        backups.append(Backup(original: destination, backup: backup, existed: existed))
        do {
            try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
            let temporary = destination.deletingLastPathComponent()
                .appendingPathComponent(".\(destination.lastPathComponent).new-\(UUID().uuidString.prefix(6))")
            try FileManager.default.copyItem(at: source, to: temporary)
            if existed {
                _ = try FileManager.default.replaceItemAt(destination, withItemAt: temporary)
            } else {
                try FileManager.default.moveItem(at: temporary, to: destination)
            }
        } catch {
            throw LauncherError(.ioFailure, "Cannot install NeoForge file \(destination.lastPathComponent): \(error.localizedDescription)")
        }
    }

    private func relativePath(of url: URL, under root: URL) throws -> String {
        let base = root.resolvingSymlinksInPath().path
        let child = url.resolvingSymlinksInPath().path
        let prefix = base.hasSuffix("/") ? base : base + "/"
        guard child.hasPrefix(prefix) else {
            throw LauncherError(.pathEscapesRoot, "NeoForge entry escapes its staging root: \(url.path)")
        }
        let relative = String(child.dropFirst(prefix.count))
        guard !relative.isEmpty, !relative.hasPrefix("/"), !relative.split(separator: "/").contains("..") else {
            throw LauncherError(.pathEscapesRoot, "Invalid NeoForge entry path: \(url.path)")
        }
        return relative
    }

    private func allFiles(under root: URL) throws -> [URL] {
        guard let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey]) else {
            return []
        }
        var result: [URL] = []
        for case let url as URL in enumerator {
            if (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true {
                result.append(url)
            }
        }
        return result
    }
}
