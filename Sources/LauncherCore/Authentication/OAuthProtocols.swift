import Foundation

/// Opens the system browser. Implemented by the platform layer, never by Core.
public protocol BrowserOpening: Sendable {
    func open(_ url: URL) throws
}

/// Performs an Authorization Code + PKCE round-trip and returns the code with its state.
public protocol OAuthAuthorizing: Sendable {
    func authorize(
        configuration: MicrosoftAuthenticationConfiguration,
        state: String,
        codeChallenge: String,
        timeout: TimeInterval
    ) async throws -> OAuthCallback
}
