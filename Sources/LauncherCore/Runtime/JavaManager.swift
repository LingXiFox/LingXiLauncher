import Foundation

public struct ManagedJava: Sendable, Equatable {
    public let runtime: JavaRuntime
    public let source: String
    public let sourceURL: URL
    public let license: String
    public let storage: URL
    /// Published artifact checksum, when the vendor supplies one.
    public let artifactSHA1: String?
    public let artifactSHA256: String?
    public let component: String?
    public let versionName: String

    public init(
        runtime: JavaRuntime,
        source: String,
        sourceURL: URL,
        license: String,
        storage: URL,
        artifactSHA1: String? = nil,
        artifactSHA256: String? = nil,
        component: String? = nil,
        versionName: String? = nil
    ) {
        self.runtime = runtime
        self.source = source
        self.sourceURL = sourceURL
        self.license = license
        self.storage = storage
        self.artifactSHA1 = artifactSHA1
        self.artifactSHA256 = artifactSHA256
        self.component = component
        self.versionName = versionName ?? runtime.versionString
    }
}

/// Reproducible record of the Java actually selected for an instance.
public struct JavaRuntimeRecord: Codable, Sendable, Equatable {
    public let source: String
    public let component: String?
    public let version: String
    public let architecture: String
    public let executable: String
    public let artifactSHA1: String?
    public let artifactSHA256: String?
    public let executableSHA256: String?
    public let recordedAt: Date

    public init(
        source: String,
        component: String?,
        version: String,
        architecture: String,
        executable: String,
        artifactSHA1: String? = nil,
        artifactSHA256: String? = nil,
        executableSHA256: String? = nil,
        recordedAt: Date = Date()
    ) {
        self.source = source
        self.component = component
        self.version = version
        self.architecture = architecture
        self.executable = executable
        self.artifactSHA1 = artifactSHA1
        self.artifactSHA256 = artifactSHA256
        self.executableSHA256 = executableSHA256
        self.recordedAt = recordedAt
    }
}

public enum JavaInstallProgress: Sendable, Equatable {
    case metadata(String)
    case downloading(totalBytes: Int?)
    case verifying(String)
    case extracting(String)
    case ready(URL)
}

/// Detects compatible Java runtimes and installs a managed Eclipse Temurin JDK into
/// `<dataRoot>/java`. It never writes to `/Library/Java` or changes `JAVA_HOME`.
public struct JavaManager: Sendable {
    public static let adoptiumAPI = URL(string: "https://api.adoptium.net/v3/assets/latest")!
    public static let mojangJavaRuntimeIndex = URL(string: "https://launchermeta.mojang.com/v1/products/java-runtime/2ec0cc96c44e5a76b9c8b7c39df7210883d12871/all.json")!
    public static let managedSourceName = "Eclipse Temurin"
    public static let managedLicense = "GPLv2 + Classpath Exception"

    private let layout: GameDataLayout
    private let transport: any DownloadTransport
    private let inspector: JavaRuntimeInspector

    public init(
        layout: GameDataLayout,
        transport: any DownloadTransport = URLSessionTransport(),
        inspector: JavaRuntimeInspector = JavaRuntimeInspector()
    ) {
        self.layout = layout
        self.transport = transport
        self.inspector = inspector
    }

    public var managedRoot: URL { layout.dataRoot.appendingPathComponent("java", isDirectory: true) }

    // MARK: - Detection

    public func detectRuntimes() -> [JavaRuntime] {
        var paths = JavaRuntimeInspector.candidateExecutablePaths()
        paths.append(contentsOf: managedExecutablePaths())
        var seen = Set<String>()
        return paths.compactMap { path in
            guard seen.insert(path.path).inserted else { return nil }
            return try? inspector.inspect(executable: path)
        }
    }

    public func managedRuntimes() -> [ManagedJava] {
        managedExecutablePaths().compactMap { javaURL -> ManagedJava? in
            guard let runtime = try? inspector.inspect(executable: javaURL) else { return nil }
            let storage = Self.installationRoot(for: javaURL)
            let sourceURL = storage.appendingPathComponent("source.json")
            let source = (try? JSONDecoder().decode(ManagedSource.self, from: Data(contentsOf: sourceURL)))
            let sourceLink: URL
            if let source, let parsed = URL(string: source.downloadURL) {
                sourceLink = parsed
            } else {
                sourceLink = Self.adoptiumAPI
            }
            return ManagedJava(
                runtime: runtime,
                source: source?.vendor ?? Self.managedSourceName,
                sourceURL: sourceLink,
                license: source?.license ?? Self.managedLicense,
                storage: storage,
                artifactSHA1: source?.checksumSHA1,
                artifactSHA256: source?.checksumSHA256,
                component: source?.component,
                versionName: source?.version
            )
        }
    }

    /// Returns the closest compatible runtime, preferring arm64. The user's explicit preference
    /// is returned only if it satisfies the metadata requirement.
    public func isCompatible(_ runtime: JavaRuntime, requirement: JavaVersionRequirement) -> Bool {
        runtime.majorVersion >= (requirement.majorVersion ?? 0)
    }

    public func selectCompatible(
        requirement: JavaVersionRequirement,
        preferredExecutable: URL? = nil
    ) -> JavaRuntime? {
        let required = requirement.majorVersion ?? 0
        if let preferredExecutable,
           let runtime = try? inspector.inspect(executable: preferredExecutable),
           isCompatible(runtime, requirement: JavaVersionRequirement(majorVersion: required)) {
            return runtime
        }
        let candidates = detectRuntimes().filter { isCompatible($0, requirement: requirement) }
        return candidates.sorted { lhs, rhs in
            if lhs.architecture == .arm64 && rhs.architecture != .arm64 { return true }
            if lhs.architecture != .arm64 && rhs.architecture == .arm64 { return false }
            if lhs.majorVersion != rhs.majorVersion { return lhs.majorVersion < rhs.majorVersion }
            return lhs.executable.path < rhs.executable.path
        }.first
    }

    public func inspectCustom(_ executable: URL) throws -> JavaRuntime {
        try inspector.inspect(executable: executable)
    }

    /// Builds an instance-persistable record. Managed runtimes contribute their published
    /// artifact checksum; custom/system runtimes still get a stable executable hash.
    public func runtimeRecord(for runtime: JavaRuntime) -> JavaRuntimeRecord {
        let targetPath = runtime.executable.resolvingSymlinksInPath().path
        let managed = managedRuntimes().first {
            $0.runtime.executable.resolvingSymlinksInPath().path == targetPath
        }
        return JavaRuntimeRecord(
            source: managed?.source ?? "system",
            component: managed?.component,
            version: managed?.versionName ?? runtime.versionString,
            architecture: runtime.architecture.rawValue,
            executable: runtime.executable.path,
            artifactSHA1: managed?.artifactSHA1,
            artifactSHA256: managed?.artifactSHA256,
            executableSHA256: try? SHA256Digest.hexDigest(ofFileAt: runtime.executable)
        )
    }

    // MARK: - Managed install

    /// Prefer Mojang's pinned java-runtime component for the selected Minecraft version
    /// (macOS arm64), falling back to Temurin only when Mojang has no suitable runtime.
    public func installManagedJava(
        requirement: JavaVersionRequirement,
        minecraftVersionID: String?,
        progress: @escaping @Sendable (JavaInstallProgress) -> Void
    ) async throws -> ManagedJava {
        if let component = requirement.component, !component.isEmpty,
           PlatformContext.hardwareArchitecture() == .arm64 {
            do {
                return try await installMojangRuntime(component: component, progress: progress)
            } catch let error as MojangRuntimeUnavailable {
                progress(.metadata("Mojang runtime unavailable (\(error.message)); falling back to Temurin"))
            }
        }
        return try await installTemurin(majorVersion: requirement.majorVersion ?? 8, progress: progress)
    }

    /// Downloads and verifies the requested Adoptium Temurin JDK, then extracts it into the
    /// launcher's private runtime directory. This is the explicit fallback path and is also
    /// used by `lingxi java install` when no Minecraft metadata component is supplied.
    public func installManagedJava(
        majorVersion: Int,
        progress: @escaping @Sendable (JavaInstallProgress) -> Void
    ) async throws -> ManagedJava {
        try await installTemurin(majorVersion: majorVersion, progress: progress)
    }

    /// Mojang's runtime index gives a pinned component for a Minecraft version and a macOS
    /// arm64 build. Files are verified individually against the manifest SHA-1 before commit.
    private func installMojangRuntime(
        component: String,
        progress: @escaping @Sendable (JavaInstallProgress) -> Void
    ) async throws -> ManagedJava {
        guard PlatformContext.hardwareArchitecture() == .arm64 else {
            throw MojangRuntimeUnavailable(message: "macOS arm64 only")
        }
        progress(.metadata("Querying Mojang java-runtime \(component)"))
        let indexData: Data
        do {
            indexData = try await transport.fetch(from: Self.mojangJavaRuntimeIndex)
        } catch {
            throw MojangRuntimeUnavailable(message: "runtime index unavailable: \(error.localizedDescription)")
        }
        let index: MojangRuntimeIndex
        do {
            index = try JSONDecoder().decode(MojangRuntimeIndex.self, from: indexData)
        } catch {
            throw MojangRuntimeUnavailable(message: "runtime index decode failed")
        }
        guard let candidates = index.macosArm64?[component], !candidates.isEmpty else {
            throw MojangRuntimeUnavailable(message: "component \(component) unavailable for macOS arm64")
        }
        let candidate = candidates.first(where: { $0.availability?.progress == 100 }) ?? candidates[0]
        guard let manifestURL = URL(string: candidate.manifest.url),
              manifestURL.scheme?.lowercased() == "https" else {
            throw MojangRuntimeUnavailable(message: "runtime manifest URL is not HTTPS")
        }
        let manifestData: Data
        do {
            manifestData = try await transport.fetch(from: manifestURL)
        } catch {
            throw MojangRuntimeUnavailable(message: "runtime manifest unavailable: \(error.localizedDescription)")
        }
        guard manifestData.count == candidate.manifest.size,
              SHA1.hexDigest(manifestData).caseInsensitiveCompare(candidate.manifest.sha1) == .orderedSame else {
            throw LauncherError(.hashMismatch, "Mojang runtime manifest checksum mismatch")
        }
        let manifest = try JSONDecoder().decode(MojangRuntimeFileManifest.self, from: manifestData)
        let fm = FileManager.default
        try fm.createDirectory(at: managedRoot, withIntermediateDirectories: true)
        let staging = managedRoot.appendingPathComponent("staging-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: staging, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: staging) }

        var tasks: [DownloadTask] = []
        var links: [(path: URL, target: String)] = []
        var executableFiles: [URL] = []
        for (relative, entry) in manifest.files {
            let destination = try PathSafety.safeJoin(base: staging, relativePath: relative)
            switch entry.type {
            case "directory":
                try fm.createDirectory(at: destination, withIntermediateDirectories: true)
            case "file":
                guard let raw = entry.downloads?["raw"], let url = URL(string: raw.url),
                      url.scheme?.lowercased() == "https" else {
                    throw LauncherError(.invalidMetadata, "Mojang runtime file '\(relative)' has no HTTPS raw download")
                }
                tasks.append(DownloadTask(destination: destination, officialURL: url, sha1: raw.sha1, size: raw.size, kind: .javaRuntime))
                if entry.executable == true { executableFiles.append(destination) }
            case "link":
                guard let target = entry.target else {
                    throw LauncherError(.invalidMetadata, "Mojang runtime link '\(relative)' has no target")
                }
                links.append((destination, target))
            default:
                break
            }
        }
        let sourceResolver = try SourceResolver(policy: .official, mirror: nil)
        let downloader = Downloader(
            transport: transport,
            sourceResolver: sourceResolver,
            configuration: DownloadConfiguration(concurrency: 6)
        )
        let totalBytes = tasks.reduce(0) { $0 + ($1.size ?? 0) }
        progress(.downloading(totalBytes: totalBytes))
        let summary = try await downloader.download(tasks, progress: { _ in })
        guard summary.failures.isEmpty else {
            throw LauncherError(.downloadFailed, "Mojang runtime download failed: \(summary.failures.first?.message ?? "unknown error")")
        }
        for file in executableFiles {
            guard PathSafety.isContained(file, inBase: staging) else {
                throw LauncherError(.pathEscapesRoot, "Runtime executable escapes staging")
            }
            try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: file.path)
        }
        for link in links {
            let parent = link.path.deletingLastPathComponent()
            let target = URL(fileURLWithPath: link.target, relativeTo: parent).standardizedFileURL
            guard PathSafety.isContained(target, inBase: staging) else {
                throw LauncherError(.pathEscapesRoot, "Runtime symlink escapes staging: \(link.path.path)")
            }
            try fm.createDirectory(at: parent, withIntermediateDirectories: true)
            if fm.fileExists(atPath: link.path.path) { try? fm.removeItem(at: link.path) }
            try fm.createSymbolicLink(atPath: link.path.path, withDestinationPath: link.target)
        }

        guard let javaURL = findJavaExecutable(in: staging) else {
            throw LauncherError(.ioFailure, "Mojang runtime did not contain a java executable")
        }
        _ = try inspector.inspect(executable: javaURL)
        let source = ManagedSource(
            vendor: "Mojang java-runtime",
            version: candidate.version.name,
            downloadURL: manifestURL.absoluteString,
            checksum: candidate.manifest.sha1,
            license: "Mojang Java Runtime / OpenJDK terms",
            checksumSHA1: candidate.manifest.sha1,
            checksumSHA256: nil,
            component: component
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(source).write(to: staging.appendingPathComponent("source.json"), options: [.atomic])

        let safeVersion = candidate.version.name.replacingOccurrences(of: "+", with: "_")
            .replacingOccurrences(of: "/", with: "_")
        let finalRoot = managedRoot.appendingPathComponent(
            "mojang-\(component)-\(safeVersion)-\(candidate.manifest.sha1.prefix(10))",
            isDirectory: true
        )
        let inspector = self.inspector
        try Self.safeReplaceDirectory(prepared: staging, destination: finalRoot) { candidateRoot in
            let candidateJava = candidateRoot.appendingPathComponent("jre.bundle/Contents/Home/bin/java")
            guard FileManager.default.isExecutableFile(atPath: candidateJava.path) else {
                throw LauncherError(.ioFailure, "Mojang runtime layout is unexpected")
            }
            _ = try inspector.inspect(executable: candidateJava)
        }
        let finalJava = finalRoot.appendingPathComponent("jre.bundle/Contents/Home/bin/java")
        let runtime = try inspector.inspect(executable: finalJava)
        progress(.ready(finalJava))
        return ManagedJava(
            runtime: runtime,
            source: "Mojang java-runtime",
            sourceURL: manifestURL,
            license: "Mojang Java Runtime / OpenJDK terms",
            storage: finalRoot,
            artifactSHA1: candidate.manifest.sha1,
            artifactSHA256: nil,
            component: component,
            versionName: candidate.version.name
        )
    }

    private func installTemurin(
        majorVersion: Int,
        progress: @escaping @Sendable (JavaInstallProgress) -> Void
    ) async throws -> ManagedJava {
        guard majorVersion >= 8 else {
            throw LauncherError(.usageError, "Java major version must be at least 8")
        }
        guard PlatformContext.hardwareArchitecture() == .arm64 else {
            throw LauncherError(
                .unsupportedVersion,
                "Managed Java downloads currently target macOS Apple Silicon (arm64) only",
                suggestion: "Select a locally installed JDK on this architecture."
            )
        }

        progress(.metadata("Querying Adoptium Temurin \(majorVersion) for macOS arm64"))
        let asset = try await fetchLatestAsset(majorVersion: majorVersion)
        let package = asset.binary.package
        guard let downloadURL = URL(string: package.link), downloadURL.scheme?.lowercased() == "https" else {
            throw LauncherError(.invalidMetadata, "Adoptium returned a non-HTTPS JDK package URL")
        }
        guard !package.checksum.isEmpty else {
            throw LauncherError(.invalidMetadata, "Adoptium did not publish a SHA-256 checksum for this JDK")
        }

        let fm = FileManager.default
        try fm.createDirectory(at: managedRoot, withIntermediateDirectories: true)
        let archiveDir = managedRoot.appendingPathComponent("archives", isDirectory: true)
        try fm.createDirectory(at: archiveDir, withIntermediateDirectories: true)
        let archiveURL = archiveDir.appendingPathComponent("temurin-\(majorVersion)-\(package.checksum.prefix(12)).tar.gz")
        progress(.downloading(totalBytes: package.size))

        if !(fm.fileExists(atPath: archiveURL.path) && (try? SHA256Digest.hexDigest(ofFileAt: archiveURL)) == package.checksum.lowercased()) {
            let part = archiveURL.appendingPathExtension("part")
            try? fm.removeItem(at: part)
            do {
                try await transport.download(from: downloadURL, to: part)
            } catch {
                try? fm.removeItem(at: part)
                throw LauncherError(.downloadFailed, "JDK download failed: \(error.localizedDescription)")
            }
            if let size = package.size {
                let actual = (try? fm.attributesOfItem(atPath: part.path)[.size] as? NSNumber)?.intValue
                guard actual == size else {
                    try? fm.removeItem(at: part)
                    throw LauncherError(.sizeMismatch, "JDK download size mismatch (expected \(size), got \(actual ?? -1))")
                }
            }
            progress(.verifying(package.checksum))
            let actual = try SHA256Digest.hexDigest(ofFileAt: part)
            guard actual == package.checksum.lowercased() else {
                try? fm.removeItem(at: part)
                throw LauncherError(.hashMismatch, "JDK SHA-256 mismatch: expected \(package.checksum), got \(actual)")
            }
            try? fm.removeItem(at: archiveURL)
            try fm.moveItem(at: part, to: archiveURL)
        }

        progress(.extracting("Extracting \(package.name)"))
        let staging = managedRoot.appendingPathComponent("staging-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: staging, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: staging) }
        try extractTarGz(archiveURL, into: staging)
        guard let javaURL = findJavaExecutable(in: staging) else {
            throw LauncherError(.ioFailure, "Downloaded JDK did not contain a java executable")
        }
        let root = Self.installationRoot(for: javaURL)
        // Validate the extracted JDK while it is still isolated from the managed tree. The old
        // runtime is not touched until this probe and the published archive checksum both pass.
        _ = try inspector.inspect(executable: javaURL)
        let source = ManagedSource(
            vendor: Self.managedSourceName,
            version: asset.version.semver,
            downloadURL: downloadURL.absoluteString,
            checksum: package.checksum,
            license: Self.managedLicense,
            checksumSHA1: nil,
            checksumSHA256: package.checksum,
            component: nil
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(source).write(to: root.appendingPathComponent("source.json"), options: [.atomic])

        let sanitizedVersion = asset.version.semver.replacingOccurrences(of: "+", with: "_")
            .replacingOccurrences(of: "/", with: "_")
        let finalRoot = managedRoot.appendingPathComponent("temurin-\(majorVersion)-\(sanitizedVersion)", isDirectory: true)
        let finalJava = finalRoot.appendingPathComponent("Contents/Home/bin/java")
        let inspector = self.inspector
        try Self.safeReplaceDirectory(prepared: root, destination: finalRoot) { candidate in
            let candidateJava = candidate.appendingPathComponent("Contents/Home/bin/java")
            guard FileManager.default.isExecutableFile(atPath: candidateJava.path) else {
                throw LauncherError(.ioFailure, "Managed JDK layout is unexpected: \(candidateJava.path) is not executable")
            }
            _ = try inspector.inspect(executable: candidateJava)
        }
        let runtime = try inspector.inspect(executable: finalJava)
        progress(.ready(finalJava))
        return ManagedJava(
            runtime: runtime,
            source: Self.managedSourceName,
            sourceURL: downloadURL,
            license: Self.managedLicense,
            storage: finalRoot,
            artifactSHA256: package.checksum,
            versionName: asset.version.semver
        )
    }

    // MARK: - Helpers

    /// Atomically commits a fully prepared directory. The destination is moved aside only
    /// after the prepared tree passes validation; if the final probe or move fails, the previous
    /// directory is restored. The old runtime is never deleted before the new one is usable.
    static func safeReplaceDirectory(
        prepared: URL,
        destination: URL,
        validate: (URL) throws -> Void
    ) throws {
        let fm = FileManager.default
        try validate(prepared)
        let parent = destination.deletingLastPathComponent()
        try fm.createDirectory(at: parent, withIntermediateDirectories: true)
        let backup = parent.appendingPathComponent(".backup-\(UUID().uuidString)", isDirectory: true)
        let destinationExists = fm.fileExists(atPath: destination.path)
        do {
            if destinationExists {
                try fm.moveItem(at: destination, to: backup)
            }
            do {
                try fm.moveItem(at: prepared, to: destination)
            } catch {
                if destinationExists, fm.fileExists(atPath: backup.path) {
                    try? fm.moveItem(at: backup, to: destination)
                }
                throw error
            }
            do {
                try validate(destination)
            } catch {
                try? fm.removeItem(at: destination)
                if destinationExists, fm.fileExists(atPath: backup.path) {
                    do { try fm.moveItem(at: backup, to: destination) } catch {
                        throw LauncherError(.ioFailure, "New JDK failed validation and the previous runtime could not be restored: \(error.localizedDescription)")
                    }
                }
                throw error
            }
            if destinationExists {
                try? fm.removeItem(at: backup)
            }
        } catch {
            throw (error as? LauncherError) ?? LauncherError(.ioFailure, "Cannot install managed JDK: \(error.localizedDescription)")
        }
    }

    /// Strips `Contents/Home/bin/java` (macOS JDK) or `bin/java` and returns the JDK root.
    private static func installationRoot(for javaURL: URL) -> URL {
        var url = javaURL.deletingLastPathComponent() // bin
        if url.lastPathComponent == "bin" { url = url.deletingLastPathComponent() }
        if url.lastPathComponent == "Home" { url = url.deletingLastPathComponent() }
        if url.lastPathComponent == "Contents" { url = url.deletingLastPathComponent() }
        if url.lastPathComponent == "jre.bundle" { url = url.deletingLastPathComponent() }
        return url
    }

    private func managedExecutablePaths() -> [URL] {
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: managedRoot,
            includingPropertiesForKeys: [.isDirectoryKey]
        ) else { return [] }
        return entries.compactMap { root -> URL? in
            guard !root.lastPathComponent.hasPrefix(".") else { return nil }
            let candidates = [
                root.appendingPathComponent("Contents/Home/bin/java"),
                root.appendingPathComponent("jre.bundle/Contents/Home/bin/java"),
                root.appendingPathComponent("bin/java"),
            ]
            return candidates.first { FileManager.default.isExecutableFile(atPath: $0.path) }
        }
    }

    private func findJavaExecutable(in root: URL) -> URL? {
        guard let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: [.isExecutableKey],
            options: [.skipsHiddenFiles]
        ) else { return nil }
        for case let url as URL in enumerator {
            if url.lastPathComponent == "java", url.path.hasSuffix("Contents/Home/bin/java") || url.path.hasSuffix("/bin/java") {
                return url
            }
        }
        return nil
    }

    private func extractTarGz(_ archive: URL, into destination: URL) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
        process.arguments = ["-xzf", archive.path, "-C", destination.path, "--no-same-owner"]
        let stderr = Pipe()
        process.standardError = stderr
        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            throw LauncherError(.ioFailure, "Cannot start tar: \(error.localizedDescription)")
        }
        guard process.terminationStatus == 0 else {
            let message = String(decoding: stderr.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            throw LauncherError(.ioFailure, "JDK archive extraction failed: \(message.prefix(300))")
        }
    }

    private func fetchLatestAsset(majorVersion: Int) async throws -> AdoptiumAsset {
        var components = URLComponents(url: Self.adoptiumAPI.appendingPathComponent("\(majorVersion)/hotspot"), resolvingAgainstBaseURL: false)!
        components.queryItems = [
            URLQueryItem(name: "architecture", value: "aarch64"),
            URLQueryItem(name: "image_type", value: "jdk"),
            URLQueryItem(name: "os", value: "mac"),
            URLQueryItem(name: "vendor", value: "eclipse"),
            URLQueryItem(name: "page_size", value: "1"),
        ]
        guard let url = components.url else { throw LauncherError(.invalidMetadata, "Invalid Adoptium API URL") }
        let data: Data
        do {
            data = try await transport.fetch(from: url)
        } catch {
            throw LauncherError(.downloadFailed, "Adoptium metadata request failed: \(error.localizedDescription)")
        }
        let assets: [AdoptiumAsset]
        do {
            assets = try JSONDecoder().decode([AdoptiumAsset].self, from: data)
        } catch {
            throw LauncherError(.invalidMetadata, "Adoptium metadata is invalid: \(error.localizedDescription)")
        }
        guard let asset = assets.first(where: {
            $0.binary.architecture == "aarch64" && $0.binary.image_type == "jdk" && $0.binary.os == "mac"
        }) else {
            throw LauncherError(
                .javaNotFound,
                "Adoptium has no macOS arm64 JDK \(majorVersion) build available",
                suggestion: "Choose another Java major version or select an installed JDK."
            )
        }
        return asset
    }

    private struct MojangRuntimeUnavailable: Error {
        let message: String
    }

    private struct MojangRuntimeIndex: Decodable {
        let macosArm64: [String: [MojangRuntimeCandidate]]?
        private enum CodingKeys: String, CodingKey { case macosArm64 = "mac-os-arm64" }
    }

    private struct MojangRuntimeCandidate: Decodable {
        struct Manifest: Decodable {
            let sha1: String
            let size: Int
            let url: String
        }
        struct Version: Decodable {
            let name: String
        }
        struct Availability: Decodable {
            let progress: Int?
        }
        let manifest: Manifest
        let version: Version
        let availability: Availability?
    }

    private struct MojangRuntimeFileManifest: Decodable {
        struct Entry: Decodable {
            struct Download: Decodable {
                let sha1: String
                let size: Int
                let url: String
            }
            let type: String
            let executable: Bool?
            let target: String?
            let downloads: [String: Download]?
        }
        let files: [String: Entry]
    }

    private struct ManagedSource: Codable {
        let vendor: String
        let version: String
        let downloadURL: String
        let checksum: String
        let license: String
        let checksumSHA1: String?
        let checksumSHA256: String?
        let component: String?
    }

    private struct AdoptiumAsset: Decodable {
        struct Binary: Decodable {
            struct Package: Decodable {
                let link: String
                let checksum: String
                let name: String
                let size: Int?
            }
            let architecture: String
            let image_type: String
            let os: String
            let package: Package
        }
        struct Version: Decodable {
            let semver: String
        }
        let binary: Binary
        let version: Version
    }
}
