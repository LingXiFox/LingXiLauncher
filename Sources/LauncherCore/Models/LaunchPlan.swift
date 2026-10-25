import Foundation

/// Everything the pure launch-plan transformation needs from the outside world.
public struct LaunchContext: Sendable {
    /// Instance root, e.g. `~/Library/Application Support/LingXiLauncher/instances/<id>`.
    public let instanceDirectory: URL
    /// The game working directory (`<instance>/.minecraft`). Saves, options and logs live here.
    public let gameDirectory: URL
    public let javaExecutable: URL
    /// Rule-evaluation context for the **selected JVM** (OS/version from the host, architecture
    /// measured from that Java). Never derive rules from the launcher process architecture.
    public let platform: PlatformContext
    public let identity: LaunchIdentity
    public let additionalJVMArguments: [String]
    /// Launcher-controlled feature flags (demo mode, custom resolution, quick play, ...).
    /// Absent means disabled — never enabled implicitly.
    public let features: [String: Bool]
    public let launcherName: String
    public let launcherVersion: String

    public init(
        instanceDirectory: URL,
        gameDirectory: URL,
        javaExecutable: URL,
        platform: PlatformContext,
        identity: LaunchIdentity,
        additionalJVMArguments: [String] = [],
        features: [String: Bool] = [:],
        launcherName: String = "LingXi Launcher",
        launcherVersion: String = LauncherInfo.version
    ) {
        self.instanceDirectory = instanceDirectory
        self.gameDirectory = gameDirectory
        self.javaExecutable = javaExecutable
        // Launcher-controlled features belong to the platform context used for rule evaluation.
        let mergedFeatures = platform.features.merging(features) { _, newValue in newValue }
        self.platform = PlatformContext(
            os: platform.os,
            architecture: platform.architecture,
            osVersion: platform.osVersion,
            features: mergedFeatures,
            hostArchitecture: platform.hostArchitecture
        )
        self.identity = identity
        self.additionalJVMArguments = additionalJVMArguments
        self.features = mergedFeatures
        self.launcherName = launcherName
        self.launcherVersion = launcherVersion
    }
}

public enum LauncherInfo {
    public static let name = "LingXi Launcher"
    public static let version = "0.1.0"
}

/// The immutable, fully resolved launch command.
///
/// Contains live credentials in `arguments` when the identity is `microsoft`.
/// Serializing `description`, `debugDescription` or `redactedArguments` is always safe;
/// never log `arguments` directly.
public struct LaunchPlan: Sendable, CustomStringConvertible, CustomDebugStringConvertible {
    public let javaExecutable: URL
    /// Real argv. May contain a session token in Microsoft mode — do not log.
    public let arguments: [String]
    /// The same argv with sensitive values replaced by `LauncherInfo.redactionPlaceholder`.
    public let redactedArguments: [String]
    public let workingDirectory: URL
    public let environmentOverrides: [String: String]
    public let versionID: String
    public let identityMode: IdentityMode

    public init(
        javaExecutable: URL,
        arguments: [String],
        redactedArguments: [String],
        workingDirectory: URL,
        environmentOverrides: [String: String] = [:],
        versionID: String,
        identityMode: IdentityMode
    ) {
        self.javaExecutable = javaExecutable
        self.arguments = arguments
        self.redactedArguments = redactedArguments
        self.workingDirectory = workingDirectory
        self.environmentOverrides = environmentOverrides
        self.versionID = versionID
        self.identityMode = identityMode
    }

    public var description: String {
        "<LaunchPlan version=\(versionID) identity=\(identityMode.rawValue) java=\(javaExecutable.path) arguments=<redacted, count=\(arguments.count)>>"
    }

    public var debugDescription: String { description }
}

/// A redacted, non-executable preview of a launch. Contains no credentials at all.
public struct LaunchPreview: Sendable, CustomStringConvertible {
    public let identityMode: IdentityMode
    public let identityDisplayName: String
    public let versionID: String
    public let javaExecutable: URL
    public let mainClass: String
    public let classpathEntryCount: Int
    public let classpathEntries: [String]
    public let gameDirectory: URL
    public let jvmArguments: [String]
    /// Game arguments with tokens replaced by the redaction placeholder.
    public let gameArguments: [String]
    public let missingDependencies: [MissingDependency]
    public let diagnostics: [LaunchDiagnostic]

    public init(
        identityMode: IdentityMode,
        identityDisplayName: String,
        versionID: String,
        javaExecutable: URL,
        mainClass: String,
        classpathEntryCount: Int,
        classpathEntries: [String] = [],
        gameDirectory: URL,
        jvmArguments: [String],
        gameArguments: [String],
        missingDependencies: [MissingDependency] = [],
        diagnostics: [LaunchDiagnostic] = []
    ) {
        self.identityMode = identityMode
        self.identityDisplayName = identityDisplayName
        self.versionID = versionID
        self.javaExecutable = javaExecutable
        self.mainClass = mainClass
        self.classpathEntryCount = classpathEntryCount
        self.classpathEntries = classpathEntries
        self.gameDirectory = gameDirectory
        self.jvmArguments = jvmArguments
        self.gameArguments = gameArguments
        self.missingDependencies = missingDependencies
        self.diagnostics = diagnostics
    }

    public var hasBlockingDiagnostics: Bool {
        !missingDependencies.isEmpty || diagnostics.contains { $0.severity == .error }
    }

    public var description: String {
        "<LaunchPreview version=\(versionID) identity=\(identityMode.rawValue) classpath=\(classpathEntryCount) missing=\(missingDependencies.count) errors=\(diagnostics.filter { $0.severity == .error }.count)>"
    }
}

public extension LauncherInfo {
    /// Placeholder substituted for session tokens in every default output path.
    static let redactionPlaceholder = "<redacted>"
}
