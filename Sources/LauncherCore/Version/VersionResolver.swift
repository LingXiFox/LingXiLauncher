import Foundation

/// Reads per-version JSON files from a game root and normalises them into `ResolvedVersion`.
///
/// M1 scope: modern `arguments` metadata only. Legacy `minecraftArguments` and `inheritsFrom`
/// are detected and rejected with an explicit error instead of producing a plan that would be
/// wrong for those versions.
public struct VersionResolver: VersionResolving {
    public init() {}

    public func resolve(versionID: String, from root: URL) throws -> ResolvedVersion {
        let layout = GameDataLayout(gameRoot: root)
        let jsonURL = try layout.versionJSONURL(versionID)
        guard FileManager.default.fileExists(atPath: jsonURL.path) else {
            throw LauncherError(
                .missingDependency,
                "Version metadata not found: \(jsonURL.path)",
                suggestion: "Download the version metadata first, or point --root at an existing .minecraft directory."
            )
        }
        let data: Data
        do {
            data = try Data(contentsOf: jsonURL)
        } catch {
            throw LauncherError(.ioFailure, "Cannot read \(jsonURL.path): \(error.localizedDescription)")
        }
        let metadata = try VersionMetadata.decode(from: data, context: "versions/\(versionID)/\(versionID).json")
        return try resolve(metadata: metadata, versionID: versionID, versionDirectory: try layout.versionDirectory(versionID), metadataURL: jsonURL)
    }

    /// Normalises already-decoded metadata. Exposed for tests and for future callers that
    /// fetch metadata from the network (M2).
    public func resolve(
        metadata: VersionMetadata,
        versionID: String,
        versionDirectory: URL,
        metadataURL: URL
    ) throws -> ResolvedVersion {
        guard metadata.id == versionID else {
            throw LauncherError(
                .invalidMetadata,
                "Version JSON id '\(metadata.id)' does not match requested version '\(versionID)'",
                suggestion: "The metadata file is misplaced or corrupted; reinstall the version metadata."
            )
        }
        guard !metadata.mainClass.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw LauncherError(.invalidMetadata, "Version \(versionID) declares an empty mainClass")
        }
        if let parent = metadata.inheritsFrom, !parent.isEmpty {
            throw LauncherError(
                .unsupportedVersion,
                "Version \(versionID) inherits from '\(parent)'",
                suggestion: "Version inheritance (Fabric/Forge or legacy layouts) is planned for M4 (T04). In M1 use a vanilla version without inheritsFrom."
            )
        }
        if let legacy = metadata.minecraftArguments, !legacy.isEmpty {
            throw LauncherError(
                .unsupportedVersion,
                "Version \(versionID) uses the legacy minecraftArguments format",
                suggestion: "Only modern Mojang `arguments` metadata is supported in M1. Pick a modern release (1.13+)."
            )
        }
        guard let arguments = metadata.arguments else {
            throw LauncherError(
                .invalidMetadata,
                "Version \(versionID) has neither modern `arguments` nor legacy `minecraftArguments`",
                suggestion: "The version JSON is incomplete or not an official Mojang client JSON."
            )
        }
        guard !arguments.game.isEmpty else {
            throw LauncherError(.invalidMetadata, "Version \(versionID) declares no game arguments")
        }
        guard !arguments.jvm.isEmpty else {
            throw LauncherError(.invalidMetadata, "Version \(versionID) declares no JVM arguments")
        }

        // The asset id used by the game is the asset index id (`assets` on very old metadata).
        let assetIndexID: String
        if let index = metadata.assetIndex {
            assetIndexID = index.id
        } else if let assets = metadata.assets, !assets.isEmpty {
            assetIndexID = assets
        } else {
            throw LauncherError(
                .invalidMetadata,
                "Version \(versionID) has no assetIndex and no assets id",
                suggestion: "The metadata cannot be launched without an asset index reference."
            )
        }

        if metadata.downloads?.client == nil {
            // Not fatal for a dry run: the client JAR may already exist locally and some
            // minor versions omit downloads. DependencyResolver reports the missing file.
        }

        return ResolvedVersion(
            id: metadata.id,
            type: metadata.type ?? "unknown",
            mainClass: metadata.mainClass,
            assetIndexID: assetIndexID,
            javaRequirement: metadata.javaVersion ?? JavaVersionRequirement(),
            libraries: metadata.libraries,
            jvmArguments: arguments.jvm,
            gameArguments: arguments.game,
            defaultUserJVMArguments: arguments.defaultUserJVMArguments.isEmpty ? (metadata.defaultUserJVMArguments ?? []) : arguments.defaultUserJVMArguments,
            assetIndex: metadata.assetIndex,
            clientLogging: metadata.logging?.client,
            clientJar: metadata.downloads?.client,
            inheritsFrom: metadata.inheritsFrom,
            versionDirectory: versionDirectory,
            metadataURL: metadataURL,
            releaseTime: metadata.releaseTime
        )
    }
}
