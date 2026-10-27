import Foundation

/// The approved LingXi Launcher Microsoft Entra public-client registration.
///
/// This is the **single** place the application identity lives. It is intentionally embedded in
/// the launcher (no `auth.json`, no user-supplied client id), and it contains no secret: the app
/// is a public client using Authorization Code + PKCE.
///
/// AppID status: Minecraft API allow list approved on 2026-10-26 (per project owner).
public enum MicrosoftAppRegistration {
    public static let clientId = "4c990be6-c02d-4f0d-84f6-c3d6785f2a36"
    public static let tenant = "consumers"
    public static let redirectURI = "http://localhost"
    public static let scopes = ["XboxLive.signin", "offline_access"]
    public static let authorizationTimeout: TimeInterval = 300

    public static var configuration: MicrosoftAuthenticationConfiguration {
        MicrosoftAuthenticationConfiguration(
            clientId: clientId,
            tenant: tenant,
            redirectURI: redirectURI,
            scopes: scopes,
            authorizationTimeout: authorizationTimeout
        )
    }
}
