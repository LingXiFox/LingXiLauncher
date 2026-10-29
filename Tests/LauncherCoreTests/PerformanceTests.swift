import XCTest
@testable import LauncherCore

private struct PerformanceRuntime: InstanceRuntimeChecking {
    let running: Bool
    func isRunning(instanceID: String) -> Bool { running }
}

private struct FixedBenchmarkClock: BenchmarkTimeSource {
    let value: Date
    func now() -> Date { value }
}

private struct MockBenchmarkProcess: BenchmarkProcessRunning {
    func run(instance: Instance, options: BenchmarkOptions, index: Int) async throws -> BenchmarkRunResult {
        let startup = 12.0 + Double(index)
        return BenchmarkRunResult(
            index: index,
            startedAt: Date(timeIntervalSince1970: 1_700_000_000 + Double(index)),
            process: ProcessIdentity(processIdentifier: 42, startTimeSeconds: 1, startTimeMicroseconds: 0),
            exitCode: 0,
            exitReason: "exit",
            phases: BenchmarkPhaseDurations(startupSeconds: startup, javaToMenuSeconds: startup, worldLoadSeconds: 4, resourceReloadSeconds: 2, totalSeconds: startup + 6),
            averageCPUPercent: 80 + Double(index),
            maximumCPUPercent: 95,
            peakResidentBytes: 1_073_741_824,
            samples: [ProcessResourceSample(offsetSeconds: 1, cpuPercent: 80, residentBytes: 1_073_741_824)],
            frameMetrics: nil,
            frameMetricsUnavailableReason: "mock",
            logPath: "/tmp/mock.log",
            renderer: "Mock Renderer",
            evidence: ["mock process"]
        )
    }
}

final class PerformanceTests: XCTestCase {
    private var root: URL!
    private var layout: GameDataLayout!
    private var hardware: PerformanceHardwareProfile!

    override func setUpWithError() throws {
        root = try FixtureLoader.temporaryDirectory("lingxi-m8-performance")
        layout = GameDataLayout(
            gameRoot: root.appendingPathComponent("mc", isDirectory: true),
            dataRoot: root.appendingPathComponent("data", isDirectory: true)
        )
        hardware = PerformanceHardwareProfile(
            modelIdentifier: "MacTest",
            cpuModel: "Apple M-Test",
            architecture: "arm64",
            physicalCores: 8,
            logicalCores: 8,
            memoryBytes: 16 * 1_073_741_824,
            operatingSystem: "macOS Test",
            gpuModel: "Apple GPU",
            gpuMemoryBytes: nil
        )
    }

    override func tearDownWithError() throws {
        if let root { try? FileManager.default.removeItem(at: root) }
    }

    func testMockBenchmarkUsesInjectedProcessAndClockWithoutLaunchingGame() async throws {
        let repository = InstanceRepository(layout: layout)
        let instance = try repository.create(id: "bench", displayName: "Bench", versionID: "1.20.1")
        let runner = BenchmarkRunner(
            layout: layout,
            hardware: hardware,
            clock: FixedBenchmarkClock(value: Date(timeIntervalSince1970: 1_700_000_100)),
            simulatedProcess: MockBenchmarkProcess()
        )
        let report = try await runner.run(
            instance: instance,
            javaExecutable: URL(fileURLWithPath: "/usr/bin/true"),
            identity: .localOffline(LocalOfflineProfile(playerName: "Tester", stableOfflineUUID: UUID())),
            options: BenchmarkOptions(warmupRuns: 0, measuredRuns: 2, timeoutSeconds: 30, sampleIntervalSeconds: 0.1, quickPlayWorld: "World")
        )
        XCTAssertEqual(report.runs.count, 2)
        XCTAssertEqual(report.aggregate.samples, 2)
        XCTAssertEqual(report.aggregate.startupAverage, 12.5)
        XCTAssertNil(report.aggregate.frameMetrics)
        XCTAssertTrue(report.notes.contains { $0.contains("FPS") })
        XCTAssertTrue(report.runs.allSatisfy { $0.frameMetrics == nil })
    }

    func testBenchmarkComparisonNeverTreatsMissingMetricsAsZero() {
        let instanceID = "bench"
        let a = report(instanceID: instanceID, startup: 20, world: 5, cpu: 50, memory: 1_073_741_824)
        let b = report(instanceID: instanceID, startup: 18, world: nil, cpu: 45, memory: 1_073_741_824)
        let comparison = BenchmarkComparisonEngine.compare(baseline: a, candidate: b)
        XCTAssertEqual(comparison.winner, "候选方案")
        XCTAssertNil(comparison.worldLoadDeltaSeconds)
        XCTAssertEqual(comparison.startupDeltaSeconds, -2)
        XCTAssertEqual(comparison.cpuDeltaPercent, -5)
        XCTAssertTrue(comparison.summary.contains("有效指标不足") == false)
    }

    func testTuningRulesAreDeterministicAndDoNotFabricateFPS() {
        let recommendations = PerformanceTuningEngine.recommendations(
            hardware: hardware,
            currentHeapMiB: nil,
            loader: "Fabric",
            modCount: 100,
            baseline: nil
        )
        XCTAssertTrue(recommendations.contains { $0.id == "heap-balanced" })
        XCTAssertTrue(recommendations.contains { $0.id == "g1-low-pause" })
        XCTAssertTrue(recommendations.contains { $0.id == "mod-count-review" })
        XCTAssertTrue(recommendations.allSatisfy { !$0.summary.contains("FPS 提升") })
    }

    func testApplyAndRestorePerformanceProfilePreservesIdentityAndInstanceData() throws {
        let repository = InstanceRepository(layout: layout)
        let instance = try repository.create(id: "tune", displayName: "Tune", versionID: "1.20.1")
        try Data("save".utf8).write(to: instance.gameDirectory.appendingPathComponent("options.txt"))
        let plan = PerformanceTuningEngine.makePlan(
            instance: instance,
            hardware: hardware,
            loader: "Fabric",
            modCount: 10
        )
        let store = PerformanceProfileStore(layout: layout, runtime: PerformanceRuntime(running: false))
        let result = try store.apply(instanceID: instance.id, plan: plan, confirmed: true)
        XCTAssertEqual(result.profile.heapMiB, plan.targetHeapMiB)
        let loaded = try repository.load(id: instance.id)
        XCTAssertEqual(loaded.manifest.memoryMiB, plan.targetHeapMiB)
        XCTAssertEqual(loaded.manifest.jvmArguments, plan.targetJVMArguments)
        XCTAssertEqual(loaded.manifest.displayName, "Tune")
        XCTAssertEqual(try Data(contentsOf: instance.gameDirectory.appendingPathComponent("options.txt")), Data("save".utf8))
        _ = try store.restore(instanceID: instance.id, confirmed: true)
        XCTAssertNil(try repository.load(id: instance.id).manifest.memoryMiB)
        XCTAssertNil(try repository.load(id: instance.id).manifest.jvmArguments)
    }

    func testApplyRefusedWhileGameRunsAndWithoutConfirmation() throws {
        let repository = InstanceRepository(layout: layout)
        let instance = try repository.create(id: "busy", displayName: "Busy", versionID: "1.20.1")
        let plan = PerformanceTuningEngine.makePlan(instance: instance, hardware: hardware, loader: "Fabric", modCount: 0)
        let busy = PerformanceProfileStore(layout: layout, runtime: PerformanceRuntime(running: true))
        XCTAssertThrowsError(try busy.apply(instanceID: instance.id, plan: plan, confirmed: true))
        let idle = PerformanceProfileStore(layout: layout, runtime: PerformanceRuntime(running: false))
        XCTAssertThrowsError(try idle.apply(instanceID: instance.id, plan: plan, confirmed: false))
        XCTAssertNil(try repository.load(id: instance.id).manifest.memoryMiB)
    }

    private func report(instanceID: String, startup: Double, world: Double?, cpu: Double, memory: UInt64) -> BenchmarkReport {
        let run = BenchmarkRunResult(
            index: 0,
            startedAt: Date(timeIntervalSince1970: 1_700_000_000),
            process: nil,
            exitCode: 0,
            exitReason: "exit",
            phases: BenchmarkPhaseDurations(startupSeconds: startup, javaToMenuSeconds: startup, worldLoadSeconds: world, resourceReloadSeconds: nil, totalSeconds: startup + (world ?? 0)),
            averageCPUPercent: cpu,
            maximumCPUPercent: cpu,
            peakResidentBytes: memory,
            samples: [],
            frameMetrics: nil,
            frameMetricsUnavailableReason: "mock",
            logPath: nil,
            renderer: nil,
            evidence: []
        )
        return BenchmarkReport(
            instanceID: instanceID,
            minecraftVersion: "1.20.1",
            loader: "Fabric",
            hardware: hardware,
            options: BenchmarkOptions(),
            runs: [run],
            aggregate: BenchmarkAggregate(
                samples: 1,
                startupMin: startup,
                startupAverage: startup,
                startupMax: startup,
                worldLoadMin: world,
                worldLoadAverage: world,
                worldLoadMax: world,
                cpuAverage: cpu,
                cpuMax: cpu,
                residentPeakBytes: memory,
                frameMetrics: nil,
                frameMetricsUnavailableReason: "mock"
            )
        )
    }
}
