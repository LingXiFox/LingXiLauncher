import Foundation

/// Downloadable artifact as described by Mojang metadata.
///
/// `urlString` is kept raw so that malformed metadata is reported where it matters
/// (download time) instead of failing an otherwise inspectable version.
public struct Artifact: Decodable, Sendable, Equatable {
    public let urlString: String?
    /// Relative path inside the `libraries` / `assets` root, e.g. `com/example/lib/1.0/lib-1.0.jar`.
    public let path: String?
    public let sha1: String?
    public let size: Int?
    /// Present on logging configuration files (`client-1.12.xml`), absent on libraries.
    public let id: String?

    public init(urlString: String? = nil, path: String? = nil, sha1: String? = nil, size: Int? = nil, id: String? = nil) {
        self.urlString = urlString
        self.path = path
        self.sha1 = sha1
        self.size = size
        self.id = id
    }

    public var url: URL? {
        guard let urlString else { return nil }
        return URL(string: urlString)
    }

    private enum CodingKeys: String, CodingKey {
        case url, path, sha1, size, id
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.urlString = try container.decodeIfPresent(String.self, forKey: .url)
        self.path = try container.decodeIfPresent(String.self, forKey: .path)
        self.sha1 = try container.decodeIfPresent(String.self, forKey: .sha1)
        self.size = try container.decodeIfPresent(Int.self, forKey: .size)
        self.id = try container.decodeIfPresent(String.self, forKey: .id)
    }

    /// File name to use when the artifact is stored outside the Maven layout (logging configs).
    public var preferredFileName: String? {
        if let id, !id.isEmpty { return id }
        if let path, !path.isEmpty { return (path as NSString).lastPathComponent }
        if let urlString, let url = URL(string: urlString), !url.lastPathComponent.isEmpty {
            return url.lastPathComponent
        }
        return nil
    }
}

/// `os.versionRange` bounds (newer metadata) evaluated numerically, part by part.
public struct VersionRange: Decodable, Sendable, Equatable {
    public let min: String?
    public let max: String?

    public init(min: String? = nil, max: String? = nil) {
        self.min = min
        self.max = max
    }
}

/// The `os` object of a rule.
///
/// Strictly decoded: an unrecognised field would silently change library/argument selection,
/// so it is rejected instead of ignored (see `RuleEvaluator` for the matching semantics).
public struct RuleOS: Decodable, Sendable, Equatable {
    public let name: String?
    /// Regular expression matched against the OS version string, e.g. `^10\\.0`.
    public let version: String?
    public let arch: String?
    public let versionRange: VersionRange?

    public init(name: String? = nil, version: String? = nil, arch: String? = nil, versionRange: VersionRange? = nil) {
        self.name = name
        self.version = version
        self.arch = arch
        self.versionRange = versionRange
    }

    private static let knownKeys: Set<String> = ["name", "version", "arch", "versionRange"]

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: AnyCodingKey.self)
        let unknown = container.unknownKeys(known: Self.knownKeys)
        if !unknown.isEmpty {
            throw LauncherError(
                .unsupportedVersion,
                "Unsupported rule field(s) in os: \(unknown.joined(separator: ", "))",
                suggestion: "Refusing to guess platform compatibility. Update LingXi Launcher or report the version JSON."
            )
        }
        self.name = try container.decodeIfPresent(String.self, forKey: AnyCodingKey("name"))
        self.version = try container.decodeIfPresent(String.self, forKey: AnyCodingKey("version"))
        self.arch = try container.decodeIfPresent(String.self, forKey: AnyCodingKey("arch"))
        self.versionRange = try container.decodeIfPresent(VersionRange.self, forKey: AnyCodingKey("versionRange"))
    }
}

/// A Mojang rule: `allow` / `disallow` with optional OS and feature conditions.
public struct Rule: Decodable, Sendable, Equatable {
    public enum Action: String, Decodable, Sendable, Equatable {
        case allow
        case disallow
    }

    public let action: Action
    public let os: RuleOS?
    public let features: [String: Bool]?

    public init(action: Action, os: RuleOS? = nil, features: [String: Bool]? = nil) {
        self.action = action
        self.os = os
        self.features = features
    }

    private static let knownKeys: Set<String> = ["action", "os", "features"]

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: AnyCodingKey.self)
        let unknown = container.unknownKeys(known: Self.knownKeys)
        if !unknown.isEmpty {
            throw LauncherError(
                .unsupportedVersion,
                "Unsupported rule field(s): \(unknown.joined(separator: ", "))",
                suggestion: "Refusing to guess rule semantics. Update LingXi Launcher or report the version JSON."
            )
        }
        self.action = try container.decode(Action.self, forKey: AnyCodingKey("action"))
        self.os = try container.decodeIfPresent(RuleOS.self, forKey: AnyCodingKey("os"))
        self.features = try container.decodeIfPresent([String: Bool].self, forKey: AnyCodingKey("features"))
    }
}

/// Maven coordinate parsed from a library `name` (`group:artifact:version[:classifier]`).
public struct MavenCoordinates: Sendable, Equatable, Hashable {
    public let group: String
    public let artifact: String
    public let version: String
    public let classifier: String?

    public init?(name: String) {
        let parts = name.split(separator: ":", omittingEmptySubsequences: false).map(String.init)
        guard parts.count == 3 || parts.count == 4, parts.prefix(3).allSatisfy({ !$0.isEmpty }) else {
            return nil
        }
        self.group = parts[0]
        self.artifact = parts[1]
        self.version = parts[2]
        self.classifier = parts.count == 4 ? parts[3] : nil
    }

    /// Path relative to the libraries root, e.g. `com/example/lib/1.0/lib-1.0.jar`.
    public var relativePath: String {
        let groupPath = group.replacingOccurrences(of: ".", with: "/")
        let suffix = classifier.map { "-\($0)" } ?? ""
        return "\(groupPath)/\(artifact)/\(version)/\(artifact)-\(version)\(suffix).jar"
    }
}

/// A `libraries[]` entry. Both the legacy form (`natives` + `downloads.classifiers`,
/// used up to ~1.18) and the modern form (native JARs listed as ordinary libraries with a
/// `natives-*` classifier in `name`) are represented by this single type.
public struct Library: Decodable, Sendable, Equatable {
    public let name: String
    public let rules: [Rule]?
    public let artifact: Artifact?
    public let classifiers: [String: Artifact]?
    /// OS name (`osx`, `linux`, `windows`) to classifier name, e.g. `osx: natives-macos`.
    public let natives: [String: String]?
    public let extractExclude: [String]?
    /// Maven repository base URL used by loader metadata (Fabric's `libraries[]` has `url`).
    public let urlString: String?
    /// Loader metadata often puts checksum/size beside `name` rather than under `downloads`.
    public let sha1: String?
    public let size: Int?

    public init(
        name: String,
        rules: [Rule]? = nil,
        artifact: Artifact? = nil,
        classifiers: [String: Artifact]? = nil,
        natives: [String: String]? = nil,
        extractExclude: [String]? = nil,
        urlString: String? = nil,
        sha1: String? = nil,
        size: Int? = nil
    ) {
        self.name = name
        self.rules = rules
        self.artifact = artifact
        self.classifiers = classifiers
        self.natives = natives
        self.extractExclude = extractExclude
        self.urlString = urlString
        self.sha1 = sha1
        self.size = size
    }

    public var coordinates: MavenCoordinates? {
        MavenCoordinates(name: name)
    }

    /// Relative path of the main JAR: metadata `downloads.artifact.path` wins, Maven layout is the fallback.
    public var artifactRelativePath: String? {
        if let path = artifact?.path { return path }
        if let derived = coordinates?.relativePath { return derived }
        return nil
    }

    /// Maven repository URL for loader libraries that omit `downloads.artifact`.
    public var mavenArtifactURL: URL? {
        guard let urlString, let base = URL(string: urlString), let path = artifactRelativePath else {
            return nil
        }
        let baseString = base.absoluteString.hasSuffix("/") ? base.absoluteString : base.absoluteString + "/"
        return URL(string: baseString + path)
    }

    /// Artifact representation for loader metadata that only supplies `name`/`url`/`sha1`.
    /// Vanilla's explicit `downloads.artifact` always wins.
    public var effectiveArtifact: Artifact? {
        if let artifact { return artifact }
        guard let path = artifactRelativePath, let url = mavenArtifactURL else { return nil }
        return Artifact(urlString: url.absoluteString, path: path, sha1: sha1, size: size)
    }

    private enum CodingKeys: String, CodingKey {
        case name, rules, downloads, natives, extract, url, sha1, size
    }

    private struct LibraryDownloads: Decodable {
        let artifact: Artifact?
        let classifiers: [String: Artifact]?
    }

    private struct Extract: Decodable {
        let exclude: [String]?
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.name = try container.decode(String.self, forKey: .name)
        self.rules = try container.decodeIfPresent([Rule].self, forKey: .rules)
        self.natives = try container.decodeIfPresent([String: String].self, forKey: .natives)
        self.urlString = try container.decodeIfPresent(String.self, forKey: .url)
        self.sha1 = try container.decodeIfPresent(String.self, forKey: .sha1)
        self.size = try container.decodeIfPresent(Int.self, forKey: .size)

        let downloads = try container.decodeIfPresent(LibraryDownloads.self, forKey: .downloads)
        self.artifact = downloads?.artifact
        self.classifiers = downloads?.classifiers
        self.extractExclude = try container.decodeIfPresent(Extract.self, forKey: .extract)?.exclude
    }
}

/// One entry of `arguments.jvm` / `arguments.game` / `default-user-jvm`:
/// either a plain string or a rule-gated list of values.
public enum ArgumentEntry: Decodable, Sendable, Equatable {
    case argument(String)
    case conditional(rules: [Rule], values: [String])

    private enum CodingKeys: String, CodingKey {
        case rules, value
    }

    public init(from decoder: Decoder) throws {
        let single = try decoder.singleValueContainer()
        if let plain = try? single.decode(String.self) {
            self = .argument(plain)
            return
        }
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let rules = try container.decodeIfPresent([Rule].self, forKey: .rules) ?? []
        let raw = try container.decode(StringOrArray.self, forKey: .value)
        self = .conditional(rules: rules, values: raw.values)
    }
}

public struct VersionArguments: Decodable, Sendable, Equatable {
    public let game: [ArgumentEntry]
    public let jvm: [ArgumentEntry]
    /// Launcher-side default JVM flags. Mojang puts this at `arguments.default-user-jvm`
    /// (observed in 1.21.9+/26.x metadata); it is not a per-version requirement.
    public let defaultUserJVMArguments: [ArgumentEntry]

    public init(
        game: [ArgumentEntry] = [],
        jvm: [ArgumentEntry] = [],
        defaultUserJVMArguments: [ArgumentEntry] = []
    ) {
        self.game = game
        self.jvm = jvm
        self.defaultUserJVMArguments = defaultUserJVMArguments
    }

    private enum CodingKeys: String, CodingKey {
        case game, jvm
        case defaultUserJVMArguments = "default-user-jvm"
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.game = try container.decodeIfPresent([ArgumentEntry].self, forKey: .game) ?? []
        self.jvm = try container.decodeIfPresent([ArgumentEntry].self, forKey: .jvm) ?? []
        self.defaultUserJVMArguments = try container.decodeIfPresent([ArgumentEntry].self, forKey: .defaultUserJVMArguments) ?? []
    }
}

public struct AssetIndex: Decodable, Sendable, Equatable {
    public let id: String
    public let sha1: String?
    public let size: Int?
    public let totalSize: Int?
    public let urlString: String?

    public init(id: String, sha1: String? = nil, size: Int? = nil, totalSize: Int? = nil, urlString: String? = nil) {
        self.id = id
        self.sha1 = sha1
        self.size = size
        self.totalSize = totalSize
        self.urlString = urlString
    }

    public var url: URL? {
        guard let urlString else { return nil }
        return URL(string: urlString)
    }

    private enum CodingKeys: String, CodingKey {
        case id, sha1, size, totalSize
        case urlString = "url"
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try container.decode(String.self, forKey: .id)
        self.sha1 = try container.decodeIfPresent(String.self, forKey: .sha1)
        self.size = try container.decodeIfPresent(Int.self, forKey: .size)
        self.totalSize = try container.decodeIfPresent(Int.self, forKey: .totalSize)
        self.urlString = try container.decodeIfPresent(String.self, forKey: .urlString)
    }
}

public struct JavaVersionRequirement: Decodable, Sendable, Equatable {
    /// Mojang runtime component id, e.g. `java-runtime-gamma`. Absent on older metadata.
    public let component: String?
    public let majorVersion: Int?

    public init(component: String? = nil, majorVersion: Int? = nil) {
        self.component = component
        self.majorVersion = majorVersion
    }
}

public struct ClientLogging: Decodable, Sendable, Equatable {
    public let argument: String
    public let file: Artifact
    public let type: String?

    public init(argument: String, file: Artifact, type: String? = nil) {
        self.argument = argument
        self.file = file
        self.type = type
    }
}

public struct LoggingSettings: Decodable, Sendable, Equatable {
    public let client: ClientLogging?
}

public struct VersionDownloads: Decodable, Sendable, Equatable {
    public let client: Artifact?
    public let server: Artifact?
}

/// A decoded per-version JSON.
///
/// Tolerance policy (documented in `docs/DEVELOPMENT.md`):
/// - Unknown top-level fields are ignored: Mojang adds fields over time and they do not
///   change how an already parsed version is launched.
/// - Fields that *do* change behaviour (`rules`, `os`, `arguments`, `natives`, `downloads`)
///   are decoded strictly: an unrecognised rule field aborts with `UNSUPPORTED_VERSION`
///   instead of silently allowing or dropping something.
/// - Missing optional fields degrade predictably (`javaVersion` absent ⇒ no Java major
///   requirement; `assetIndex` absent ⇒ legacy `assets` id used as a name).
public struct VersionMetadata: Decodable, Sendable, Equatable {
    public let id: String
    public let type: String?
    public let mainClass: String
    public let assets: String?
    public let assetIndex: AssetIndex?
    public let downloads: VersionDownloads?
    public let javaVersion: JavaVersionRequirement?
    public let libraries: [Library]
    public let arguments: VersionArguments?
    /// Legacy (pre-1.13) game arguments string. Parsed only to produce a clear error.
    public let minecraftArguments: String?
    public let logging: LoggingSettings?
    public let inheritsFrom: String?
    /// Newer launcher-side default JVM flags (`default-user-jvm`, 1.21.9+/26.x metadata).
    public let defaultUserJVMArguments: [ArgumentEntry]?
    public let minimumLauncherVersion: Int?
    public let releaseTime: String?
    public let complianceLevel: Int?

    public init(
        id: String,
        type: String? = nil,
        mainClass: String,
        assets: String? = nil,
        assetIndex: AssetIndex? = nil,
        downloads: VersionDownloads? = nil,
        javaVersion: JavaVersionRequirement? = nil,
        libraries: [Library] = [],
        arguments: VersionArguments? = nil,
        minecraftArguments: String? = nil,
        logging: LoggingSettings? = nil,
        inheritsFrom: String? = nil,
        defaultUserJVMArguments: [ArgumentEntry]? = nil,
        minimumLauncherVersion: Int? = nil,
        releaseTime: String? = nil,
        complianceLevel: Int? = nil
    ) {
        self.id = id
        self.type = type
        self.mainClass = mainClass
        self.assets = assets
        self.assetIndex = assetIndex
        self.downloads = downloads
        self.javaVersion = javaVersion
        self.libraries = libraries
        self.arguments = arguments
        self.minecraftArguments = minecraftArguments
        self.logging = logging
        self.inheritsFrom = inheritsFrom
        self.defaultUserJVMArguments = defaultUserJVMArguments
        self.minimumLauncherVersion = minimumLauncherVersion
        self.releaseTime = releaseTime
        self.complianceLevel = complianceLevel
    }

    private enum CodingKeys: String, CodingKey {
        case id, type, mainClass, assets, assetIndex, downloads, javaVersion, libraries
        case arguments, minecraftArguments, logging, inheritsFrom
        case defaultUserJVMArguments = "default-user-jvm"
        case minimumLauncherVersion, releaseTime, complianceLevel
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try container.decode(String.self, forKey: .id)
        self.type = try container.decodeIfPresent(String.self, forKey: .type)
        self.mainClass = try container.decode(String.self, forKey: .mainClass)
        self.assets = try container.decodeIfPresent(String.self, forKey: .assets)
        self.assetIndex = try container.decodeIfPresent(AssetIndex.self, forKey: .assetIndex)
        self.downloads = try container.decodeIfPresent(VersionDownloads.self, forKey: .downloads)
        self.javaVersion = try container.decodeIfPresent(JavaVersionRequirement.self, forKey: .javaVersion)
        self.libraries = try container.decodeIfPresent([Library].self, forKey: .libraries) ?? []
        self.arguments = try container.decodeIfPresent(VersionArguments.self, forKey: .arguments)
        self.minecraftArguments = try container.decodeIfPresent(String.self, forKey: .minecraftArguments)
        self.logging = try container.decodeIfPresent(LoggingSettings.self, forKey: .logging)
        self.inheritsFrom = try container.decodeIfPresent(String.self, forKey: .inheritsFrom)
        self.defaultUserJVMArguments = try container.decodeIfPresent([ArgumentEntry].self, forKey: .defaultUserJVMArguments)
        self.minimumLauncherVersion = try container.decodeIfPresent(Int.self, forKey: .minimumLauncherVersion)
        self.releaseTime = try container.decodeIfPresent(String.self, forKey: .releaseTime)
        self.complianceLevel = try container.decodeIfPresent(Int.self, forKey: .complianceLevel)
    }

    public static func decode(from data: Data, context: String = "version JSON") throws -> VersionMetadata {
        try data.decodeLauncherJSON(VersionMetadata.self, context: context)
    }
}
