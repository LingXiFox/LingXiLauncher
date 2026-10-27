import Foundation

/// OAuth token response. The raw access/refresh token strings never appear in logs or errors.
public struct OAuthToken: Sendable, Equatable {
    public let accessToken: String
    public let refreshToken: String?
    public let expiresAt: Date
    public let scope: String?
    public let tokenType: String

    public init(accessToken: String, refreshToken: String?, expiresAt: Date, scope: String?, tokenType: String) {
        self.accessToken = accessToken
        self.refreshToken = refreshToken
        self.expiresAt = expiresAt
        self.scope = scope
        self.tokenType = tokenType
    }

    public var isExpired: Bool {
        Date() >= expiresAt.addingTimeInterval(-60)
    }
}

/// Result of a browser authorization round-trip.
public struct OAuthCallback: Sendable, Equatable {
    public let code: String
    public let state: String
    /// The exact redirect URI used for the authorization request, including the loopback port.
    public let redirectURI: URL

    public init(code: String, state: String, redirectURI: URL) {
        self.code = code
        self.state = state
        self.redirectURI = redirectURI
    }
}

/// Authorization Code + PKCE client for a public Microsoft Entra app (no client secret).
public struct MicrosoftOAuthClient: Sendable {
    public let configuration: MicrosoftAuthenticationConfiguration
    private let http: any MicrosoftHTTPClient

    public init(configuration: MicrosoftAuthenticationConfiguration, http: any MicrosoftHTTPClient) {
        self.configuration = configuration
        self.http = http
    }

    public func authorizationURL(state: String, codeChallenge: String, redirectURI: URL) -> URL {
        Self.authorizationURL(
            configuration: configuration,
            state: state,
            codeChallenge: codeChallenge,
            redirectURI: redirectURI
        )
    }

    public static func authorizationURL(
        configuration: MicrosoftAuthenticationConfiguration,
        state: String,
        codeChallenge: String,
        redirectURI: URL
    ) -> URL {
        var components = URLComponents(url: configuration.authorizationEndpoint, resolvingAgainstBaseURL: false)!
        components.queryItems = [
            URLQueryItem(name: "client_id", value: configuration.clientId),
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "redirect_uri", value: redirectURI.absoluteString),
            URLQueryItem(name: "response_mode", value: "query"),
            URLQueryItem(name: "scope", value: configuration.scopes.joined(separator: " ")),
            URLQueryItem(name: "state", value: state),
            URLQueryItem(name: "code_challenge", value: codeChallenge),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
            URLQueryItem(name: "prompt", value: "select_account"),
        ]
        return components.url!
    }

    public func exchange(code: String, verifier: String, redirectURI: URL) async throws -> OAuthToken {
        let body = [
            "client_id": configuration.clientId,
            "grant_type": "authorization_code",
            "code": code,
            "redirect_uri": redirectURI.absoluteString,
            "code_verifier": verifier,
            "scope": configuration.scopes.joined(separator: " "),
        ]
        return try await requestToken(body: body, isRefresh: false)
    }

    public func refresh(refreshToken: String) async throws -> OAuthToken {
        let body = [
            "client_id": configuration.clientId,
            "grant_type": "refresh_token",
            "refresh_token": refreshToken,
            "scope": configuration.scopes.joined(separator: " "),
        ]
        return try await requestToken(body: body, isRefresh: true)
    }

    private func requestToken(body: [String: String], isRefresh: Bool) async throws -> OAuthToken {
        let form = body
            .map { "\(urlEncode($0.key))=\(urlEncode($0.value))" }
            .sorted()
            .joined(separator: "&")
        let request = MicrosoftHTTPRequest(
            url: configuration.tokenEndpoint,
            method: "POST",
            headers: [
                "Content-Type": "application/x-www-form-urlencoded",
                "Accept": "application/json",
            ],
            body: Data(form.utf8),
            timeout: 30
        )
        let response = try await http.send(request)
        guard (200...299).contains(response.statusCode) else {
            let payload = (try? JSONDecoder().decode(TokenErrorPayload.self, from: response.data))
            let description = payload?.errorDescription ?? payload?.error ?? response.responseSnippet
            if isRefresh, response.statusCode == 400, payload?.error == "invalid_grant" {
                throw LauncherError(
                    .tokenExpired,
                    "The saved Microsoft session has expired: \(description)",
                    suggestion: "Sign in with Microsoft again; the launcher will not fall back to a local identity."
                )
            }
            throw LauncherError(
                .unauthorized,
                "Microsoft OAuth token request failed (HTTP \(response.statusCode)): \(description)",
                suggestion: "Check the Entra client id, redirect URI and that the app is registered as a public client with PKCE."
            )
        }
        let token = try response.decodeJSON(TokenResponsePayload.self)
        guard !token.accessToken.isEmpty else {
            throw LauncherError(.unauthorized, "Microsoft OAuth response did not contain an access token")
        }
        return OAuthToken(
            accessToken: token.accessToken,
            refreshToken: token.refreshToken,
            expiresAt: Date().addingTimeInterval(TimeInterval(token.expiresIn ?? 3600)),
            scope: token.scope,
            tokenType: token.tokenType ?? "Bearer"
        )
    }

    private func urlEncode(_ value: String) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        return value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
    }

    private struct TokenResponsePayload: Decodable {
        let accessToken: String
        let refreshToken: String?
        let expiresIn: Int?
        let scope: String?
        let tokenType: String?

        enum CodingKeys: String, CodingKey {
            case accessToken = "access_token"
            case refreshToken = "refresh_token"
            case expiresIn = "expires_in"
            case scope
            case tokenType = "token_type"
        }
    }

    private struct TokenErrorPayload: Decodable {
        let error: String?
        let errorDescription: String?

        enum CodingKeys: String, CodingKey {
            case error
            case errorDescription = "error_description"
        }
    }
}
