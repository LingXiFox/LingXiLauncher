import Foundation

/// Risk is deliberately explicit: every automatic change must be explainable and reversible.
public enum PerformanceRisk: String, Codable, CaseIterable, Sendable {
    case low
    case medium
    case high

    public var displayName: String {
        switch self {
        case .low: return "低风险"
        case .medium: return "中风险"
        case .high: return "高风险"
        }
    }
}

public struct PerformanceRecommendation: Codable, Sendable, Equatable, Identifiable {
    public let id: String
    public let title: String
    public let summary: String
    public let rationale: String
    public let expectedEffect: String
    public let risk: PerformanceRisk
    public let heapMiB: Int?
    public let jvmArguments: [String]
    public let requiresConfirmation: Bool

    public init(
        id: String,
        title: String,
        summary: String,
        rationale: String,
        expectedEffect: String,
        risk: PerformanceRisk,
        heapMiB: Int? = nil,
        jvmArguments: [String] = [],
        requiresConfirmation: Bool = true
    ) {
        self.id = id
        self.title = title
        self.summary = summary
        self.rationale = rationale
        self.expectedEffect = expectedEffect
        self.risk = risk
        self.heapMiB = heapMiB
        self.jvmArguments = jvmArguments
        self.requiresConfirmation = requiresConfirmation
    }
}

public struct PerformanceTuningPlan: Codable, Sendable, Equatable, Identifiable {
    public let id: UUID
    public let createdAt: Date
    public let instanceID: String
    public let targetHeapMiB: Int
    public let targetJVMArguments: [String]
    public let recommendations: [PerformanceRecommendation]
    public let estimatedChange: String
    public let hardware: PerformanceHardwareProfile

    public init(
        id: UUID = UUID(),
        createdAt: Date = Date(),
        instanceID: String,
        targetHeapMiB: Int,
        targetJVMArguments: [String],
        recommendations: [PerformanceRecommendation],
        estimatedChange: String,
        hardware: PerformanceHardwareProfile
    ) {
        self.id = id
        self.createdAt = createdAt
        self.instanceID = instanceID
        self.targetHeapMiB = targetHeapMiB
        self.targetJVMArguments = targetJVMArguments
        self.recommendations = recommendations
        self.estimatedChange = estimatedChange
        self.hardware = hardware
    }
}

public struct BenchmarkComparison: Codable, Sendable, Equatable {
    public let baselineReportID: UUID
    public let candidateReportID: UUID
    public let startupDeltaSeconds: Double?
    public let worldLoadDeltaSeconds: Double?
    public let cpuDeltaPercent: Double?
    public let memoryDeltaBytes: Int64?
    public let winner: String
    public let confidence: PerformanceRisk
    public let summary: String

    public init(
        baselineReportID: UUID,
        candidateReportID: UUID,
        startupDeltaSeconds: Double?,
        worldLoadDeltaSeconds: Double?,
        cpuDeltaPercent: Double?,
        memoryDeltaBytes: Int64?,
        winner: String,
        confidence: PerformanceRisk,
        summary: String
    ) {
        self.baselineReportID = baselineReportID
        self.candidateReportID = candidateReportID
        self.startupDeltaSeconds = startupDeltaSeconds
        self.worldLoadDeltaSeconds = worldLoadDeltaSeconds
        self.cpuDeltaPercent = cpuDeltaPercent
        self.memoryDeltaBytes = memoryDeltaBytes
        self.winner = winner
        self.confidence = confidence
        self.summary = summary
    }
}

public struct BenchmarkComparisonEngine: Sendable {
    public init() {}

    /// Positive deltas mean the candidate is slower/heavier. A missing measurement is never
    /// treated as zero; it lowers confidence and is called out in the summary.
    public static func compare(baseline: BenchmarkReport, candidate: BenchmarkReport) -> BenchmarkComparison {
        let startup = delta(candidate.aggregate.startupAverage, baseline.aggregate.startupAverage)
        let world = delta(candidate.aggregate.worldLoadAverage, baseline.aggregate.worldLoadAverage)
        let cpu = delta(candidate.aggregate.cpuAverage, baseline.aggregate.cpuAverage)
        let memory: Int64? = {
            guard let b = baseline.aggregate.residentPeakBytes, let c = candidate.aggregate.residentPeakBytes else { return nil }
            return Int64(c) - Int64(b)
        }()
        let comparable = [startup, world, cpu].compactMap { $0 }
        let available = [startup, world, cpu].compactMap { $0 }.count
        let average = comparable.isEmpty ? 0 : comparable.reduce(0, +) / Double(comparable.count)
        let winner: String
        if comparable.isEmpty { winner = "无法判断" }
        else if average < -0.03 { winner = "候选方案" }
        else if average > 0.03 { winner = "基准方案" }
        else { winner = "差异不显著" }
        let confidence: PerformanceRisk = available >= 2 ? .low : .medium
        var parts: [String] = []
        if let startup { parts.append(String(format: "启动平均变化 %+.2f 秒", startup)) }
        if let world { parts.append(String(format: "世界加载平均变化 %+.2f 秒", world)) }
        if let cpu { parts.append(String(format: "平均 CPU 变化 %+.1f%%", cpu)) }
        if let memory { parts.append("峰值内存变化 \(memory / 1_048_576) MiB") }
        if parts.isEmpty { parts.append("两组报告没有可比较的启动/世界加载指标") }
        parts.append("胜出：\(winner)")
        if available < 2 { parts.append("有效指标不足，结论置信度有限") }
        return BenchmarkComparison(
            baselineReportID: baseline.id,
            candidateReportID: candidate.id,
            startupDeltaSeconds: startup,
            worldLoadDeltaSeconds: world,
            cpuDeltaPercent: cpu,
            memoryDeltaBytes: memory,
            winner: winner,
            confidence: confidence,
            summary: parts.joined(separator: "；")
        )
    }

    private static func delta(_ candidate: Double?, _ baseline: Double?) -> Double? {
        guard let candidate, let baseline else { return nil }
        return candidate - baseline
    }
}

public enum PerformanceTuningEngine {
    public static func recommendedHeap(hardware: PerformanceHardwareProfile) -> Int {
        let totalMiB = Int(hardware.memoryBytes / 1_048_576)
        let half = totalMiB / 2
        let clamped = max(2_048, min(8_192, half))
        return (clamped / 512) * 512
    }

    public static func recommendations(
        hardware: PerformanceHardwareProfile,
        currentHeapMiB: Int?,
        loader: String,
        modCount: Int,
        baseline: BenchmarkReport?
    ) -> [PerformanceRecommendation] {
        var results: [PerformanceRecommendation] = []
        let heap = recommendedHeap(hardware: hardware)
        if currentHeapMiB != heap {
            results.append(PerformanceRecommendation(
                id: "heap-balanced",
                title: "将堆内存调整为 \(heap) MiB",
                summary: "为 \(hardware.modelIdentifier) 的 \(hardware.memoryBytes / 1_073_741_824) GiB 内存保留系统与 GPU 共享内存余量。",
                rationale: "Minecraft 与 JVM 需要为原生库、GPU 驱动和系统留出内存；把物理内存全部交给 -Xmx 会增加换页和系统卡顿风险。",
                expectedEffect: "减少因堆过小导致的频繁 GC；避免堆过大造成的系统换页。",
                risk: .low,
                heapMiB: heap
            ))
        }
        let g1 = ["-XX:+UseG1GC", "-XX:MaxGCPauseMillis=50", "-XX:+ParallelRefProcEnabled"]
        results.append(PerformanceRecommendation(
            id: "g1-low-pause",
            title: "启用 G1GC 低暂停配置",
            summary: "使用 G1 垃圾回收器，并把目标停顿设为 50ms。",
            rationale: "G1 在 Apple Silicon 与 Java 21 上对不同堆大小更稳健；50ms 是低风险起点，不追求极端吞吐。",
            expectedEffect: "减轻大型模组包中的长 GC 停顿；不保证提高平均 FPS。",
            risk: .low,
            jvmArguments: g1
        ))
        if modCount > 80 {
            results.append(PerformanceRecommendation(
                id: "mod-count-review",
                title: "审查大型模组包",
                summary: "当前实例有 \(modCount) 个模组；先测量再逐个禁用可疑模组。",
                rationale: "模组数量本身不是性能结论，但大型包中的初始化钩子、渲染替换和内存占用需要 A/B 证据。",
                expectedEffect: "找出真正影响启动或世界加载的模组，而不是盲目删模组。",
                risk: .medium
            ))
        }
        if let baseline {
            if let startup = baseline.aggregate.startupAverage, startup > 45 {
                results.append(PerformanceRecommendation(
                    id: "slow-startup-review",
                    title: "启动耗时偏高，建议做 A/B 对比",
                    summary: String(format: "当前启动平均 %.1f 秒；用相同世界和设置再测一次，比较模组/参数变化。", startup),
                    rationale: "启动时间受磁盘缓存、资源包、模组初始化和首次资源加载影响；单次结果不足以证明某个参数有效。",
                    expectedEffect: "用可重复的基准找出启动瓶颈。",
                    risk: .low
                ))
            }
            if baseline.aggregate.frameMetrics == nil {
                results.append(PerformanceRecommendation(
                    id: "fps-evidence-gap",
                    title: "FPS 没有外部可验证数据",
                    summary: "启动器不会用 CPU 占用率伪造 FPS。",
                    rationale: "Minecraft 没有向外部进程暴露稳定的帧计数器；当前报告只包含启动、世界加载、CPU 和 RSS。",
                    expectedEffect: "避免把不可靠的数字当成性能提升证据。",
                    risk: .low
                ))
            }
        }
        results.append(PerformanceRecommendation(
            id: "render-distance-manual",
            title: "渲染距离与分辨率需在游戏内验证",
            summary: "不自动修改 options.txt；请在游戏内降低渲染距离或分辨率并重新测量。",
            rationale: "直接改 options.txt 可能与游戏版本、模组或用户设置冲突；视觉设置应由用户在确认后调整。",
            expectedEffect: "降低 GPU 压力，但会改变画面；必须由用户决定。",
            risk: .low
        ))
        return results
    }

    public static func makePlan(
        instance: Instance,
        hardware: PerformanceHardwareProfile = SystemProfiler.hardware(),
        loader: String,
        modCount: Int,
        baseline: BenchmarkReport? = nil
    ) -> PerformanceTuningPlan {
        let recommendations = recommendations(
            hardware: hardware,
            currentHeapMiB: instance.manifest.memoryMiB,
            loader: loader,
            modCount: modCount,
            baseline: baseline
        )
        var arguments: [String] = []
        for item in recommendations where item.id == "g1-low-pause" {
            arguments.append(contentsOf: item.jvmArguments)
        }
        let heap = recommendations.first(where: { $0.heapMiB != nil })?.heapMiB
            ?? instance.manifest.memoryMiB
            ?? recommendedHeap(hardware: hardware)
        return PerformanceTuningPlan(
            instanceID: instance.id,
            targetHeapMiB: heap,
            targetJVMArguments: arguments,
            recommendations: recommendations,
            estimatedChange: "预计减少 GC 停顿；实际效果需用同一世界和设置的 A/B 基准验证。",
            hardware: hardware
        )
    }
}
