import Foundation

/// Centralised Microsoft Entra (public client) configuration.
///
/// The approved public-client identity is embedded once in `MicrosoftAppRegistration`; there is
/// no external auth configuration file. A `LINGXI_MICROSOFT_CLIENT_ID` environment override is
/// kept strictly for developer testing. A client secret is explicitly rejected: this is a
/// public desktop client using Authorization Code + PKCE.
public struct MicrosoftAuthenticationConfiguration: Decodable, Sendable, Equatable {
    public let clientId: String
    /// `consumers`, `organizations`, `common`, or a tenant id/domain.
    public let tenant: String
    /// Registered loopback redirect URI, without a port (`http://localhost`) or with an optional
    /// path (`http://localhost/callback`). The actual port is chosen at runtime.
    public let redirectURI: String
    public let scopes: [String]
    /// How long the launcher waits for the browser callback.
    public let authorizationTimeout: TimeInterval

    public init(
        clientId: String,
        tenant: String = "consumers",
        redirectURI: String = "http://localhost",
        scopes: [String] = ["XboxLive.signin", "offline_access"],
        authorizationTimeout: TimeInterval = 300
    ) {
        self.clientId = clientId
        self.tenant = tenant
        self.redirectURI = redirectURI
        self.scopes = scopes
        self.authorizationTimeout = authorizationTimeout
    }

    private enum CodingKeys: String, CodingKey {
        case clientId, tenant, redirectURI, scopes, authorizationTimeout
        // Explicitly named so attempting to configure a secret is a clear error.
        case clientSecret
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        if container.contains(.clientSecret) {
            throw LauncherError(
                .invalidMetadata,
                "Configuration must not contain clientSecret: LingXi Launcher is a public client using PKCE",
                suggestion: "Remove the client secret and register the app as a public client."
            )
        }
        let clientId = try container.decode(String.self, forKey: .clientId)
        self.init(
            clientId: clientId,
            tenant: try container.decodeIfPresent(String.self, forKey: .tenant) ?? "consumers",
            redirectURI: try container.decodeIfPresent(String.self, forKey: .redirectURI) ?? "http://localhost",
            scopes: try container.decodeIfPresent([String].self, forKey: .scopes) ?? ["XboxLive.signin", "offline_access"],
            authorizationTimeout: try container.decodeIfPresent(TimeInterval.self, forKey: .authorizationTimeout) ?? 300
        )
        try validate()
    }

    public func validate() throws {
        guard !clientId.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw LauncherError(.configurationMissing, "Microsoft Entra clientId is empty")
        }
        let allowedTenantCharacters = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: ".-"))
        guard !tenant.isEmpty, tenant.unicodeScalars.allSatisfy({ allowedTenantCharacters.contains($0) }) else {
            throw LauncherError(.invalidMetadata, "Invalid Entra tenant '\(tenant)'")
        }
        guard let components = URLComponents(string: redirectURI),
              components.scheme?.lowercased() == "http",
              components.host == "localhost" || components.host == "127.0.0.1" else {
            throw LauncherError(
                .invalidMetadata,
                "redirectURI must be a loopback HTTP URL (http://localhost or http://127.0.0.1), got '\(redirectURI)'"
            )
        }
        guard !scopes.isEmpty, scopes.contains("offline_access") else {
            throw LauncherError(
                .invalidMetadata,
                "OAuth scopes must include offline_access so the refresh token can be stored securely"
            )
        }
        guard authorizationTimeout > 0, authorizationTimeout <= 900 else {
            throw LauncherError(.invalidMetadata, "authorizationTimeout must be between 1 and 900 seconds")
        }
    }

    /// Full redirect URI for a concrete loopback port chosen at runtime.
    public func redirectURI(port: UInt16) -> URL {
        var components = URLComponents(string: redirectURI) ?? URLComponents()
        components.scheme = "http"
        components.host = components.host ?? "localhost"
        components.port = Int(port)
        return components.url ?? URL(string: "http://localhost:\(port)")!
    }

    public var authorizationEndpoint: URL {
        URL(string: "https://login.microsoftonline.com/\(tenant)/oauth2/v2.0/authorize")!
    }

    public var tokenEndpoint: URL {
        URL(string: "https://login.microsoftonline.com/\(tenant)/oauth2/v2.0/token")!
    }

    /// Returns the embedded LingXi Launcher registration.
    ///
    /// An explicit `LINGXI_MICROSOFT_CLIENT_ID` environment override is kept for developer
    /// testing, but there is no external auth configuration file: the shipped app always has a
    /// usable client id.
    public static func load(
        dataRoot: URL,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) throws -> MicrosoftAuthenticationConfiguration {
        if let clientId = environment["LINGXI_MICROSOFT_CLIENT_ID"]?.trimmingCharacters(in: .whitespacesAndNewlines),
           !clientId.isEmpty {
            let configuration = MicrosoftAuthenticationConfiguration(
                clientId: clientId,
                tenant: environment["LINGXI_MICROSOFT_TENANT"] ?? MicrosoftAppRegistration.tenant,
                redirectURI: environment["LINGXI_MICROSOFT_REDIRECT_URI"] ?? MicrosoftAppRegistration.redirectURI
            )
            try configuration.validate()
            return configuration
        }
        let configuration = MicrosoftAppRegistration.configuration
        try configuration.validate()
        return configuration
    }

    public static func isConfigured(
        dataRoot: URL,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> Bool {
        true
    }
}

/// Progress phases shown by CLI/GUI. Contains no secrets.
public enum AuthenticationPhase: String, Sendable, Equatable, Codable {
    case openingBrowser = "opening-browser"
    case waitingForCallback = "waiting-for-callback"
    case exchangingCode = "exchanging-code"
    case xboxLive = "xbox-live"
    case xsts
    case minecraftServices = "minecraft-services"
    case verifyingOwnership = "verifying-ownership"
    case refreshing
    case completed
}

public enum AuthenticationState: Sendable, Equatable {
    case signedOut
    case working(AuthenticationPhase)
    case signedIn(MicrosoftAccount)
    case failed(message: String, code: LauncherError.Code?)

    public var isWorking: Bool {
        if case .working = self { return true }
        return false
    }
}

/// Non-secret Microsoft account metadata. Tokens live in the Keychain, never here.
public struct MicrosoftAccount: Codable, Sendable, Equatable, Identifiable {
    public let id: UUID
    public let playerName: String
    public let xuid: String
    public let addedAt: Date
    public var lastValidatedAt: Date?
    public var ownsGame: Bool

    public init(
        id: UUID,
        playerName: String,
        xuid: String,
        addedAt: Date = Date(),
        lastValidatedAt: Date? = nil,
        ownsGame: Bool
    ) {
        self.id = id
        self.playerName = playerName
        self.xuid = xuid
        self.addedAt = addedAt
        self.lastValidatedAt = lastValidatedAt
        self.ownsGame = ownsGame
    }
}
