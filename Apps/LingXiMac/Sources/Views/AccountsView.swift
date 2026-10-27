import AppKit
import LauncherCore
import SwiftUI

struct AccountsView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.lxTheme) private var theme

    private var microsoftAccounts: [AppModel.AccountRow] {
        model.accounts.filter { $0.kind == .microsoft }
    }

    private var localAccounts: [AppModel.AccountRow] {
        model.accounts.filter { $0.kind == .local }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: LXSpace.md) {
                LXPageHeader(
                    eyebrow: "ACCOUNT / MICROSOFT",
                    title: "账户管理",
                    subtitle: "正版会话、所有权和本地身份在这里保持严格隔离。"
                ) {
                    LXButton("添加 Microsoft 账户", systemImage: "person.badge.plus", kind: .primary, isDisabled: model.authActionInProgress || model.authState.isWorking) {
                        model.signInMicrosoft()
                    }
                    .padding(.top, 3)
                }

                authStatusCard

                if let account = model.activeMicrosoftAccount {
                    activeAccountCard(account)
                } else {
                    signedOutCard
                }

                if !microsoftAccounts.isEmpty {
                    accountList
                }

                localSection
            }
            .padding(.horizontal, LXSpace.xxl)
            .padding(.vertical, LXSpace.xl)
            .frame(maxWidth: 1100, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .center)
        }
        .scrollIndicators(.never)
        .background(theme.canvas)
    }

    private var authStatusCard: some View {
        LXCard(padding: LXSpace.md) {
            HStack(alignment: .center, spacing: 12) {
                ZStack {
                    Circle().fill(theme.orangeSoft)
                    Image(systemName: "shield.lefthalf.filled")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(theme.orange)
                }
                .frame(width: 32, height: 32)

                VStack(alignment: .leading, spacing: 2) {
                    Text(model.authPhaseText)
                        .font(LXFont.bodyStrong)
                        .foregroundStyle(theme.text)
                    Text("Authorization Code + PKCE S256 · 系统浏览器 · 无 Client Secret")
                        .font(LXFont.caption)
                        .foregroundStyle(theme.textTertiary)
                }
                Spacer()
                if model.authState.isWorking || model.authActionInProgress {
                    ProgressView().controlSize(.small).tint(theme.orange)
                } else {
                    LXBadge(
                        text: model.authConfigAvailable ? "内嵌认证已就绪" : "认证不可用",
                        tone: model.authConfigAvailable ? .success : .danger,
                        dot: true
                    )
                }
            }
            if !model.authConfigAvailable, let setupError = model.authSetupError {
                Text(setupError)
                    .font(LXFont.caption)
                    .foregroundStyle(theme.warning)
                    .padding(.top, 4)
                    .textSelection(.enabled)
            }
        }
    }

    private func activeAccountCard(_ account: MicrosoftAccount) -> some View {
        LXCard(padding: LXSpace.lg, elevated: true, accent: theme.orange) {
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .top, spacing: LXSpace.xl) {
                    activeIdentity(account)
                    Divider().background(theme.border)
                    appearancePanel
                        .frame(width: 260)
                }
                VStack(alignment: .leading, spacing: LXSpace.md) {
                    activeIdentity(account)
                    appearancePanel
                }
            }
        }
    }

    private func activeIdentity(_ account: MicrosoftAccount) -> some View {
        VStack(alignment: .leading, spacing: LXSpace.sm) {
            HStack {
                LXOverline(text: "ACTIVE ACCOUNT", color: theme.orange)
                Spacer()
                LXBadge(
                    text: account.ownsGame ? "所有权已验证" : "未验证所有权",
                    tone: account.ownsGame ? .success : .warning,
                    icon: account.ownsGame ? "checkmark.seal.fill" : "exclamationmark.triangle.fill"
                )
            }
            HStack(spacing: 14) {
                LXAvatar(name: account.playerName, size: 72, showsRing: true, skinTextureURL: model.playerAppearance?.skinTextureURL)
                VStack(alignment: .leading, spacing: 5) {
                    Text(account.playerName)
                        .font(LXFont.display(27))
                        .foregroundStyle(theme.text)
                        .lineLimit(1)
                    HStack(spacing: 7) {
                        Text(account.id.uuidString.lowercased())
                            .font(LXFont.monoSmall)
                            .foregroundStyle(theme.textSecondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        LXIconButton(systemImage: "doc.on.doc", label: "复制 UUID") {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(account.id.uuidString.lowercased(), forType: .string)
                        }
                    }
                    HStack(spacing: 6) {
                        LXBadge(text: "Microsoft", tone: .neutral)
                        if let date = account.lastValidatedAt {
                            Text("验证于 \(date.formatted(date: .abbreviated, time: .shortened))")
                                .font(LXFont.caption)
                                .foregroundStyle(theme.textTertiary)
                                .lineLimit(1)
                        }
                    }
                }
            }
            Text("XUID \(account.xuid)")
                .font(LXFont.monoSmall)
                .foregroundStyle(theme.textTertiary)
                .textSelection(.enabled)
            HStack(spacing: 8) {
                LXButton("验证所有权", systemImage: "checkmark.shield", kind: .secondary) {
                    if let row = microsoftAccounts.first(where: { $0.id == account.id.uuidString.lowercased() }) {
                        model.validateMicrosoft(row)
                    }
                }
                .disabled(model.authActionInProgress)
                LXButton("添加账户", systemImage: "person.badge.plus", kind: .ghost) {
                    model.signInMicrosoft()
                }
                .disabled(model.authActionInProgress || model.authState.isWorking)
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

    private var appearancePanel: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                LXOverline(text: "APPEARANCE")
                Spacer()
                LXBadge(
                    text: model.playerAppearance == nil ? "接口预留" : "已接入",
                    tone: model.playerAppearance == nil ? .neutral : .success
                )
            }
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
            Text("纹理来自 Minecraft Profile；未设置时显示真实空缺，不会伪造玩家皮肤或披风。")
                .font(LXFont.caption)
                .foregroundStyle(theme.textTertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var signedOutCard: some View {
        LXCard(padding: LXSpace.lg) {
            HStack(spacing: LXSpace.lg) {
                LXAvatar(name: "?", size: 64)
                VStack(alignment: .leading, spacing: 5) {
                    Text("还没有登录 Microsoft 账户")
                        .font(LXFont.title(20))
                        .foregroundStyle(theme.text)
                    Text("登录后即可验证 Minecraft 所有权，并使用正版会话启动。登录过程不会要求输入密码到启动器。")
                        .font(LXFont.body)
                        .foregroundStyle(theme.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer()
                LXButton("登录 Microsoft", systemImage: "person.badge.plus", kind: .primary) {
                    model.signInMicrosoft()
                }
                .disabled(model.authActionInProgress || model.authState.isWorking)
            }
        }
    }

    private var accountList: some View {
        VStack(alignment: .leading, spacing: 8) {
            LXOverline(text: "SAVED ACCOUNTS")
                .padding(.horizontal, 2)
            VStack(spacing: 0) {
                ForEach(microsoftAccounts) { account in
                    MICROSOFTAccountRow(
                        account: account,
                        onSelect: { model.selectAccount(account) },
                        onValidate: { model.validateMicrosoft(account) },
                        onSignOut: { model.signOutMicrosoft(account) },
                        isBusy: model.authActionInProgress
                    )
                    if account.id != microsoftAccounts.last?.id {
                        LXDivider().padding(.leading, 58)
                    }
                }
            }
            .background(theme.surface, in: RoundedRectangle(cornerRadius: LXRadius.lg, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: LXRadius.lg, style: .continuous)
                    .strokeBorder(theme.border, lineWidth: 1)
            )
        }
    }

    private var localSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            LXOverline(text: "LOCAL IDENTITIES")
                .padding(.horizontal, 2)
            LXCard(padding: LXSpace.md) {
                VStack(alignment: .leading, spacing: LXSpace.sm) {
                    ForEach(localAccounts) { account in
                        HStack(spacing: 10) {
                            LXAvatar(name: account.name, size: 30, skinTextureURL: account.appearance?.skinTextureURL)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(account.name)
                                    .font(LXFont.bodyStrong)
                                    .foregroundStyle(theme.text)
                                Text(account.uuid)
                                    .font(LXFont.monoSmall)
                                    .foregroundStyle(theme.textTertiary)
                                    .lineLimit(1)
                            }
                            Spacer()
                            LXBadge(text: "仅 CLI", tone: .warning)
                        }
                    }
                    if localAccounts.isEmpty {
                        Text("没有本地离线身份。")
                            .font(LXFont.body)
                            .foregroundStyle(theme.textSecondary)
                    }
                    Text("按 Mojang AppID 审核条款，GUI 不提供绕过所有权验证的本地启动入口；本地身份仅用于 CLI 技术验证。")
                        .font(LXFont.caption)
                        .foregroundStyle(theme.textTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }
}

private struct MICROSOFTAccountRow: View {
    @Environment(\.lxTheme) private var theme

    let account: AppModel.AccountRow
    let onSelect: () -> Void
    let onValidate: () -> Void
    let onSignOut: () -> Void
    let isBusy: Bool

    var body: some View {
        HStack(spacing: 10) {
            LXAvatar(name: account.name, size: 34, skinTextureURL: account.appearance?.skinTextureURL)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(account.name)
                        .font(LXFont.bodyStrong)
                        .foregroundStyle(theme.text)
                    if account.active {
                        LXBadge(text: "当前", tone: .accent)
                    }
                    if account.ownsGame == true {
                        LXBadge(text: "正版", tone: .success)
                    }
                }
                Text(account.uuid)
                    .font(LXFont.monoSmall)
                    .foregroundStyle(theme.textTertiary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer()
            if !account.active {
                LXButton("设为当前", kind: .ghost, isDisabled: isBusy, action: onSelect)
            }
            LXButton("验证", kind: .ghost, isDisabled: isBusy, action: onValidate)
            LXButton("退出", kind: .destructive, isDisabled: isBusy, action: onSignOut)
        }
        .padding(.horizontal, LXSpace.md)
        .padding(.vertical, 9)
    }
}
