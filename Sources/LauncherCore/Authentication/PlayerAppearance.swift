import Foundation

/// Public Minecraft profile appearance metadata from `GET /minecraft/profile`.
/// Texture URLs are public; they are not credentials and never contain tokens.
public struct PlayerAppearance: Codable, Sendable, Equatable {
    public enum SkinModel: String, Codable, Sendable, Equatable {
        case classic
        case slim
    }

    public let skinTextureURL: URL?
    public let capeTextureURL: URL?
    public let skinModel: SkinModel?

    public init(skinTextureURL: URL?, capeTextureURL: URL?, skinModel: SkinModel?) {
        self.skinTextureURL = Self.secureTextureURL(skinTextureURL)
        self.capeTextureURL = Self.secureTextureURL(capeTextureURL)
        self.skinModel = skinModel
    }

    /// Mojang currently returns `http://textures.minecraft.net/...`; prefer HTTPS so App
    /// Transport Security does not block the avatar in the GUI.
    private static func secureTextureURL(_ url: URL?) -> URL? {
        guard let url, var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            return url
        }
        if components.scheme?.lowercased() == "http", components.host == "textures.minecraft.net" {
            components.scheme = "https"
        }
        return components.url ?? url
    }
}
