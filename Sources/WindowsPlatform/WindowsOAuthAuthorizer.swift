import Foundation
import LauncherCore

/// Windows builds currently use device-code/manual flows; the loopback listener is macOS-only.
public struct LoopbackOAuthAuthorizer: OAuthAuthorizing {
    private let browser: any BrowserOpening
    public init(browser: any BrowserOpening) { self.browser = browser }

    public func authorize(
        configuration: MicrosoftAuthenticationConfiguration,
        state: String,
        codeChallenge: String,
        timeout: TimeInterval
    ) async throws -> OAuthCallback {
        throw LauncherError(.unsupportedVersion,
            "Microsoft loopback sign-in is not available in this Windows build",
            suggestion: "Use the macOS client for Microsoft sign-in; this build still supports offline identities.")
    }
}
