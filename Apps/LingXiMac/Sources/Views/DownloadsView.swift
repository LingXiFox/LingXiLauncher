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
                    LXButton("安装向导", systemImage: "wand.and.stars", kind: .primary) {
                        model.installWizardInitialVersion = selectedVersionID
                        model.showInstallWizard = true
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
                wizardCard
                sourceCard
            }
            .frame(maxWidth: 760, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .scrollIndicators(.never)
    }

    private var wizardCard: some View {
        LXCard(padding: LXSpace.lg, elevated: true, accent: theme.orange) {
            VStack(alignment: .leading, spacing: LXSpace.md) {
                LXOverline(text: "ONE-STOP INSTALL", color: theme.orange)
                Text("从版本到启动，一次完成")
                    .font(LXFont.title(23))
                    .foregroundStyle(theme.text)
                Text("安装 Minecraft、选择 Vanilla、Fabric 或 NeoForge、检测/下载 Java，并明确创建新实例或更新现有实例。")
                    .font(LXFont.body)
                    .foregroundStyle(theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                VStack(alignment: .leading, spacing: 6) {
                    wizardPoint("自动读取版本元数据与 Java 要求", icon: "cpu")
                    wizardPoint("Fabric / NeoForge 官方 Loader 与 Maven 依赖", icon: "square.stack.3d.up")
                    wizardPoint("失败/取消不修改目标实例", icon: "shield.checkered")
                }
                if let selectedVersionID {
                    HStack(spacing: 6) {
                        Image(systemName: "checkmark.circle.fill").foregroundStyle(theme.success)
                        Text("已选择 Minecraft \(selectedVersionID)，可在向导中确认")
                            .font(LXFont.caption)
                            .foregroundStyle(theme.textSecondary)
                    }
                }
                LXButton("打开安装向导", systemImage: "arrow.right", kind: .primary, isFullWidth: true) {
                    model.installWizardInitialVersion = selectedVersionID
                    model.showInstallWizard = true
                }
            }
        }
    }

    private func wizardPoint(_ text: String, icon: String) -> some View {
        HStack(spacing: 7) {
            Image(systemName: icon)
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(theme.orange)
                .frame(width: 16)
            Text(text)
                .font(LXFont.caption)
                .foregroundStyle(theme.textSecondary)
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
