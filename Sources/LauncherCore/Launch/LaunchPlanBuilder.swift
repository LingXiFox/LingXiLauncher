import Foundation

/// Turns resolved version metadata, a launch context and resolved dependencies into argv.
///
/// Pure transformation: no network access, no directory creation, no file writes. The only
/// filesystem read happens in `validate()`, which checks whether the game directory exists yet.
///
/// The platform used for rule evaluation is the host process's platform (`uname`-derived) with
/// `LaunchContext.features` applied: `LaunchContext` carries the feature flags because those are
/// launcher-controlled, while OS/architecture/version describe the machine the JVM will run on.
public struct LaunchPlanBuilder: LaunchPlanning {
    private static let classpathFlag = "-cp"
    private static let redactedKeys: Set<String> = ["auth_access_token"]

    private let argumentResolver: any ArgumentResolving

    public init(argumentResolver: any ArgumentResolving) {
        self.argumentResolver = argumentResolver
    }

    // MARK: - Build

    public func build(
        version: ResolvedVersion,
        context: LaunchContext,
        dependencies: DependencyResolution
    ) throws -> LaunchPlan {
        let platform = try PlatformContext.current(features: context.features)
        let variables = try variables(version: version, context: context, dependencies: dependencies)

        let real = try assembledArguments(
            version: version,
            context: context,
            dependencies: dependencies,
            platform: platform,
            variables: variables,
            sensitiveKeys: []
        )
        // Built independently from the same inputs: never post-process the live argv, so the two
        // lists cannot drift even if a future variable value itself looks like the placeholder.
        let redacted = try assembledArguments(
            version: version,
            context: context,
            dependencies: dependencies,
            platform: platform,
            variables: variables,
            sensitiveKeys: Self.redactedKeys
        )
        return LaunchPlan(
            javaExecutable: context.javaExecutable,
            arguments: real,
            redactedArguments: redacted,
            workingDirectory: context.gameDirectory,
            environmentOverrides: [:],
            versionID: version.id,
            identityMode: context.identity.mode
        )
    }

    // MARK: - Preview

    public func preview(
        version: ResolvedVersion,
        context: LaunchContext,
        dependencies: DependencyResolution,
        java: JavaRuntime?
    ) throws -> LaunchPreview {
        let platform = try PlatformContext.current(features: context.features)
        let variables = try variables(version: version, context: context, dependencies: dependencies)

        // Credentials never enter the preview: every expansion uses the redaction key set, so the
        // Microsoft access token is replaced by the placeholder before it reaches any returned value.
        let jvm = try jvmArguments(
            version: version,
            context: context,
            dependencies: dependencies,
            platform: platform,
            variables: variables,
            sensitiveKeys: Self.redactedKeys
        )
        let gameArguments = try argumentResolver.expand(
            version.gameArguments,
            platform: platform,
            variables: variables,
            sensitiveKeys: Self.redactedKeys
        )
        // `validate()` only needs the structural shape (JVM prefix / main class / game tail). The
        // probe plan is built from the already-redacted argv, so it can never expose a token.
        let probe = LaunchPlan(
            javaExecutable: context.javaExecutable,
            arguments: jvm + [version.mainClass] + gameArguments,
            redactedArguments: jvm + [version.mainClass] + gameArguments,
            workingDirectory: context.gameDirectory,
            versionID: version.id,
            identityMode: context.identity.mode
        )
        var diagnostics = dependencies.diagnostics
        diagnostics.append(contentsOf: validate(
            version: version,
            context: context,
            plan: probe,
            dependencies: dependencies,
            java: java
        ))

        return LaunchPreview(
            identityMode: context.identity.mode,
            identityDisplayName: context.identity.displayName,
            versionID: version.id,
            javaExecutable: context.javaExecutable,
            mainClass: version.mainClass,
            classpathEntryCount: dependencies.classpath.count,
            classpathEntries: dependencies.classpath.map(\.path),
            gameDirectory: context.gameDirectory,
            jvmArguments: jvm,
            gameArguments: gameArguments,
            missingDependencies: dependencies.missing,
            diagnostics: diagnostics
        )
    }

    // MARK: - Validation

    public func validate(
        version: ResolvedVersion,
        context: LaunchContext,
        plan: LaunchPlan,
        dependencies: DependencyResolution,
        java: JavaRuntime?
    ) -> [LaunchDiagnostic] {
        var diagnostics: [LaunchDiagnostic] = []

        for missing in dependencies.missing {
            diagnostics.append(.error(
                .missingDependency,
                "Missing \(missing.kind.rawValue) (\(missing.reason.rawValue)): \(missing.path.path)",
                suggestion: "Place the file at the expected path or fetch it before launching."
            ))
        }

        if let java {
            if let required = version.javaRequirement.majorVersion {
                if java.majorVersion < required {
                    diagnostics.append(.error(
                        .javaVersionMismatch,
                        "Java \(java.versionString) is too old: Minecraft \(version.id) requires Java \(required)+",
                        suggestion: "Point the launcher at a Java \(required) or newer runtime."
                    ))
                } else if java.majorVersion > required {
                    diagnostics.append(.warning(
                        .javaVersionMismatch,
                        "Java \(java.versionString) is newer than the Java \(required) pinned by Minecraft \(version.id)",
                        suggestion: "The game usually works, but Mojang ships and tests this version against Java \(required)."
                    ))
                }
            }
            if java.architecture == .arm64,
               let legacyNative = dependencies.legacyNatives.first(where: { $0.architectureHint == .x86_64 }) {
                diagnostics.append(.error(
                    .javaArchitectureMismatch,
                    "Legacy native '\(legacyNative.classifier)' targets x86_64 but the selected Java is arm64",
                    suggestion: "Use a version whose natives support Apple Silicon, or run an x86_64 Java under Rosetta."
                ))
            }
        } else {
            let requirement = version.javaRequirement.majorVersion.map { "Java \($0)+" } ?? "a Java runtime"
            diagnostics.append(.error(
                .javaNotFound,
                "No Java runtime selected for Minecraft \(version.id)",
                suggestion: "Install \(requirement) and point the launcher at its java executable."
            ))
        }

        if version.clientLogging != nil, dependencies.missing.contains(where: { $0.kind == .loggingConfig }) {
            diagnostics.append(.warning(
                .missingDependency,
                "Minecraft \(version.id) declares a log4j configuration but no local copy was found",
                suggestion: "The game falls back to default logging; provide assets/log_configs to get Mojang's configuration."
            ))
        }

        var isDirectory: ObjCBool = false
        let gameDirectoryExists = FileManager.default.fileExists(
            atPath: context.gameDirectory.path,
            isDirectory: &isDirectory
        )
        if !gameDirectoryExists || !isDirectory.boolValue {
            // Warning, not error: the launcher creates the working directory immediately before
            // spawning, and a dry run legitimately previews an instance skeleton that does not
            // exist yet. Only real preflight blockers may be errors.
            diagnostics.append(.warning(
                .ioFailure,
                "Game directory does not exist yet: \(context.gameDirectory.path)",
                suggestion: "LingXi Launcher creates it before spawning; ignore this warning for dry runs."
            ))
        }

        let jvmPrefix = jvmPrefix(of: plan.arguments, mainClass: version.mainClass)
        let classpathFlagCount = jvmPrefix.filter { $0 == Self.classpathFlag }.count
        if classpathFlagCount != 1 {
            diagnostics.append(.error(
                .invalidMetadata,
                "Expanded JVM arguments contain \(classpathFlagCount) '\(Self.classpathFlag)' flags; exactly one is required",
                suggestion: "The version metadata is malformed; reinstall it."
            ))
        }

        if version.mainClass.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            diagnostics.append(.error(
                .invalidMetadata,
                "Version \(version.id) declares an empty mainClass",
                suggestion: "The metadata cannot be launched; reinstall it."
            ))
        }

        return diagnostics
    }

    // MARK: - Variables

    private func variables(
        version: ResolvedVersion,
        context: LaunchContext,
        dependencies: DependencyResolution
    ) throws -> [String: String] {
        var variables: [String: String] = [
            "classpath": dependencies.classpath.map(\.path).joined(separator: ":"),
            "classpath_separator": ":",
            "natives_directory": dependencies.nativesDirectory.path,
            "library_directory": dependencies.layout.librariesDirectory.path,
            "assets_root": dependencies.layout.assetsDirectory.path,
            "assets_index_name": version.assetIndexID,
            "game_directory": context.gameDirectory.path,
            "launcher_name": context.launcherName,
            "launcher_version": context.launcherVersion,
            "version_name": version.id,
            "version_type": version.type,
        ]
        if let loggingFile = dependencies.loggingFile {
            // `${path}` is only meaningful when the log4j configuration actually exists locally.
            variables["path"] = loggingFile.path.path
        }
        variables.merge(try identityVariables(for: context.identity), uniquingKeysWith: { _, identityValue in identityValue })
        return variables
    }

    private func identityVariables(for identity: LaunchIdentity) throws -> [String: String] {
        switch identity {
        case let .localOffline(profile):
            // Deliberately explicit, non-secret placeholders: a local offline profile is not an
            // authentication session and must never look like one.
            return [
                "auth_player_name": profile.playerName,
                "auth_uuid": Self.uuidArgument(profile.stableOfflineUUID),
                "auth_access_token": "0",
                "auth_xuid": "0",
                "clientid": "0",
                "user_type": "legacy",
                "user_properties": "{}",
            ]
        case let .microsoft(session):
            return [
                "auth_player_name": session.profile.name,
                "auth_uuid": Self.uuidArgument(session.profile.id),
                "auth_access_token": session.accessToken,
                "auth_xuid": session.xuid,
                "clientid": "0",
                "user_type": session.userType,
                "user_properties": "{}",
            ]
        case .licensedOffline:
            throw LauncherError(
                .unauthorized,
                "Licensed-offline launching is not implemented (M3)",
                suggestion: "Use a local offline profile for local technical validation, or sign in with Microsoft once accounts are implemented."
            )
        }
    }

    private static func uuidArgument(_ uuid: UUID) -> String {
        uuid.uuidString.replacingOccurrences(of: "-", with: "").lowercased()
    }

    // MARK: - Assembly

    private func assembledArguments(
        version: ResolvedVersion,
        context: LaunchContext,
        dependencies: DependencyResolution,
        platform: PlatformContext,
        variables: [String: String],
        sensitiveKeys: Set<String>
    ) throws -> [String] {
        let jvm = try jvmArguments(
            version: version,
            context: context,
            dependencies: dependencies,
            platform: platform,
            variables: variables,
            sensitiveKeys: sensitiveKeys
        )
        let game = try argumentResolver.expand(
            version.gameArguments,
            platform: platform,
            variables: variables,
            sensitiveKeys: sensitiveKeys
        )
        return jvm + [version.mainClass] + game
    }

    private func jvmArguments(
        version: ResolvedVersion,
        context: LaunchContext,
        dependencies: DependencyResolution,
        platform: PlatformContext,
        variables: [String: String],
        sensitiveKeys: Set<String>
    ) throws -> [String] {
        var jvm = try argumentResolver.expand(
            version.jvmArguments,
            platform: platform,
            variables: variables,
            sensitiveKeys: sensitiveKeys
        )
        insert(context.additionalJVMArguments, beforeClasspathFlagIn: &jvm)
        // log4j configuration is an ordinary JVM property; keep it inside the JVM prefix,
        // immediately before the classpath flag the same way the official launcher does.
        if let logging = version.clientLogging, dependencies.loggingFile != nil {
            let loggingArgument = try argumentResolver.expand(
                [.argument(logging.argument)],
                platform: platform,
                variables: variables,
                sensitiveKeys: sensitiveKeys
            )
            insert(loggingArgument, beforeClasspathFlagIn: &jvm)
        }
        return jvm
    }

    /// Inserts values immediately before the single `-cp` flag, or appends them when the metadata
    /// declares no classpath flag at all. `validate()` reports the latter as malformed metadata,
    /// but `build()` still has to produce a deterministic, inspectable argv.
    private func insert(_ values: [String], beforeClasspathFlagIn jvm: inout [String]) {
        guard !values.isEmpty else { return }
        if let index = jvm.firstIndex(of: Self.classpathFlag) {
            jvm.insert(contentsOf: values, at: index)
        } else {
            jvm.append(contentsOf: values)
        }
    }

    /// The JVM prefix is everything before the main class; game arguments never contain `-cp`,
    /// so this is the structural way to inspect the expanded JVM arguments from a `LaunchPlan`.
    private func jvmPrefix(of arguments: [String], mainClass: String) -> [String] {
        guard let index = arguments.firstIndex(of: mainClass) else { return arguments }
        return Array(arguments[..<index])
    }
}
