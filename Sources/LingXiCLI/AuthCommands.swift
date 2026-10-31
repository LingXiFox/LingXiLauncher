import Foundation
import LauncherCore
#if canImport(MacPlatform)
import MacPlatform
#elseif canImport(WindowsPlatform)
import WindowsPlatform
#endif

extension CLI {
    static func microsoftService(layout: GameDataLayout) throws -> MicrosoftAuthenticationService {
        try MicrosoftAuthenticationFactory.makeDefault(
            layout: layout,
            authorizer: LoopbackOAuthAuthorizer(browser: ProcessBrowserOpener())
        )
    }

    static func runMicrosoftAccountCommand(_ arguments: [String]) async throws -> Int32 {
        guard let action = arguments.first else {
            throw LauncherError(
                .usageError,
                "Missing Microsoft account action",
                suggestion: "Use `lingxi account microsoft login`, `status` or `logout`."
            )
        }
        let rest = Array(arguments.dropFirst())
        switch action {
        case "login":
            return try await runMicrosoftLogin(rest)
        case "status":
            return try runMicrosoftStatus(rest)
        case "logout":
            return try runMicrosoftLogout(rest)
        default:
            throw LauncherError(.usageError, "Unknown Microsoft account action '\(action)'")
        }
    }

    // MARK: - login

    private static func runMicrosoftLogin(_ arguments: [String]) async throws -> Int32 {
        let spec = ArgumentParser.Spec(valueOptions: ["root", "data-root"], flagOptions: ["json", "help"])
        let input = try ArgumentParser.parse(arguments, spec: spec)
        if input.has("help") {
            print("usage: lingxi account microsoft login [--root <path>] [--data-root <path>] [--json]")
            return ExitStatus.success.rawValue
        }
        let layout = try resolveLayout(input, requireGameRoot: false)
        let service = try microsoftService(layout: layout)

        var monitor: Task<Void, Never>?
        if !input.has("json") {
            CLIOutput.fail("Starting Microsoft sign-in (a browser window will open)…")
            monitor = Task {
                for await state in await service.stateUpdates() {
                    guard case let .working(phase) = state else { continue }
                    CLIOutput.fail("  \(describe(phase))")
                }
            }
        }
        defer { monitor?.cancel() }

        do {
            let account = try await service.signIn()
            monitor?.cancel()
            try? ActiveAccountStore(layout: layout).save(AccountReference(kind: .microsoft, identifier: account.id.uuidString.lowercased()))

            if input.has("json") {
                CLIOutput.emitJSON(JSONMicrosoftAccount(account))
                return ExitStatus.success.rawValue
            }
            CLIOutput.header("Microsoft sign-in complete")
            CLIOutput.field("player", account.playerName)
            CLIOutput.field("uuid", account.id.uuidString.lowercased())
            CLIOutput.field("xuid", account.xuid)
            CLIOutput.field("ownership", account.ownsGame ? "verified" : "not verified")
            CLIOutput.field("token storage", "refresh token saved in macOS Keychain")
            print("Launch with: lingxi launch --instance <id> --identity microsoft:\(account.id.uuidString.lowercased())")
            return ExitStatus.success.rawValue
        } catch {
            monitor?.cancel()
            throw error
        }
    }

    // MARK: - status

    private static func runMicrosoftStatus(_ arguments: [String]) throws -> Int32 {
        let spec = ArgumentParser.Spec(valueOptions: ["root", "data-root"], flagOptions: ["json", "help"])
        let input = try ArgumentParser.parse(arguments, spec: spec)
        if input.has("help") {
            print("usage: lingxi account microsoft status [--root <path>] [--data-root <path>] [--json]")
            return ExitStatus.success.rawValue
        }
        let layout = try resolveLayout(input, requireGameRoot: false)
        let accounts = try MicrosoftAccountStore(layout: layout).list()
        let active = ActiveAccountStore(layout: layout).load()

        if input.has("json") {
            CLIOutput.emitJSON(accounts.map(JSONMicrosoftAccount.init))
            return ExitStatus.success.rawValue
        }
        if accounts.isEmpty {
            print("No Microsoft accounts signed in. Use `lingxi account microsoft login`.")
            return ExitStatus.success.rawValue
        }
        CLIOutput.header("Microsoft accounts")
        for account in accounts {
            let marker = active?.kind == .microsoft && active?.identifier == account.id.uuidString.lowercased() ? " *" : ""
            let validated = account.lastValidatedAt.map(CLIOutput.formatDate) ?? "never"
            print("  - \(account.playerName)  \(account.id.uuidString.lowercased())\(marker)")
            print("      xuid \(account.xuid) · ownership \(account.ownsGame ? "verified" : "unverified") · last validated \(validated)")
        }
        print("Tokens are stored in the macOS Keychain; this status is cached metadata only.")
        return ExitStatus.success.rawValue
    }

    // MARK: - logout

    private static func runMicrosoftLogout(_ arguments: [String]) throws -> Int32 {
        let spec = ArgumentParser.Spec(
            valueOptions: ["account", "root", "data-root"],
            flagOptions: ["all", "json", "help"]
        )
        let input = try ArgumentParser.parse(arguments, spec: spec)
        if input.has("help") {
            print("usage: lingxi account microsoft logout [--account <uuid|player-name>] [--all] [--root <path>] [--data-root <path>]")
            return ExitStatus.success.rawValue
        }
        guard input.has("all") || input.value("account") != nil else {
            throw LauncherError(
                .usageError,
                "Specify --account <uuid|player-name> or --all",
                suggestion: "This prevents accidentally removing every saved Microsoft account."
            )
        }
        let layout = try resolveLayout(input, requireGameRoot: false)
        let store = MicrosoftAccountStore(layout: layout)
        let tokenStore = PlatformRuntime.credentials
        let activeStore = ActiveAccountStore(layout: layout)
        let accounts = try store.list()

        let targets: [MicrosoftAccount]
        if input.has("all") {
            targets = accounts
        } else if let raw = input.value("account") {
            let matches = accounts.filter {
                $0.id.uuidString.caseInsensitiveCompare(raw) == .orderedSame
                    || $0.playerName.caseInsensitiveCompare(raw) == .orderedSame
            }
            guard !matches.isEmpty else {
                throw LauncherError(.missingDependency, "No Microsoft account matches '\(raw)'")
            }
            targets = matches
        } else {
            targets = []
        }

        for account in targets {
            try tokenStore.deleteRefreshToken(for: account.id)
            try store.delete(id: account.id)
            print("Signed out \(account.playerName)")
            if let active = activeStore.load(),
               active.kind == .microsoft, active.identifier == account.id.uuidString.lowercased() {
                try? activeStore.save(nil)
            }
        }
        if targets.isEmpty {
            print("No Microsoft accounts to sign out.")
        }
        return ExitStatus.success.rawValue
    }

    // MARK: - account list

    static func runAccountList(_ arguments: [String]) async throws -> Int32 {
        let spec = ArgumentParser.Spec(valueOptions: ["root", "data-root"], flagOptions: ["json", "help"])
        let input = try ArgumentParser.parse(arguments, spec: spec)
        if input.has("help") {
            print("usage: lingxi account list [--root <path>] [--data-root <path>] [--json]")
            return ExitStatus.success.rawValue
        }
        let layout = try resolveLayout(input, requireGameRoot: false)
        let active = ActiveAccountStore(layout: layout).load()
        let localAccounts = try LocalAccountStore(layout: layout).list()
        let microsoftAccounts = try MicrosoftAccountStore(layout: layout).list()

        if input.has("json") {
            var summaries: [JSONAccountSummary] = []
            for account in microsoftAccounts {
                summaries.append(JSONAccountSummary(
                    kind: "microsoft",
                    identifier: account.id.uuidString.lowercased(),
                    playerName: account.playerName,
                    uuid: account.id.uuidString.lowercased(),
                    ownsGame: account.ownsGame,
                    active: active?.kind == .microsoft && active?.identifier == account.id.uuidString.lowercased()
                ))
            }
            for account in localAccounts {
                summaries.append(JSONAccountSummary(
                    kind: "local",
                    identifier: account.playerName,
                    playerName: account.playerName,
                    uuid: account.offlineUUID.uuidString.lowercased(),
                    ownsGame: nil,
                    active: active?.kind == .local && active?.identifier == account.playerName
                ))
            }
            CLIOutput.emitJSON(summaries)
            return ExitStatus.success.rawValue
        }

        CLIOutput.header("Accounts")
        if microsoftAccounts.isEmpty && localAccounts.isEmpty {
            print("No accounts yet.")
        }
        for account in microsoftAccounts {
            let marker = active?.kind == .microsoft && active?.identifier == account.id.uuidString.lowercased() ? " *" : ""
            print("  - microsoft  \(account.playerName)  \(account.id.uuidString.lowercased())\(marker)")
            print("      ownership \(account.ownsGame ? "verified" : "unverified") · tokens in Keychain")
        }
        for account in localAccounts {
            let marker = active?.kind == .local && active?.identifier == account.playerName ? " *" : ""
            print("  - local      \(account.playerName)  \(account.offlineUUID.uuidString.lowercased())\(marker)  (unverified)")
        }
        print("* = active account")
        return ExitStatus.success.rawValue
    }

    private static func describe(_ phase: AuthenticationPhase) -> String {
        switch phase {
        case .openingBrowser: return "Opening the system browser…"
        case .waitingForCallback: return "Waiting for the Microsoft callback…"
        case .exchangingCode: return "Exchanging the authorization code…"
        case .xboxLive: return "Authenticating with Xbox Live…"
        case .xsts: return "Authorizing with XSTS…"
        case .minecraftServices: return "Signing in to Minecraft Services…"
        case .verifyingOwnership: return "Verifying Minecraft ownership and profile…"
        case .refreshing: return "Refreshing the saved Microsoft session…"
        case .completed: return "Completed."
        }
    }
}
