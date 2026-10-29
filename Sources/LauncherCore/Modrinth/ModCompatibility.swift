import Foundation

public enum ModLoaderKind: String, Sendable, Equatable, Codable {
    case vanilla
    case fabric
    case neoforge

    public var displayName: String {
        switch self {
        case .vanilla: return "Vanilla"
        case .fabric: return "Fabric"
        case .neoforge: return "NeoForge"
        }
    }
}

public struct ModCompatibility: Sendable, Equatable {
    public let instanceID: String
    public let versionID: String
    /// The Minecraft game version, not the Fabric profile id.
    public let gameVersion: String
    public let loader: ModLoaderKind

    public init(instanceID: String, versionID: String, gameVersion: String, loader: ModLoaderKind) {
        self.instanceID = instanceID
        self.versionID = versionID
        self.gameVersion = gameVersion
        self.loader = loader
    }
}

public enum ModCompatibilityResolver {
    /// Reads the instance's actual version profile. This is deliberately not inferred from the
    /// display name or user input: a renamed instance must still filter mods against its profile.
    public static func resolve(instance: Instance, layout: GameDataLayout) throws -> ModCompatibility {
        guard let versionID = instance.manifest.versionID, !versionID.isEmpty else {
            throw LauncherError(
                .missingDependency,
                "Instance '\(instance.id)' has no bound Minecraft version",
                suggestion: "Bind a version before managing mods."
            )
        }
        let version = try VersionResolver().resolve(versionID: versionID, from: layout.gameRoot)
        let gameVersion = version.inheritsFrom ?? version.id
        let lowerID = version.id.lowercased()
        let isNeoForge = lowerID.hasPrefix("neoforge-")
            || version.mainClass.localizedCaseInsensitiveContains("neoforged")
            || version.libraries.contains { $0.name.lowercased().contains("neoforge") }
        let isFabric = lowerID.hasPrefix("fabric-loader-")
            || version.mainClass.localizedCaseInsensitiveContains("fabric")
            || version.libraries.contains { $0.name.lowercased().contains("fabric-loader") }
        return ModCompatibility(
            instanceID: instance.id,
            versionID: versionID,
            gameVersion: gameVersion,
            loader: isNeoForge ? .neoforge : (isFabric ? .fabric : .vanilla)
        )
    }
}
