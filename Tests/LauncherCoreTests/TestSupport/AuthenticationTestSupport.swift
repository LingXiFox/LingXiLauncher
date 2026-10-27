import Foundation
@testable import LauncherCore

actor StubMicrosoftHTTPClient: MicrosoftHTTPClient {
    typealias Handler = @Sendable (MicrosoftHTTPRequest) async throws -> MicrosoftHTTPResponse

    private let handler: Handler
    private var recorded: [MicrosoftHTTPRequest] = []

    init(handler: @escaping Handler) {
        self.handler = handler
    }

    func send(_ request: MicrosoftHTTPRequest) async throws -> MicrosoftHTTPResponse {
        recorded.append(request)
        return try await handler(request)
    }

    var requests: [MicrosoftHTTPRequest] {
        recorded
    }
}

struct StubOAuthAuthorizer: OAuthAuthorizing {
    let code: String
    var stateOverride: String?

    func authorize(
        configuration: MicrosoftAuthenticationConfiguration,
        state: String,
        codeChallenge: String,
        timeout: TimeInterval
    ) async throws -> OAuthCallback {
        OAuthCallback(
            code: code,
            state: stateOverride ?? state,
            redirectURI: configuration.redirectURI(port: 12_345)
        )
    }
}

struct StubMinecraftAuthenticator: MinecraftAuthenticatorProtocol {
    let result: MinecraftAuthenticationResult

    func authenticateMicrosoft(_ microsoftAccessToken: String) async throws -> XboxTokens {
        XboxTokens(token: "xbl", userHash: "uhs", xuid: "xuid")
    }

    func authorizeXSTS(_ xbox: XboxTokens) async throws -> XSTSResult {
        XSTSResult(token: "xsts", userHash: "uhs", xuid: "xuid")
    }

    func loginMinecraft(xstsToken: String, userHash: String, xuid: String) async throws -> (token: String, expiresAt: Date) {
        (result.accessToken, result.expiresAt)
    }

    func verifyOwnershipAndProfile(
        minecraftToken: String,
        expiresAt: Date,
        xuid: String
    ) async throws -> MinecraftAuthenticationResult {
        result
    }
}

/// Browser stub for the real loopback server: performs the redirect with curl (no ATS involvement).
final class LoopbackCallbackBrowser: BrowserOpening, @unchecked Sendable {
    private(set) var openedURL: URL?
    private let code: String
    private let stateOverride: String?

    init(code: String = "test-code", stateOverride: String? = nil) {
        self.code = code
        self.stateOverride = stateOverride
    }

    func open(_ url: URL) throws {
        openedURL = url
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let redirect = components.queryItems?.first(where: { $0.name == "redirect_uri" })?.value,
              let state = components.queryItems?.first(where: { $0.name == "state" })?.value else {
            throw LauncherError(.invalidMetadata, "authorization URL missing redirect_uri/state")
        }
        var callback = URLComponents(string: redirect)!
        callback.queryItems = [
            URLQueryItem(name: "code", value: code),
            URLQueryItem(name: "state", value: stateOverride ?? state),
        ]
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/curl")
        process.arguments = ["-s", "-o", "/dev/null", callback.url!.absoluteString]
        try process.run()
        process.waitUntilExit()
    }
}
