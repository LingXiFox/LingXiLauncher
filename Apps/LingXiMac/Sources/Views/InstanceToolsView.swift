import AppKit
import LauncherCore
import SwiftUI
import UniformTypeIdentifiers

/// Instance maintenance: copy, integrity, world backups and crash diagnostics.
/// All reads and mutations go through LauncherCore; this view only coordinates user intent.
struct InstanceToolsView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.lxTheme) private var theme
    @EnvironmentObject private var model: AppModel

    let instance: Instance

    @State private var copyName = ""
    @State private var includeSaves = false
    @State private var working = false
    @State private var message: String?
    @State private var errorMessage: String?
    @State private var integrity: InstanceIntegrityReport?

    @State private var worlds: [MinecraftWorld] = []
    @State private var backups: [WorldBackupSummary] = []
    @State private var selectedWorld = ""
    @State private var pendingRestore: WorldBackupSummary?
    @State private var showRawLogs = false

    private var manager: WorldBackupManager {
        WorldBackupManager(layout: model.layout)
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().overlay(theme.border)
            tabBar
            Divider().overlay(theme.border)
            ScrollView {
                VStack(alignment: .leading, spacing: LXSpace.md) {
                    if let errorMessage {
                        LXErrorBanner(message: errorMessage) { self.errorMessage = nil }
                    }
                    if let message {
                        statusBanner(message)
                    }
                    switch model.instanceToolsTab {
                    case .manage: manageTab
                    case .worlds: worldsTab
                    case .diagnostics: diagnosticsTab
                    }
                }
                .padding(LXSpace.lg)
                .frame(maxWidth: 900, alignment: .leading)
            }
            .scrollIndicators(.never)
        }
        .frame(minWidth: 920, minHeight: 640)
        .background(theme.canvas)
        .task {
            copyName = copyName.isEmpty ? "\(instance.manifest.displayName) 副本" : copyName
            await reloadWorlds()
        }
        .sheet(isPresented: $showRawLogs) { rawLogsSheet }
        .confirmationDialog(
            "恢复这个存档备份？",
            isPresented: Binding(
                get: { pendingRestore != nil },
                set: { if !$0 { pendingRestore = nil } }
            ),
            presenting: pendingRestore
        ) { backup in
            Button("恢复 \(backup.worldName)", role: .destructive) {
                restore(backup)
            }
            Button("取消", role: .cancel) { pendingRestore = nil }
        } message: { backup in
            Text("现有存档会先暂存为恢复点；完整校验通过后才替换。备份时间：\(backup.createdAt.formatted(date: .abbreviated, time: .shortened))")
        }
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 14) {
            VStack(alignment: .leading, spacing: 3) {
                LXOverline(text: "INSTANCE TOOLS", color: theme.orange)
                Text(instance.manifest.displayName)
                    .font(LXFont.display(26))
                    .foregroundStyle(theme.text)
                Text("\(instance.id) · \(instance.gameDirectory.path)")
                    .font(LXFont.monoSmall)
                    .foregroundStyle(theme.textTertiary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer()
            LXButton("关闭", kind: .ghost) { dismiss() }
        }
        .padding(LXSpace.lg)
    }

    private var tabBar: some View {
        HStack(spacing: 4) {
            ForEach(AppModel.InstanceToolsTab.allCases) { tab in
                Button {
                    model.instanceToolsTab = tab
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: tab.icon).font(.system(size: 11, weight: .medium))
                        Text(tab.title).font(LXFont.bodyStrong)
                    }
                    .foregroundStyle(model.instanceToolsTab == tab ? theme.orange : theme.textSecondary)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(
                        model.instanceToolsTab == tab ? theme.orangeSoft : Color.clear,
                        in: RoundedRectangle(cornerRadius: 7, style: .continuous)
                    )
                }
                .buttonStyle(.plain)
            }
            Spacer()
        }
        .padding(.horizontal, LXSpace.lg)
        .padding(.vertical, 8)
    }

    private var manageTab: some View {
        VStack(alignment: .leading, spacing: LXSpace.md) {
            LXCard {
                VStack(alignment: .leading, spacing: 10) {
                    LXOverline(text: "INSTANCE INFORMATION")
                    LXKeyValue(label: "实例 ID", value: instance.id)
                    LXKeyValue(label: "Minecraft", value: instance.manifest.versionID ?? "未绑定")
                    LXKeyValue(label: "最近启动", value: instance.manifest.lastLaunchedAt?.formatted(date: .abbreviated, time: .shortened) ?? "尚未启动")
                    LXKeyValue(label: "游戏目录", value: instance.gameDirectory.path)
                }
            }

            LXCard {
                VStack(alignment: .leading, spacing: 12) {
                    LXOverline(text: "COPY INSTANCE")
                    Text("复制基础配置、Loader、JVM 参数和实例内的模组/光影/配置。全局 libraries 与 assets 继续共享，不复制缓存。")
                        .font(LXFont.caption)
                        .foregroundStyle(theme.textSecondary)
                    TextField("新实例名称", text: $copyName)
                        .lxInput()
                    Toggle("同时复制世界存档（saves）", isOn: $includeSaves)
                        .toggleStyle(.switch)
                        .font(LXFont.caption)
                    HStack {
                        LXButton("复制实例", systemImage: "square.on.square", kind: .primary, isDisabled: working || copyName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty) {
                            copyInstance()
                        }
                        Spacer()
                    }
                }
            }

            LXCard {
                VStack(alignment: .leading, spacing: 10) {
                    LXOverline(text: "INTEGRITY")
                    if let integrity {
                        if integrity.issues.isEmpty {
                            Label("未发现实例完整性风险", systemImage: "checkmark.seal.fill")
                                .font(LXFont.bodyStrong)
                                .foregroundStyle(theme.success)
                        } else {
                            ForEach(integrity.issues) { issue in
                                HStack(alignment: .top, spacing: 8) {
                                    Image(systemName: "exclamationmark.triangle.fill")
                                        .foregroundStyle(issue.severity == "error" ? theme.danger : theme.warning)
                                    Text(issue.message).font(LXFont.caption)
                                }
                            }
                        }
                    } else {
                        Text("检查实例目录、版本元数据和符号链接边界。")
                            .font(LXFont.caption)
                            .foregroundStyle(theme.textSecondary)
                    }
                    HStack {
                        LXButton("检查完整性", systemImage: "checkmark.shield", kind: .secondary, isDisabled: working) {
                            inspect()
                        }
                        LXButton("打开游戏目录", systemImage: "folder", kind: .ghost) {
                            model.openInstanceFolder(instance)
                        }
                        Spacer()
                    }
                }
            }
        }
    }

    private var worldsTab: some View {
        VStack(alignment: .leading, spacing: LXSpace.md) {
            LXCard {
                VStack(alignment: .leading, spacing: 10) {
                    LXOverline(text: "WORLD SAVES")
                    if worlds.isEmpty {
                        Text("没有找到可备份的世界存档。启动游戏创建世界后会显示在这里。")
                            .font(LXFont.caption)
                            .foregroundStyle(theme.textSecondary)
                    } else {
                        Picker("世界", selection: $selectedWorld) {
                            ForEach(worlds) { world in
                                Text("\(world.name) · \(ByteCountFormatter.string(fromByteCount: Int64(world.byteCount), countStyle: .file))")
                                    .tag(world.name)
                            }
                        }
                        .pickerStyle(.menu)
                        LXButton("创建备份", systemImage: "archivebox", kind: .primary, isDisabled: working || selectedWorld.isEmpty) {
                            createBackup()
                        }
                    }
                }
            }

            LXCard {
                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        LXOverline(text: "BACKUPS")
                        Spacer()
                        LXButton("刷新", systemImage: "arrow.clockwise", kind: .ghost) {
                            Task { await reloadWorlds() }
                        }
                    }
                    if backups.isEmpty {
                        Text("还没有备份。备份位于 dataRoot/backups/\(instance.id)，不会写入世界目录。")
                            .font(LXFont.caption)
                            .foregroundStyle(theme.textSecondary)
                    } else {
                        ForEach(backups) { backup in
                            HStack(alignment: .center, spacing: 10) {
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(backup.worldName).font(LXFont.bodyStrong)
                                    Text("\(backup.createdAt.formatted(date: .abbreviated, time: .shortened)) · \(backup.fileCount) 个文件 · \(ByteCountFormatter.string(fromByteCount: Int64(backup.totalBytes), countStyle: .file))")
                                        .font(LXFont.caption)
                                        .foregroundStyle(theme.textSecondary)
                                }
                                Spacer()
                                LXButton("恢复", kind: .secondary, isDisabled: working) {
                                    pendingRestore = backup
                                }
                                LXButton("删除", kind: .destructive, isDisabled: working) {
                                    delete(backup)
                                }
                            }
                            .padding(.vertical, 6)
                            if backup.id != backups.last?.id { LXDivider() }
                        }
                    }
                }
            }
        }
    }

    private var diagnosticsTab: some View {
        VStack(alignment: .leading, spacing: LXSpace.md) {
            if model.isDiagnosing {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("正在读取实例日志并分析…").font(LXFont.caption)
                }
            }
            if let error = model.crashReportError {
                LXErrorBanner(message: error) { model.crashReportError = nil }
            }
            if let report = model.crashReport {
                diagnosticSummary(report)
                ForEach(report.diagnostics) { diagnostic in
                    diagnosticCard(diagnostic, isRoot: diagnostic.id == report.rootCauseID)
                }
            } else {
                LXEmptyState(
                    icon: "stethoscope",
                    title: "尚无诊断结果",
                    message: "启动失败时会自动分析当前实例的日志；也可以手动重新诊断。"
                )
            }
            HStack(spacing: 8) {
                LXButton("重新诊断", systemImage: "arrow.clockwise", kind: .secondary, isDisabled: model.isDiagnosing) {
                    model.refreshCrashDiagnostics(instance: instance, exitCode: model.lastExit?.code)
                }
                LXButton("查看原始日志", systemImage: "doc.text", kind: .ghost, isDisabled: model.crashReport == nil) {
                    showRawLogs = true
                }
                LXButton("复制报告", systemImage: "doc.on.doc", kind: .ghost, isDisabled: model.crashReport == nil) {
                    if let report = model.crashReport {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(CrashReportExporter.markdown(for: report), forType: .string)
                        message = "诊断报告已复制"
                    }
                }
                LXButton("导出 Markdown", kind: .ghost, isDisabled: model.crashReport == nil) {
                    if let report = model.crashReport { model.exportCrashReport(report, markdown: true) }
                }
                LXButton("导出 JSON", kind: .ghost, isDisabled: model.crashReport == nil) {
                    if let report = model.crashReport { model.exportCrashReport(report, markdown: false) }
                }
                Spacer()
                LXButton("打开模组管理", systemImage: "puzzlepiece.extension", kind: .secondary) {
                    dismiss()
                    model.openMods(instance: instance)
                }
            }
        }
    }

    private func diagnosticSummary(_ report: CrashDiagnosticReport) -> some View {
        LXCard(accent: report.abnormalExit ? theme.warning : theme.success) {
            VStack(alignment: .leading, spacing: 7) {
                HStack {
                    Text(report.summary).font(LXFont.bodyStrong).foregroundStyle(theme.text)
                    Spacer()
                    LXBadge(text: report.abnormalExit ? "异常退出" : "正常退出", tone: report.abnormalExit ? .warning : .success)
                }
                Text("退出码 \(report.exitCode.map(String.init) ?? "未知") · 生成于 \(report.generatedAt.formatted(date: .abbreviated, time: .shortened))")
                    .font(LXFont.caption)
                    .foregroundStyle(theme.textSecondary)
                ForEach(report.logs) { log in
                    Text("• \(log.kind.displayName)：\(log.name)（\(ByteCountFormatter.string(fromByteCount: Int64(log.byteCount), countStyle: .file))）")
                        .font(LXFont.monoSmall)
                        .foregroundStyle(theme.textTertiary)
                }
            }
        }
    }

    private func diagnosticCard(_ diagnostic: CrashDiagnostic, isRoot: Bool) -> some View {
        LXCard(accent: isRoot ? theme.orange : nil) {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text(diagnostic.category.displayName).font(LXFont.bodyStrong)
                    LXBadge(text: "\(diagnostic.severity.rawValue) · \(diagnostic.confidence.rawValue)", tone: isRoot ? .warning : .neutral)
                    if isRoot { LXBadge(text: "根因", tone: .accent) }
                    if diagnostic.isSecondary { LXBadge(text: "连锁", tone: .neutral) }
                    Spacer()
                }
                Text(diagnostic.explanation).font(LXFont.caption).foregroundStyle(theme.textSecondary)
                if !diagnostic.affectedComponents.isEmpty {
                    Text("涉及：\(diagnostic.affectedComponents.joined(separator: "、"))")
                        .font(LXFont.caption)
                        .foregroundStyle(theme.textTertiary)
                }
                ForEach(Array(diagnostic.evidence.enumerated()), id: \.offset) { _, evidence in
                    Text("\(evidence.source)\(evidence.line.map { ":\($0)" } ?? "")  \(evidence.excerpt)")
                        .font(LXFont.monoSmall)
                        .foregroundStyle(theme.textTertiary)
                        .textSelection(.enabled)
                }
                if !diagnostic.recommendations.isEmpty {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("建议").font(LXFont.captionStrong).foregroundStyle(theme.textSecondary)
                        ForEach(diagnostic.recommendations, id: \.self) { item in
                            Text("• \(item)").font(LXFont.caption).foregroundStyle(theme.textSecondary)
                        }
                    }
                }
            }
        }
    }

    private var rawLogsSheet: some View {
        VStack(spacing: 0) {
            HStack {
                Text("原始日志").font(LXFont.display(22))
                Spacer()
                LXButton("关闭", kind: .ghost) { showRawLogs = false }
            }
            .padding(LXSpace.lg)
            Divider().overlay(theme.border)
            ScrollView {
                VStack(alignment: .leading, spacing: LXSpace.md) {
                    ForEach(Array((model.crashReport?.logTexts ?? []).enumerated()), id: \.offset) { _, log in
                        VStack(alignment: .leading, spacing: 4) {
                            Text("\(log.kind.displayName) · \(log.name)").font(LXFont.bodyStrong)
                            Text(log.text).font(LXFont.monoSmall).textSelection(.enabled)
                        }
                        .padding(LXSpace.md)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(theme.surfaceRaised, in: RoundedRectangle(cornerRadius: 8))
                    }
                }
                .padding(LXSpace.lg)
            }
        }
        .frame(minWidth: 820, minHeight: 560)
        .background(theme.canvas)
    }

    private func statusBanner(_ text: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "checkmark.circle.fill").foregroundStyle(theme.success)
            Text(text).font(LXFont.caption)
            Spacer()
        }
        .padding(LXSpace.md)
        .background(theme.success.opacity(0.10), in: RoundedRectangle(cornerRadius: 8))
    }

    private func copyInstance() {
        working = true
        errorMessage = nil
        message = nil
        do {
            let report = try InstanceCopyService(layout: model.layout).copy(
                instanceID: instance.id,
                displayName: copyName,
                options: InstanceCopyOptions(includeSaves: includeSaves)
            )
            model.reloadInstances()
            message = "已创建实例 \(report.instance.manifest.displayName)（\(report.instance.id)），复制 \(report.copiedPaths.count) 个路径。"
        } catch {
            errorMessage = Self.describe(error)
        }
        working = false
    }

    private func inspect() {
        working = true
        errorMessage = nil
        do {
            integrity = try InstanceCopyService(layout: model.layout).inspect(instanceID: instance.id)
        } catch {
            errorMessage = Self.describe(error)
        }
        working = false
    }

    private func reloadWorlds() async {
        do {
            let manager = self.manager
            worlds = try manager.listWorlds(instanceID: instance.id)
            backups = try manager.listBackups(instanceID: instance.id)
            if selectedWorld.isEmpty { selectedWorld = worlds.first?.name ?? "" }
        } catch {
            errorMessage = Self.describe(error)
        }
    }

    private func createBackup() {
        guard !selectedWorld.isEmpty else { return }
        working = true
        errorMessage = nil
        do {
            let backup = try manager.createBackup(instanceID: instance.id, worldName: selectedWorld)
            message = "已创建 \(backup.worldName) 的备份（\(backup.fileCount) 个文件）。"
            Task { await reloadWorlds() }
        } catch {
            errorMessage = Self.describe(error)
        }
        working = false
    }

    private func restore(_ backup: WorldBackupSummary) {
        pendingRestore = nil
        working = true
        errorMessage = nil
        do {
            _ = try manager.restore(instanceID: instance.id, backupID: backup.id)
            message = "已恢复世界 \(backup.worldName)，所有文件已通过 SHA-256 校验。"
            Task { await reloadWorlds() }
        } catch {
            errorMessage = Self.describe(error)
        }
        working = false
    }

    private func delete(_ backup: WorldBackupSummary) {
        working = true
        errorMessage = nil
        do {
            try manager.deleteBackup(instanceID: instance.id, backupID: backup.id)
            message = "已删除备份 \(backup.id)"
            Task { await reloadWorlds() }
        } catch {
            errorMessage = Self.describe(error)
        }
        working = false
    }

    private static func describe(_ error: Error) -> String {
        (error as? LauncherError)?.description ?? error.localizedDescription
    }
}
