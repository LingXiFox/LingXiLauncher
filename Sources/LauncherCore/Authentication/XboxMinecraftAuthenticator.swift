import Foundation

/// Result of the Xbox Live user authentication step. `xuid` is not guaranteed here; the
/// authoritative XUID arrives in the XSTS response.
public struct XboxTokens: Sendable, Equatable {
    public let token: String
    public let userHash: String
    /// XUID is returned by Xbox Live on some responses and by XSTS on others; it is optional
    /// here and resolved after both calls.
    public let xuid: String?

    public init(token: String, userHash: String, xuid: String? = nil) {
        self.token = token
        self.userHash = userHash
        self.xuid = xuid
    }
}

/// XSTS token plus the XUID it carries in `DisplayClaims.xui`.
public struct XSTSResult: Sendable, Equatable {
    public let token: String
    public let userHash: String
    public let xuid: String?

    public init(token: String, userHash: String, xuid: String?) {
        self.token = token
        self.userHash = userHash
        self.xuid = xuid
    }
}

public struct MinecraftAuthenticationResult: Sendable, Equatable {
    public let profile: MinecraftProfile
    public let accessToken: String
    public let expiresAt: Date
    public let xuid: String
    public let ownsGame: Bool

    public init(profile: MinecraftProfile, accessToken: String, expiresAt: Date, xuid: String, ownsGame: Bool) {
        self.profile = profile
        self.accessToken = accessToken
        self.expiresAt = expiresAt
        self.xuid = xuid
        self.ownsGame = ownsGame
    }
}

/// Xbox Live → XSTS → Minecraft Services authentication.
///
/// Each step is a separate method so the caller can expose progress phases and so token expiry,
/// Xbox restrictions and Minecraft 403s map to distinct errors.
public struct XboxMinecraftAuthenticator: Sendable {
    private let http: any MicrosoftHTTPClient

    public init(http: any MicrosoftHTTPClient = URLSessionMicrosoftHTTPClient()) {
        self.http = http
    }

    // MARK: - Xbox Live

    public func authenticateMicrosoft(_ microsoftAccessToken: String) async throws -> XboxTokens {
        let body: [String: Any] = [
            "Properties": [
                "AuthMethod": "RPS",
                "SiteName": "user.auth.xboxlive.com",
                "RpsTicket": "d=\(microsoftAccessToken)",
            ],
            "RelyingParty": "http://auth.xboxlive.com",
            "TokenType": "JWT",
        ]
        let response = try await postJSON(
            url: URL(string: "https://user.auth.xboxlive.com/user/authenticate")!,
            body: body,
            contractVersion: true
        )
        guard (200...299).contains(response.statusCode) else {
            throw LauncherError(
                .unauthorized,
                "Xbox Live authentication failed (HTTP \(response.statusCode)): \(response.responseSnippet)",
                suggestion: "Sign in with a Microsoft account that has an Xbox profile."
            )
        }
        let payload = try response.decodeJSON(XboxAuthenticationResponse.self)
        guard let claim = payload.displayClaims.xui.first, !claim.userHash.isEmpty, !payload.token.isEmpty else {
            throw LauncherError(.invalidMetadata, "Xbox Live response did not contain a user hash")
        }
        var tokens = XboxTokens(token: payload.token, userHash: claim.userHash, xuid: claim.xuid)
        if tokens.xuid == nil || tokens.xuid?.isEmpty == true {
            tokens = XboxTokens(
                token: tokens.token,
                userHash: tokens.userHash,
                xuid: try? await resolveXUID(tokens)
            )
        }
        return tokens
    }

    public func authorizeXSTS(_ xbox: XboxTokens) async throws -> XSTSResult {
        try await authorizeXSTS(xbox, relyingParty: "rp://api.minecraftservices.com/")
    }

    public func authorizeXSTS(
        _ xbox: XboxTokens,
        relyingParty: String
    ) async throws -> XSTSResult {
        let body: [String: Any] = [
            "Properties": [
                "SandboxId": "RETAIL",
                "UserTokens": [xbox.token],
            ],
            "RelyingParty": relyingParty,
            "TokenType": "JWT",
        ]
        let response = try await postJSON(
            url: URL(string: "https://xsts.auth.xboxlive.com/xsts/authorize")!,
            body: body,
            contractVersion: true
        )
        guard (200...299).contains(response.statusCode) else {
            if response.statusCode == 401 {
                let xerr = (try? JSONDecoder().decode(XSTSErrorResponse.self, from: response.data))?.xerr
                throw XSTSErrorMapper.error(for: xerr)
            }
            throw LauncherError(
                .xboxAccountRestricted,
                "XSTS authorization failed (HTTP \(response.statusCode)): \(response.responseSnippet)",
                suggestion: "Verify the Microsoft account can sign in to Xbox Live."
            )
        }
        let payload = try response.decodeJSON(XboxAuthenticationResponse.self)
        guard !payload.token.isEmpty,
              let claim = payload.displayClaims.xui.first,
              !claim.userHash.isEmpty else {
            throw LauncherError(.invalidMetadata, "XSTS response did not contain a token and user hash")
        }
        // The Minecraft XSTS token is scoped to Minecraft Services; XUID is optional here and
        // was resolved separately (or is simply unavailable for this account/API version).
        let xuid = claim.xuid ?? xbox.xuid
        return XSTSResult(token: payload.token, userHash: claim.userHash, xuid: xuid)
    }

    /// Resolves the XUID through a separate XSTS audience and the Xbox profile service.
    /// Returns nil when the profile service is unavailable; callers may continue with a
    /// placeholder XUID for local play.
    public func resolveXUID(_ xbox: XboxTokens) async throws -> String? {
        let profileToken = try await authorizeXSTS(xbox, relyingParty: "http://xboxlive.com")
        return try await fetchXUID(xstsToken: profileToken.token, userHash: profileToken.userHash)
    }

    /// Reads the XUID from the Xbox profile service using an XSTS token scoped to Xbox Live.
    public func fetchXUID(xstsToken: String, userHash: String) async throws -> String? {
        let request = MicrosoftHTTPRequest(
            url: URL(string: "https://profile.xboxlive.com/users/me/profile/settings?settings=Gamertag")!,
            headers: [
                "Authorization": "XBL3.0 x=\(userHash);\(xstsToken)",
                "Accept": "application/json",
                "x-xbl-contract-version": "3",
            ]
        )
        let response = try await http.send(request)
        guard (200...299).contains(response.statusCode) else { return nil }
        let payload = try? response.decodeJSON(XboxProfileResponse.self)
        let xuid = payload?.profileUsers.first?.id
        return (xuid?.isEmpty == false) ? xuid : nil
    }

    // MARK: - Minecraft Services

    public func loginMinecraft(xstsToken: String, userHash: String, xuid: String) async throws -> (token: String, expiresAt: Date) {
        let body: [String: Any] = [
            "identityToken": "XBL3.0 x=\(userHash);\(xstsToken)"
        ]
        let response = try await postJSON(
            url: URL(string: "https://api.minecraftservices.com/authentication/login_with_xbox")!,
            body: body,
            contractVersion: false
        )
        if response.statusCode == 403 {
            throw LauncherError(
                .appRegistrationRejected,
                "Minecraft Services rejected this application (HTTP 403): \(response.responseSnippet)",
                suggestion: "The Entra application must be approved on the Minecraft API allow list."
            )
        }
        guard (200...299).contains(response.statusCode) else {
            throw LauncherError(
                .unauthorized,
                "Minecraft Services login failed (HTTP \(response.statusCode)): \(response.responseSnippet)",
                suggestion: "Retry sign-in; if the account has no Minecraft profile, verify ownership first."
            )
        }
        let payload = try response.decodeJSON(MinecraftLoginResponse.self)
        guard !payload.accessToken.isEmpty else {
            throw LauncherError(.invalidMetadata, "Minecraft Services did not return an access token")
        }
        return (
            payload.accessToken,
            Date().addingTimeInterval(TimeInterval(payload.expiresIn ?? 86_400))
        )
    }

    /// Verifies ownership via entitlements and the Minecraft profile, then builds a session.
    public func verifyOwnershipAndProfile(
        minecraftToken: String,
        expiresAt: Date,
        xuid: String
    ) async throws -> MinecraftAuthenticationResult {
        let entitlements = try await fetchEntitlements(token: minecraftToken)
        let profile = try await fetchProfile(token: minecraftToken)
        // A Minecraft profile is only issued to accounts that own Java Edition, so either
        // signal is sufficient; an empty entitlement list alone is not proof of ownership.
        let ownsGame = !entitlements.isEmpty || profile != nil
        guard let profile, ownsGame else {
            throw LauncherError(
                .gameOwnershipMissing,
                "This Microsoft account does not own Minecraft: Java Edition",
                suggestion: "Purchase Java Edition or sign in with the Microsoft account that owns it."
            )
        }
        return MinecraftAuthenticationResult(
            profile: profile,
            accessToken: minecraftToken,
            expiresAt: expiresAt,
            xuid: xuid,
            ownsGame: true
        )
    }

    public func fetchEntitlements(token: String) async throws -> [String] {
        let request = MicrosoftHTTPRequest(
            url: URL(string: "https://api.minecraftservices.com/entitlements/mcstore")!,
            headers: ["Authorization": "Bearer \(token)", "Accept": "application/json"]
        )
        let response = try await http.send(request)
        if response.statusCode == 403 {
            throw LauncherError(
                .appRegistrationRejected,
                "Minecraft entitlements request was rejected (HTTP 403): \(response.responseSnippet)",
                suggestion: "The Entra application must be on the Minecraft API allow list."
            )
        }
        if response.statusCode == 401 {
            throw LauncherError(.tokenExpired, "Minecraft access token was rejected; sign in again")
        }
        guard (200...299).contains(response.statusCode) else {
            throw LauncherError(
                .gameOwnershipMissing,
                "Could not verify Minecraft ownership (HTTP \(response.statusCode)): \(response.responseSnippet)"
            )
        }
        let payload = try response.decodeJSON(EntitlementsResponse.self)
        return payload.items.map(\.name)
    }

    /// Returns nil when the account has no Minecraft profile (HTTP 404).
    public func fetchProfile(token: String) async throws -> MinecraftProfile? {
        let request = MicrosoftHTTPRequest(
            url: URL(string: "https://api.minecraftservices.com/minecraft/profile")!,
            headers: ["Authorization": "Bearer \(token)", "Accept": "application/json"]
        )
        let response = try await http.send(request)
        if response.statusCode == 404 {
            return nil
        }
        if response.statusCode == 401 {
            throw LauncherError(.tokenExpired, "Minecraft access token was rejected; sign in again")
        }
        if response.statusCode == 403 {
            throw LauncherError(
                .appRegistrationRejected,
                "Minecraft profile request was rejected (HTTP 403): \(response.responseSnippet)",
                suggestion: "The Entra application must be on the Minecraft API allow list."
            )
        }
        guard (200...299).contains(response.statusCode) else {
            throw LauncherError(
                .unauthorized,
                "Minecraft profile request failed (HTTP \(response.statusCode)): \(response.responseSnippet)"
            )
        }
        let payload = try response.decodeJSON(MinecraftProfileResponse.self)
        guard let uuid = Self.uuid(fromMinecraftID: payload.id), !payload.name.isEmpty else {
            throw LauncherError(.invalidMetadata, "Minecraft profile response contained an invalid id or name")
        }
        return MinecraftProfile(id: uuid, name: payload.name)
    }

    // MARK: - Helpers

    private func postJSON(url: URL, body: [String: Any], contractVersion: Bool) async throws -> MicrosoftHTTPResponse {
        let data: Data
        do {
            data = try JSONSerialization.data(withJSONObject: body, options: [])
        } catch {
            throw LauncherError(.invalidMetadata, "Could not encode authentication request: \(error.localizedDescription)")
        }
        var headers = [
            "Content-Type": "application/json",
            "Accept": "application/json",
        ]
        if contractVersion {
            headers["x-xbl-contract-version"] = "1"
        }
        return try await http.send(MicrosoftHTTPRequest(
            url: url,
            method: "POST",
            headers: headers,
            body: data,
            timeout: 30
        ))
    }

    static func uuid(fromMinecraftID id: String) -> UUID? {
        let hex = id.replacingOccurrences(of: "-", with: "").lowercased()
        guard hex.count == 32, hex.allSatisfy({ $0.isHexDigit }) else { return nil }
        let formatted = "\(hex.prefix(8))-\(hex.dropFirst(8).prefix(4))-\(hex.dropFirst(12).prefix(4))-\(hex.dropFirst(16).prefix(4))-\(hex.dropFirst(20))"
        return UUID(uuidString: formatted)
    }

    private struct XboxAuthenticationResponse: Decodable {
        let token: String
        let displayClaims: DisplayClaims

        enum CodingKeys: String, CodingKey {
            case token = "Token"
            case displayClaims = "DisplayClaims"
        }

        struct DisplayClaims: Decodable {
            let xui: [XUI]

            enum CodingKeys: String, CodingKey {
                case xui
            }

            struct XUI: Decodable {
                let userHash: String
                let xuid: String?

                enum CodingKeys: String, CodingKey {
                    case userHash = "uhs"
                    // Xbox responses spell the XUID claim `xid`; tolerate it being numeric.
                    case xuid = "xid"
                }

                init(from decoder: Decoder) throws {
                    let container = try decoder.container(keyedBy: AnyCodingKey.self)
                    self.userHash = try container.decode(String.self, forKey: AnyCodingKey("uhs"))
                    self.xuid = Self.xuidValue(in: container)
                }

                private static func xuidValue(in container: KeyedDecodingContainer<AnyCodingKey>) -> String? {
                    for key in ["xid", "xuid", "Xid", "XUID"] {
                        let codingKey = AnyCodingKey(key)
                        if let value = try? container.decode(String.self, forKey: codingKey), !value.isEmpty {
                            return value
                        }
                        if let value = try? container.decode(Int64.self, forKey: codingKey) {
                            return String(value)
                        }
                        if let value = try? container.decode(UInt64.self, forKey: codingKey) {
                            return String(value)
                        }
                    }
                    return nil
                }

            }
        }
    }

    private struct XboxProfileResponse: Decodable {
        struct ProfileUser: Decodable {
            let id: String
        }
        let profileUsers: [ProfileUser]
    }

    private struct XSTSErrorResponse: Decodable {
        let xerr: Int?

        enum CodingKeys: String, CodingKey {
            case xerr = "XErr"
        }
    }

    private struct MinecraftLoginResponse: Decodable {
        let accessToken: String
        let expiresIn: Int?

        enum CodingKeys: String, CodingKey {
            case accessToken = "access_token"
            case expiresIn = "expires_in"
        }
    }

    private struct EntitlementsResponse: Decodable {
        struct Item: Decodable {
            let name: String
        }
        let items: [Item]
    }

    private struct MinecraftProfileResponse: Decodable {
        let id: String
        let name: String
    }
}

public enum XSTSErrorMapper {
    public static func error(for xerr: Int?) -> LauncherError {
        switch xerr {
        case 2_148_916_227:
            return LauncherError(
                .xboxAccountRestricted,
                "This Xbox account is banned and cannot access Minecraft",
                suggestion: "Resolve the ban at xbox.com before signing in."
            )
        case 2_148_916_233:
            return LauncherError(
                .xboxAccountRestricted,
                "This Microsoft account has no Xbox profile",
                suggestion: "Create an Xbox profile, or use the Microsoft account that owns Minecraft."
            )
        case 2_148_916_235:
            return LauncherError(
                .xboxAccountRestricted,
                "Xbox Live is not available in this account's region",
                suggestion: "Use an account from a supported region."
            )
        case 2_148_916_236, 2_148_916_237:
            return LauncherError(
                .xboxAccountRestricted,
                "This Xbox account requires adult verification",
                suggestion: "Complete the age verification at xbox.com, then retry."
            )
        case 2_148_916_238:
            return LauncherError(
                .xboxAccountRestricted,
                "This is a child account without Xbox Live permission",
                suggestion: "Ask the Microsoft family organizer to grant Xbox Live access."
            )
        default:
            return LauncherError(
                .xboxAccountRestricted,
                "Xbox Live authorization was rejected (XErr \(xerr.map(String.init) ?? "unknown"))",
                suggestion: "Check the account's Xbox Live status and try again."
            )
        }
    }
}
