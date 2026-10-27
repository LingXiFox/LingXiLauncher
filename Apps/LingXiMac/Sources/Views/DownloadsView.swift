import LauncherCore
import SwiftUI

struct DownloadsView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.lxTheme) private var theme
    @State private var selectedVersionID: String?

    private struct VersionRow: Identifiable {
        let id: String
        let entry: VersionManifest.Entry
    }

    private var versionRows: [VersionRow] {
        model.versionEntries.map { VersionRow(id: $0.id, entry: $0) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: LXSpace.md) {
            LXPageHeader(
                eyebrow: "LIBRARY / DOWNLOADS",
                title: "版本下载",
                subtitle: "从 Mojang 官方源或显式配置的可信镜像安装。所有文件都会校验。"
            ) {
                HStack(spacing: 8) {
                    if model.isLoadingVersions {
                        ProgressView().controlSize(.small).tint(theme.orange)
                    }
                    LXIconButton(systemImage: "arrow.clockwise", label: "刷新版本列表") {
                        Task { await model.loadVersions() }
                    }
                }
                .padding(.top, 3)
            }

            HStack(alignment: .top, spacing: LXSpace.md) {
                versionBrowser
                    .frame(width: 340)
                installPane
            }
        }
        .padding(.horizontal, LXSpace.xxl)
        .padding(.vertical, LXSpace.xl)
        .frame(maxWidth: 1240, maxHeight: .infinity, alignment: .topLeading)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(theme.canvas)
        .task {
            if model.versionEntries.isEmpty {
                await model.loadVersions()
            }
        }
        .onChange(of: model.versionFilter) { _, _ in
            selectedVersionID = nil
            Task { await model.loadVersions() }
        }
        .onChange(of: model.settings.sourceRaw) { _, _ in
            model.saveSettings()
            selectedVersionID = nil
            Task { await model.loadVersions() }
        }
    }

    private var versionBrowser: some View {
        VStack(alignment: .leading, spacing: LXSpace.sm) {
            HStack(spacing: 5) {
                ForEach(AppModel.VersionFilter.allCases) { filter in
                    LXChip(title: filter.title, isSelected: model.versionFilter == filter) {
                        model.versionFilter = filter
                    }
                }
                Spacer()
                Menu {
                    ForEach(DownloadSourcePolicy.allCases, id: \.self) { policy in
                        Button(policy.displayName) {
                            model.settings.source = policy
                        }
                    }
                } label: {
                    HStack(spacing: 4) {
                        Text(model.settings.source.displayName)
                            .font(LXFont.captionStrong)
                        Image(systemName: "chevron.down")
                            .font(.system(size: 8, weight: .semibold))
                    }
                    .foregroundStyle(theme.textSecondary)
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
            }
            .padding(.horizontal, 2)

            LXCard(padding: 0) {
                if model.versionEntries.isEmpty {
                    LXEmptyState(
                        icon: "arrow.down.circle",
                        title: model.isLoadingVersions ? "正在获取版本列表…" : "没有版本",
                        message: "切换类型或下载源后刷新；官方清单会缓存到 dataRoot/cache。"
                    )
                    .frame(height: 280)
                } else {
                    ScrollView {
                        LazyVStack(spacing: 0) {
                            ForEach(versionRows) { row in
                                VersionListRow(
                                    row: row.entry,
                                    selected: selectedVersionID == row.id,
                                    onSelect: { selectedVersionID = row.id }
                                )
                                if row.id != versionRows.last?.id {
                                    LXDivider().padding(.leading, 14)
                                }
                            }
                        }
                        .padding(.vertical, 4)
                    }
                    .scrollIndicators(.never)
                }
            }
        }
    }

    private var installPane: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: LXSpace.md) {
                targetCard
                installCard
                progressCard
                sourceCard
            }
            .frame(maxWidth: 760, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .scrollIndicators(.never)
    }

    private var targetCard: some View {
        LXCard(padding: LXSpace.md) {
            VStack(alignment: .leading, spacing: 8) {
                LXOverline(text: "TARGET INSTANCE", color: theme.textSecondary)
                if let instance = model.selectedInstance {
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(instance.manifest.displayName)
                                .font(LXFont.headline)
                                .foregroundStyle(theme.text)
                            Text("安装会更新该实例绑定的版本，不会删除世界。")
                                .font(LXFont.caption)
                                .foregroundStyle(theme.textTertiary)
                        }
                        Spacer()
                        LXBadge(text: "已有实例", tone: .neutral)
                    }
                } else {
                    Text("未选择实例；安装时会创建 `vanilla-<version>` 实例。")
                        .font(LXFont.body)
                        .foregroundStyle(theme.textSecondary)
                }
            }
        }
    }

    private var installCard: some View {
        LXCard(padding: LXSpace.md) {
            VStack(alignment: .leading, spacing: LXSpace.sm) {
                LXOverline(text: "INSTALL", color: theme.textSecondary)
                if let selectedVersionID {
                    HStack(alignment: .firstTextBaseline) {
                        Text(selectedVersionID)
                            .font(.system(size: 25, weight: .bold, design: .rounded))
                            .foregroundStyle(theme.text)
                        Spacer()
                        LXBadge(text: model.settings.source.displayName, tone: .info)
                    }
                } else {
                    Text("从左侧列表选择一个 Minecraft 版本。")
                        .font(LXFont.body)
                        .foregroundStyle(theme.textSecondary)
                }
                HStack(spacing: 8) {
                    LXButton("安装", systemImage: "arrow.down.circle", kind: .primary, isDisabled: selectedVersionID == nil || model.installState.isRunning) {
                        if let selectedVersionID { model.installVersion(selectedVersionID) }
                    }
                    if model.installState.isRunning {
                        LXButton("取消下载", systemImage: "xmark", kind: .destructive) {
                            model.cancelInstall()
                        }
                    }
                    Spacer()
                }
            }
        }
    }

    private var progressCard: some View {
        LXCard(padding: LXSpace.md, elevated: true) {
            VStack(alignment: .leading, spacing: LXSpace.sm) {
                HStack {
                    LXOverline(text: "DOWNLOAD PROGRESS", color: theme.textSecondary)
                    Spacer()
                    if model.installState.isRunning {
                        LXBadge(text: "进行中", tone: .accent, dot: true)
                    } else if model.installState.cancelled {
                        LXBadge(text: "已取消", tone: .warning)
                    } else if model.installState.finished {
                        LXBadge(text: "完成", tone: .success, icon: "checkmark")
                    } else {
                        LXBadge(text: "空闲", tone: .neutral)
                    }
                }

                Text(model.installState.phase)
                    .font(LXFont.headline)
                    .foregroundStyle(theme.text)
                    .lineLimit(2)

                LXProgressBar(fraction: model.installState.fraction, height: 7)
                    .padding(.top, 2)

                HStack(spacing: LXSpace.lg) {
                    progressMetric("速度", speedText)
                    progressMetric("已下载", "\(compactBytes(model.installState.bytes)) / \(compactBytes(model.installState.totalBytes))")
                    progressMetric("文件", model.installState.total > 0 ? "\(model.installState.completed) / \(model.installState.total)" : "—")
                }

                if let file = model.installState.currentFile {
                    HStack(spacing: 6) {
                        Image(systemName: "doc.fill")
                            .font(.system(size: 9))
                        Text(file)
                            .font(LXFont.monoSmall)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    .foregroundStyle(theme.textTertiary)
                }

                if let error = model.installState.error {
                    Text(error)
                        .font(LXFont.caption)
                        .foregroundStyle(theme.danger)
                        .textSelection(.enabled)
                }
                if let verify = model.installState.verifyMessage {
                    HStack(spacing: 6) {
                        Image(systemName: verify.contains("通过") ? "checkmark.seal.fill" : "exclamationmark.triangle.fill")
                        Text(verify)
                    }
                    .font(LXFont.captionStrong)
                    .foregroundStyle(verify.contains("通过") ? theme.success : theme.warning)
                }
            }
        }
    }

    private var sourceCard: some View {
        LXCard(padding: LXSpace.md) {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: "lock.shield")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(theme.info)
                    .padding(.top, 1)
                VStack(alignment: .leading, spacing: 3) {
                    Text("下载源：\(model.settings.source.displayName)")
                        .font(LXFont.bodyStrong)
                        .foregroundStyle(theme.text)
                    Text("官方源不重写 URL；镜像必须提供显式 HTTPS host 映射。所有下载都校验 SHA-1 与大小。")
                        .font(LXFont.caption)
                        .foregroundStyle(theme.textTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    private var speedText: String {
        guard model.installState.bytesPerSecond > 0 else { return "—" }
        return "\(compactBytes(Int(model.installState.bytesPerSecond)))/s"
    }

    private func compactBytes(_ bytes: Int) -> String {
        let value = max(0, bytes)
        if value < 1024 { return "\(value) B" }
        let units = ["KB", "MB", "GB", "TB"]
        var amount = Double(value)
        var unit = 0
        while amount >= 1024 && unit < units.count - 1 {
            amount /= 1024
            unit += 1
        }
        return String(format: amount >= 100 ? "%.0f %@" : "%.1f %@", amount, units[unit])
    }

    private func progressMetric(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label)
                .font(LXFont.caption)
                .foregroundStyle(theme.textTertiary)
            Text(value)
                .font(LXFont.monoSmall)
                .foregroundStyle(theme.textSecondary)
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct VersionListRow: View {
    @Environment(\.lxTheme) private var theme
    @State private var hovering = false

    let row: VersionManifest.Entry
    let selected: Bool
    let onSelect: () -> Void

    var body: some View {
        Button(action: onSelect) {
            HStack(spacing: 10) {
                RoundedRectangle(cornerRadius: 2)
                    .fill(row.type == .release ? theme.orange : theme.textTertiary)
                    .frame(width: 3, height: 25)
                    .opacity(selected ? 1 : 0.35)
                VStack(alignment: .leading, spacing: 2) {
                    Text(row.id)
                        .font(LXFont.bodyStrong)
                        .foregroundStyle(theme.text)
                        .lineLimit(1)
                    Text(shortDate(row.releaseTime))
                        .font(LXFont.monoSmall)
                        .foregroundStyle(theme.textTertiary)
                }
                Spacer()
                LXBadge(text: row.type.rawValue, tone: row.type == .release ? .accent : .neutral)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .background(
                selected
                    ? theme.orangeSoft
                    : (hovering ? theme.surfaceHover : .clear)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.12), value: hovering)
        .accessibilityLabel("\(row.id)，\(row.type.rawValue)")
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private func shortDate(_ raw: String?) -> String {
        guard let raw, raw.count >= 10 else { return raw ?? "" }
        return String(raw.prefix(10))
    }
}
