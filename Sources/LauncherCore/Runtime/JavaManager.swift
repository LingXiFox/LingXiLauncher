import Foundation

public struct ManagedJava: Sendable, Equatable {
    public let runtime: JavaRuntime
    public let source: String
    public let sourceURL: URL
    public let license: String
    public let storage: URL

    public init(runtime: JavaRuntime, source: String, sourceURL: URL, license: String, storage: URL) {
        self.runtime = runtime
        self.source = source
        self.sourceURL = sourceURL
        self.license = license
        self.storage = storage
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
                storage: storage
            )
        }
    }

    /// Returns the closest compatible runtime, preferring arm64. The user's explicit preference
    /// is returned only if it satisfies the metadata requirement.
    public func selectCompatible(
        requirement: JavaVersionRequirement,
        preferredExecutable: URL? = nil
    ) -> JavaRuntime? {
        let required = requirement.majorVersion ?? 0
        if let preferredExecutable,
           let runtime = try? inspector.inspect(executable: preferredExecutable),
           runtime.majorVersion >= required {
            return runtime
        }
        let candidates = detectRuntimes().filter { $0.majorVersion >= required }
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

    // MARK: - Managed install

    /// Downloads and verifies the requested Adoptium Temurin JDK, then extracts it into the
    /// launcher's private runtime directory. The caller must present the source/license and ask
    /// for confirmation before invoking this method.
    public func installManagedJava(
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
        let sanitizedVersion = asset.version.semver.replacingOccurrences(of: "+", with: "_")
            .replacingOccurrences(of: "/", with: "_")
        let finalRoot = managedRoot.appendingPathComponent("temurin-\(majorVersion)-\(sanitizedVersion)", isDirectory: true)
        if fm.fileExists(atPath: finalRoot.path) {
            try? fm.removeItem(at: finalRoot)
        }
        try fm.moveItem(at: root, to: finalRoot)
        let finalJava = finalRoot.appendingPathComponent("Contents/Home/bin/java")
        guard fm.isExecutableFile(atPath: finalJava.path) else {
            throw LauncherError(.ioFailure, "Managed JDK layout is unexpected: \(finalJava.path) is not executable")
        }
        let source = ManagedSource(
            vendor: Self.managedSourceName,
            version: asset.version.semver,
            downloadURL: downloadURL.absoluteString,
            checksum: package.checksum,
            license: Self.managedLicense
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(source).write(to: finalRoot.appendingPathComponent("source.json"), options: [.atomic])
        let runtime = try inspector.inspect(executable: finalJava)
        progress(.ready(finalJava))
        return ManagedJava(
            runtime: runtime,
            source: Self.managedSourceName,
            sourceURL: downloadURL,
            license: Self.managedLicense,
            storage: finalRoot
        )
    }

    // MARK: - Helpers

    /// Strips `Contents/Home/bin/java` (macOS JDK) or `bin/java` and returns the JDK root.
    private static func installationRoot(for javaURL: URL) -> URL {
        var url = javaURL.deletingLastPathComponent() // bin
        if url.lastPathComponent == "bin" { url = url.deletingLastPathComponent() }
        if url.lastPathComponent == "Home" { url = url.deletingLastPathComponent() }
        if url.lastPathComponent == "Contents" { url = url.deletingLastPathComponent() }
        return url
    }

    private func managedExecutablePaths() -> [URL] {
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: managedRoot,
            includingPropertiesForKeys: [.isDirectoryKey]
        ) else { return [] }
        return entries.compactMap { root -> URL? in
            let mac = root.appendingPathComponent("Contents/Home/bin/java")
            if FileManager.default.isExecutableFile(atPath: mac.path) { return mac }
            let flat = root.appendingPathComponent("bin/java")
            return FileManager.default.isExecutableFile(atPath: flat.path) ? flat : nil
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

    private struct ManagedSource: Codable {
        let vendor: String
        let version: String
        let downloadURL: String
        let checksum: String
        let license: String
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
