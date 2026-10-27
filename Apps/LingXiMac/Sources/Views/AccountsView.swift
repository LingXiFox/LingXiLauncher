import LauncherCore
import SwiftUI

struct AccountsView: View {
    @EnvironmentObject private var model: AppModel

    private var microsoftAccounts: [AppModel.AccountRow] {
        model.accounts.filter { $0.kind == .microsoft }
    }

    private var localAccounts: [AppModel.AccountRow] {
        model.accounts.filter { $0.kind == .local }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                SectionCard(title: "Microsoft 登录") {
                    HStack(spacing: 14) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(model.authPhaseText)
                                .font(.body.weight(.medium))
                            Text("系统浏览器登录，Authorization Code + PKCE S256；不收集密码，不使用 Client Secret。")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        if model.authState.isWorking || model.authActionInProgress {
                            ProgressView().controlSize(.small)
                        }
                        Button {
                            model.signInMicrosoft()
                        } label: {
                            Label("添加 Microsoft 账户", systemImage: "person.badge.plus")
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(model.authActionInProgress || model.authState.isWorking)
                    }
                    if !model.authConfigAvailable {
                        Divider().padding(.vertical, 4)
                        Text(model.authSetupError ?? "Microsoft 认证不可用。")
                            .font(.caption)
                            .foregroundStyle(.orange)
                            .textSelection(.enabled)
                    }
                }

                SectionCard(title: "已登录账户") {
                    if microsoftAccounts.isEmpty {
                        Text("还没有 Microsoft 账户。登录后可选择账户并用正版会话启动游戏。")
                            .foregroundStyle(.secondary)
                    } else {
                        VStack(spacing: 0) {
                            ForEach(microsoftAccounts) { account in
                                accountRow(account)
                                if account.id != microsoftAccounts.last?.id { Divider() }
                            }
                        }
                    }
                }

                SectionCard(title: "本地离线身份") {
                    if localAccounts.isEmpty {
                        Text("没有本地离线账户。")
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(localAccounts) { account in
                            HStack {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(account.name)
                                    Text(account.uuid)
                                        .font(.caption.monospaced())
                                        .foregroundStyle(.secondary)
                                }
                                Spacer()
                                StatusPill(text: "未验证", color: .orange)
                            }
                            .padding(.vertical, 3)
                        }
                    }
                    Text("本地离线身份仅用于 CLI 技术验证。按 Mojang AppID 审核条款，GUI 不提供绕过所有权验证的启动入口；本地身份与 Microsoft 身份严格隔离。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .padding(.top, 4)
                }
            }
            .padding(22)
        }
    }

    private func accountRow(_ account: AppModel.AccountRow) -> some View {
        HStack(alignment: .center, spacing: 12) {
            Image(systemName: account.kind == .microsoft ? "person.crop.circle.fill" : "person.crop.circle")
                .font(.title2)
                .foregroundStyle(account.kind == .microsoft ? Color.lingxiOrange : .secondary)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 8) {
                    Text(account.name).font(.body.weight(.medium))
                    if account.active { StatusPill(text: "当前", color: .lingxiOrange) }
                    if let owns = account.ownsGame {
                        StatusPill(text: owns ? "所有权已验证" : "未验证所有权", color: owns ? .green : .orange)
                    }
                }
                Text(account.uuid)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                if let date = account.lastValidated {
                    Text("最近验证 \(date.formatted(date: .abbreviated, time: .shortened))")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }
            Spacer()
            if !account.active {
                Button("设为当前") { model.selectAccount(account) }
                    .buttonStyle(.borderless)
            }
            Button("验证") { model.validateMicrosoft(account) }
                .buttonStyle(.borderless)
                .disabled(model.authActionInProgress)
            Button("退出") { model.signOutMicrosoft(account) }
                .buttonStyle(.borderless)
                .foregroundStyle(.red)
                .disabled(model.authActionInProgress)
        }
        .padding(.vertical, 6)
    }
}
