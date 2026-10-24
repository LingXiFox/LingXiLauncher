import Foundation

/// The resolved (rule-filtered) view of a version, still free of any launch-time decision.
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
    public let inheritsFrom: String?
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
        inheritsFrom: String?,
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
        self.inheritsFrom = inheritsFrom
        self.versionDirectory = versionDirectory
        self.metadataURL = metadataURL
        self.releaseTime = releaseTime
    }
}
