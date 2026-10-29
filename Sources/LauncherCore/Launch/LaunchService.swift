import Foundation

public struct LaunchServiceRequest: Sendable {
    public let instance: Instance
    public let identity: LaunchIdentity
    public let javaExecutable: URL
    public let additionalJVMArguments: [String]
    public let features: [String: Bool]
    /// Optional single-player world used by the automated benchmark. It is not a general
    /// command-line injection point: the launch builder maps it to the official quick-play
    /// argument declared by the Minecraft version metadata.
    public let quickPlayWorld: String?

    public init(
        instance: Instance,
        identity: LaunchIdentity,
        javaExecutable: URL,
        additionalJVMArguments: [String] = [],
        features: [String: Bool] = [:],
        quickPlayWorld: String? = nil
    ) {
        self.instance = instance
        self.identity = identity
        self.javaExecutable = javaExecutable
        self.additionalJVMArguments = additionalJVMArguments
        self.features = features
        self.quickPlayWorld = quickPlayWorld
    }
}

public enum LaunchServiceEvent: Sendable {
    case phase(String)
    case prepared(LaunchPreview)
    case logFile(URL)
    case started(processIdentifier: Int32)
    case stdout(String)
    case stderr(String)
    case exited(GameExit)
    case failed(LauncherError)
}

/// Shared launch orchestration for GUI (and future frontends): resolve → validate → spawn.
/// The CLI keeps its thin shell but performs the same Core calls; the GUI never shells out.
public actor LaunchService {
    private let layout: GameDataLayout
    private let javaInspector: JavaRuntimeInspector
    private let dependencyResolver: DependencyResolver
    private let planBuilder: LaunchPlanBuilder
    private let processController: GameProcessController
    private let runtimeRegistry: InstanceRuntimeRegistry

    private var runningGame: RunningGame?
    private var runningProcessIdentity: ProcessIdentity?
    private var launching = false

    public init(
        layout: GameDataLayout,
        javaInspector: JavaRuntimeInspector = JavaRuntimeInspector(),
        ruleEvaluator: RuleEvaluator = RuleEvaluator(),
        argumentResolver: ArgumentResolver? = nil
    ) {
        self.layout = layout
        self.javaInspector = javaInspector
        self.dependencyResolver = DependencyResolver(ruleEvaluator: ruleEvaluator)
        self.planBuilder = LaunchPlanBuilder(
            argumentResolver: argumentResolver ?? ArgumentResolver(ruleEvaluator: ruleEvaluator)
        )
        self.processController = GameProcessController()
        self.runtimeRegistry = InstanceRuntimeRegistry(layout: layout)
    }

    public func isRunning() -> Bool {
        runningGame != nil
    }

    /// Starts a launch and returns the event stream. The stream always terminates.
    public func launch(_ request: LaunchServiceRequest) -> AsyncStream<LaunchServiceEvent> {
        let pair = AsyncStream<LaunchServiceEvent>.makeStream(bufferingPolicy: .unbounded)
        if launching || runningGame != nil {
            pair.continuation.yield(.failed(LauncherError(.launchFailed, "A game process is already running")))
            pair.continuation.finish()
            return pair.stream
        }
        launching = true
        Task {
            await self.run(request, continuation: pair.continuation)
        }
        return pair.stream
    }

    public func stop() async {
        await runningGame?.control.terminate()
    }

    /// The identity of the currently launched process, including its kernel start time. A bare
    /// PID is never sufficient: macOS may reuse it as soon as the game exits.
    public func currentProcessIdentity() -> ProcessIdentity? {
        runningProcessIdentity
    }

    private func run(_ request: LaunchServiceRequest, continuation: AsyncStream<LaunchServiceEvent>.Continuation) async {
        defer {
            finishingLaunch(instanceID: request.instance.id)
        }
        do {
            guard let versionID = request.instance.manifest.versionID else {
                throw LauncherError(.usageError, "Instance has no Minecraft version assigned")
            }

            continuation.yield(.phase("Checking Java runtime"))
            let runtime = try javaInspector.inspect(executable: request.javaExecutable)
            let platform = try PlatformContext.forJVM(runtime)
            // Keep the reproducible Java record in instance metadata even when the user
            // launches without reinstalling. A failed record write must not block launch.
            let record = JavaManager(layout: layout).runtimeRecord(for: runtime)
            _ = try? InstanceRepository(layout: layout).setJavaRuntime(id: request.instance.id, record: record)

            continuation.yield(.phase("Resolving Minecraft \(versionID)"))
            let version = try VersionResolver().resolve(versionID: versionID, from: layout.gameRoot)

            continuation.yield(.phase("Resolving libraries and natives"))
            let dependencies = try dependencyResolver.resolve(version: version, layout: layout, platform: platform)

            var jvmArguments = (request.instance.manifest.jvmArguments ?? []) + request.additionalJVMArguments
            var seenArguments = Set<String>()
            jvmArguments = jvmArguments.filter { seenArguments.insert($0).inserted }
            // Memory is a launcher contract, not an optional frontend decoration. Automatic
            // mode still resolves to a concrete -Xmx so the JVM never inherits an unbounded heap.
            if !jvmArguments.contains(where: { $0.hasPrefix("-Xmx") }) {
                jvmArguments.append(contentsOf: InstanceMemory.jvmArguments(
                    configured: request.instance.manifest.memoryMiB
                ))
            }
            var features = request.features
            if let world = request.quickPlayWorld, !world.isEmpty {
                features["is_quick_play_singleplayer"] = true
            }
            let context = LaunchContext(
                instanceDirectory: request.instance.directory,
                gameDirectory: request.instance.gameDirectory,
                javaExecutable: request.javaExecutable,
                platform: platform,
                identity: request.identity,
                additionalJVMArguments: jvmArguments,
                features: features,
                quickPlaySingleplayer: request.quickPlayWorld
            )

            continuation.yield(.phase("Validating launch plan"))
            let preview = try planBuilder.preview(version: version, context: context, dependencies: dependencies, java: runtime)
            continuation.yield(.prepared(preview))

            let plan = try planBuilder.build(version: version, context: context, dependencies: dependencies)
            let diagnostics = planBuilder.validate(
                version: version,
                context: context,
                plan: plan,
                dependencies: dependencies,
                java: runtime
            )
            let errors = diagnostics.filter { $0.severity == .error }
            if !errors.isEmpty {
                let message = errors.prefix(4).map(\.message).joined(separator: " | ")
                throw LauncherError(
                    .missingDependency,
                    "Preflight blocked the launch: \(message)",
                    suggestion: "Run verify/doctor, or fix the highlighted files and try again."
                )
            }

            continuation.yield(.phase("Starting Java process"))
            let running = try await processController.start(plan)
            runningGame = running
            runningProcessIdentity = SystemProfiler.processIdentity(pid: running.processIdentifier)
            try? runtimeRegistry.markRunning(
                instanceID: request.instance.id,
                pid: running.processIdentifier,
                executable: request.javaExecutable
            )
            continuation.yield(.started(processIdentifier: running.processIdentifier))
            let logURL = makeLogURL()
            continuation.yield(.logFile(logURL))
            let logHandle = try? FileHandle(forWritingTo: createLogFile(logURL))
            defer { try? logHandle?.close() }
            writeLogHeader(
                logHandle,
                instance: request.instance,
                plan: plan,
                version: version,
                identity: request.identity,
                runtime: runtime
            )

            for await event in running.events {
                switch event {
                case let .stdout(text):
                    continuation.yield(.stdout(text))
                    try? logHandle?.write(contentsOf: Data(text.utf8))
                case let .stderr(text):
                    continuation.yield(.stderr(text))
                    try? logHandle?.write(contentsOf: Data(text.utf8))
                case let .exited(exit):
                    continuation.yield(.exited(exit))
                    try? logHandle?.write(contentsOf: Data("\n[launcher] exited code=\(exit.code) reason=\(exit.reason.rawValue)\n".utf8))
                    continuation.finish()
                    return
                }
            }
            continuation.finish()
        } catch let error as LauncherError {
            continuation.yield(.failed(error))
            continuation.finish()
        } catch is CancellationError {
            continuation.yield(.failed(LauncherError(.launchFailed, "Launch was cancelled")))
            continuation.finish()
        } catch {
            continuation.yield(.failed(LauncherError(.launchFailed, error.localizedDescription)))
            continuation.finish()
        }
    }

    private func finishingLaunch(instanceID: String) {
        runtimeRegistry.clear(instanceID: instanceID)
        launching = false
        runningGame = nil
        runningProcessIdentity = nil
    }

    // MARK: - Logging

    private func makeLogURL() -> URL {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        let name = "gui-launch-\(formatter.string(from: Date()))-\(UUID().uuidString.prefix(4)).log"
        try? FileManager.default.createDirectory(at: layout.launcherLogsDirectory, withIntermediateDirectories: true)
        return layout.launcherLogsDirectory.appendingPathComponent(name, isDirectory: false)
    }

    private func createLogFile(_ url: URL) -> URL {
        if !FileManager.default.fileExists(atPath: url.path) {
            FileManager.default.createFile(atPath: url.path, contents: nil)
        }
        return url
    }

    private func writeLogHeader(
        _ handle: FileHandle?,
        instance: Instance,
        plan: LaunchPlan,
        version: ResolvedVersion,
        identity: LaunchIdentity,
        runtime: JavaRuntime
    ) {
        var lines = [
            "# LingXi Launcher \(LauncherInfo.version)",
            "# instance: \(instance.id)",
            "# instanceName: \(instance.manifest.displayName)",
            "# gameDirectory: \(instance.gameDirectory.path)",
            "# started: \(ISO8601DateFormatter().string(from: Date()))",
            "# version: \(version.id)",
            "# identity: \(identity.mode.rawValue)",
            "# java: \(runtime.executable.path) (\(runtime.displayDescription))",
            "# argv (redacted, \(plan.redactedArguments.count) entries):",
        ]
        lines.append(contentsOf: plan.redactedArguments.map { "#   \($0)" })
        lines.append("")
        try? handle?.write(contentsOf: Data((lines.joined(separator: "\n") + "\n").utf8))
    }
}
