import Foundation

/// The three identity modes. They must never be confused or silently substituted for each other.
public enum IdentityMode: String, Sendable, Codable, Equatable, CaseIterable {
    /// Real Microsoft → Xbox Live → Minecraft Services session (M3, not implemented yet).
    case microsoft
    /// A locally cached identity that previously passed a real ownership check (M3).
    case licensedOffline = "licensed-offline"
    /// A purely local identity. Never represents a verified purchase and never carries a token (M1).
    case localOffline = "local-offline"
}

/// A player profile as reported by Minecraft Services. Contains no secret material.
public struct MinecraftProfile: Sendable, Equatable, Codable {
    public let id: UUID
    public let name: String

    public init(id: UUID, name: String) {
        self.id = id
        self.name = name
    }
}

/// A local, unverified identity used for local technical validation only.
///
/// It intentionally holds no token, no Microsoft account id and no ownership claim.
/// The UUID is derived deterministically from `OfflinePlayer:<name>` (Java-compatible).
public struct LocalOfflineProfile: Sendable, Equatable, Codable {
    public let playerName: String
    public let stableOfflineUUID: UUID

    public init(playerName: String, stableOfflineUUID: UUID) {
        self.playerName = playerName
        self.stableOfflineUUID = stableOfflineUUID
    }

    /// The profile as a `MinecraftProfile` for plumbing that only needs uuid/name.
    /// This is *not* a claim that the profile is verified.
    public var unverifiedProfile: MinecraftProfile {
        MinecraftProfile(id: stableOfflineUUID, name: playerName)
    }
}

/// A real Minecraft Services session. M3 issues these; nothing else may construct one.
///
/// The access token is intentionally not public and `description` is redacted so that a
/// `LaunchPlan`, an error or a crash log can never leak it.
public struct AuthorizedMinecraftSession: Sendable {
    public let profile: MinecraftProfile
    public let xuid: String
    public let userType: String
    public let expiresAt: Date
    /// Deliberately internal: only the authentication module (M3) can read the secret.
    let accessToken: String

    init(profile: MinecraftProfile, xuid: String, userType: String, expiresAt: Date, accessToken: String) {
        self.profile = profile
        self.xuid = xuid
        self.userType = userType
        self.expiresAt = expiresAt
        self.accessToken = accessToken
    }

    public var isExpired: Bool {
        expiresAt <= Date()
    }
}

extension AuthorizedMinecraftSession: CustomStringConvertible, CustomDebugStringConvertible {
    public var description: String {
        "<AuthorizedMinecraftSession profile=\(profile.name) uuid=\(profile.id.uuidString) token=<redacted>>"
    }

    public var debugDescription: String { description }
}

/// A previously verified licensed identity cached locally for offline use (M3).
public struct PreviouslyVerifiedProfile: Sendable, Equatable, Codable {
    public let profile: MinecraftProfile
    public let verifiedAt: Date

    public init(profile: MinecraftProfile, verifiedAt: Date) {
        self.profile = profile
        self.verifiedAt = verifiedAt
    }
}

/// The identity a launch plan is built for.
public enum LaunchIdentity: Sendable {
    case microsoft(AuthorizedMinecraftSession)
    case licensedOffline(PreviouslyVerifiedProfile)
    case localOffline(LocalOfflineProfile)

    public var mode: IdentityMode {
        switch self {
        case .microsoft: return .microsoft
        case .licensedOffline: return .licensedOffline
        case .localOffline: return .localOffline
        }
    }

    /// Human-readable label that never implies more verification than actually happened.
    public var displayName: String {
        switch self {
        case let .microsoft(session): return "Microsoft (\(session.profile.name))"
        case let .licensedOffline(profile): return "Licensed offline (\(profile.profile.name), verified \(profile.verifiedAt.formatted(.iso8601.dateTimeSeparator(.standard))))"
        case let .localOffline(profile): return "Local offline / unverified (\(profile.playerName))"
        }
    }
}
