import Foundation

/// Filesystem layout of the game data root and the launcher data root.
///
/// ```text
/// <dataRoot>/versions/<id>/<id>.json        (when the launcher owns the game root)
/// <gameRoot>/versions/<id>/<id>.jar
/// <gameRoot>/libraries/<maven path>
/// <gameRoot>/assets/indexes/<id>.json
/// <gameRoot>/assets/objects/<hash[0..2]>/<hash>
/// <dataRoot>/.minecraft/versions/<instance-id>   (one shared .minecraft)
/// <dataRoot>/instances/<instance-id>/instance.json
/// <dataRoot>/natives/<version-id>/<arch>
/// <dataRoot>/accounts/local/<name>.json
/// <dataRoot>/cache/manifests
/// <dataRoot>/logs/launcher
/// ```
///
/// `gameRoot` may point at an existing official-launcher directory. M1 treats it as read-only:
/// nothing is written there unless the caller explicitly asks for it.
public struct GameDataLayout: Sendable, Equatable {
    public let gameRoot: URL
    public let dataRoot: URL

    public init(gameRoot: URL, dataRoot: URL = GameDataLayout.defaultDataRoot) {
        self.gameRoot = gameRoot.standardizedFileURL
        self.dataRoot = dataRoot.standardizedFileURL
    }

    public static var defaultDataRoot: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/LingXiLauncher", isDirectory: true)
    }

    /// The official launcher's default location, used as a read-only M1 sample when present.
    public static var officialMinecraftRoot: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/minecraft", isDirectory: true)
    }

    public var versionsDirectory: URL { gameRoot.appendingPathComponent("versions", isDirectory: true) }
    public var librariesDirectory: URL { gameRoot.appendingPathComponent("libraries", isDirectory: true) }
    public var assetsDirectory: URL { gameRoot.appendingPathComponent("assets", isDirectory: true) }
    public var assetIndexesDirectory: URL { assetsDirectory.appendingPathComponent("indexes", isDirectory: true) }
    public var assetObjectsDirectory: URL { assetsDirectory.appendingPathComponent("objects", isDirectory: true) }

    public var instancesDirectory: URL { dataRoot.appendingPathComponent("instances", isDirectory: true) }

    /// The single user-facing game data root. There is exactly one `.minecraft` per launcher
    /// data root; every instance is forced into its own isolated version directory below it.
    public var minecraftDirectory: URL { dataRoot.appendingPathComponent(".minecraft", isDirectory: true) }

    /// Root for forced version/isolation game directories. The directory name is intentional:
    /// profiles never share saves, options, mods or logs.
    public var isolationRoot: URL { minecraftDirectory.appendingPathComponent("versions", isDirectory: true) }
    public var nativesRoot: URL { dataRoot.appendingPathComponent("natives", isDirectory: true) }
    public var accountsDirectory: URL { dataRoot.appendingPathComponent("accounts", isDirectory: true) }
    public var localAccountsDirectory: URL { accountsDirectory.appendingPathComponent("local", isDirectory: true) }
    public var launcherLogsDirectory: URL { dataRoot.appendingPathComponent("logs/launcher", isDirectory: true) }
    public var manifestsCacheDirectory: URL { dataRoot.appendingPathComponent("cache/manifests", isDirectory: true) }

    /// Instance/world backups live outside the game directory so deleting a world or instance
    /// can never take its recovery copies with it.
    public var backupsDirectory: URL { dataRoot.appendingPathComponent("backups", isDirectory: true) }

    /// Where Mojang's log4j configuration files live (`assets/log_configs`).
    public var loggingConfigsDirectory: URL { assetsDirectory.appendingPathComponent("log_configs", isDirectory: true) }

    public func loggingConfigURL(id: String) throws -> URL {
        let component = try PathSafety.validatedPathComponent(id)
        return loggingConfigsDirectory.appendingPathComponent(component, isDirectory: false)
    }

    public func versionDirectory(_ versionID: String) throws -> URL {
        try versionsDirectory.appendingPathComponent(PathSafety.validatedPathComponent(versionID), isDirectory: true)
    }

    public func versionJSONURL(_ versionID: String) throws -> URL {
        let component = try PathSafety.validatedPathComponent(versionID)
        // Official launchers name the metadata file after the version id; some third-party
        // launchers use <id>.json too, so this stays the canonical location.
        return try versionDirectory(versionID).appendingPathComponent("\(component).json", isDirectory: false)
    }

    public func clientJarURL(_ versionID: String) throws -> URL {
        let component = try PathSafety.validatedPathComponent(versionID)
        return try versionDirectory(versionID).appendingPathComponent("\(component).jar", isDirectory: false)
    }

    public func libraryURL(relativePath: String) throws -> URL {
        try PathSafety.safeJoin(base: librariesDirectory, relativePath: relativePath)
    }

    public func assetIndexURL(id: String) throws -> URL {
        let component = try PathSafety.validatedPathComponent(id)
        return assetIndexesDirectory.appendingPathComponent("\(component).json", isDirectory: false)
    }

    public func assetObjectURL(sha1: String) throws -> URL {
        let hash = sha1.lowercased()
        guard hash.count >= 2, hash.allSatisfy({ $0.isHexDigit }) else {
            throw LauncherError(.invalidMetadata, "Asset hash '\(sha1)' is not a hex digest")
        }
        let prefix = String(hash.prefix(2))
        return try PathSafety.safeJoin(base: assetObjectsDirectory, relativePath: "\(prefix)/\(hash)")
    }

    /// Natives extraction cache. Scoped per version **and** architecture so an x86_64 cache
    /// can never be reused by an arm64 JVM.
    public func nativesDirectory(versionID: String, architecture: PlatformContext.CPUArch) throws -> URL {
        try nativesRoot
            .appendingPathComponent(PathSafety.validatedPathComponent(versionID), isDirectory: true)
            .appendingPathComponent(PathSafety.validatedPathComponent(architecture.rawValue), isDirectory: true)
    }

    public func instanceDirectory(_ instanceID: String) throws -> URL {
        try instancesDirectory.appendingPathComponent(PathSafety.validatedPathComponent(instanceID), isDirectory: true)
    }

    /// Forced version isolation: `<dataRoot>/.minecraft/versions/<instance-id>`.
    /// The instance's metadata directory (under `instances/`) never contains a nested
    /// `.minecraft`; all game writes are confined to this single `.minecraft` tree.
    public func instanceGameDirectory(_ instanceID: String) throws -> URL {
        try isolationRoot.appendingPathComponent(PathSafety.validatedPathComponent(instanceID), isDirectory: true)
    }

    /// The directory game-side logs are written into by the game itself (`<gameDir>/logs`).
    public func instanceLogsDirectory(_ instanceID: String) throws -> URL {
        try instanceGameDirectory(instanceID).appendingPathComponent("logs", isDirectory: true)
    }
}
