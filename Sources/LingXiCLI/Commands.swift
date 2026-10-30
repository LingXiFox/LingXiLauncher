import Foundation
import LauncherCore

/// Composition root: the CLI is a thin shell that wires concrete Core services together.
/// It contains no launcher business logic of its own.
struct CLIServices: Sendable {
    let ruleEvaluator: RuleEvaluator
    let argumentResolver: ArgumentResolver
    let planBuilder: LaunchPlanBuilder
    let dependencyResolver: DependencyResolver
    let javaInspector: JavaRuntimeInspector

    init() {
        let rules = RuleEvaluator()
        let arguments = ArgumentResolver(ruleEvaluator: rules)
        self.ruleEvaluator = rules
        self.argumentResolver = arguments
        self.planBuilder = LaunchPlanBuilder(argumentResolver: arguments)
        self.dependencyResolver = DependencyResolver(ruleEvaluator: rules)
        self.javaInspector = JavaRuntimeInspector()
    }
}

enum CLI {
    static let services = CLIServices()

    static func run(arguments: [String]) async -> Int32 {
        do {
            return try await dispatch(arguments)
        } catch let error as LauncherError {
            CLIOutput.fail(error)
            return exitCode(for: error)
        } catch {
            CLIOutput.fail("error: \(error.localizedDescription)")
            return ExitStatus.internalError.rawValue
        }
    }

    static func exitCode(for error: LauncherError) -> Int32 {
        switch error.code {
        case .usageError: return ExitStatus.usage.rawValue
        case .invalidMetadata, .unsupportedVersion, .identityIsolationViolation, .pathEscapesRoot, .invalidProfileName:
            return ExitStatus.dataError.rawValue
        case .missingDependency:
            return ExitStatus.missingInput.rawValue
        case .javaNotFound, .javaVersionMismatch, .javaArchitectureMismatch:
            return ExitStatus.javaUnusable.rawValue
        case .notImplemented, .unauthorized, .appRegistrationRejected,
             .configurationMissing, .authenticationCancelled, .authenticationTimeout,
             .gameOwnershipMissing, .xboxAccountRestricted, .tokenExpired:
            return ExitStatus.unavailable.rawValue
        case .ioFailure, .diskFull, .permissionDenied, .keychainFailure:
            return ExitStatus.ioError.rawValue
        case .networkFailure, .httpForbidden, .httpNotFound, .downloadFailed:
            return ExitStatus.unavailable.rawValue
        case .hashMismatch, .sizeMismatch:
            return ExitStatus.dataError.rawValue
        case .launchFailed:
            return ExitStatus.internalError.rawValue
        }
    }

    // MARK: - Dispatch

    private static func dispatch(_ arguments: [String]) async throws -> Int32 {
        guard let command = arguments.first else {
            printHelp()
            return ExitStatus.success.rawValue
        }
        let rest = Array(arguments.dropFirst())
        switch command {
        case "help", "--help", "-h":
            printHelp()
            return ExitStatus.success.rawValue
        case "--version", "-V", "cli-version":
            print("\(LauncherInfo.name) \(LauncherInfo.version)")
            return ExitStatus.success.rawValue
        case "version":
            return try await runVersionCommand(rest)
        case "doctor":
            return try runDoctorCommand(rest)
        case "launch":
            return try await runLaunchCommand(rest)
        case "account":
            return try await runAccountCommand(rest)
        case "java":
            return try await runJavaCommand(rest)
        case "instance":
            if rest.first == "copy" {
                return try InstanceToolsCLI.copy(Array(rest.dropFirst()))
            }
            return try runInstanceCommand(rest)
        case "world":
            return try InstanceToolsCLI.runWorld(rest)
        case "diagnose":
            return try InstanceToolsCLI.runDiagnose(rest)
        case "install":
            return try await runInstall(rest)
        case "mod":
            return try await runModCommand(rest)
        case "mrpack":
            return try await runMrpackCommand(rest)
        case "modpack":
            return try await runModpackCommand(rest)
        case "graphics":
            return try await runGraphicsCommand(rest)
        case "shader":
            return try await runShaderCommand(rest)
        case "resourcepack", "resourcepacks":
            return try await runResourcePackCommand(rest)
        case "performance", "perf":
            return try await runPerformanceCommand(rest)
        case "verify":
            return try await runVerify(rest)
        default:
            throw LauncherError(.usageError, "Unknown command '\(command)'", suggestion: "Run `lingxi help`.")
        }
    }

    // MARK: - Context helpers

    static func dataRoot(_ input: CommandLineInput) -> URL {
        if let raw = input.value("data-root") {
            return URL(fileURLWithPath: (raw as NSString).expandingTildeInPath, isDirectory: true).standardizedFileURL
        }
        if let env = ProcessInfo.processInfo.environment["LINGXI_DATA_ROOT"], !env.isEmpty {
            return URL(fileURLWithPath: (env as NSString).expandingTildeInPath, isDirectory: true).standardizedFileURL
        }
        return GameDataLayout.defaultDataRoot
    }

    static func gameRoot(_ input: CommandLineInput) throws -> URL {
        if let raw = input.value("root") {
            return URL(fileURLWithPath: (raw as NSString).expandingTildeInPath, isDirectory: true).standardizedFileURL
        }
        let official = GameDataLayout.officialMinecraftRoot
        if FileManager.default.fileExists(atPath: official.path) {
            return official
        }
        throw LauncherError(
            .usageError,
            "No game root found",
            suggestion: "Pass --root <path-to-.minecraft> (the official launcher default is ~/Library/Application Support/minecraft)."
        )
    }

    /// Resolves the layout for a command.
    ///
    /// `requireGameRoot` is false for commands that only touch launcher-owned data (accounts,
    /// instances): they must work on a machine without any official Minecraft installation.
    static func resolveLayout(_ input: CommandLineInput, requireGameRoot: Bool = true) throws -> GameDataLayout {
        let root: URL
        if requireGameRoot {
            root = try gameRoot(input)
        } else {
            root = (try? gameRoot(input)) ?? GameDataLayout.defaultDataRoot.appendingPathComponent("minecraft", isDirectory: true)
        }
        return GameDataLayout(gameRoot: root, dataRoot: dataRoot(input))
    }

    static func platform() throws -> PlatformContext {
        try PlatformContext.current()
    }

    /// Platform used for rule evaluation: the selected JVM when `--java` is given, host otherwise.
    static func commandPlatform(_ input: CommandLineInput) throws -> PlatformContext {
        guard let javaPath = input.value("java") else { return try platform() }
        let executable = URL(fileURLWithPath: (javaPath as NSString).expandingTildeInPath)
        let runtime = try services.javaInspector.inspect(executable: executable)
        return try PlatformContext.forJVM(runtime)
    }

    // MARK: - version

    private static func runVersionCommand(_ arguments: [String]) async throws -> Int32 {
        guard let subcommand = arguments.first else {
            throw LauncherError(.usageError, "Missing version subcommand", suggestion: "Use `lingxi version inspect --id <version-id>`.")
        }
        let rest = Array(arguments.dropFirst())
        switch subcommand {
        case "inspect":
            return try runVersionInspect(rest)
        case "list":
            return try await runVersionList(rest)
        default:
            throw LauncherError(.usageError, "Unknown version subcommand '\(subcommand)'")
        }
    }

    private static func runVersionInspect(_ arguments: [String]) throws -> Int32 {
        let spec = ArgumentParser.Spec(valueOptions: ["id", "java", "root", "data-root"])
        let input = try ArgumentParser.parse(arguments, spec: spec)
        if input.has("help") {
            print("usage: lingxi version inspect --id <version-id> [--java <path>] [--root <path>] [--data-root <path>] [--json]")
            return ExitStatus.success.rawValue
        }
        let versionID = try input.requireValue("id")
        let layout = try resolveLayout(input)
        let platform = try commandPlatform(input)
        let version = try VersionResolver().resolve(versionID: versionID, from: layout.gameRoot)
        let dependencies = try services.dependencyResolver.resolve(version: version, layout: layout, platform: platform)
        let allowedLibraries = try version.libraries.filter {
            try services.ruleEvaluator.isAllowed($0.rules, platform: platform)
        }

        if input.has("json") {
            CLIOutput.emitJSON(JSONInspect(
                versionID: version.id,
                type: version.type,
                mainClass: version.mainClass,
                format: "modern-arguments",
                javaComponent: version.javaRequirement.component,
                javaMajorVersion: version.javaRequirement.majorVersion,
                libraryCount: version.libraries.count,
                allowedLibraryCount: allowedLibraries.count,
                classpathEntryCount: dependencies.classpath.count,
                legacyNativeCount: dependencies.legacyNatives.count,
                jvmArgumentCount: version.jvmArguments.count,
                gameArgumentCount: version.gameArguments.count,
                assetIndexID: version.assetIndexID,
                clientJarSHA1: version.clientJar?.sha1,
                clientJarSize: version.clientJar?.size,
                inheritsFrom: version.inheritsFrom,
                metadataPath: version.metadataURL.path,
                missing: dependencies.missing.map(JSONMissingDependency.init),
                diagnostics: dependencies.diagnostics.map(JSONDiagnostic.init)
            ))
            return ExitStatus.success.rawValue
        }

        CLIOutput.header("Minecraft \(version.id) (\(version.type))")
        CLIOutput.field("metadata", version.metadataURL.path)
        CLIOutput.field("mainClass", version.mainClass)
        CLIOutput.field("format", "modern arguments (arguments.jvm / arguments.game)")
        let javaRequirement = version.javaRequirement.majorVersion.map { "Java \($0)+" + (version.javaRequirement.component.map { " (\($0))" } ?? "") } ?? "not declared"
        CLIOutput.field("java requirement", javaRequirement)
        CLIOutput.field("libraries", "\(version.libraries.count) total, \(allowedLibraries.count) allowed on this platform")
        CLIOutput.field("classpath entries", "\(dependencies.classpath.count)")
        CLIOutput.field("legacy natives", "\(dependencies.legacyNatives.count)")
        CLIOutput.field("arguments", "\(version.jvmArguments.count) JVM / \(version.gameArguments.count) game entries")
        CLIOutput.field("asset index", version.assetIndexID)
        if let client = version.clientJar {
            CLIOutput.field("client jar", "sha1 \(client.sha1 ?? "?") size \(client.size.map(String.init) ?? "?")")
        } else {
            CLIOutput.field("client jar", "metadata does not declare downloads.client")
        }
        if let inherited = version.inheritsFrom {
            CLIOutput.field("inheritsFrom", inherited)
        }
        CLIOutput.printMissing(dependencies.missing)
        CLIOutput.printDiagnostics(dependencies.diagnostics)
        return ExitStatus.success.rawValue
    }

    // MARK: - doctor

    private static func runDoctorCommand(_ arguments: [String]) throws -> Int32 {
        let spec = ArgumentParser.Spec(valueOptions: ["root", "data-root", "java", "version"])
        let input = try ArgumentParser.parse(arguments, spec: spec)
        if input.has("help") {
            print("usage: lingxi doctor [--root <path>] [--java <path>] [--version <id>] [--data-root <path>] [--json]")
            return ExitStatus.success.rawValue
        }
        let layout = try resolveLayout(input)
        let platform = try platform()

        var candidates: [URL] = []
        if let javaPath = input.value("java") {
            candidates.append(URL(fileURLWithPath: (javaPath as NSString).expandingTildeInPath))
        }
        for candidate in JavaRuntimeInspector.candidateExecutablePaths() where !candidates.contains(candidate) {
            candidates.append(candidate)
        }

        var usable: [(URL, JavaRuntime)] = []
        var reported: [JSONJavaRuntime] = []
        var lines: [(String, String, String, String)] = []
        for candidate in candidates {
            do {
                let runtime = try services.javaInspector.inspect(executable: candidate)
                usable.append((candidate, runtime))
                reported.append(CLIOutput.jsonRuntime(runtime))
                lines.append((candidate.path, runtime.versionString, runtime.architecture.rawValue, runtime.vendor ?? "-"))
            } catch {
                reported.append(CLIOutput.jsonJavaFailure(path: candidate, error: error))
                lines.append((candidate.path, "unusable", "-", (error as? LauncherError)?.message ?? error.localizedDescription))
            }
        }

        let selected = usable.first?.1
        let evaluationPlatform = selected.flatMap { try? PlatformContext.forJVM($0) } ?? platform

        var diagnostics: [LaunchDiagnostic] = []
        var missing: [MissingDependency] = []
        var resolvedVersion: ResolvedVersion?
        if let runtime = selected, runtime.isRosettaTranslated {
            diagnostics.append(.warning(
                .javaArchitectureMismatch,
                "Selected Java is x86_64 running through Rosetta on Apple Silicon; x86_64 natives will be used",
                suggestion: "Prefer a native arm64 JDK unless Rosetta is intentional."
            ))
        }
        if let versionID = input.value("version") {
            do {
                let version = try VersionResolver().resolve(versionID: versionID, from: layout.gameRoot)
                resolvedVersion = version
                let dependencies = try services.dependencyResolver.resolve(version: version, layout: layout, platform: evaluationPlatform)
                missing = dependencies.missing
                diagnostics.append(contentsOf: dependencies.diagnostics)
                if let requirement = version.javaRequirement.majorVersion {
                    if let runtime = usable.first?.1, runtime.majorVersion < requirement {
                        diagnostics.append(.error(
                            .javaVersionMismatch,
                            "Minecraft \(version.id) needs Java \(requirement)+ but the selected runtime is \(runtime.displayDescription)",
                            suggestion: "Pass --java with a \(requirement)+ runtime."
                        ))
                    }
                }
            } catch let error as LauncherError {
                diagnostics.append(.error(error.code, error.message, suggestion: error.suggestion))
            }
        }

        // Missing files are blocking for a real launch, so `doctor --version` must fail on them
        // even though they are reported through the dedicated list rather than a diagnostic.
        let hasErrors = diagnostics.contains { $0.severity == .error }
            || selected == nil
            || (input.value("version") != nil && !missing.isEmpty)

        if input.has("json") {
            CLIOutput.emitJSON(JSONDoctor(
                platform: JSONPlatform(
                    os: evaluationPlatform.os.rawValue,
                    architecture: evaluationPlatform.architecture.rawValue,
                    hostArchitecture: evaluationPlatform.hostArchitecture.rawValue,
                    version: evaluationPlatform.osVersion
                ),
                gameRoot: layout.gameRoot.path,
                dataRoot: layout.dataRoot.path,
                javaCandidates: reported,
                selectedJava: selected.map(CLIOutput.jsonRuntime),
                versionID: resolvedVersion?.id ?? input.value("version"),
                missing: missing.map(JSONMissingDependency.init),
                diagnostics: diagnostics.map(JSONDiagnostic.init),
                ok: !hasErrors
            ))
            return hasErrors ? (selected == nil ? ExitStatus.javaUnusable.rawValue : ExitStatus.preflightBlocked.rawValue) : ExitStatus.success.rawValue
        }

        CLIOutput.header("LingXi doctor")
        CLIOutput.field("platform", "\(evaluationPlatform.os.rawValue) \(evaluationPlatform.osVersion) jvm=\(evaluationPlatform.architecture.rawValue) host=\(evaluationPlatform.hostArchitecture.rawValue)")
        CLIOutput.field("game root", layout.gameRoot.path)
        CLIOutput.field("data root", layout.dataRoot.path)
        print("Java runtimes:")
        if lines.isEmpty {
            print("  - none found")
        }
        for (path, version, arch, vendor) in lines {
            print("  - \(path)")
            print("      \(version)  \(arch)  \(vendor)")
        }
        if let selected {
            print("Selected: \(selected.executable.path) — \(selected.displayDescription)")
        } else {
            print("Selected: none usable")
        }

        if let version = resolvedVersion {
            print("Version \(version.id): \(version.libraries.count) libraries, \(missing.count) missing files")
            CLIOutput.printMissing(missing)
        }
        CLIOutput.printDiagnostics(diagnostics)

        if selected == nil {
            CLIOutput.fail("No usable Java runtime found. Pass --java /path/to/java.")
            return ExitStatus.javaUnusable.rawValue
        }
        if hasErrors {
            CLIOutput.fail("Doctor found blocking problems.")
            return ExitStatus.preflightBlocked.rawValue
        }
        print("No blocking problems found.")
        return ExitStatus.success.rawValue
    }

    // MARK: - launch

    private static func runLaunchCommand(_ arguments: [String]) async throws -> Int32 {
        let spec = ArgumentParser.Spec(
            valueOptions: ["root", "data-root", "version", "instance", "identity", "java"],
            flagOptions: ["dry-run", "json", "help"]
        )
        let input = try ArgumentParser.parse(arguments, spec: spec)
        if input.has("help") {
            print("usage: lingxi launch --identity local:<name>|microsoft:<uuid|playerName> [--instance <id> | --root <path> --version <id>] [--dry-run] [--java <path>] [--json]")
            return ExitStatus.success.rawValue
        }
        let dryRun = input.has("dry-run")
        if input.has("json") && !dryRun {
            throw LauncherError(.usageError, "--json is only supported together with --dry-run for launch", suggestion: "Use `lingxi launch ... --dry-run --json`.")
        }
        let layout = try resolveLayout(input)
        let registry = InstanceRepository(layout: layout)

        var instance: Instance?
        if let instanceID = input.value("instance") {
            instance = try registry.load(id: instanceID)
        }
        guard let versionID = input.value("version") ?? instance?.manifest.versionID else {
            throw LauncherError(.usageError, "No Minecraft version selected", suggestion: "Pass --version <version-id> or use an instance that stores one.")
        }
        if !dryRun && instance == nil {
            throw LauncherError(
                .usageError,
                "Launching requires an instance",
                suggestion: "Create one with `lingxi instance create --name <name> --version \(versionID)` and pass --instance."
            )
        }

        let identity = try await resolveIdentity(input.requireValue("identity"), layout: layout)

        let instanceDirectory: URL
        let gameDirectory: URL
        if let instance {
            instanceDirectory = instance.directory
            gameDirectory = instance.gameDirectory
        } else {
            instanceDirectory = try layout.instanceDirectory("preview-\(versionID)")
            gameDirectory = try layout.instanceGameDirectory("preview-\(versionID)")
        }

        let javaURL: URL
        if let javaPath = input.value("java") {
            javaURL = URL(fileURLWithPath: (javaPath as NSString).expandingTildeInPath)
        } else {
            javaURL = try services.javaInspector.discoverDefaultExecutable()
        }
        let runtime = try services.javaInspector.inspect(executable: javaURL)
        if let instance {
            let record = JavaManager(layout: layout).runtimeRecord(for: runtime)
            _ = try? registry.setJavaRuntime(id: instance.id, record: record)
        }
        // Rules, natives selection and natives cache paths must follow the JVM, not the launcher.
        let jvmPlatform = try PlatformContext.forJVM(runtime)

        let version = try VersionResolver().resolve(versionID: versionID, from: layout.gameRoot)
        let dependencies = try services.dependencyResolver.resolve(version: version, layout: layout, platform: jvmPlatform)

        let memoryArguments = instance.map {
            InstanceMemory.jvmArguments(configured: $0.manifest.memoryMiB)
        } ?? []
        let context = LaunchContext(
            instanceDirectory: instanceDirectory,
            gameDirectory: gameDirectory,
            javaExecutable: javaURL,
            platform: jvmPlatform,
            identity: identity,
            additionalJVMArguments: memoryArguments,
            features: [:]
        )

        if dryRun {
            let preview = try services.planBuilder.preview(version: version, context: context, dependencies: dependencies, java: runtime)
            // Missing files are reported once, as a dedicated list; the per-file diagnostics
            // that validate() derives from the same list would only duplicate them here.
            let shownDiagnostics = preview.diagnostics.filter { $0.code != .missingDependency }
            if input.has("json") {
                CLIOutput.emitJSON(JSONPreview(
                    dryRun: true,
                    identityMode: preview.identityMode.rawValue,
                    identity: preview.identityDisplayName,
                    versionID: preview.versionID,
                    javaExecutable: preview.javaExecutable.path,
                    mainClass: preview.mainClass,
                    classpathEntryCount: preview.classpathEntryCount,
                    classpathEntries: preview.classpathEntries,
                    gameDirectory: preview.gameDirectory.path,
                    jvmArguments: preview.jvmArguments,
                    gameArguments: preview.gameArguments,
                    missingDependencies: preview.missingDependencies.map(JSONMissingDependency.init),
                    diagnostics: shownDiagnostics.map(JSONDiagnostic.init),
                    blocking: preview.hasBlockingDiagnostics
                ))
                return ExitStatus.success.rawValue
            }
            printPreview(preview, diagnostics: shownDiagnostics)
            print("Dry run only: no process was started and no file was written.")
            return ExitStatus.success.rawValue
        }

        let plan = try services.planBuilder.build(version: version, context: context, dependencies: dependencies)
        let diagnostics = services.planBuilder.validate(version: version, context: context, plan: plan, dependencies: dependencies, java: runtime)
        let blocking = diagnostics.filter { $0.severity == .error }
        if !blocking.isEmpty {
            CLIOutput.fail("Preflight blocked the launch (\(blocking.count) problem(s)):")
            for diagnostic in blocking.prefix(12) {
                CLIOutput.fail("  - \(diagnostic.description)")
            }
            if blocking.count > 12 {
                CLIOutput.fail("  … and \(blocking.count - 12) more")
            }
            return ExitStatus.preflightBlocked.rawValue
        }

        try ensureInstanceDirectories(gameDirectory)
        let logURL = try makeLaunchLogURL(layout)
        CLIOutput.header("Launching Minecraft \(version.id)")
        CLIOutput.field("identity", identity.displayName)
        CLIOutput.field("java", "\(runtime.executable.path) (\(runtime.displayDescription))")
        CLIOutput.field("mainClass", version.mainClass)
        CLIOutput.field("game directory", gameDirectory.path)
        CLIOutput.field("log", logURL.path)

        let controller = GameProcessController()
        let running = try await controller.start(plan)
        let runtimeRegistry = InstanceRuntimeRegistry(layout: layout)
        if let instance {
            try? runtimeRegistry.markRunning(
                instanceID: instance.id,
                pid: running.processIdentifier,
                executable: runtime.executable
            )
        }
        defer {
            if let instance { runtimeRegistry.clear(instanceID: instance.id) }
        }

        let logHandle = try makeLogHandle(logURL)
        defer { try? logHandle.close() }
        writeLogHeader(
            to: logHandle,
            instance: instance,
            plan: plan,
            version: version,
            context: context,
            runtime: runtime,
            diagnostics: diagnostics
        )

        var gameExit = GameExit(code: 0, reason: .exited)
        for await event in running.events {
            switch event {
            case let .stdout(text):
                FileHandle.standardOutput.write(Data(text.utf8))
                try? logHandle.write(contentsOf: Data(text.utf8))
            case let .stderr(text):
                FileHandle.standardError.write(Data(text.utf8))
                try? logHandle.write(contentsOf: Data(text.utf8))
            case let .exited(exit):
                gameExit = exit
                try? logHandle.write(contentsOf: Data("\n[launcher] game exited: code=\(exit.code) reason=\(exit.reason.rawValue) signal=\(exit.signal.map(String.init) ?? "none")\n".utf8))
            }
        }

        if let instance {
            try? registry.recordLaunch(id: instance.id, identityMode: identity.mode)
        }

        switch gameExit.reason {
        case .exited:
            print("\nGame exited with code \(gameExit.code)")
            return Int32(clamping: gameExit.code)
        case .signalled:
            let signal = gameExit.signal ?? 0
            print("\nGame terminated by signal \(signal)")
            return Int32(clamping: 128 + signal)
        case .cancelled:
            print("\nGame was asked to stop")
            return 130
        }
    }

    static func resolveIdentity(_ raw: String, layout: GameDataLayout) async throws -> LaunchIdentity {
        let parts = raw.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false).map(String.init)
        guard parts.count == 2, !parts[1].isEmpty else {
            throw LauncherError(
                .usageError,
                "Malformed --identity value '\(raw)'",
                suggestion: "Use --identity local:<player-name> or --identity microsoft:<uuid|player-name>."
            )
        }
        switch parts[0] {
        case "local":
            let profile = try LocalAccountStore(layout: layout).profile(forName: parts[1])
            return .localOffline(profile)
        case "microsoft":
            let service = try MicrosoftAuthenticationFactory.makeDefault(
                layout: layout,
                browser: ProcessBrowserOpener()
            )
            let accounts = try await service.accounts()
            let identifier = parts[1]
            let account: MicrosoftAccount?
            if let uuid = UUID(uuidString: identifier) {
                account = accounts.first { $0.id == uuid }
            } else {
                account = accounts.first { $0.playerName.caseInsensitiveCompare(identifier) == .orderedSame }
            }
            guard let account else {
                throw LauncherError(
                    .unauthorized,
                    "No signed-in Microsoft account matches '\(identifier)'",
                    suggestion: "Run `lingxi account microsoft login` or `lingxi account list`."
                )
            }
            CLIOutput.fail("Refreshing Microsoft session for \(account.playerName)...")
            let session = try await service.session(for: account.id)
            return .microsoft(session)
        case "licensed-offline":
            throw LauncherError(
                .notImplemented,
                "Licensed-offline identity is not implemented yet",
                suggestion: "Use a Microsoft account, or a local profile for local technical validation."
            )
        default:
            throw LauncherError(.usageError, "Unknown identity mode '\(parts[0])'")
        }
    }

    private static func printPreview(_ preview: LaunchPreview, diagnostics: [LaunchDiagnostic]) {
        CLIOutput.header("Launch preview — Minecraft \(preview.versionID)")
        CLIOutput.field("identity", "\(preview.identityMode.rawValue) — \(preview.identityDisplayName)")
        CLIOutput.field("java", preview.javaExecutable.path)
        CLIOutput.field("mainClass", preview.mainClass)
        CLIOutput.field("classpath entries", "\(preview.classpathEntryCount)")
        for entry in preview.classpathEntries.prefix(5) {
            print("      \(entry)")
        }
        if preview.classpathEntries.count > 5 {
            print("      … and \(preview.classpathEntries.count - 5) more")
        }
        CLIOutput.field("game directory", preview.gameDirectory.path)
        print("JVM arguments (\(preview.jvmArguments.count)):")
        let classpathArgumentIndex = preview.jvmArguments.firstIndex(of: "-cp").map { $0 + 1 }
        for (index, argument) in preview.jvmArguments.enumerated() {
            if index == classpathArgumentIndex {
                // The expanded classpath is one argv element; keep the human output readable.
                print("      <classpath: \(preview.classpathEntryCount) entries>")
            } else {
                print("      \(argument)")
            }
        }
        print("Game arguments (redacted, \(preview.gameArguments.count)):")
        for argument in preview.gameArguments {
            print("      \(argument)")
        }
        if preview.identityMode == .localOffline {
            print("Note: the local offline identity is unverified and must not be used to access online services.")
        }
        CLIOutput.printMissing(preview.missingDependencies)
        CLIOutput.printDiagnostics(diagnostics)
    }

    private static func ensureInstanceDirectories(_ gameDirectory: URL) throws {
        do {
            try FileManager.default.createDirectory(at: gameDirectory, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: gameDirectory.appendingPathComponent("logs"), withIntermediateDirectories: true)
        } catch {
            throw LauncherError(.ioFailure, "Cannot create game directory \(gameDirectory.path): \(error.localizedDescription)")
        }
    }

    private static func makeLaunchLogURL(_ layout: GameDataLayout) throws -> URL {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        let name = "launch-\(formatter.string(from: Date()))-\(UUID().uuidString.prefix(4)).log"
        do {
            try FileManager.default.createDirectory(at: layout.launcherLogsDirectory, withIntermediateDirectories: true)
        } catch {
            throw LauncherError(.ioFailure, "Cannot create launcher log directory: \(error.localizedDescription)")
        }
        return layout.launcherLogsDirectory.appendingPathComponent(name, isDirectory: false)
    }

    private static func makeLogHandle(_ url: URL) throws -> FileHandle {
        guard FileManager.default.createFile(atPath: url.path, contents: nil),
              let handle = try? FileHandle(forWritingTo: url) else {
            throw LauncherError(.ioFailure, "Cannot write launcher log \(url.path)")
        }
        return handle
    }

    private static func writeLogHeader(
        to handle: FileHandle,
        instance: Instance?,
        plan: LaunchPlan,
        version: ResolvedVersion,
        context: LaunchContext,
        runtime: JavaRuntime,
        diagnostics: [LaunchDiagnostic]
    ) {
        // Only the redacted plan is ever persisted; argv may contain a session token.
        var lines: [String] = []
        lines.append("# LingXi Launcher \(LauncherInfo.version)")
        lines.append("# instance: \(instance?.id ?? "none")")
        lines.append("# instanceName: \(instance?.manifest.displayName ?? "none")")
        lines.append("# gameDirectory: \(context.gameDirectory.path)")
        lines.append("# started: \(CLIOutput.formatDate(Date()))")
        lines.append("# version: \(version.id)")
        lines.append("# identity: \(context.identity.mode.rawValue)")
        lines.append("# java: \(runtime.executable.path) (\(runtime.displayDescription))")
        lines.append("# argv (redacted, \(plan.redactedArguments.count) entries):")
        for argument in plan.redactedArguments {
            lines.append("#   \(argument)")
        }
        if !diagnostics.isEmpty {
            lines.append("# diagnostics:")
            for diagnostic in diagnostics {
                lines.append("#   \(diagnostic.description)")
            }
        }
        lines.append("")
        let header = lines.joined(separator: "\n") + "\n"
        try? handle.write(contentsOf: Data(header.utf8))
    }

    // MARK: - account

    private static func runAccountCommand(_ arguments: [String]) async throws -> Int32 {
        guard let scope = arguments.first else {
            throw LauncherError(.usageError, "Missing account subcommand", suggestion: "Use `lingxi account list` or `lingxi account microsoft login`.")
        }
        let rest = Array(arguments.dropFirst())
        switch scope {
        case "local":
            let status = try runLocalAccountCommand(rest)
            markLocalAccountActiveIfCreated(rest)
            return status
        case "microsoft":
            return try await runMicrosoftAccountCommand(rest)
        case "list":
            return try await runAccountList(rest)
        case "login":
            throw LauncherError(
                .usageError,
                "Use `lingxi account microsoft login`",
                suggestion: "The local identity never substitutes for a Microsoft sign-in."
            )
        case "status":
            throw LauncherError(
                .usageError,
                "Use `lingxi account microsoft status`",
                suggestion: "Run `lingxi account list` to see all local and Microsoft accounts."
            )
        default:
            throw LauncherError(.usageError, "Unknown account subcommand '\(scope)'")
        }
    }

    /// Records the last-created local account as active (non-secret convenience only).
    private static func markLocalAccountActiveIfCreated(_ arguments: [String]) {
        guard arguments.first == "create" else { return }
        let spec = ArgumentParser.Spec(valueOptions: ["name", "root", "data-root"])
        guard let input = try? ArgumentParser.parse(Array(arguments.dropFirst()), spec: spec),
              let name = input.value("name"),
              let layout = try? resolveLayout(input, requireGameRoot: false) else { return }
        try? ActiveAccountStore(layout: layout).save(AccountReference(kind: .local, identifier: name))
    }

    private static func runLocalAccountCommand(_ arguments: [String]) throws -> Int32 {
        guard let action = arguments.first else {
            throw LauncherError(.usageError, "Missing local account action", suggestion: "Use `lingxi account local create --name <name>` or `lingxi account local list`.")
        }
        let rest = Array(arguments.dropFirst())
        let spec = ArgumentParser.Spec(valueOptions: ["name", "root", "data-root"])
        let input = try ArgumentParser.parse(rest, spec: spec)
        if input.has("help") {
            print("usage: lingxi account local create --name <player-name> | lingxi account local list")
            return ExitStatus.success.rawValue
        }
        let layout = try resolveLayout(input, requireGameRoot: false)
        let store = LocalAccountStore(layout: layout)
        switch action {
        case "create":
            let account = try store.create(playerName: input.requireValue("name"))
            if input.has("json") {
                CLIOutput.emitJSON(JSONAccount(
                    playerName: account.playerName,
                    offlineUUID: account.offlineUUID.uuidString.lowercased(),
                    identityMode: account.identityMode.rawValue,
                    unverified: account.unverified,
                    createdAt: CLIOutput.formatDate(account.createdAt)
                ))
                return ExitStatus.success.rawValue
            }
            print("Local offline account ready: \(account.playerName)")
            CLIOutput.field("offline UUID", account.offlineUUID.uuidString.lowercased())
            CLIOutput.field("identity mode", "\(account.identityMode.rawValue) (unverified; not a licence check)")
            return ExitStatus.success.rawValue
        case "list":
            let accounts = try store.list()
            if input.has("json") {
                CLIOutput.emitJSON(accounts.map {
                    JSONAccount(
                        playerName: $0.playerName,
                        offlineUUID: $0.offlineUUID.uuidString.lowercased(),
                        identityMode: $0.identityMode.rawValue,
                        unverified: $0.unverified,
                        createdAt: CLIOutput.formatDate($0.createdAt)
                    )
                })
                return ExitStatus.success.rawValue
            }
            if accounts.isEmpty {
                print("No local offline accounts yet. Create one with `lingxi account local create --name <name>`.")
                return ExitStatus.success.rawValue
            }
            CLIOutput.header("Local offline accounts (unverified)")
            for account in accounts {
                print("  - \(account.playerName)  \(account.offlineUUID.uuidString.lowercased())")
            }
            return ExitStatus.success.rawValue
        default:
            throw LauncherError(.usageError, "Unknown local account action '\(action)'")
        }
    }

    // MARK: - instance

    private static func runInstanceCommand(_ arguments: [String]) throws -> Int32 {
        guard let action = arguments.first else {
            throw LauncherError(.usageError, "Missing instance action", suggestion: "Use `lingxi instance create --name <name>` or `lingxi instance list`.")
        }
        let spec = ArgumentParser.Spec(valueOptions: ["name", "version", "root", "data-root"])
        let input = try ArgumentParser.parse(Array(arguments.dropFirst()), spec: spec)
        if input.has("help") {
            print("usage: lingxi instance create --name <display-name> [--version <id>] | lingxi instance list")
            return ExitStatus.success.rawValue
        }
        let layout = try resolveLayout(input, requireGameRoot: false)
        let registry = InstanceRepository(layout: layout)
        switch action {
        case "create":
            let instance = try registry.create(displayName: input.requireValue("name"), versionID: input.value("version"))
            if input.has("json") {
                CLIOutput.emitJSON(jsonInstance(instance))
                return ExitStatus.success.rawValue
            }
            print("Instance created: \(instance.id)")
            CLIOutput.field("display name", instance.manifest.displayName)
            CLIOutput.field("game directory", instance.gameDirectory.path)
            return ExitStatus.success.rawValue
        case "list":
            let instances = try registry.list()
            if input.has("json") {
                CLIOutput.emitJSON(instances.map(jsonInstance))
                return ExitStatus.success.rawValue
            }
            if instances.isEmpty {
                print("No instances yet. Create one with `lingxi instance create --name <name> --version <id>`.")
                return ExitStatus.success.rawValue
            }
            CLIOutput.header("Instances")
            for instance in instances {
                let version = instance.manifest.versionID ?? "no version"
                let last = instance.manifest.lastIdentityMode?.rawValue ?? "never launched"
                print("  - \(instance.id)  \(instance.manifest.displayName)  [\(version)]  \(last)")
            }
            return ExitStatus.success.rawValue
        default:
            throw LauncherError(.usageError, "Unknown instance action '\(action)'")
        }
    }

    private static func jsonInstance(_ instance: Instance) -> JSONInstance {
        JSONInstance(
            id: instance.id,
            displayName: instance.manifest.displayName,
            versionID: instance.manifest.versionID,
            directory: instance.directory.path,
            gameDirectory: instance.gameDirectory.path,
            createdAt: CLIOutput.formatDate(instance.manifest.createdAt),
            lastLaunchedAt: instance.manifest.lastLaunchedAt.map(CLIOutput.formatDate),
            lastIdentityMode: instance.manifest.lastIdentityMode?.rawValue
        )
    }

    // MARK: - help

    static func printHelp() {
        print("""
        \(LauncherInfo.name) \(LauncherInfo.version) — macOS Apple Silicon Minecraft: Java Edition launcher

        USAGE
          lingxi <command> [options]

        COMMANDS
          version inspect --id <version-id> [--root <path>] [--json]
              Read a per-version JSON and print mainClass, Java requirement,
              rule-allowed libraries, classpath and argument counts.

          doctor [--root <path>] [--java <path>] [--version <id>] [--json]
              Inspect local Java runtimes (version + architecture) and report
              missing files and architecture problems.

          launch --identity local:<player-name> [--instance <id>] [--dry-run] [--json]
                 [--root <path>] [--version <id>] [--java <path>]
              Build a launch plan. --dry-run prints a redacted, deterministic
              preview and never starts the game. A real launch requires --instance.

          account local create --name <player-name> [--json]
          account local list [--json]
              Local offline identities (unverified, no token, local single-player
              technical validation only).
          account microsoft login | account microsoft status
              Microsoft OAuth/Xbox/Minecraft authentication and Keychain refresh.

          instance create --name "<display name>" [--version <id>] [--json]
          instance list [--json]
          instance copy <source-id> --name "<display name>" [--saves] [--json]
              Copy instance-owned files; global libraries/assets stay shared.
          world list|backup|restore|delete --instance <id> [--world <name>] [--backup <id>]
              Manage isolated saves and checksummed backups under dataRoot/backups.
          diagnose --instance <id> [--exit-code <n>] [--json]
              Analyze instance-bound logs with deterministic rules and redaction.
          performance status|benchmark|tune|apply|reports --instance <id> [...]
              Run real launcher-side benchmarks and apply conservative tuning.

          version list [--type release|snapshot|all] [--source official|auto|mirror]
              Fetch the official version manifest (cached) and list versions.

          install vanilla --version <id> --instance <instance-id> [--source auto]
                  [--mirror-config <path>] [--concurrency 4] [--java <path>]
              Download the vanilla profile and shared files, then create/update
              the instance. Never needs a login.

          install fabric --version <minecraft-id> --instance <instance-id> [--update]
                  [--loader <fabric-version>] [--java <path>] [--source auto]
              Install Fabric Loader on top of vanilla, querying Fabric's official
              compatibility metadata and Maven artifacts. New instance by default;
              --update explicitly backs up instance.json before changing the target.

          install neoforge --version <minecraft-id> --instance <instance-id> [--update]
                  [--loader <neoforge-version>] [--java <path>] [--source auto]
              Install NeoForge through its official installer in an isolated staging
              root. Requires Java 21+; only official NeoForge Maven artifacts are used.

          java list [--data-root <path>]
          java install --major <version> --yes [--data-root <path>]
              Detect Java runtimes; optionally download a verified Eclipse Temurin
              JDK into <dataRoot>/java without touching system Java.

          mod search --instance <id> [--query <text>] [--category a,b]
                     [--sort relevance|downloads|follows|newest|updated] [--json]
          mod install --instance <id> --project <id|slug> [--version <id>] [--replace]
          mod list --instance <id> [--json]
          mod enable|disable|remove --instance <id> --file <mod.jar>
          mod updates --instance <id> [--json]
              Modrinth Fabric/NeoForge mod browsing/install with required-dependency resolution,
              SHA-1/SHA-512 verification and atomic local mod updates.

          mrpack inspect --file <pack.mrpack> [--json]
          mrpack install --file <pack.mrpack> [--name <name>] [--java <path>]
                  [--root <path>] [--data-root <path>] [--source auto|official] [--json]
              Validate a Modrinth .mrpack, download/verify its files through the
              persistent cache, install Minecraft plus Fabric/NeoForge and commit the pack into a
              fresh isolated instance. Forge/Quilt are rejected explicitly.

          graphics status --instance <id> [--json]
          graphics setup --instance <id> [--replace] [--json]
              Resolve and install a compatible Iris + Sodium pair from Modrinth.
              Existing mismatched mods require --replace; no loader is installed.

          shader search --instance <id> [--query <text>] [--category a,b]
                  [--sort relevance|downloads|follows|newest|updated] [--json]
          shader install --instance <id> --project <id|slug> [--version <id>]
                  [--replace <old-file>] [--json]
          shader import --instance <id> --file <pack.zip> [--json]
          shader list --instance <id> [--json]
          shader updates --instance <id> [--json]
          shader enable --instance <id> --file <pack.zip> [--json]
          shader disable --instance <id> [--json]
          shader remove --instance <id> --file <pack.zip>
              Browse/install verified shader packs into instance-local shaderpacks/,
              and only rewrite the verified Iris shaderPack/enableShaders keys when
              enabling/disabling. Shader installation never implies activation.

          verify --instance <instance-id> [--json]
              Re-check every installed file against the metadata SHA-1/size.

        GLOBAL OPTIONS
          --root <path>        Minecraft data root (default: official launcher directory)
          --data-root <path>   LingXi data root (default: ~/Library/Application Support/LingXiLauncher)
          --json               machine-readable output (tokens are always redacted)
          -h, --help           show help
          -V, --version        print launcher version

        EXIT CODES
          0 success · 3 no usable Java · 4 preflight blocked · 64 usage ·
          65 invalid metadata/checksum · 66 missing input · 69 not implemented/unavailable ·
          70 internal · 74 I/O. A completed game's own exit code is passed through.

        SAFETY
          Local offline mode is not a purchase check. It never contacts Microsoft and
          never presents itself as a licensed session.
        """)
    }
}
