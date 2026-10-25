import Foundation

// MARK: - Version resolution

/// Reads per-version metadata from disk and produces a structural `ResolvedVersion`.
/// Never launches a process and never touches the network.
public protocol VersionResolving: Sendable {
    func resolve(versionID: String, from root: URL) throws -> ResolvedVersion
}

// MARK: - Rules

/// Evaluates Mojang `rules` arrays against a platform.
///
/// Semantics: no rules ⇒ allowed. Otherwise the result starts as disallowed and every
/// matching rule overwrites it, so the last matching rule wins.
public protocol RuleEvaluating: Sendable {
    func isAllowed(_ rules: [Rule]?, platform: PlatformContext) throws -> Bool
}

// MARK: - Arguments

/// Expands `arguments.jvm` / `arguments.game` entries into argv elements.
///
/// Each element of a `value` array becomes its own argv element (never joined), and
/// `${placeholder}` occurrences are substituted. Unknown placeholders are an error rather
/// than silently empty strings.
public protocol ArgumentResolving: Sendable {
    func expand(
        _ entries: [ArgumentEntry],
        platform: PlatformContext,
        variables: [String: String],
        sensitiveKeys: Set<String>
    ) throws -> [String]
}

// MARK: - Dependencies

/// Maps the rule-allowed libraries / natives / asset metadata onto local URLs and reports
/// what is missing. Never downloads.
public protocol DependencyResolving: Sendable {
    func resolve(
        version: ResolvedVersion,
        layout: GameDataLayout,
        platform: PlatformContext
    ) throws -> DependencyResolution
}

// MARK: - Java runtime

/// Facts about a concrete `java` executable, discovered by actually running it.
public struct JavaRuntime: Sendable, Equatable {
    public let executable: URL
    public let versionString: String
    public let majorVersion: Int
    public let architecture: PlatformContext.CPUArch
    /// Physical CPU architecture of the host, used to detect Rosetta translation.
    public let hostArchitecture: PlatformContext.CPUArch
    /// True when this is an x86_64 JVM running through Rosetta on Apple Silicon.
    public let isRosettaTranslated: Bool
    public let vendor: String?
    public let osName: String?
    public let rawProperties: [String: String]

    public init(
        executable: URL,
        versionString: String,
        majorVersion: Int,
        architecture: PlatformContext.CPUArch,
        vendor: String? = nil,
        osName: String? = nil,
        rawProperties: [String: String] = [:],
        hostArchitecture: PlatformContext.CPUArch? = nil,
        isRosettaTranslated: Bool? = nil
    ) {
        self.executable = executable
        self.versionString = versionString
        self.majorVersion = majorVersion
        self.architecture = architecture
        self.hostArchitecture = hostArchitecture ?? architecture
        self.isRosettaTranslated = isRosettaTranslated ?? (self.hostArchitecture == .arm64 && architecture == .x86_64)
        self.vendor = vendor
        self.osName = osName
        self.rawProperties = rawProperties
    }

    public var displayDescription: String {
        let vendorPart = vendor.map { " (\($0))" } ?? ""
        let rosettaPart = isRosettaTranslated ? " via Rosetta" : ""
        return "Java \(versionString)\(vendorPart) \(architecture.rawValue)\(rosettaPart)"
    }
}

public protocol JavaRuntimeInspecting: Sendable {
    /// Runs the executable and reports version, architecture and vendor.
    /// Throws `javaNotFound` / `javaVersionMismatch` style errors when the binary is unusable.
    func inspect(executable: URL) throws -> JavaRuntime
}

// MARK: - Launch planning

/// Pure transformation: resolved metadata + context ⇒ immutable plan / redacted preview.
/// Must not perform network access.
public protocol LaunchPlanning: Sendable {
    /// Redacted, deterministic preview. Contains no credentials.
    func preview(
        version: ResolvedVersion,
        context: LaunchContext,
        dependencies: DependencyResolution,
        java: JavaRuntime?
    ) throws -> LaunchPreview

    /// Executable plan. The `arguments` may contain a session token in Microsoft mode.
    func build(
        version: ResolvedVersion,
        context: LaunchContext,
        dependencies: DependencyResolution
    ) throws -> LaunchPlan

    /// Preflight diagnostics that must be resolved before `Process.run()`.
    func validate(
        version: ResolvedVersion,
        context: LaunchContext,
        plan: LaunchPlan,
        dependencies: DependencyResolution,
        java: JavaRuntime?
    ) -> [LaunchDiagnostic]
}

// MARK: - Game process

/// How a game process ended.
public struct GameExit: Sendable, Equatable {
    public enum Reason: String, Sendable, Equatable {
        /// The JVM exited on its own (code 0 = clean).
        case exited
        /// The JVM was terminated by a signal.
        case signalled
        /// The launcher asked it to stop.
        case cancelled
    }

    public let code: Int32
    public let reason: Reason
    public let signal: Int32?

    public init(code: Int32, reason: Reason, signal: Int32? = nil) {
        self.code = code
        self.reason = reason
        self.signal = signal
    }

    public var isSuccess: Bool { reason == .exited && code == 0 }
}

/// Events streamed from a running game process. The stream always finishes with `.exited`.
public enum GameProcessEvent: Sendable, Equatable {
    case stdout(String)
    case stderr(String)
    case exited(GameExit)
}

/// Control surface for a running game. Separated from the event stream so the stream can be
/// consumed without holding a reference that keeps the process alive.
public protocol RunningGameControlling: Sendable {
    /// Politely terminate the process (SIGTERM). Safe to call multiple times.
    func terminate() async
}

public struct RunningGame: Sendable {
    public let processIdentifier: Int32
    public let events: AsyncStream<GameProcessEvent>
    public let control: any RunningGameControlling

    public init(processIdentifier: Int32, events: AsyncStream<GameProcessEvent>, control: any RunningGameControlling) {
        self.processIdentifier = processIdentifier
        self.events = events
        self.control = control
    }
}

public protocol GameProcessControlling: Sendable {
    /// Starts the plan. Throws `launchFailed` when the process cannot be spawned at all
    /// (a crash of the game itself is reported as an `.exited` event instead).
    func start(_ plan: LaunchPlan) async throws -> RunningGame
}
