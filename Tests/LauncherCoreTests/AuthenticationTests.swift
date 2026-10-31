import XCTest
#if os(macOS)
import MacPlatform
#endif
#if os(macOS)
#endif
@testable import LauncherCore

final class AuthenticationConfigurationTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = try FixtureLoader.temporaryDirectory("lingxi-auth-config")
    }

    override func tearDownWithError() throws {
        if let root { try? FileManager.default.removeItem(at: root) }
    }

    func testEnvironmentConfiguration() throws {
        let configuration = try MicrosoftAuthenticationConfiguration.load(
            dataRoot: root,
            environment: [
                "LINGXI_MICROSOFT_CLIENT_ID": "11111111-2222-3333-4444-555555555555",
                "LINGXI_MICROSOFT_TENANT": "consumers",
                "LINGXI_MICROSOFT_REDIRECT_URI": "http://localhost",
            ]
        )
        XCTAssertEqual(configuration.clientId, "11111111-2222-3333-4444-555555555555")
        XCTAssertEqual(configuration.tenant, "consumers")
        XCTAssertEqual(configuration.redirectURI, "http://localhost")
        XCTAssertTrue(configuration.scopes.contains("offline_access"))
    }

    func testEmbeddedRegistrationIsAvailableWithoutFiles() throws {
        let configuration = try MicrosoftAuthenticationConfiguration.load(dataRoot: root, environment: [:])
        XCTAssertEqual(configuration.clientId, "4c990be6-c02d-4f0d-84f6-c3d6785f2a36")
        XCTAssertEqual(configuration.tenant, "consumers")
        XCTAssertEqual(configuration.redirectURI, "http://localhost")
        XCTAssertEqual(configuration.scopes, ["XboxLive.signin", "offline_access"])
    }

    func testEnvironmentOverrideWins() throws {
        let configuration = try MicrosoftAuthenticationConfiguration.load(
            dataRoot: root,
            environment: [
                "LINGXI_MICROSOFT_CLIENT_ID": "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee",
                "LINGXI_MICROSOFT_REDIRECT_URI": "http://127.0.0.1",
            ]
        )
        XCTAssertEqual(configuration.clientId, "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee")
        XCTAssertEqual(configuration.redirectURI, "http://127.0.0.1")
    }

    func testClientSecretInConfigurationJSONIsRejected() {
        let json = #"{"clientId":"abc","clientSecret":"shhh"}"#
        XCTAssertThrowsError(try JSONDecoder().decode(MicrosoftAuthenticationConfiguration.self, from: Data(json.utf8))) { error in
            XCTAssertEqual((error as? LauncherError)?.code, .invalidMetadata)
        }
    }

    func testNonLoopbackRedirectIsRejected() {
        let configuration = MicrosoftAuthenticationConfiguration(clientId: "abc", redirectURI: "https://evil.example.com/cb")
        XCTAssertThrowsError(try configuration.validate()) { error in
            XCTAssertEqual((error as? LauncherError)?.code, .invalidMetadata)
        }
    }

    func testRedirectURIPortInjectionPreservesPath() {
        let configuration = MicrosoftAuthenticationConfiguration(clientId: "abc", redirectURI: "http://localhost/callback")
        let url = configuration.redirectURI(port: 43210)
        XCTAssertEqual(url.absoluteString, "http://localhost:43210/callback")
    }
}

final class PKCETests: XCTestCase {
    func testRFC7636Vector() {
        // Appendix B of RFC 7636.
        let verifier = "dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk"
        let challenge = PKCE.challenge(for: verifier)
        XCTAssertEqual(challenge, "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM")
    }

    func testGeneratedVerifierAndStateAreURLSafe() {
        let pair = PKCE.generate()
        XCTAssertGreaterThanOrEqual(pair.verifier.count, 43)
        XCTAssertFalse(pair.verifier.contains("+"))
        XCTAssertFalse(pair.verifier.contains("/"))
        XCTAssertFalse(pair.challenge.contains("="))
        XCTAssertNotEqual(PKCE.generate().verifier, pair.verifier)
        XCTAssertEqual(PKCE.challenge(for: pair.verifier), pair.challenge)
    }
}

final class MicrosoftOAuthClientTests: XCTestCase {
    private let configuration = MicrosoftAuthenticationConfiguration(
        clientId: "test-client-id",
        tenant: "consumers",
        redirectURI: "http://localhost/callback"
    )

    func testAuthorizationURLContainsPKCEAndNoSecret() {
        let url = MicrosoftOAuthClient.authorizationURL(
            configuration: configuration,
            state: "state-123",
            codeChallenge: "challenge-xyz",
            redirectURI: configuration.redirectURI(port: 52345)
        )
        let components = URLComponents(url: url, resolvingAgainstBaseURL: false)!
        let items = Dictionary(uniqueKeysWithValues: (components.queryItems ?? []).map { ($0.name, $0.value ?? "") })
        XCTAssertEqual(components.host, "login.microsoftonline.com")
        XCTAssertEqual(components.path, "/consumers/oauth2/v2.0/authorize")
        XCTAssertEqual(items["client_id"], "test-client-id")
        XCTAssertEqual(items["response_type"], "code")
        XCTAssertEqual(items["code_challenge_method"], "S256")
        XCTAssertEqual(items["code_challenge"], "challenge-xyz")
        XCTAssertEqual(items["state"], "state-123")
        XCTAssertEqual(items["redirect_uri"], "http://localhost:52345/callback")
        XCTAssertTrue(items["scope"]?.contains("XboxLive.signin") ?? false)
        XCTAssertTrue(items["scope"]?.contains("offline_access") ?? false)
        XCTAssertNil(items["client_secret"])
    }

    func testAuthorizationCodeExchangeUsesPKCEVerifier() async throws {
        let client = StubMicrosoftHTTPClient { request in
            XCTAssertEqual(request.url.path, "/consumers/oauth2/v2.0/token")
            XCTAssertEqual(request.method, "POST")
            let body = String(decoding: request.body ?? Data(), as: UTF8.self)
            XCTAssertTrue(body.contains("grant_type=authorization_code"))
            XCTAssertTrue(body.contains("code_verifier=verifier-123"))
            XCTAssertTrue(body.contains("code=code-456"))
            XCTAssertFalse(body.contains("client_secret"))
            let json = """
            {"access_token":"ms-access","refresh_token":"ms-refresh","expires_in":3600,"token_type":"Bearer","scope":"XboxLive.signin offline_access"}
            """
            return MicrosoftHTTPResponse(statusCode: 200, data: Data(json.utf8))
        }
        let oauth = MicrosoftOAuthClient(configuration: configuration, http: client)
        let token = try await oauth.exchange(
            code: "code-456",
            verifier: "verifier-123",
            redirectURI: configuration.redirectURI(port: 52345)
        )
        XCTAssertEqual(token.accessToken, "ms-access")
        XCTAssertEqual(token.refreshToken, "ms-refresh")
        XCTAssertFalse(token.isExpired)
    }

    func testInvalidGrantOnRefreshBecomesTokenExpired() async {
        let client = StubMicrosoftHTTPClient { _ in
            let json = #"{"error":"invalid_grant","error_description":"AADSTS70008: refresh token expired"}"#
            return MicrosoftHTTPResponse(statusCode: 400, data: Data(json.utf8))
        }
        let oauth = MicrosoftOAuthClient(configuration: configuration, http: client)
        do {
            _ = try await oauth.refresh(refreshToken: "expired")
            XCTFail("expected error")
        } catch let error as LauncherError {
            XCTAssertEqual(error.code, .tokenExpired)
        } catch {
            XCTFail("unexpected error: \(error)")
        }
    }
}

final class XboxMinecraftAuthenticationTests: XCTestCase {
    func testSuccessfulXboxXSTSAndMinecraftFlow() async throws {
        let client = StubMicrosoftHTTPClient { request in
            let bodyText = String(decoding: request.body ?? Data(), as: UTF8.self)
            switch request.url.path {
            case "/user/authenticate":
                XCTAssertEqual(request.headers["x-xbl-contract-version"], "1")
                XCTAssertTrue(bodyText.contains("d=ms-access-token"))
                return MicrosoftHTTPResponse(statusCode: 200, data: Data(#"{"Token":"xbl-token","DisplayClaims":{"xui":[{"uhs":"user-hash"}]}}"#.utf8))
            case "/xsts/authorize":
                XCTAssertTrue(bodyText.contains("SandboxId"))
                XCTAssertTrue(bodyText.contains("xbl-token"))
                return MicrosoftHTTPResponse(statusCode: 200, data: Data(#"{"Token":"xsts-token","DisplayClaims":{"xui":[{"uhs":"user-hash","xid":"123456789"}]}}"#.utf8))
            case "/authentication/login_with_xbox":
                XCTAssertTrue(bodyText.contains("XBL3.0 x=user-hash;xsts-token"))
                return MicrosoftHTTPResponse(statusCode: 200, data: Data(#"{"access_token":"mc-access","expires_in":3600,"username":"069a79f444e94726a5befca90e38aaf5"}"#.utf8))
            case "/entitlements/mcstore":
                XCTAssertEqual(request.headers["Authorization"], "Bearer mc-access")
                return MicrosoftHTTPResponse(statusCode: 200, data: Data(#"{"items":[{"name":"product_minecraft"}]}"#.utf8))
            case "/minecraft/profile":
                XCTAssertEqual(request.headers["Authorization"], "Bearer mc-access")
                return MicrosoftHTTPResponse(statusCode: 200, data: Data(#"{"id":"069a79f444e94726a5befca90e38aaf5","name":"Notch","skins":[{"state":"ACTIVE","url":"http://textures.minecraft.net/texture/skin","variant":"SLIM"}],"capes":[{"state":"ACTIVE","url":"http://textures.minecraft.net/texture/cape"}]}"#.utf8))
            default:
                return MicrosoftHTTPResponse(statusCode: 404, data: Data())
            }
        }
        let authenticator = XboxMinecraftAuthenticator(http: client)
        let xbox = try await authenticator.authenticateMicrosoft("ms-access-token")
        XCTAssertEqual(xbox.token, "xbl-token")
        XCTAssertEqual(xbox.userHash, "user-hash")

        let xsts = try await authenticator.authorizeXSTS(xbox)
        XCTAssertEqual(xsts.token, "xsts-token")
        XCTAssertEqual(xsts.xuid, "123456789" as String?)

        let minecraft = try await authenticator.loginMinecraft(xstsToken: xsts.token, userHash: xsts.userHash, xuid: xsts.xuid ?? "0")
        XCTAssertEqual(minecraft.token, "mc-access")

        let result = try await authenticator.verifyOwnershipAndProfile(
            minecraftToken: minecraft.token,
            expiresAt: minecraft.expiresAt,
            xuid: xsts.xuid ?? "0"
        )
        XCTAssertEqual(result.profile.name, "Notch")
        XCTAssertEqual(result.profile.id.uuidString.lowercased(), "069a79f4-44e9-4726-a5be-fca90e38aaf5")
        XCTAssertTrue(result.ownsGame)
        XCTAssertEqual(result.xuid, "123456789")
        XCTAssertEqual(result.appearance?.skinModel, .slim)
        XCTAssertEqual(result.appearance?.skinTextureURL?.absoluteString, "https://textures.minecraft.net/texture/skin")
        XCTAssertEqual(result.appearance?.capeTextureURL?.absoluteString, "https://textures.minecraft.net/texture/cape")
    }

    func testXboxRestrictionMapsXErrToActionableError() async {
        let client = StubMicrosoftHTTPClient { request in
            if request.url.path == "/user/authenticate" {
                return MicrosoftHTTPResponse(statusCode: 200, data: Data(#"{"Token":"xbl","DisplayClaims":{"xui":[{"uhs":"uhs","xid":"1"}]}}"#.utf8))
            }
            return MicrosoftHTTPResponse(statusCode: 401, data: Data(#"{"XErr":2148916233}"#.utf8))
        }
        let authenticator = XboxMinecraftAuthenticator(http: client)
        do {
            let xbox = try await authenticator.authenticateMicrosoft("ms")
            _ = try await authenticator.authorizeXSTS(xbox)
            XCTFail("expected error")
        } catch let error as LauncherError {
            XCTAssertEqual(error.code, .xboxAccountRestricted)
            XCTAssertTrue(error.message.contains("no Xbox profile"), error.message)
        } catch {
            XCTFail("unexpected error: \(error)")
        }
    }

    func testNoOwnershipIsRejected() async {
        let client = StubMicrosoftHTTPClient { request in
            switch request.url.path {
            case "/entitlements/mcstore":
                return MicrosoftHTTPResponse(statusCode: 200, data: Data(#"{"items":[]}"#.utf8))
            case "/minecraft/profile":
                return MicrosoftHTTPResponse(statusCode: 404, data: Data())
            default:
                return MicrosoftHTTPResponse(statusCode: 200, data: Data())
            }
        }
        let authenticator = XboxMinecraftAuthenticator(http: client)
        do {
            _ = try await authenticator.verifyOwnershipAndProfile(
                minecraftToken: "mc",
                expiresAt: Date().addingTimeInterval(3600),
                xuid: "1"
            )
            XCTFail("expected error")
        } catch let error as LauncherError {
            XCTAssertEqual(error.code, .gameOwnershipMissing)
        } catch {
            XCTFail("unexpected error: \(error)")
        }
    }

    func testAppRegistration403IsDistinct() async {
        let client = StubMicrosoftHTTPClient { _ in
            MicrosoftHTTPResponse(statusCode: 403, data: Data(#"{"error":"Forbidden"}"#.utf8))
        }
        let authenticator = XboxMinecraftAuthenticator(http: client)
        do {
            _ = try await authenticator.loginMinecraft(xstsToken: "x", userHash: "u", xuid: "1")
            XCTFail("expected error")
        } catch let error as LauncherError {
            XCTAssertEqual(error.code, .appRegistrationRejected)
        } catch {
            XCTFail("unexpected error: \(error)")
        }
    }
}

final class MicrosoftAuthenticationServiceTests: XCTestCase {
    private var root: URL!
    private var layout: GameDataLayout!
    private let configuration = MicrosoftAuthenticationConfiguration(clientId: "test-client")

    override func setUpWithError() throws {
        root = try FixtureLoader.temporaryDirectory("lingxi-auth-service")
        layout = GameDataLayout(gameRoot: root.appendingPathComponent("mc"), dataRoot: root.appendingPathComponent("data"))
    }

    override func tearDownWithError() throws {
        if let root { try? FileManager.default.removeItem(at: root) }
    }

    private static func tokenResponse(refresh: String = "refresh-token") -> MicrosoftHTTPResponse {
        let json = """
        {"access_token":"ms-access","refresh_token":"\(refresh)","expires_in":3600,"token_type":"Bearer"}
        """
        return MicrosoftHTTPResponse(statusCode: 200, data: Data(json.utf8))
    }

    private func result(name: String = "Notch") -> MinecraftAuthenticationResult {
        MinecraftAuthenticationResult(
            profile: MinecraftProfile(id: UUID(uuidString: "069a79f4-44e9-4726-a5be-fca90e38aaf5")!, name: name),
            accessToken: "mc-access-token",
            expiresAt: Date().addingTimeInterval(3600),
            xuid: "123456789",
            ownsGame: true,
            appearance: PlayerAppearance(
                skinTextureURL: URL(string: "https://textures.minecraft.net/texture/service-skin"),
                capeTextureURL: URL(string: "https://textures.minecraft.net/texture/service-cape"),
                skinModel: .classic
            )
        )
    }

    private func makeService(
        http: StubMicrosoftHTTPClient,
        authorizer: any OAuthAuthorizing = StubOAuthAuthorizer(code: "code"),
        authenticator: any MinecraftAuthenticatorProtocol,
        tokenStore: any RefreshTokenStoring,
        accountStore: MicrosoftAccountStore
    ) -> MicrosoftAuthenticationService {
        MicrosoftAuthenticationService(
            configuration: configuration,
            http: http,
            authorizer: authorizer,
            tokenStore: tokenStore,
            accountStore: accountStore,
            authenticator: authenticator
        )
    }

    func testSignInStoresAccountMetadataWithoutTokens() async throws {
        let tokenStore = InMemoryRefreshTokenStore()
        let accountStore = MicrosoftAccountStore(layout: layout)
        let http = StubMicrosoftHTTPClient { _ in Self.tokenResponse() }
        let service = makeService(
            http: http,
            authenticator: StubMinecraftAuthenticator(result: result()),
            tokenStore: tokenStore,
            accountStore: accountStore
        )

        let account = try await service.signIn()
        XCTAssertEqual(account.playerName, "Notch")
        XCTAssertTrue(account.ownsGame)
        XCTAssertEqual(try tokenStore.loadRefreshToken(for: account.id), "refresh-token")

        let state = await service.currentState()
        XCTAssertEqual(state, .signedIn(account))

        let metadataURL = layout.accountsDirectory
            .appendingPathComponent("microsoft/\(account.id.uuidString.lowercased()).json")
        let metadata = try String(contentsOf: metadataURL, encoding: .utf8).lowercased()
        XCTAssertFalse(metadata.contains("refresh"))
        XCTAssertFalse(metadata.contains("access_token"))
        XCTAssertFalse(metadata.contains("token\""))
        XCTAssertTrue(metadata.contains("notch"))
        XCTAssertTrue(metadata.contains("textures.minecraft.net"))
        XCTAssertTrue(metadata.contains("service-skin"))
        XCTAssertTrue(metadata.contains("service-cape"))
    }

    func testSessionUsesCacheThenRefreshesWithRefreshToken() async throws {
        let tokenStore = InMemoryRefreshTokenStore()
        let accountStore = MicrosoftAccountStore(layout: layout)
        let http = StubMicrosoftHTTPClient { request in
            let body = String(decoding: request.body ?? Data(), as: UTF8.self)
            if body.contains("grant_type=refresh_token") {
                XCTAssertTrue(body.contains("refresh_token=refresh-token"))
                return Self.tokenResponse(refresh: "rotated-refresh")
            }
            return Self.tokenResponse()
        }
        let service = makeService(
            http: http,
            authenticator: StubMinecraftAuthenticator(result: result()),
            tokenStore: tokenStore,
            accountStore: accountStore
        )
        let account = try await service.signIn()

        // Same process: the in-memory Minecraft session is still valid and is reused.
        let cached = try await service.session(for: account.id)
        XCTAssertEqual(cached.accessToken, "mc-access-token")

        // A fresh service has no cached Minecraft token, so it must use the stored refresh token.
        let refreshedService = makeService(
            http: http,
            authenticator: StubMinecraftAuthenticator(result: result()),
            tokenStore: tokenStore,
            accountStore: accountStore
        )
        let refreshed = try await refreshedService.session(for: account.id)
        XCTAssertEqual(refreshed.accessToken, "mc-access-token")
        XCTAssertEqual(try tokenStore.loadRefreshToken(for: account.id), "rotated-refresh")
    }

    func testExpiredRefreshTokenIsExplicitAndNeverFallsBack() async throws {
        let tokenStore = InMemoryRefreshTokenStore()
        let accountStore = MicrosoftAccountStore(layout: layout)
        let account = MicrosoftAccount(id: result().profile.id, playerName: "Notch", xuid: "1", ownsGame: true)
        try accountStore.save(account)
        try tokenStore.save(refreshToken: "old", for: account.id)

        let http = StubMicrosoftHTTPClient { _ in
            MicrosoftHTTPResponse(statusCode: 400, data: Data(#"{"error":"invalid_grant"}"#.utf8))
        }
        let service = makeService(
            http: http,
            authenticator: StubMinecraftAuthenticator(result: result()),
            tokenStore: tokenStore,
            accountStore: accountStore
        )
        do {
            _ = try await service.session(for: account.id)
            XCTFail("expected error")
        } catch let error as LauncherError {
            XCTAssertEqual(error.code, .tokenExpired)
        } catch {
            XCTFail("unexpected error: \(error)")
        }
        let state = await service.currentState()
        guard case let .failed(_, code) = state else {
            return XCTFail("expected failed state, got \(state)")
        }
        XCTAssertEqual(code, .tokenExpired)
    }

    func testSignOutDeletesMetadataAndRefreshToken() async throws {
        let tokenStore = InMemoryRefreshTokenStore()
        let accountStore = MicrosoftAccountStore(layout: layout)
        let service = makeService(
            http: StubMicrosoftHTTPClient { _ in Self.tokenResponse() },
            authenticator: StubMinecraftAuthenticator(result: result()),
            tokenStore: tokenStore,
            accountStore: accountStore
        )
        let account = try await service.signIn()
        try await service.signOut(accountID: account.id)
        XCTAssertEqual(try accountStore.list(), [])
        XCTAssertNil(try tokenStore.loadRefreshToken(for: account.id))
        let state = await service.currentState()
        XCTAssertEqual(state, .signedOut)
    }
}


    func testKeychainRoundTrip() throws {
        let serviceName = "com.lingxifox.LingXiLauncher.tests.\(UUID().uuidString)"
        #if os(macOS)
        let store = MacKeychainCredentialStore(service: serviceName)
        #else
        let store = InMemoryRefreshTokenStore()
        #endif
        let accountID = UUID()
        do {
            try store.save(refreshToken: "keychain-test-token", for: accountID)
        } catch let error as LauncherError {
            throw XCTSkip("Keychain unavailable in this environment: \(error.message)")
        }
        XCTAssertEqual(try store.loadRefreshToken(for: accountID), "keychain-test-token")
        try store.deleteRefreshToken(for: accountID)
        XCTAssertNil(try store.loadRefreshToken(for: accountID))
    }

final class LoopbackAuthorizationTests: XCTestCase {

    func testLocalhostRedirectWorksWithLoopbackServer() async throws {
        let configuration = MicrosoftAuthenticationConfiguration(
            clientId: "test-client",
            redirectURI: "http://localhost",
            authorizationTimeout: 10
        )
        let browser = LoopbackCallbackBrowser(code: "localhost-code")
        let authorizer = LoopbackOAuthAuthorizer(browser: browser)
        let callback = try await authorizer.authorize(
            configuration: configuration,
            state: "localhost-state",
            codeChallenge: "challenge",
            timeout: 10
        )
        XCTAssertEqual(callback.code, "localhost-code")
        XCTAssertEqual(callback.redirectURI.host, "localhost")
    }

    func testRealLoopbackServerReceivesCodeAndState() async throws {
        let configuration = MicrosoftAuthenticationConfiguration(
            clientId: "test-client",
            redirectURI: "http://127.0.0.1",
            authorizationTimeout: 10
        )
        let browser = LoopbackCallbackBrowser(code: "loopback-code")
        let authorizer = LoopbackOAuthAuthorizer(browser: browser)
        let callback = try await authorizer.authorize(
            configuration: configuration,
            state: "expected-state",
            codeChallenge: "challenge",
            timeout: 10
        )
        XCTAssertEqual(callback.code, "loopback-code")
        XCTAssertEqual(callback.state, "expected-state")
        XCTAssertEqual(callback.redirectURI.host, "127.0.0.1")
        XCTAssertNotNil(callback.redirectURI.port)
        XCTAssertEqual(browser.openedURL?.host, "login.microsoftonline.com")
    }

    func testMismatchedStateIsRejected() async throws {
        let configuration = MicrosoftAuthenticationConfiguration(
            clientId: "test-client",
            redirectURI: "http://127.0.0.1",
            authorizationTimeout: 10
        )
        let browser = LoopbackCallbackBrowser(code: "code", stateOverride: "attacker-state")
        let authorizer = LoopbackOAuthAuthorizer(browser: browser)
        do {
            _ = try await authorizer.authorize(
                configuration: configuration,
                state: "expected-state",
                codeChallenge: "challenge",
                timeout: 10
            )
            XCTFail("expected error")
        } catch let error as LauncherError {
            XCTAssertEqual(error.code, .unauthorized)
            XCTAssertTrue(error.message.contains("state"))
        } catch {
            XCTFail("unexpected error: \(error)")
        }
    }
}
