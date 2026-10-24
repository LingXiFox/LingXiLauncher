import Foundation

/// A file the launcher expects to exist locally, together with the metadata needed to fetch
/// and verify it later (M2). M1 only reports whether it exists.
public struct ResolvedFile: Sendable, Equatable {
    public let path: URL
    public let sha1: String?
    public let size: Int?
    public let downloadURL: URL?

    public init(path: URL, sha1: String? = nil, size: Int? = nil, downloadURL: URL? = nil) {
        self.path = path
        self.sha1 = sha1
        self.size = size
        self.downloadURL = downloadURL
    }
}

/// A native JAR that must be extracted into the version/arch-scoped natives cache.
///
/// Only the legacy metadata layout (`natives.osx` + `downloads.classifiers`) produces these.
/// Modern versions ship natives as ordinary libraries on the classpath, so they produce none.
public struct ResolvedNative: Sendable, Equatable {
    public let classifier: String
    public let file: ResolvedFile
    public let extractExclude: [String]
    /// Best-effort architecture hint derived from the classifier name (`natives-macos-arm64`).
    public let architectureHint: PlatformContext.CPUArch?

    public init(
        classifier: String,
        file: ResolvedFile,
        extractExclude: [String] = [],
        architectureHint: PlatformContext.CPUArch? = nil
    ) {
        self.classifier = classifier
        self.file = file
        self.extractExclude = extractExclude
        self.architectureHint = architectureHint
    }
}

/// A dependency the launcher could not find locally.
public struct MissingDependency: Sendable, Equatable, CustomStringConvertible {
    public enum Kind: String, Sendable, Equatable, Codable {
        case clientJar = "client-jar"
        case library
        case native
        case assetIndex = "asset-index"
        case assetObject = "asset-object"
        case loggingConfig = "logging-config"
    }

    public enum Reason: String, Sendable, Equatable, Codable {
        case absent
        case emptyFile = "empty-file"
        /// Present but the size differs from metadata. Hash verification itself is M2.
        case sizeMismatch = "size-mismatch"
        case invalidDownloadURL = "invalid-download-url"
    }

    public let kind: Kind
    public let path: URL
    public let reason: Reason
    public let downloadURL: URL?
    public let sha1: String?
    public let size: Int?

    public init(
        kind: Kind,
        path: URL,
        reason: Reason,
        downloadURL: URL? = nil,
        sha1: String? = nil,
        size: Int? = nil
    ) {
        self.kind = kind
        self.path = path
        self.reason = reason
        self.downloadURL = downloadURL
        self.sha1 = sha1
        self.size = size
    }

    public var description: String {
        "\(kind.rawValue) \(reason.rawValue): \(path.path)"
    }
}

/// Rule-filtered plan of which files a launch needs, and which of them are missing.
public struct DependencyResolution: Sendable {
    /// The layout the paths were resolved against. The plan builder needs it for
    /// `${library_directory}` / `${assets_root}` style placeholders.
    public let layout: GameDataLayout
    /// Classpath entries in metadata order, de-duplicated.
    public let classpath: [URL]
    public let classpathFiles: [ResolvedFile]
    public let legacyNatives: [ResolvedNative]
    public let nativesDirectory: URL
    public let clientJar: ResolvedFile?
    public let assetIndexFile: ResolvedFile?
    public let loggingFile: ResolvedFile?
    public let missing: [MissingDependency]
    public let diagnostics: [LaunchDiagnostic]

    public init(
        layout: GameDataLayout,
        classpath: [URL],
        classpathFiles: [ResolvedFile],
        legacyNatives: [ResolvedNative],
        nativesDirectory: URL,
        clientJar: ResolvedFile?,
        assetIndexFile: ResolvedFile?,
        loggingFile: ResolvedFile?,
        missing: [MissingDependency],
        diagnostics: [LaunchDiagnostic]
    ) {
        self.layout = layout
        self.classpath = classpath
        self.classpathFiles = classpathFiles
        self.legacyNatives = legacyNatives
        self.nativesDirectory = nativesDirectory
        self.clientJar = clientJar
        self.assetIndexFile = assetIndexFile
        self.loggingFile = loggingFile
        self.missing = missing
        self.diagnostics = diagnostics
    }
}
