import SwiftUI
import AppKit
import LauncherCore

struct PerformanceView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.lxTheme) private var theme
    @StateObject private var store: PerformanceStore
    @State private var reportToExport: BenchmarkReport?

    init(instance: Instance, model: AppModel) {
        _store = StateObject(wrappedValue: PerformanceStore(instance: instance, model: model))
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().overlay(theme.border)
            HStack(spacing: 0) {
                sidebar
                Divider().overlay(theme.border)
                content
            }
        }
        .frame(minWidth: 980, minHeight: 660)
        .background(theme.canvas)
        .task { store.load() }
        .confirmationDialog(
            "应用这组性能设置？",
            isPresented: $store.showApplyConfirmation
        ) {
            Button("应用并备份原设置") { Task { await store.applyPlan() } }
            Button("取消", role: .cancel) {}
        } message: {
            Text("只会修改该实例的堆内存和 JVM 参数，不会改存档、模组或 options.txt。原设置会写入独立备份，可随时恢复。")
        }
        .confirmationDialog(
            "恢复上一次性能设置？",
            isPresented: $store.showRestoreConfirmation
        ) {
            Button("恢复") { Task { await store.restoreProfile() } }
            Button("取消", role: .cancel) {}
        } message: {
            Text("将恢复应用调优前的堆内存与 JVM 参数；不会触碰游戏数据。")
        }
        .alert("导出基准报告", isPresented: Binding(
            get: { reportToExport != nil },
            set: { if !$0 { reportToExport = nil } }
        )) {
            Button("保存 JSON") { saveReport() }
            Button("取消", role: .cancel) { reportToExport = nil }
        } message: {
            Text("报告包含硬件、启动/世界加载耗时、CPU/RSS 样本和日志路径，不包含认证 Token。")
        }
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 14) {
            LXPageHeader(
                eyebrow: "INSTANCE / PERFORMANCE",
                title: "性能工作台",
                subtitle: "\(store.instance.manifest.displayName) · \(store.loaderName) · \(store.modCount) 个模组"
            )
            Spacer()
            if store.isRunning || store.isApplying {
                ProgressView().controlSize(.small)
            }
            LXIconButton(systemImage: "xmark", label: "关闭") { dismiss() }
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 16)
        .background(theme.surface)
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("性能工具")
                .font(LXFont.captionStrong)
                .foregroundStyle(theme.textTertiary)
                .padding(.horizontal, 12)
                .padding(.top, 4)
            ForEach(PerformanceStore.Tab.allCases) { tab in
                Button {
                    store.tab = tab
                } label: {
                    HStack(spacing: 9) {
                        Image(systemName: tab.icon)
                            .font(.system(size: 12, weight: .medium))
                            .frame(width: 18)
                        Text(tab.rawValue).font(LXFont.bodyStrong)
                        Spacer()
                        if tab == .reports, !store.reports.isEmpty {
                            LXBadge(text: "\(store.reports.count)", tone: .neutral)
                        }
                    }
                    .foregroundStyle(store.tab == tab ? theme.orange : theme.textSecondary)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 9)
                    .background(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .fill(store.tab == tab ? theme.orangeSoft : .clear)
                    )
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            Spacer(minLength: 18)
            hardwareCard
                .padding(8)
        }
        .padding(.vertical, 12)
        .frame(width: 225)
        .background(theme.sidebar)
    }

    private var hardwareCard: some View {
        VStack(alignment: .leading, spacing: 7) {
            Label("本机硬件", systemImage: "cpu")
                .font(LXFont.captionStrong)
                .foregroundStyle(theme.textSecondary)
            Text(store.hardware.cpuModel)
                .font(LXFont.caption)
                .foregroundStyle(theme.textTertiary)
                .fixedSize(horizontal: false, vertical: true)
            Text("\(store.hardware.physicalCores) 核 · \(ByteCountFormatter.string(fromByteCount: Int64(store.hardware.memoryBytes), countStyle: .memory))")
                .font(LXFont.caption)
                .foregroundStyle(theme.textTertiary)
            if let gpu = store.hardware.gpuModel {
                Text(gpu)
                    .font(LXFont.caption)
                    .foregroundStyle(theme.textTertiary)
                    .lineLimit(2)
            }
            Text("OpenGL 4.1 是 macOS 的兼容上限；不会伪造 FPS 或“RTX”指标。")
                .font(LXFont.caption)
                .foregroundStyle(theme.textTertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(12)
        .background(theme.surface, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(theme.border, lineWidth: 0.8))
    }

    @ViewBuilder
    private var content: some View {
        VStack(spacing: 0) {
            if let error = store.errorMessage {
                LXErrorBanner(message: error) { store.clearError() }
                    .padding(.horizontal, 20)
                    .padding(.top, 12)
            }
            if let status = store.statusMessage {
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: "checkmark.circle").foregroundStyle(theme.success)
                    Text(status).font(LXFont.caption).foregroundStyle(theme.textSecondary)
                    Spacer()
                    Button("关闭") { store.clearStatus() }.buttonStyle(.plain).font(LXFont.caption)
                }
                .padding(10)
                .background(theme.success.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
                .padding(.horizontal, 20)
                .padding(.top, 12)
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    switch store.tab {
                    case .benchmark: benchmarkTab
                    case .tune: tuneTab
                    case .reports: reportsTab
                    }
                }
                .padding(20)
            }
        }
    }

    private var benchmarkTab: some View {
        VStack(alignment: .leading, spacing: 14) {
            LXCard {
                VStack(alignment: .leading, spacing: 12) {
                    sectionTitle("可重复基准", icon: "gauge.with.dots.needle.50percent")
                    Text("每个采样点都来自真实启动的 Minecraft 进程。务必关闭其他大型应用；首次运行受磁盘缓存影响，暖机次数用于降低偏差。")
                        .font(LXFont.caption)
                        .foregroundStyle(theme.textSecondary)
                    HStack(spacing: 18) {
                        stepper("暖机次数", value: $store.options.warmupRuns, range: 0...5)
                        stepper("测量次数", value: $store.options.measuredRuns, range: 1...10)
                        VStack(alignment: .leading, spacing: 5) {
                            Text("超时（秒）").font(LXFont.captionStrong).foregroundStyle(theme.textTertiary)
                            TextField("180", value: $store.options.timeoutSeconds, format: .number)
                                .textFieldStyle(.roundedBorder)
                                .frame(width: 86)
                        }
                    }
                    HStack(spacing: 10) {
                        VStack(alignment: .leading, spacing: 5) {
                            Text("快速进入世界（可选）").font(LXFont.captionStrong).foregroundStyle(theme.textTertiary)
                            TextField("世界文件夹名，例如 World", text: $store.quickPlayWorld)
                                .textFieldStyle(.roundedBorder)
                                .frame(maxWidth: 360)
                        }
                        if !store.worlds.isEmpty {
                            Menu("选择世界") {
                                ForEach(store.worlds) { world in
                                    Button(world.name) { store.quickPlayWorld = world.name }
                                }
                            }
                            .menuStyle(.borderlessButton)
                        }
                    }
                    Text("指定世界后，Minecraft 会通过 quickPlay 进入该世界；世界加载证据来自日志中的 Preparing spawn area，不会伪造区块生成耗时。")
                        .font(LXFont.caption)
                        .foregroundStyle(theme.textTertiary)
                    HStack(spacing: 10) {
                        LXButton(store.isRunning ? "正在测试…" : "开始基准", systemImage: "play.fill", kind: .primary, isDisabled: store.isRunning) {
                            Task { await store.runBenchmark() }
                        }
                        if store.isRunning {
                            LXButton("取消", systemImage: "stop.fill", kind: .ghost) {
                                Task { await store.cancelBenchmark() }
                            }
                        }
                        if let report = store.latestReport {
                            LXButton("导出最新报告", systemImage: "square.and.arrow.up", kind: .secondary) {
                                reportToExport = report
                            }
                        }
                        Spacer()
                        Text(store.progressText)
                            .font(LXFont.caption)
                            .foregroundStyle(theme.textTertiary)
                    }
                }
            }
            if let report = store.latestReport {
                latestSummary(report)
            } else {
                LXEmptyState(
                    icon: "gauge",
                    title: "还没有基准报告",
                    message: "第一次运行会采集启动、资源加载、世界加载、CPU 与常驻内存；FPS 不会被伪造。"
                )
            }
        }
    }

    private func latestSummary(_ report: BenchmarkReport) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                sectionTitle("最新结果", icon: "chart.bar.xaxis")
                Spacer()
                Text(report.createdAt.formatted(date: .abbreviated, time: .shortened))
                    .font(LXFont.caption).foregroundStyle(theme.textTertiary)
            }
            HStack(spacing: 10) {
                metric("启动平均", PerformanceStore.seconds(report.aggregate.startupAverage), "timer")
                metric("世界加载", PerformanceStore.seconds(report.aggregate.worldLoadAverage), "globe")
                metric("CPU 平均", report.aggregate.cpuAverage.map { String(format: "%.1f%%", $0) } ?? "无数据", "cpu")
                metric("峰值 RSS", PerformanceStore.bytes(report.aggregate.residentPeakBytes), "memorychip")
                metric("FPS", "不可用", "questionmark.circle")
            }
            if let comparison = store.comparison {
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: "arrow.left.arrow.right").foregroundStyle(theme.info)
                    VStack(alignment: .leading, spacing: 4) {
                        Text("与上一份报告对比").font(LXFont.captionStrong)
                        Text(comparison.summary).font(LXFont.caption).foregroundStyle(theme.textSecondary)
                    }
                }
                .padding(10)
                .background(theme.info.opacity(0.07), in: RoundedRectangle(cornerRadius: 8))
            }
            if !report.notes.isEmpty {
                ForEach(report.notes, id: \.self) { note in
                    Label(note, systemImage: "info.circle")
                        .font(LXFont.caption)
                        .foregroundStyle(theme.textTertiary)
                }
            }
        }
        .padding(14)
        .background(theme.surface, in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(theme.border, lineWidth: 0.8))
    }

    private var tuneTab: some View {
        VStack(alignment: .leading, spacing: 14) {
            LXCard {
                VStack(alignment: .leading, spacing: 10) {
                    sectionTitle("安全调优建议", icon: "slider.horizontal.3")
                    Text("规则基于本机内存、当前堆、加载器、模组数量和最近基准；所有改动都需要确认，并先备份，再原子写入实例配置。")
                        .font(LXFont.caption).foregroundStyle(theme.textSecondary)
                    if let plan = store.plan {
                        HStack(spacing: 18) {
                            valueLine("当前堆", store.currentHeap.map { "\($0) MiB" } ?? "自动")
                            valueLine("建议堆", "\(plan.targetHeapMiB) MiB")
                            valueLine("风险", plan.recommendations.map(\.risk.displayName).joined(separator: " / "))
                        }
                        if let applied = store.appliedProfile {
                            Text("已应用：\(applied.heapMiB.map { "\($0) MiB" } ?? "自动堆") · \(applied.jvmArguments.joined(separator: " "))")
                                .font(LXFont.caption).foregroundStyle(theme.textTertiary)
                        }
                        ForEach(plan.recommendations) { recommendation in
                            recommendationRow(recommendation)
                        }
                        HStack {
                            LXButton("应用建议", systemImage: "checkmark.shield", kind: .primary, isDisabled: store.isApplying) {
                                store.showApplyConfirmation = true
                            }
                            if store.appliedProfile != nil {
                                LXButton("恢复上次设置", systemImage: "arrow.uturn.backward", kind: .ghost, isDisabled: store.isApplying) {
                                    store.showRestoreConfirmation = true
                                }
                            }
                            Spacer()
                            Text(plan.estimatedChange).font(LXFont.caption).foregroundStyle(theme.textTertiary)
                        }
                    } else {
                        ProgressView()
                    }
                }
            }
            LXCard {
                VStack(alignment: .leading, spacing: 6) {
                    sectionTitle("不会自动做的事", icon: "hand.raised")
                    Text("不修改 options.txt、渲染距离、分辨率、世界存档或模组文件；不承诺提升 FPS；不伪造 GPU/RTX 指标。")
                        .font(LXFont.caption).foregroundStyle(theme.textSecondary)
                }
            }
        }
    }

    private func recommendationRow(_ recommendation: PerformanceRecommendation) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: recommendation.risk == .low ? "checkmark.seal" : "exclamationmark.triangle")
                .foregroundStyle(recommendation.risk == .low ? theme.success : theme.warning)
                .padding(.top, 2)
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 7) {
                    Text(recommendation.title).font(LXFont.bodyStrong)
                    LXBadge(text: recommendation.risk.displayName, tone: recommendation.risk == .low ? .success : .warning)
                }
                Text(recommendation.summary).font(LXFont.caption).foregroundStyle(theme.textSecondary)
                Text(recommendation.rationale).font(LXFont.caption).foregroundStyle(theme.textTertiary)
                Text("预期：\(recommendation.expectedEffect)").font(LXFont.caption).foregroundStyle(theme.textTertiary)
                if !recommendation.jvmArguments.isEmpty {
                    Text(recommendation.jvmArguments.joined(separator: " "))
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(theme.textTertiary)
                }
            }
            Spacer()
        }
        .padding(10)
        .background(theme.surfaceRaised, in: RoundedRectangle(cornerRadius: 8))
    }

    private var reportsTab: some View {
        VStack(alignment: .leading, spacing: 14) {
            if store.reports.isEmpty {
                LXEmptyState(icon: "chart.xyaxis.line", title: "还没有历史报告", message: "完成一次基准测试后，这里会显示可对比的报告。")
            } else {
                LXCard {
                    VStack(alignment: .leading, spacing: 10) {
                        sectionTitle("A/B 对比", icon: "arrow.left.arrow.right")
                        if let comparison = store.comparison {
                            Text(comparison.summary).font(LXFont.body).foregroundStyle(theme.textSecondary)
                            HStack(spacing: 8) {
                                LXBadge(text: "胜出：\(comparison.winner)", tone: comparison.winner == "候选方案" ? .success : .neutral)
                                LXBadge(text: "置信：\(comparison.confidence.displayName)", tone: .info)
                            }
                        } else {
                            Text("至少需要两份报告才能做 A/B 对比。").font(LXFont.caption).foregroundStyle(theme.textTertiary)
                        }
                    }
                }
                ForEach(store.reports) { report in
                    HStack(spacing: 12) {
                        Image(systemName: "doc.text.magnifyingglass").foregroundStyle(theme.orange)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(report.createdAt.formatted(date: .abbreviated, time: .shortened)).font(LXFont.bodyStrong)
                            Text("启动 \(PerformanceStore.seconds(report.aggregate.startupAverage)) · 世界 \(PerformanceStore.seconds(report.aggregate.worldLoadAverage)) · \(report.options.measuredRuns) 次测量")
                                .font(LXFont.caption).foregroundStyle(theme.textSecondary)
                        }
                        Spacer()
                        Button("导出") { reportToExport = report }
                            .buttonStyle(.plain)
                            .font(LXFont.caption)
                    }
                    .padding(12)
                    .background(theme.surface, in: RoundedRectangle(cornerRadius: 9))
                    .overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(theme.border, lineWidth: 0.8))
                }
            }
        }
    }

    private func sectionTitle(_ title: String, icon: String) -> some View {
        Label(title, systemImage: icon)
            .font(LXFont.headline)
            .foregroundStyle(theme.text)
    }

    private func valueLine(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(label).font(LXFont.caption).foregroundStyle(theme.textTertiary)
            Text(value).font(LXFont.bodyStrong).foregroundStyle(theme.text)
        }
    }

    private func metric(_ label: String, _ value: String, _ icon: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Label(label, systemImage: icon).font(LXFont.caption).foregroundStyle(theme.textTertiary)
            Text(value).font(LXFont.mono).foregroundStyle(theme.text)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(9)
        .background(theme.surfaceRaised, in: RoundedRectangle(cornerRadius: 7))
    }

    private func stepper(_ label: String, value: Binding<Int>, range: ClosedRange<Int>) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(label).font(LXFont.captionStrong).foregroundStyle(theme.textTertiary)
            HStack(spacing: 6) {
                Text("\(value.wrappedValue)").font(LXFont.mono).frame(width: 22)
                Stepper("", value: value, in: range).labelsHidden()
            }
        }
    }

    private func saveReport() {
        guard let report = reportToExport else { return }
        let panel = NSSavePanel()
        panel.canCreateDirectories = true
        panel.nameFieldStringValue = "lingxi-benchmark-\(report.instanceID).json"
        panel.allowedContentTypes = [.json]
        if panel.runModal() == .OK, let url = panel.url {
            do { try store.export(report, to: url) }
            catch { store.errorMessage = PerformanceStore.describe(error) }
        }
        reportToExport = nil
    }
}
