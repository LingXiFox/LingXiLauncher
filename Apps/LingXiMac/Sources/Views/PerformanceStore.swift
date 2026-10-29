import Foundation
import SwiftUI
import LauncherCore

@MainActor
final class PerformanceStore: ObservableObject {
    enum Tab: String, CaseIterable, Identifiable {
        case benchmark = "性能测试"
        case tune = "自动调优"
        case reports = "报告对比"

        var id: String { rawValue }
        var icon: String {
            switch self {
            case .benchmark: return "gauge.with.dots.needle.50percent"
            case .tune: return "slider.horizontal.3"
            case .reports: return "chart.xyaxis.line"
            }
        }
    }

    let instance: Instance
    private let model: AppModel
    private let store: PerformanceProfileStore
    private let runner: BenchmarkRunner
    private let worldManager: WorldBackupManager

    @Published var tab: Tab = .benchmark
    @Published var hardware: PerformanceHardwareProfile
    @Published var options = BenchmarkOptions()
    @Published var quickPlayWorld = ""
    @Published var reports: [BenchmarkReport] = []
    @Published var latestReport: BenchmarkReport?
    @Published var comparison: BenchmarkComparison?
    @Published var plan: PerformanceTuningPlan?
    @Published var appliedProfile: AppliedPerformanceProfile?
    @Published var isRunning = false
    @Published var isApplying = false
    @Published var progressText = ""
    @Published var errorMessage: String?
    @Published var statusMessage: String?
    @Published var worlds: [MinecraftWorld] = []
    @Published var showApplyConfirmation = false
    @Published var showRestoreConfirmation = false

    init(instance: Instance, model: AppModel) {
        self.instance = instance
        self.model = model
        self.store = model.makePerformanceProfileStore()
        self.runner = model.makeBenchmarkRunner()
        self.worldManager = WorldBackupManager(layout: model.layout)
        self.hardware = SystemProfiler.hardware()
    }

    var currentHeap: Int? { instance.manifest.memoryMiB }

    var loaderName: String {
        (try? ModCompatibilityResolver.resolve(instance: instance, layout: model.layout).loader.displayName) ?? "Unknown"
    }

    var modCount: Int {
        (try? ModRepository(layout: model.layout).list(instance: instance).count) ?? 0
    }

    func load() {
        reports = store.loadReports(instanceID: instance.id)
        latestReport = reports.first
        appliedProfile = try? store.loadProfile(instanceID: instance.id)
        worlds = (try? worldManager.listWorlds(instanceID: instance.id)) ?? []
        if quickPlayWorld.isEmpty, worlds.count == 1 {
            quickPlayWorld = worlds[0].name
        }
        refreshPlan()
        refreshComparison()
    }

    func refreshPlan() {
        plan = PerformanceTuningEngine.makePlan(
            instance: instance,
            hardware: hardware,
            loader: loaderName,
            modCount: modCount,
            baseline: latestReport
        )
    }

    func refreshComparison() {
        comparison = reports.count >= 2
            ? BenchmarkComparisonEngine.compare(baseline: reports[1], candidate: reports[0])
            : nil
    }

    func runBenchmark() async {
        guard !isRunning else { return }
        isRunning = true
        errorMessage = nil
        statusMessage = nil
        progressText = "准备身份与 Java…"
        options.quickPlayWorld = quickPlayWorld.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? nil
            : quickPlayWorld.trimmingCharacters(in: .whitespacesAndNewlines)
        do {
            let (identity, java) = try await model.makeBenchmarkContext(for: instance)
            progressText = "启动 Minecraft，暖机 \(options.warmupRuns) 次，测量 \(options.measuredRuns) 次…"
            let report = try await runner.run(
                instance: instance,
                javaExecutable: java,
                identity: identity,
                options: options
            )
            _ = try store.saveReport(report)
            reports = store.loadReports(instanceID: instance.id)
            latestReport = reports.first
            refreshPlan()
            refreshComparison()
            statusMessage = "已保存基准报告；启动均值 \(Self.seconds(report.aggregate.startupAverage))，世界加载 \(Self.seconds(report.aggregate.worldLoadAverage))。"
            progressText = ""
        } catch {
            errorMessage = Self.describe(error)
            progressText = ""
        }
        isRunning = false
    }

    func cancelBenchmark() async {
        await runner.cancel()
        statusMessage = "正在取消基准测试…"
    }

    func applyPlan() async {
        guard let plan, !isApplying else { return }
        isApplying = true
        errorMessage = nil
        do {
            let result = try store.apply(
                instanceID: instance.id,
                plan: plan,
                baselineReportID: latestReport?.id,
                confirmed: true
            )
            appliedProfile = result.profile
            statusMessage = "性能设置已应用；原设置备份在 \(result.backupPath)。"
            model.reloadInstances()
        } catch {
            errorMessage = Self.describe(error)
        }
        isApplying = false
        showApplyConfirmation = false
    }

    func restoreProfile() async {
        guard !isApplying else { return }
        isApplying = true
        errorMessage = nil
        do {
            let result = try store.restore(instanceID: instance.id, confirmed: true)
            appliedProfile = result.profile
            statusMessage = "已恢复上一次性能设置。"
            model.reloadInstances()
        } catch {
            errorMessage = Self.describe(error)
        }
        isApplying = false
        showRestoreConfirmation = false
    }

    func clearError() { errorMessage = nil }
    func clearStatus() { statusMessage = nil }

    func export(_ report: BenchmarkReport, to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(report).write(to: url, options: .atomic)
    }

    static func seconds(_ value: Double?) -> String {
        guard let value else { return "无数据" }
        return String(format: "%.2f 秒", value)
    }

    static func bytes(_ value: UInt64?) -> String {
        guard let value else { return "无数据" }
        return ByteCountFormatter.string(fromByteCount: Int64(value), countStyle: .memory)
    }

    static func describe(_ error: Error) -> String {
        if let localized = error as? LocalizedError, let description = localized.errorDescription {
            return description
        }
        return error.localizedDescription
    }
}
