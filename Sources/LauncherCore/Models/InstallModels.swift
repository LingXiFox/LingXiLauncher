import Foundation

/// Phases reported by the installer, in execution order.
public enum InstallPhase: String, Sendable, Equatable, Codable {
    case manifest
    case versionMetadata = "version-metadata"
    case assetIndex = "asset-index"
    case downloading
    case extractingNatives = "extracting-natives"
    case loaderMetadata = "loader-metadata"
    case loaderProfile = "loader-profile"
    case loaderLibraries = "loader-libraries"
    case finalizing
}

/// Progress events. Delivered from concurrent download tasks; consumers must be thread-safe.
public enum InstallProgressEvent: Sendable, Equatable {
    case phase(InstallPhase, String)
    case plan(totalFiles: Int, totalBytes: Int, cacheHits: Int)
    case fileStarted(path: String, size: Int)
    case fileFinished(path: String, bytes: Int, source: String)
    case fileFailed(path: String, message: String)
}

/// One file the installer wants to exist locally.
public struct DownloadTask: Sendable, Equatable {
    public let destination: URL
    /// URL from the version/asset metadata. `nil` means the metadata gives no source.
    public let officialURL: URL?
    public let sha1: String?
    public let size: Int?
    public let kind: MissingDependency.Kind

    public init(destination: URL, officialURL: URL?, sha1: String?, size: Int?, kind: MissingDependency.Kind) {
        self.destination = destination
        self.officialURL = officialURL
        self.sha1 = sha1?.lowercased()
        self.size = size
        self.kind = kind
    }
}

public struct DownloadedFile: Sendable, Equatable {
    public let path: URL
    public let bytes: Int
    public let source: String
}

public struct DownloadFailure: Sendable, Equatable {
    public let task: DownloadTask
    public let code: LauncherError.Code
    public let message: String
}

public struct DownloadSummary: Sendable {
    public let downloaded: [DownloadedFile]
    public let cacheHits: Int
    public let failures: [DownloadFailure]

    public var downloadedBytes: Int {
        downloaded.reduce(0) { $0 + $1.bytes }
    }

    public init(downloaded: [DownloadedFile], cacheHits: Int, failures: [DownloadFailure]) {
        self.downloaded = downloaded
        self.cacheHits = cacheHits
        self.failures = failures
    }
}

public struct DownloadConfiguration: Sendable, Equatable {
    /// Bounded parallelism. Default 4 as required by the spec.
    public var concurrency: Int
    /// Attempts per source URL for retryable failures.
    public var maxRetries: Int
    /// Base delay between retries (grows linearly, capped at 5 s).
    public var retryDelay: TimeInterval
    /// Skip the free-disk-space preflight (tests only).
    public var skipDiskSpaceCheck: Bool

    public init(concurrency: Int = 4, maxRetries: Int = 3, retryDelay: TimeInterval = 0.5, skipDiskSpaceCheck: Bool = false) {
        self.concurrency = max(1, concurrency)
        self.maxRetries = max(1, maxRetries)
        self.retryDelay = max(0, retryDelay)
        self.skipDiskSpaceCheck = skipDiskSpaceCheck
    }
}

/// The result of a full installation.
public struct InstallReport: Sendable {
    public let versionID: String
    public let instanceID: String
    public let gameDirectory: URL
    public let downloadedFiles: Int
    public let downloadedBytes: Int
    public let cacheHits: Int
    public let assetObjectCount: Int
    public let extractedNatives: Int
    public let missingAfterInstall: [MissingDependency]
    public let diagnostics: [LaunchDiagnostic]
    public let javaRequirement: JavaVersionRequirement
    public let sourcePolicy: DownloadSourcePolicy
    /// The JVM architecture the installation was planned for (natives, rules, cache paths).
    public let platformArchitecture: PlatformContext.CPUArch

    public var isComplete: Bool { missingAfterInstall.isEmpty }
}

public struct VerificationIssue: Sendable, Equatable, CustomStringConvertible {
    public enum Kind: String, Sendable, Equatable {
        case missing
        case emptyFile = "empty-file"
        case sizeMismatch = "size-mismatch"
        case hashMismatch = "hash-mismatch"
        case readError = "read-error"
    }

    public let kind: Kind
    public let path: URL
    public let expected: String?
    public let actual: String?

    public init(kind: Kind, path: URL, expected: String? = nil, actual: String? = nil) {
        self.kind = kind
        self.path = path
        self.expected = expected
        self.actual = actual
    }

    public var description: String {
        var text = "\(kind.rawValue): \(path.path)"
        if let expected { text += " (expected \(expected))" }
        if let actual { text += " (actual \(actual))" }
        return text
    }
}

public struct VerificationReport: Sendable {
    public let versionID: String
    public let checkedFiles: Int
    public let checkedBytes: Int
    public let issues: [VerificationIssue]

    public var isClean: Bool { issues.isEmpty }
    public var missingCount: Int { issues.filter { $0.kind == .missing }.count }
    public var mismatchCount: Int {
        issues.filter { $0.kind == .sizeMismatch || $0.kind == .hashMismatch || $0.kind == .emptyFile }.count
    }
}
