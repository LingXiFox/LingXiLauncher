import Foundation

/// Orchestrates Microsoft → Xbox → Minecraft authentication, secure token storage and session
/// refresh. Used by both CLI and GUI; no UI or CLI parsing lives here.
public actor MicrosoftAuthenticationService {
    public let configuration: MicrosoftAuthenticationConfiguration
    private let oauth: MicrosoftOAuthClient
    private let authorizer: any OAuthAuthorizing
    private let authenticator: MinecraftAuthenticatorProtocol
    private let tokenStore: any RefreshTokenStoring
    private let accountStore: MicrosoftAccountStore

    private var state: AuthenticationState = .signedOut
    private var observers: [UUID: AsyncStream<AuthenticationState>.Continuation] = [:]
    private var sessions: [UUID: CachedSession] = [:]

    private struct CachedSession {
        let session: AuthorizedMinecraftSession
        let refreshToken: String
    }

    public init(
        configuration: MicrosoftAuthenticationConfiguration,
        http: any MicrosoftHTTPClient = URLSessionMicrosoftHTTPClient(),
        authorizer: any OAuthAuthorizing,
        tokenStore: any RefreshTokenStoring,
        accountStore: MicrosoftAccountStore,
        authenticator: MinecraftAuthenticatorProtocol? = nil
    ) {
        self.configuration = configuration
        self.oauth = MicrosoftOAuthClient(configuration: configuration, http: http)
        self.authorizer = authorizer
        self.tokenStore = tokenStore
        self.accountStore = accountStore
        self.authenticator = authenticator ?? XboxMinecraftAuthenticator(http: http)
    }

    // MARK: - Observation

    public func currentState() -> AuthenticationState {
        state
    }

    public func stateUpdates() -> AsyncStream<AuthenticationState> {
        let pair = AsyncStream<AuthenticationState>.makeStream(bufferingPolicy: .bufferingNewest(1))
        let id = UUID()
        let continuation = pair.continuation
        continuation.onTermination = { [weak self] _ in
            Task { await self?.removeObserver(id) }
        }
        observers[id] = continuation
        continuation.yield(state)
        return pair.stream
    }

    private func removeObserver(_ id: UUID) {
        observers.removeValue(forKey: id)
    }

    private func setState(_ newState: AuthenticationState) {
        state = newState
        for continuation in observers.values {
            continuation.yield(newState)
        }
    }

    // MARK: - Accounts

    public func accounts() throws -> [MicrosoftAccount] {
        try accountStore.list()
    }

    public func account(id: UUID) throws -> MicrosoftAccount {
        try accountStore.load(id: id)
    }

    // MARK: - Sign in

    /// Interactive sign-in: opens the browser, waits for the loopback callback, completes the
    /// Xbox/Minecraft chain and stores the refresh token in the Keychain.
    @discardableResult
    public func signIn() async throws -> MicrosoftAccount {
        if state.isWorking {
            throw LauncherError(.unauthorized, "A Microsoft sign-in is already in progress")
        }
        let pkce = PKCE.generate()
        let oauthState = PKCE.randomURLSafeString(byteCount: 32)
        setState(.working(.openingBrowser))

        do {
            setState(.working(.waitingForCallback))
            let callback = try await authorizer.authorize(
                configuration: configuration,
                state: oauthState,
                codeChallenge: pkce.challenge,
                timeout: configuration.authorizationTimeout
            )

            setState(.working(.exchangingCode))
            let token = try await oauth.exchange(
                code: callback.code,
                verifier: pkce.verifier,
                redirectURI: callback.redirectURI
            )
            guard let refreshToken = token.refreshToken, !refreshToken.isEmpty else {
                throw LauncherError(
                    .unauthorized,
                    "Microsoft did not return a refresh token; offline sign-in cannot be restored",
                    suggestion: "Ensure the Entra app requests the offline_access scope."
                )
            }
            let result = try await completeAuthentication(
                microsoftAccessToken: token.accessToken,
                refreshToken: refreshToken,
                existingAccount: nil
            )
            return result.account
        } catch let error as LauncherError {
            setState(.failed(message: error.message, code: error.code))
            throw error
        } catch is CancellationError {
            let error = LauncherError(.authenticationCancelled, "Microsoft sign-in was cancelled")
            setState(.failed(message: error.message, code: error.code))
            throw error
        } catch {
            let launcherError = LauncherError(.unauthorized, "Microsoft sign-in failed: \(error.localizedDescription)")
            setState(.failed(message: launcherError.message, code: launcherError.code))
            throw launcherError
        }
    }

    // MARK: - Sessions

    /// Returns a usable Minecraft session, refreshing the saved refresh token if needed.
    /// Never falls back to another identity mode.
    public func session(for accountID: UUID) async throws -> AuthorizedMinecraftSession {
        if let cached = sessions[accountID], cached.session.expiresAt > Date().addingTimeInterval(120) {
            return cached.session
        }
        let account: MicrosoftAccount
        do {
            account = try accountStore.load(id: accountID)
        } catch let error as LauncherError {
            setState(.failed(message: error.message, code: error.code))
            throw error
        }

        guard let refreshToken = try tokenStore.loadRefreshToken(for: accountID), !refreshToken.isEmpty else {
            let error = LauncherError(
                .tokenExpired,
                "No saved Microsoft session for \(account.playerName)",
                suggestion: "Sign in with Microsoft again. The launcher will not switch to a local identity."
            )
            setState(.failed(message: error.message, code: error.code))
            throw error
        }

        setState(.working(.refreshing))
        do {
            let token = try await oauth.refresh(refreshToken: refreshToken)
            let newRefreshToken = token.refreshToken ?? refreshToken
            let result = try await completeAuthentication(
                microsoftAccessToken: token.accessToken,
                refreshToken: newRefreshToken,
                existingAccount: account
            )
            return result.session
        } catch let error as LauncherError {
            setState(.failed(message: error.message, code: error.code))
            throw error
        } catch {
            let error = LauncherError(.unauthorized, "Microsoft session refresh failed: \(error.localizedDescription)")
            setState(.failed(message: error.message, code: error.code))
            throw error
        }
    }

    /// Refreshes and returns the updated account metadata (used by the GUI status page).
    @discardableResult
    public func validate(accountID: UUID) async throws -> MicrosoftAccount {
        _ = try await session(for: accountID)
        return try accountStore.load(id: accountID)
    }

    // MARK: - Sign out

    public func signOut(accountID: UUID) throws {
        try tokenStore.deleteRefreshToken(for: accountID)
        try accountStore.delete(id: accountID)
        sessions.removeValue(forKey: accountID)
        setState(.signedOut)
    }

    public func signOutAll() throws {
        for account in try accountStore.list() {
            try tokenStore.deleteRefreshToken(for: account.id)
            try accountStore.delete(id: account.id)
        }
        sessions.removeAll()
        setState(.signedOut)
    }

    // MARK: - Core flow

    private func completeAuthentication(
        microsoftAccessToken: String,
        refreshToken: String,
        existingAccount: MicrosoftAccount?
    ) async throws -> (account: MicrosoftAccount, session: AuthorizedMinecraftSession) {
        setState(.working(.xboxLive))
        let xbox = try await authenticator.authenticateMicrosoft(microsoftAccessToken)

        setState(.working(.xsts))
        let xsts = try await authenticator.authorizeXSTS(xbox)

        setState(.working(.minecraftServices))
        // XUID is optional: Minecraft launches with an explicit "0" placeholder when Xbox
        // profile lookup is unavailable, and online features may be limited.
        let xuid = xsts.xuid ?? "0"
        let minecraft = try await authenticator.loginMinecraft(
            xstsToken: xsts.token,
            userHash: xsts.userHash,
            xuid: xuid
        )

        setState(.working(.verifyingOwnership))
        let verified = try await authenticator.verifyOwnershipAndProfile(
            minecraftToken: minecraft.token,
            expiresAt: minecraft.expiresAt,
            xuid: xuid
        )

        let account = MicrosoftAccount(
            id: verified.profile.id,
            playerName: verified.profile.name,
            xuid: verified.xuid,
            addedAt: existingAccount?.addedAt ?? Date(),
            lastValidatedAt: Date(),
            ownsGame: verified.ownsGame,
            appearance: verified.appearance ?? existingAccount?.appearance
        )
        let session = AuthorizedMinecraftSession(
            profile: verified.profile,
            xuid: verified.xuid,
            userType: "msa",
            expiresAt: verified.expiresAt,
            accessToken: verified.accessToken
        )

        // Persist the refresh token first: metadata without a token would be a broken account.
        try tokenStore.save(refreshToken: refreshToken, for: account.id)
        try accountStore.save(account)
        sessions[account.id] = CachedSession(session: session, refreshToken: refreshToken)
        setState(.signedIn(account))
        return (account, session)
    }
}

/// Small seam for tests and future alternative authentication backends.
public protocol MinecraftAuthenticatorProtocol: Sendable {
    func authenticateMicrosoft(_ microsoftAccessToken: String) async throws -> XboxTokens
    func authorizeXSTS(_ xbox: XboxTokens) async throws -> XSTSResult
    func loginMinecraft(xstsToken: String, userHash: String, xuid: String) async throws -> (token: String, expiresAt: Date)
    func verifyOwnershipAndProfile(minecraftToken: String, expiresAt: Date, xuid: String) async throws -> MinecraftAuthenticationResult
}

extension XboxMinecraftAuthenticator: MinecraftAuthenticatorProtocol {}

/// Builds the production authentication service (URLSession + loopback + Keychain).
public enum MicrosoftAuthenticationFactory {
    public static func makeDefault(
        layout: GameDataLayout,
        authorizer: any OAuthAuthorizing,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) throws -> MicrosoftAuthenticationService {
        let configuration = try MicrosoftAuthenticationConfiguration.load(dataRoot: layout.dataRoot, environment: environment)
        let http = URLSessionMicrosoftHTTPClient()
        return MicrosoftAuthenticationService(
            configuration: configuration,
            http: http,
            authorizer: authorizer,
            tokenStore: PlatformRuntime.credentials,
            accountStore: MicrosoftAccountStore(layout: layout)
        )
    }

    /// Whether a client id/config file exists. GUI uses this to show setup guidance without
    /// failing at launch.
    public static func isConfigured(
        layout: GameDataLayout,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> Bool {
        MicrosoftAuthenticationConfiguration.isConfigured(dataRoot: layout.dataRoot, environment: environment)
    }
}
