import Foundation

/// The resolved (rule-filtered) view of a version, still free of any launch-time decision.
public enum VersionCompatibility: String, Sendable, Equatable {
    /// Modern `arguments` metadata merged without legacy assumptions.
    case modern
    /// Legacy `minecraftArguments` was converted and a baseline JVM argument set was supplied.
    case legacyArguments = "legacy-arguments"
    /// Metadata is structurally incomplete; callers must not present it as fully compatible.
    case incomplete
}

public struct ResolvedVersion: Sendable {
    public let id: String
    public let type: String
    public let mainClass: String
    /// Asset index id (`assetIndex.id` when present, otherwise the legacy `assets` string).
    public let assetIndexID: String
    public let javaRequirement: JavaVersionRequirement
    /// All libraries, in metadata order, with rules **not** yet evaluated.
    public let libraries: [Library]
    public let jvmArguments: [ArgumentEntry]
    public let gameArguments: [ArgumentEntry]
    public let defaultUserJVMArguments: [ArgumentEntry]
    public let assetIndex: AssetIndex?
    public let clientLogging: ClientLogging?
    public let clientJar: Artifact?
    /// The version whose client JAR must be on the classpath. Fabric inherits the vanilla
    /// client JAR instead of expecting a JAR named after the Fabric profile.
    public let clientJarVersionID: String
    /// Version id whose shared natives cache is used. Fabric reuses the vanilla parent's
    /// extracted natives, so the cache is never keyed by a profile JAR that has no natives.
    public let nativesVersionID: String
    public let inheritsFrom: String?
    public let compatibility: VersionCompatibility
    public let versionDirectory: URL
    public let metadataURL: URL
    public let releaseTime: String?

    public init(
        id: String,
        type: String,
        mainClass: String,
        assetIndexID: String,
        javaRequirement: JavaVersionRequirement,
        libraries: [Library],
        jvmArguments: [ArgumentEntry],
        gameArguments: [ArgumentEntry],
        defaultUserJVMArguments: [ArgumentEntry],
        assetIndex: AssetIndex?,
        clientLogging: ClientLogging?,
        clientJar: Artifact?,
        clientJarVersionID: String? = nil,
        nativesVersionID: String? = nil,
        inheritsFrom: String?,
        compatibility: VersionCompatibility = .modern,
        versionDirectory: URL,
        metadataURL: URL,
        releaseTime: String?
    ) {
        self.id = id
        self.type = type
        self.mainClass = mainClass
        self.assetIndexID = assetIndexID
        self.javaRequirement = javaRequirement
        self.libraries = libraries
        self.jvmArguments = jvmArguments
        self.gameArguments = gameArguments
        self.defaultUserJVMArguments = defaultUserJVMArguments
        self.assetIndex = assetIndex
        self.clientLogging = clientLogging
        self.clientJar = clientJar
        self.clientJarVersionID = clientJarVersionID ?? id
        self.nativesVersionID = nativesVersionID ?? clientJarVersionID ?? id
        self.inheritsFrom = inheritsFrom
        self.compatibility = compatibility
        self.versionDirectory = versionDirectory
        self.metadataURL = metadataURL
        self.releaseTime = releaseTime
    }
}
