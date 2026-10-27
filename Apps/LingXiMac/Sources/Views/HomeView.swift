import LauncherCore
import SwiftUI

struct HomeView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.lxTheme) private var theme

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: LXSpace.lg) {
                header
                mainGrid
                infoGrid
                footerNote
            }
            .padding(.horizontal, LXSpace.xxl)
            .padding(.vertical, LXSpace.xl)
            .frame(maxWidth: 1240, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .center)
        }
        .background(theme.canvas)
        .scrollIndicators(.never)
    }

    private var header: some View {
        LXPageHeader(
            eyebrow: "PLAY / LAUNCHPAD",
            title: "准备好出发了吗？",
            subtitle: "当前实例、账户与运行环境都在这里。按下启动，剩下的交给本狐。"
        ) {
            HStack(spacing: 8) {
                LXBadge(
                    text: model.isGameRunning ? "游戏运行中" : "环境就绪",
                    tone: model.isGameRunning ? .success : .accent,
                    dot: true
                )
                if let pid = model.gamePID {
                    Text("PID \(pid)")
                        .font(LXFont.monoSmall)
                        .foregroundStyle(theme.textTertiary)
                }
            }
            .padding(.top, 4)
        }
    }

    private var mainGrid: some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .top, spacing: LXSpace.md) {
                InstanceHeroCard()
                    .frame(minWidth: 520, maxWidth: .infinity)
                AccountPanel()
                    .frame(width: 302)
            }
            VStack(spacing: LXSpace.md) {
                InstanceHeroCard()
                AccountPanel()
            }
        }
    }

    private var infoGrid: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: LXSpace.md) {
                javaCard
                memoryCard
                recentCard
            }
            VStack(spacing: LXSpace.sm) {
                javaCard
                memoryCard
                recentCard
            }
        }
    }

    private var javaCard: some View {
        HomeInfoCard(
            overline: "JAVA RUNTIME",
            icon: "terminal.fill",
            title: model.selectedJavaRuntime?.displayDescription ?? "未选择 Java",
            detail: model.selectedJavaRuntime.map { shortPath($0.executable.path) } ?? "在设置中检测或选择运行时",
            tone: model.selectedJavaRuntime == nil ? .warning : .neutral
        ) {
            model.section = .settings
        }
    }

    private var memoryCard: some View {
        HomeInfoCard(
            overline: "MEMORY",
            icon: "memorychip.fill",
            title: model.selectedInstance?.manifest.memoryMiB.map { "\($0) MiB · 手动" } ?? "自动 · \(InstanceMemory.automaticMiB()) MiB",
            detail: model.selectedInstance == nil ? "创建实例后自动按物理内存选择堆上限" : "自动分配会解析为具体 -Xmx；可改为手动",
            tone: model.selectedInstance?.manifest.memoryMiB == nil ? .info : .accent
        ) {
            model.section = .instances
        }
    }

    private var recentCard: some View {
        HomeInfoCard(
            overline: "LAST LAUNCH",
            icon: "clock.arrow.circlepath",
            title: recentTitle,
            detail: recentDetail,
            tone: recentTone
        ) {
            model.section = .logs
        }
    }

    private var recentTitle: String {
        if let exit = model.lastExit {
            return exit.isSuccess ? "正常退出 · 0" : "异常退出 · \(exit.code)"
        }
        if model.lastLaunchAt != nil { return "正在启动…" }
        if let last = model.selectedInstance?.manifest.lastLaunchedAt {
            return "上次启动 · \(last.formatted(date: .abbreviated, time: .shortened))"
        }
        return "还没有启动记录"
    }

    private var recentDetail: String {
        if let last = model.selectedInstance?.manifest.lastLaunchedAt, model.lastLaunchAt == nil {
            return "\(model.selectedInstance?.manifest.lastIdentityMode?.rawValue ?? "上次会话") · 退出码未缓存"
        }
        guard let date = model.lastLaunchAt else {
            return "完成一次启动后，这里会记录结果"
        }
        let time = date.formatted(date: .abbreviated, time: .shortened)
        if let exit = model.lastExit {
            return "\(time) · \(exit.reason.rawValue)"
        }
        return time
    }

    private var recentTone: LXBadgeTone {
        guard let exit = model.lastExit else {
            return model.selectedInstance?.manifest.lastLaunchedAt == nil ? .neutral : .info
        }
        return exit.isSuccess ? .success : .danger
    }

    private var footerNote: some View {
        HStack(spacing: 8) {
            Image(systemName: "checkmark.shield")
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(theme.success)
            Text("正版会话由 Microsoft 提供 · 本地离线身份仅在 CLI 技术验证中可用")
                .font(LXFont.caption)
                .foregroundStyle(theme.textTertiary)
            Spacer()
            Button("查看运行日志") {
                model.section = .logs
            }
            .buttonStyle(.plain)
            .font(LXFont.captionStrong)
            .foregroundStyle(theme.orange)
        }
        .padding(.top, 2)
    }

    private func shortPath(_ path: String) -> String {
        let parts = path.split(separator: "/")
        guard parts.count > 3 else { return path }
        return "…/" + parts.suffix(3).joined(separator: "/")
    }
}

// MARK: - Hero

private struct InstanceHeroCard: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.lxTheme) private var theme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack(alignment: .topLeading) {
            RoundedRectangle(cornerRadius: LXRadius.xl, style: .continuous)
                .fill(theme.surface)
            HeroPattern()
                .clipShape(RoundedRectangle(cornerRadius: LXRadius.xl, style: .continuous))
                .allowsHitTesting(false)
            content
        }
        .overlay(
            RoundedRectangle(cornerRadius: LXRadius.xl, style: .continuous)
                .strokeBorder(theme.border, lineWidth: 1)
        )
        .shadow(color: theme.shadow, radius: 20, x: 0, y: 10)
        .clipShape(RoundedRectangle(cornerRadius: LXRadius.xl, style: .continuous))
        .accessibilityElement(children: .contain)
    }

    @ViewBuilder
    private var content: some View {
        if let instance = model.selectedInstance {
            loadedContent(instance)
        } else {
            emptyContent
        }
    }

    private func loadedContent(_ instance: Instance) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 5) {
                    HStack(spacing: 7) {
                        Circle()
                            .fill(model.isGameRunning ? theme.success : theme.orange)
                            .frame(width: 6, height: 6)
                        LXOverline(text: "CURRENT INSTANCE", color: theme.textSecondary)
                    }
                    Text(instance.manifest.displayName)
                        .font(LXFont.display(32))
                        .foregroundStyle(theme.text)
                        .lineLimit(1)
                        .minimumScaleFactor(0.75)
                    Text(instance.id)
                        .font(LXFont.monoSmall)
                        .foregroundStyle(theme.textTertiary)
                        .textSelection(.enabled)
                }
                Spacer(minLength: 12)
                VStack(alignment: .trailing, spacing: 7) {
                    LXBadge(
                        text: model.isGameRunning ? "RUNNING" : "READY",
                        tone: model.isGameRunning ? .success : .accent,
                        dot: true
                    )
                    Text(instance.manifest.versionID ?? "—")
                        .font(.system(size: 22, weight: .bold, design: .rounded))
                        .foregroundStyle(theme.text.opacity(0.16))
                        .lineLimit(1)
                }
            }
            .padding(.horizontal, LXSpace.xl)
            .padding(.top, LXSpace.xl)

            HStack(spacing: 7) {
                heroTag(instance.manifest.versionID ?? "未指定版本", icon: "cube.fill")
                heroTag("Vanilla", icon: "shippingbox.fill")
                if let memory = instance.manifest.memoryMiB {
                    heroTag("\(memory) MiB", icon: "memorychip")
                } else {
                    heroTag("自动 · \(InstanceMemory.automaticMiB()) MiB", icon: "memorychip")
                }
            }
            .padding(.horizontal, LXSpace.xl)
            .padding(.top, LXSpace.md)

            HStack(spacing: 7) {
                Image(systemName: model.activeMicrosoftAccount == nil ? "exclamationmark.shield" : "checkmark.shield.fill")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(model.activeMicrosoftAccount == nil ? theme.warning : theme.success)
                Text(model.activeMicrosoftAccount == nil ? "尚未连接 Microsoft 会话" : "Microsoft 会话已连接 · 启动时刷新")
                    .font(LXFont.caption)
                    .foregroundStyle(theme.textTertiary)
                Spacer()
                if let last = instance.manifest.lastLaunchedAt {
                    Text("上次启动 \(last.formatted(date: .abbreviated, time: .shortened))")
                        .font(LXFont.caption)
                        .foregroundStyle(theme.textTertiary.opacity(0.8))
                        .lineLimit(1)
                }
            }
            .padding(.horizontal, LXSpace.xl)
            .padding(.top, LXSpace.sm)

            Spacer(minLength: LXSpace.md)

            VStack(alignment: .leading, spacing: LXSpace.md) {
                LXDivider()
                HStack(alignment: .center, spacing: LXSpace.md) {
                    if model.isGameRunning {
                        LXButton("停止游戏", systemImage: "stop.fill", kind: .destructive) {
                            model.stopGame()
                        }
                    } else {
                        LXButton("启动 Minecraft", systemImage: "play.fill", kind: .primary) {
                            model.launchSelectedInstance()
                        }
                        .keyboardShortcut(.return, modifiers: [.command])
                        .disabled(!canLaunch(instance))
                        .opacity(canLaunch(instance) ? 1 : 0.55)
                    }

                    VStack(alignment: .leading, spacing: 3) {
                        Text(model.isGameRunning ? "游戏进程正在运行" : canLaunch(instance) ? "Java 与文件会在启动前校验" : readinessHint(instance))
                            .font(LXFont.bodyStrong)
                            .foregroundStyle(model.isGameRunning ? theme.success : canLaunch(instance) ? theme.textSecondary : theme.warning)
                        Text(model.isGameRunning ? "PID \(model.gamePID.map(String.init) ?? "—") · 退出后将记录结果" : "\(instance.manifest.versionID ?? "—") · Vanilla · \(model.selectedJavaRuntime?.displayDescription ?? "Java 未选择")")
                            .font(LXFont.caption)
                            .foregroundStyle(theme.textTertiary)
                            .lineLimit(1)
                    }
                    Spacer(minLength: 4)
                    LXIconButton(systemImage: "folder", label: "打开实例文件夹") {
                        model.openInstanceFolder(instance)
                    }
                }
            }
            .padding(.horizontal, LXSpace.xl)
            .padding(.bottom, LXSpace.xl)
        }
    }

    private var emptyContent: some View {
        VStack(alignment: .leading, spacing: LXSpace.md) {
            HStack {
                LXOverline(text: "CURRENT INSTANCE", color: theme.textSecondary)
                Spacer()
                LXBadge(text: "NO INSTANCE", tone: .neutral, dot: true)
            }
            Text("还没有可启动的实例")
                .font(LXFont.display(30))
                .foregroundStyle(theme.text)
            Text("安装一个 Minecraft 版本，或创建一个空实例。游戏文件只会写入你指定的目录。")
                .font(LXFont.body)
                .foregroundStyle(theme.textSecondary)
                .frame(maxWidth: 460, alignment: .leading)
            HStack(spacing: 8) {
                LXButton("浏览版本", systemImage: "arrow.down.circle", kind: .primary) {
                    model.section = .downloads
                }
                LXButton("创建实例", systemImage: "plus", kind: .secondary) {
                    model.section = .instances
                }
            }
        }
        .padding(LXSpace.xl)
        .frame(maxWidth: .infinity, minHeight: 330, alignment: .leading)
    }

    private func heroTag(_ text: String, icon: String) -> some View {
        HStack(spacing: 5) {
            Image(systemName: icon)
                .font(.system(size: 9, weight: .medium))
            Text(text)
                .font(LXFont.captionStrong)
        }
        .foregroundStyle(theme.textSecondary)
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(theme.surfaceRaised, in: Capsule())
        .overlay(Capsule().strokeBorder(theme.border, lineWidth: 0.7))
    }

    private func canLaunch(_ instance: Instance) -> Bool {
        model.activeMicrosoftAccount != nil && model.selectedJavaRuntime != nil && instance.manifest.versionID != nil
    }

    private func readinessHint(_ instance: Instance) -> String {
        if model.activeMicrosoftAccount == nil { return "先在账户管理登录 Microsoft 账户" }
        if model.selectedJavaRuntime == nil { return "先在设置中选择 Java 运行时" }
        if instance.manifest.versionID == nil { return "该实例还没有绑定 Minecraft 版本" }
        return "启动条件未满足"
    }
}

private struct HeroPattern: View {
    @Environment(\.lxTheme) private var theme

    var body: some View {
        Canvas { context, size in
            var diagonal = Path()
            let step: CGFloat = 26
            var x: CGFloat = -size.height
            while x < size.width {
                diagonal.move(to: CGPoint(x: x, y: size.height))
                diagonal.addLine(to: CGPoint(x: x + size.height, y: 0))
                x += step
            }
            context.stroke(diagonal, with: .color(theme.orange.opacity(theme.isDark ? 0.055 : 0.035)), lineWidth: 0.7)

            let dotColor = theme.orange.opacity(theme.isDark ? 0.28 : 0.15)
            for row in 0..<5 {
                for column in 0..<7 {
                    let point = CGPoint(
                        x: size.width - 24 - CGFloat(column) * 16,
                        y: 26 + CGFloat(row) * 16
                    )
                    context.fill(
                        Path(ellipseIn: CGRect(x: point.x, y: point.y, width: 1.5, height: 1.5)),
                        with: .color(dotColor.opacity(column > 3 ? 0.35 : 0.8))
                    )
                }
            }
        }
    }
}

// MARK: - Account panel

private struct AccountPanel: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.lxTheme) private var theme

    var body: some View {
        LXCard(padding: LXSpace.lg, elevated: true) {
            VStack(alignment: .leading, spacing: LXSpace.md) {
                HStack {
                    LXOverline(text: "ACCOUNT", color: theme.textSecondary)
                    Spacer()
                    Button("管理") { model.section = .accounts }
                        .buttonStyle(.plain)
                        .font(LXFont.captionStrong)
                        .foregroundStyle(theme.orange)
                }

                if let account = model.activeMicrosoftAccount {
                    accountContent(account)
                } else {
                    signedOutContent
                }

                LXDivider()

                if let account = model.activeMicrosoftAccount {
                    HStack(spacing: 8) {
                        LXSkinSlot(
                            title: "皮肤",
                            systemImage: "person.crop.square",
                            subtitle: skinSubtitle,
                            height: 88,
                            imageURL: model.playerAppearance?.skinTextureURL
                        )
                        LXSkinSlot(
                            title: "披风",
                            systemImage: "flag.fill",
                            subtitle: capeSubtitle,
                            height: 88,
                            imageURL: model.playerAppearance?.capeTextureURL
                        )
                    }
                    Text(account.lastValidatedAt.map { "最近验证 \($0.formatted(date: .abbreviated, time: .shortened))" } ?? "所有权已缓存")
                        .font(LXFont.caption)
                        .foregroundStyle(theme.textTertiary)
                        .lineLimit(1)
                } else {
                    Text("登录后会显示真实玩家名、UUID，以及 Minecraft Profile 返回的皮肤和披风纹理。")
                        .font(LXFont.caption)
                        .foregroundStyle(theme.textTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    private var skinSubtitle: String {
        guard let appearance = model.playerAppearance else { return "未获取 · 验证账户" }
        guard appearance.skinTextureURL != nil else { return "未设置" }
        return appearance.skinModel == .slim ? "Slim · 已获取" : "Classic · 已获取"
    }

    private var capeSubtitle: String {
        guard let appearance = model.playerAppearance else { return "未获取 · 验证账户" }
        return appearance.capeTextureURL == nil ? "未装备披风" : "已装备"
    }

    private func accountContent(_ account: MicrosoftAccount) -> some View {
        VStack(alignment: .leading, spacing: LXSpace.sm) {
            HStack(spacing: 11) {
                LXAvatar(name: account.playerName, size: 52, showsRing: true, skinTextureURL: model.playerAppearance?.skinTextureURL)
                VStack(alignment: .leading, spacing: 3) {
                    Text(account.playerName)
                        .font(LXFont.title(19))
                        .foregroundStyle(theme.text)
                        .lineLimit(1)
                    Text(account.id.uuidString.lowercased())
                        .font(LXFont.monoSmall)
                        .foregroundStyle(theme.textTertiary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Spacer(minLength: 0)
            }
            HStack(spacing: 6) {
                LXBadge(
                    text: account.ownsGame ? "正版已验证" : "所有权未验证",
                    tone: account.ownsGame ? .success : .warning,
                    icon: account.ownsGame ? "checkmark.seal.fill" : "exclamationmark.triangle.fill"
                )
                LXBadge(text: "Microsoft", tone: .neutral)
            }
            if model.authState.isWorking {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.mini)
                    Text(model.authPhaseText)
                        .font(LXFont.caption)
                        .foregroundStyle(theme.textSecondary)
                        .lineLimit(1)
                }
            }
        }
    }

    private var signedOutContent: some View {
        VStack(alignment: .leading, spacing: LXSpace.sm) {
            HStack(spacing: 11) {
                LXAvatar(name: "?", size: 52, showsRing: true)
                VStack(alignment: .leading, spacing: 2) {
                    Text("未登录")
                        .font(LXFont.title(19))
                        .foregroundStyle(theme.text)
                    Text("连接 Microsoft 账户开始正版游戏")
                        .font(LXFont.caption)
                        .foregroundStyle(theme.textSecondary)
                }
            }
            LXButton("登录 Microsoft 账户", systemImage: "person.badge.plus", kind: .primary, isFullWidth: true) {
                model.signInMicrosoft()
            }
            .disabled(model.authActionInProgress || model.authState.isWorking)
            if !model.authConfigAvailable, let setupError = model.authSetupError {
                Text(setupError)
                    .font(LXFont.caption)
                    .foregroundStyle(theme.warning)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

// MARK: - Info cards

private struct HomeInfoCard: View {
    @Environment(\.lxTheme) private var theme
    @State private var hovering = false

    let overline: String
    let icon: String
    let title: String
    let detail: String
    let tone: LXBadgeTone
    let action: () -> Void

    private var toneColor: Color {
        switch tone {
        case .accent: return theme.orange
        case .success: return theme.success
        case .warning: return theme.warning
        case .danger: return theme.danger
        case .info: return theme.info
        case .neutral: return theme.textSecondary
        }
    }

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: LXSpace.sm) {
                HStack {
                    LXOverline(text: overline)
                    Spacer()
                    Image(systemName: icon)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(toneColor)
                }
                Text(title)
                    .font(LXFont.headline)
                    .foregroundStyle(theme.text)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(detail)
                    .font(LXFont.caption)
                    .foregroundStyle(theme.textTertiary)
                    .lineLimit(2)
            }
            .padding(LXSpace.md)
            .frame(maxWidth: .infinity, minHeight: 108, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: LXRadius.lg, style: .continuous)
                    .fill(hovering ? theme.surfaceHover : theme.surface)
            )
            .overlay(
                RoundedRectangle(cornerRadius: LXRadius.lg, style: .continuous)
                    .strokeBorder(hovering ? theme.borderStrong : theme.border, lineWidth: 1)
            )
            .overlay(alignment: .leading) {
                Capsule()
                    .fill(toneColor.opacity(0.75))
                    .frame(width: 2, height: 24)
                    .padding(.leading, 1)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.14), value: hovering)
    }
}
