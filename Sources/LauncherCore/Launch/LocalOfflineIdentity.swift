import CryptoKit
import Foundation

/// Creates and validates `LocalOffline` identities.
///
/// A local offline profile is **not** an authentication session: it carries no token, makes no
/// ownership claim and may only be used for local technical validation. The UUID algorithm is
/// Java's `UUID.nameUUIDFromBytes("OfflinePlayer:" + name)` (MD5, RFC 4122 version 3) so that
/// existing worlds and server bans keyed by that UUID keep working.
public enum LocalOfflineIdentity {
    /// Minecraft-compatible player name: 3-16 characters, `A-Z a-z 0-9 _`.
    public static let playerNamePattern = "^[A-Za-z0-9_]{3,16}$"

    static let offlinePrefix = "OfflinePlayer:"

    /// Validates a player name and returns it unchanged.
    public static func validatedName(_ playerName: String) throws -> String {
        guard playerName.range(of: playerNamePattern, options: [.regularExpression]) != nil,
              playerName.count >= 3, playerName.count <= 16 else {
            throw LauncherError(
                .invalidProfileName,
                "Invalid local player name '\(playerName)'",
                suggestion: "Use 3-16 characters from A-Z, a-z, 0-9 or underscore."
            )
        }
        return playerName
    }

    /// Deterministic Java-compatible offline UUID. Case sensitive, as in Java.
    public static func offlineUUID(forName playerName: String) -> UUID {
        let digest = md5(Data((offlinePrefix + playerName).utf8))
        var bytes = [UInt8](digest)
        bytes[6] = (bytes[6] & 0x0F) | 0x30 // version 3
        bytes[8] = (bytes[8] & 0x3F) | 0x80 // RFC 4122 variant
        return UUID(uuid: (
            bytes[0], bytes[1], bytes[2], bytes[3],
            bytes[4], bytes[5], bytes[6], bytes[7],
            bytes[8], bytes[9], bytes[10], bytes[11],
            bytes[12], bytes[13], bytes[14], bytes[15]
        ))
    }

    /// Profile with a validated name and its deterministic UUID.
    public static func makeProfile(playerName: String) throws -> LocalOfflineProfile {
        let name = try validatedName(playerName)
        return LocalOfflineProfile(playerName: name, stableOfflineUUID: offlineUUID(forName: name))
    }

    /// `--uuid` style value: the UUID without dashes, which is what the client expects.
    public static func uuidArgument(for profile: LocalOfflineProfile) -> String {
        profile.stableOfflineUUID.uuidString.replacingOccurrences(of: "-", with: "").lowercased()
    }

    private static func md5(_ data: Data) -> [UInt8] {
        Array(Insecure.MD5.hash(data: data))
    }
}
