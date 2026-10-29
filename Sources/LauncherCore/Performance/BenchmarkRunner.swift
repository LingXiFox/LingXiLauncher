import Foundation

/// Runs repeatable, process-level Minecraft benchmarks. It deliberately measures observable
/// timings and OS resource samples; it never invents an FPS number when the game has not
/// exposed one to the launcher.
public actor BenchmarkRunner {
    private let layout: GameDataLayout
    private let hardware: PerformanceHardwareProfile
    private let clock: any BenchmarkTimeSource
    private let simulatedProcess: (any BenchmarkProcessRunning)?
    private var activeService: LaunchService?
    private var cancelled = false

    public init(
        layout: GameDataLayout,
        hardware: PerformanceHardwareProfile = SystemProfiler.hardware(),
        clock: any BenchmarkTimeSource = SystemBenchmarkClock(),
        simulatedProcess: (any BenchmarkProcessRunning)? = nil
    ) {
        self.layout = layout
        self.hardware = hardware
        self.clock = clock
        self.simulatedProcess = simulatedProcess
    }

    public func cancel() async {
        cancelled = true
        await activeService?.stop()
    }

    public func run(
        instance: Instance,
        javaExecutable: URL,
        identity: LaunchIdentity,
        options: BenchmarkOptions,
        additionalJVMArguments: [String] = []
    ) async throws -> BenchmarkReport {
        guard instance.manifest.versionID != nil else {
            throw BenchmarkError.invalidInstance(instance.id)
        }
        cancelled = false
        let compatibility = try? ModCompatibilityResolver.resolve(instance: instance, layout: layout)
        let totalRuns = options.warmupRuns + options.measuredRuns
        var measured: [BenchmarkRunResult] = []
        for runIndex in 0..<totalRuns {
            try Task.checkCancellation()
            if cancelled { throw BenchmarkError.cancelled }
            let result: BenchmarkRunResult
            do {
                if let simulatedProcess {
                    result = try await simulatedProcess.run(
                        instance: instance,
                        options: options,
                        index: runIndex - options.warmupRuns
                    )
                } else {
                    result = try await runSingle(
                        instance: instance,
                        javaExecutable: javaExecutable,
                        identity: identity,
                        options: options,
                        additionalJVMArguments: additionalJVMArguments,
                        index: runIndex - options.warmupRuns
                    )
                }
            } catch is CancellationError {
                throw BenchmarkError.cancelled
            }
            if runIndex >= options.warmupRuns {
                measured.append(result)
            }
        }
        guard !measured.isEmpty else { throw BenchmarkError.noMeasuredRuns }
        let aggregate = Self.aggregate(measured)
        var notes: [String] = []
        if options.quickPlayWorld == nil {
            notes.append("未指定快速进入世界，世界加载与区块生成工作负载未测量。")
        } else if measured.allSatisfy({ $0.phases.worldLoadSeconds == nil }) {
            notes.append("日志中没有 Preparing spawn area 证据，世界加载时间未报告。")
        }
        notes.append("FPS 需要游戏内帧计数器；启动器不会用 CPU 使用率伪造帧率。")
        return BenchmarkReport(
            instanceID: instance.id,
            minecraftVersion: compatibility?.gameVersion ?? instance.manifest.versionID ?? "unknown",
            loader: compatibility?.loader.displayName ?? "Unknown",
            hardware: hardware,
            options: options,
            runs: measured,
            aggregate: aggregate,
            notes: notes
        )
    }


    /// Reads only bytes produced by this benchmark launch. The game may append or truncate
    /// `latest.log` at startup; using the old file would report a fake 0.5 s startup time.
    private static func freshLogText(at url: URL, previousSize: UInt64, launchedAt: Date) -> String? {
        let attributes: [FileAttributeKey: Any]
        do {
            attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        } catch {
            return nil
        }
        guard let modified = attributes[.modificationDate] as? Date,
              modified >= launchedAt,
              let current = attributes[.size] as? NSNumber else { return nil }
        let size = current.uint64Value
        let offset = size < previousSize ? 0 : previousSize
        guard size > offset else { return nil }
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        do {
            try handle.seek(toOffset: offset)
            let data = try handle.readToEnd() ?? Data()
            return String(decoding: data, as: UTF8.self)
        } catch {
            return nil
        }
    }

    private static func fileSize(_ url: URL) -> UInt64 {
        (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.uint64Value ?? 0
    }

    private func runSingle(
        instance: Instance,
        javaExecutable: URL,
        identity: LaunchIdentity,
        options: BenchmarkOptions,
        additionalJVMArguments: [String],
        index: Int
    ) async throws -> BenchmarkRunResult {
        let startedAt = clock.now()
        let service = LaunchService(layout: layout)
        activeService = service
        defer { activeService = nil }

        let benchmarkLogURL = instance.gameDirectory.appendingPathComponent("logs/latest.log")
        let benchmarkLogOffset = Self.fileSize(benchmarkLogURL)
        let benchmarkLaunchedAt = Date()

        let stream = await service.launch(LaunchServiceRequest(
            instance: instance,
            identity: identity,
            javaExecutable: javaExecutable,
            additionalJVMArguments: additionalJVMArguments,
            quickPlayWorld: options.quickPlayWorld
        ))

        var processIdentity: ProcessIdentity?
        var logURL: URL?
        var output = ""
        var exit: GameExit?
        var failure: Error?
        var sampler: ProcessSampler?
        let stopState = BenchmarkStopState()
        let menuWatcher = Task { [weak service] in
            for _ in 0..<240 {
                try? await Task.sleep(nanoseconds: 500_000_000)
                if Task.isCancelled { return }
                guard let text = Self.freshLogText(
                    at: benchmarkLogURL,
                    previousSize: benchmarkLogOffset,
                    launchedAt: benchmarkLaunchedAt
                ) else { continue }
                let menuReady = text.contains("OpenAL initialized") && text.contains("Created:")
                let worldReady = text.contains("Preparing spawn area") && text.contains("Time elapsed")
                if menuReady || worldReady {
                    await stopState.markReached(at: Date())
                    try? await Task.sleep(nanoseconds: 2_000_000_000)
                    await service?.stop()
                    return
                }
            }
        }
        let timeoutTask = Task { [weak service] in
            guard let service else { return }
            try? await Task.sleep(nanoseconds: UInt64(options.timeoutSeconds * 1_000_000_000))
            if !Task.isCancelled { await service.stop() }
        }

        for await event in stream {
            switch event {
            case .started:
                if processIdentity == nil {
                    processIdentity = await service.currentProcessIdentity()
                    if let identity = processIdentity {
                        let newSampler = ProcessSampler()
                        await newSampler.start(identity: identity, interval: options.sampleIntervalSeconds)
                        sampler = newSampler
                    }
                }
            case let .logFile(url):
                logURL = url
            case let .stdout(text), let .stderr(text):
                if output.utf8.count < 2_000_000 { output += text }
            case let .exited(result):
                exit = result
            case let .failed(error):
                failure = error
            case .phase, .prepared:
                break
            }
        }
        timeoutTask.cancel()
        menuWatcher.cancel()
        let samples = await sampler?.stop() ?? []
        let reachedMenu = await stopState.reached
        let reachedSeconds = await stopState.secondsSince(startedAt)

        if let failure {
            throw failure
        }
        // A benchmark run intentionally stops the game after the menu/world is ready. That
        // stop is reported as SIGTERM; only an unsuccessful exit without a readiness marker is
        // a failed benchmark.
        if let exit, !exit.isSuccess, !reachedMenu {
            throw LauncherError(
                .launchFailed,
                "Benchmark run \(index) exited with code \(exit.code) (\(exit.reason.rawValue))",
                suggestion: "Open the instance diagnostics to inspect the log before running another benchmark."
            )
        }

        let logText: String
        if let logURL, let text = try? String(contentsOf: logURL, encoding: .utf8) {
            logText = text
        } else if let latest = try? String(contentsOf: instance.gameDirectory.appendingPathComponent("logs/latest.log"), encoding: .utf8) {
            logText = latest
        } else {
            logText = output
        }
        let timeline = MinecraftLogTimeline.parse(logText)
        let total = clock.now().timeIntervalSince(startedAt)
        let cpuValues = samples.map(\.cpuPercent)
        let peakRSS = samples.map(\.residentBytes).max()
        let startup = timeline.menuSeconds ?? reachedSeconds
        let phases = BenchmarkPhaseDurations(
            startupSeconds: startup,
            javaToMenuSeconds: startup,
            worldLoadSeconds: timeline.worldLoadSeconds,
            resourceReloadSeconds: timeline.resourceReloadSeconds,
            totalSeconds: total
        )
        var evidence = timeline.evidence
        if let processIdentity {
            evidence.insert("process \(processIdentity.processIdentifier) start=\(processIdentity.startTimeSeconds).\(processIdentity.startTimeMicroseconds)", at: 0)
        }
        return BenchmarkRunResult(
            index: index,
            startedAt: startedAt,
            process: processIdentity,
            exitCode: exit?.code ?? 0,
            exitReason: reachedMenu ? "reached-menu" : (exit?.reason.rawValue ?? "unknown"),
            phases: phases,
            averageCPUPercent: cpuValues.isEmpty ? nil : cpuValues.reduce(0, +) / Double(cpuValues.count),
            maximumCPUPercent: cpuValues.max(),
            peakResidentBytes: peakRSS,
            samples: samples,
            frameMetrics: nil,
            frameMetricsUnavailableReason: "Minecraft does not expose a stable frame counter to an external launcher process.",
            logPath: logURL?.path,
            renderer: timeline.renderer,
            evidence: evidence
        )
    }

    private static func aggregate(_ runs: [BenchmarkRunResult]) -> BenchmarkAggregate {
        let startups = runs.compactMap(\.phases.startupSeconds)
        let worlds = runs.compactMap(\.phases.worldLoadSeconds)
        let cpu = runs.compactMap(\.averageCPUPercent)
        let cpuMax = runs.compactMap(\.maximumCPUPercent)
        let rss = runs.compactMap(\.peakResidentBytes)
        return BenchmarkAggregate(
            samples: runs.count,
            startupMin: startups.min(),
            startupAverage: startups.isEmpty ? nil : startups.reduce(0, +) / Double(startups.count),
            startupMax: startups.max(),
            worldLoadMin: worlds.min(),
            worldLoadAverage: worlds.isEmpty ? nil : worlds.reduce(0, +) / Double(worlds.count),
            worldLoadMax: worlds.max(),
            cpuAverage: cpu.isEmpty ? nil : cpu.reduce(0, +) / Double(cpu.count),
            cpuMax: cpuMax.max(),
            residentPeakBytes: rss.max(),
            frameMetrics: nil,
            frameMetricsUnavailableReason: "No in-game frame counter was available."
        )
    }
}

private actor BenchmarkStopState {
    private(set) var reached = false
    private var reachedAt: Date?

    func markReached(at date: Date) {
        reached = true
        if reachedAt == nil { reachedAt = date }
    }

    func secondsSince(_ start: Date) -> Double? {
        guard let reachedAt else { return nil }
        return max(0, reachedAt.timeIntervalSince(start))
    }
}

private actor ProcessSampler {
    private var samples: [ProcessResourceSample] = []
    private var task: Task<Void, Never>?

    func start(identity: ProcessIdentity, interval: TimeInterval) {
        task?.cancel()
        samples = []
        let nanoseconds = UInt64(max(0.1, interval) * 1_000_000_000)
        task = Task { [weak self] in
            while !Task.isCancelled {
                if let sample = SystemProfiler.sampleProcess(identity) {
                    await self?.append(sample)
                } else {
                    break
                }
                try? await Task.sleep(nanoseconds: nanoseconds)
            }
        }
    }

    func stop() -> [ProcessResourceSample] {
        task?.cancel()
        task = nil
        return samples
    }

    private func append(_ sample: ProcessResourceSample) {
        if samples.count < 4_000 { samples.append(sample) }
    }
}
