import SwiftUI
import LauncherCore

/// Review and apply a Modrinth `.mrpack` update. The plan is built from the actual target
/// archive, not from version metadata, and the user can explicitly preserve local changes.
struct ModpackUpdateView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.lxTheme) private var theme

    let instance: Instance
    let manager: ModpackUpdateManager

    @State private var current: ModpackRecord?
    @State private var target: ModrinthVersion?
    @State private var plan: ModpackUpdatePlan?
    @State private var actions: [String: ModpackUpdateAction] = [:]
    @State private var loading = false
    @State private var applying = false
    @State private var pending = false
    @State private var error: String?
    @State private var status: String?
    @State private var confirmApply = false

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().overlay(theme.border)
            ScrollView {
                VStack(alignment: .leading, spacing: LXSpace.lg) {
                    if let error {
                        LXErrorBanner(message: error, dismiss: {})
                    }
                    if let status {
                        notice(status)
                    }
                    if pending {
                        recoveryCard
                    } else if loading {
                        ProgressView("正在检查整合包版本…")
                            .frame(maxWidth: .infinity, minHeight: 180)
                    } else if let plan {
                        planView(plan)
                    } else {
                        LXCard {
                            LXEmptyState(
                                icon: "checkmark.seal",
                                title: "没有可用更新",
                                message: "当前整合包已是可用的最新稳定版本。"
                            )
                        }
                    }
                }
                .padding(LXSpace.xxl)
                .frame(maxWidth: 1000)
                .frame(maxWidth: .infinity)
            }
            Divider().overlay(theme.border)
            footer
        }
        .frame(minWidth: 760, minHeight: 560)
        .background(theme.canvas)
        .task { await load() }
        .confirmationDialog("应用整合包更新？", isPresented: $confirmApply, titleVisibility: .visible) {
            Button("确认更新", role: .destructive) { Task { await apply() } }
            Button("取消", role: .cancel) {}
        } message: {
            Text("更新会修改实例文件；本地修改和未知文件默认保留。任何失败都会回滚。")
        }
    }

    private var header: some View {
        HStack(spacing: LXSpace.md) {
            ZStack {
                RoundedRectangle(cornerRadius: LXRadius.md, style: .continuous)
                    .fill(theme.orangeSoft)
                Image(systemName: "shippingbox.and.arrow.backward")
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(theme.orange)
            }
            .frame(width: 42, height: 42)
            VStack(alignment: .leading, spacing: 3) {
                Text("整合包更新")
                    .font(LXFont.title())
                    .foregroundStyle(theme.text)
                Text(instance.manifest.displayName)
                    .font(LXFont.caption)
                    .foregroundStyle(theme.textSecondary)
            }
            Spacer()
            LXIconButton(systemImage: "xmark", label: "关闭") { dismiss() }
        }
        .padding(.horizontal, LXSpace.xxl)
        .padding(.vertical, LXSpace.lg)
    }

    private var footer: some View {
        HStack {
            if let current {
                Text("当前包版本 \(current.packVersionID ?? current.versionID)")
                    .font(LXFont.caption)
                    .foregroundStyle(theme.textSecondary)
            }
            Spacer()
            LXButton("关闭", kind: .ghost) { dismiss() }
            if plan != nil {
                LXButton("应用更新", systemImage: "arrow.down.circle", kind: .primary, isDisabled: applying) {
                    confirmApply = true
                }
            }
        }
        .padding(.horizontal, LXSpace.xxl)
        .padding(.vertical, LXSpace.md)
    }

    private var recoveryCard: some View {
        LXCard(accent: theme.warning) {
            VStack(alignment: .leading, spacing: LXSpace.md) {
                Text("检测到未完成的更新")
                    .font(LXFont.headline)
                    .foregroundStyle(theme.text)
                Text("上次更新在提交前中断。恢复会从事务备份还原实例文件，不会删除已完成的其他实例数据。")
                    .font(LXFont.body)
                    .foregroundStyle(theme.textSecondary)
                LXButton("恢复上次状态", systemImage: "arrow.uturn.backward", kind: .secondary) {
                    recover()
                }
            }
        }
    }

    @ViewBuilder
    private func planView(_ plan: ModpackUpdatePlan) -> some View {
        LXCard {
            VStack(alignment: .leading, spacing: LXSpace.md) {
                HStack {
                    Text("版本 \(plan.currentVersionID) → \(plan.targetVersionNumber)")
                        .font(LXFont.headline)
                        .foregroundStyle(theme.text)
                    Spacer()
                    LXBadge(text: "\(plan.changes.count) 项文件变更", tone: .info)
                }
                Text("目标 Minecraft \(plan.targetMinecraftVersion) · \(plan.targetLoaderKind)\(plan.targetLoaderVersion.map { " \($0)" } ?? "")")
                    .font(LXFont.caption)
                    .foregroundStyle(theme.textSecondary)
                if plan.requiresMinecraftChange || plan.requiresLoaderChange {
                    LXErrorBanner(message: "该版本需要切换 Minecraft 或 Loader；当前界面不会自动更换实例运行时，请先创建兼容实例。", dismiss: {})
                }
                HStack(spacing: LXSpace.lg) {
                    stat("新增", plan.changes.filter { $0.kind == .added }.count)
                    stat("更新", plan.changes.filter { $0.kind == .upgraded }.count)
                    stat("移除", plan.changes.filter { $0.kind == .removed }.count)
                    stat("保留", plan.changes.filter { $0.kind == .userModified || $0.kind == .conflict }.count)
                }
            }
        }

        LXCard(padding: LXSpace.md) {
            VStack(alignment: .leading, spacing: 0) {
                HStack {
                    Text("文件差异").font(LXFont.captionStrong).foregroundStyle(theme.textSecondary)
                    Spacer()
                    Text("下载 \(ByteCountFormatter.string(fromByteCount: Int64(plan.totalDownloadBytes), countStyle: .file))")
                        .font(LXFont.caption).foregroundStyle(theme.textTertiary)
                }
                .padding(.vertical, LXSpace.sm)
                ForEach(plan.changes, id: \.path) { change in
                    changeRow(change)
                    Divider().overlay(theme.border.opacity(0.6))
                }
            }
        }
    }

    private func changeRow(_ change: ModpackUpdateFileChange) -> some View {
        HStack(spacing: LXSpace.md) {
            Image(systemName: icon(for: change.kind))
                .foregroundStyle(color(for: change.kind))
                .frame(width: 18)
            VStack(alignment: .leading, spacing: 2) {
                Text(change.path)
                    .font(LXFont.monoSmall)
                    .foregroundStyle(theme.text)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(change.reason)
                    .font(LXFont.caption)
                    .foregroundStyle(theme.textTertiary)
            }
            Spacer()
            if change.kind == .userModified || change.kind == .conflict {
                Picker("", selection: actionBinding(for: change)) {
                    Text("保留本地").tag(ModpackUpdateAction.preserve)
                    Text("用包内文件替换").tag(ModpackUpdateAction.replace)
                    Text("跳过").tag(ModpackUpdateAction.skip)
                }
                .labelsHidden()
                .frame(width: 145)
            } else {
                LXBadge(text: kindLabel(change.kind), tone: tone(for: change.kind))
            }
        }
        .padding(.vertical, 7)
    }

    private func actionBinding(for change: ModpackUpdateFileChange) -> Binding<ModpackUpdateAction> {
        Binding(
            get: { actions[change.path] ?? defaultAction(for: change) },
            set: { actions[change.path] = $0 }
        )
    }

    private func defaultAction(for change: ModpackUpdateFileChange) -> ModpackUpdateAction {
        switch change.kind {
        case .userModified, .conflict: return .preserve
        case .removed, .added, .upgraded, .unchanged: return .replace
        }
    }

    private func stat(_ label: String, _ value: Int) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text("\(value)").font(LXFont.headline).foregroundStyle(theme.text)
            Text(label).font(LXFont.caption).foregroundStyle(theme.textTertiary)
        }
    }

    private func notice(_ text: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "checkmark.circle.fill").foregroundStyle(theme.success)
            Text(text).font(LXFont.body).foregroundStyle(theme.text)
            Spacer()
        }
        .padding(LXSpace.md)
        .background(theme.success.opacity(0.10), in: RoundedRectangle(cornerRadius: LXRadius.md))
    }

    private func icon(for kind: ModpackFileChange.Kind) -> String {
        switch kind {
        case .added: return "plus.circle.fill"
        case .removed: return "minus.circle.fill"
        case .upgraded: return "arrow.up.circle.fill"
        case .unchanged: return "equal.circle"
        case .userModified: return "pencil.circle.fill"
        case .conflict: return "exclamationmark.triangle.fill"
        }
    }

    private func color(for kind: ModpackFileChange.Kind) -> Color {
        switch kind {
        case .added, .upgraded: return theme.success
        case .removed: return theme.danger
        case .userModified: return theme.info
        case .conflict: return theme.danger
        case .unchanged: return theme.textTertiary
        }
    }

    private func tone(for kind: ModpackFileChange.Kind) -> LXBadgeTone {
        switch kind {
        case .added, .upgraded: return .success
        case .removed, .conflict: return .danger
        case .userModified: return .warning
        case .unchanged: return .neutral
        }
    }

    private func kindLabel(_ kind: ModpackFileChange.Kind) -> String {
        switch kind {
        case .added: return "新增"
        case .removed: return "移除"
        case .upgraded: return "更新"
        case .unchanged: return "未变"
        case .userModified: return "本地修改"
        case .conflict: return "冲突"
        }
    }

    @MainActor
    private func load() async {
        loading = true
        error = nil
        status = nil
        pending = manager.pendingTransaction(instanceID: instance.id)
        guard !pending else { loading = false; return }
        do {
            current = try manager.record(instanceID: instance.id)
            guard let latest = try await manager.latestUpdate(instanceID: instance.id) else {
                loading = false
                return
            }
            target = latest
            let value = try await manager.preview(instanceID: instance.id, targetVersionID: latest.id)
            plan = value
            for change in value.changes where change.kind == .userModified || change.kind == .conflict {
                actions[change.path] = .preserve
            }
        } catch {
            self.error = error.localizedDescription
        }
        loading = false
    }

    private func recover() {
        do {
            try manager.recover(instanceID: instance.id)
            pending = false
            status = "已恢复上次更新前的状态。"
            Task { await load() }
        } catch {
            self.error = error.localizedDescription
        }
    }

    @MainActor
    private func apply() async {
        guard let target else { return }
        applying = true
        error = nil
        do {
            let report = try await manager.apply(
                instanceID: instance.id,
                targetVersionID: target.id,
                actions: actions
            )
            status = "已应用 \(report.applied.count) 项变更，保留 \(report.preserved.count) 项，移除 \(report.removed.count) 项。"
            plan = nil
            current = try manager.record(instanceID: instance.id)
        } catch {
            self.error = error.localizedDescription
        }
        applying = false
    }
}
