import AppKit
import LauncherCore
import SwiftUI

struct SettingsView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.lxTheme) private var theme

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: LXSpace.md) {
                LXPageHeader(
                    eyebrow: "SYSTEM / PREFERENCES",
                    title: "设置",
                    subtitle: "外观、Java、下载源与认证状态。修改会立即保存。"
                )

                appearanceSection
                javaSection
                sourceSection
                pathsSection
                authSection
                aboutSection
            }
            .padding(.horizontal, LXSpace.xxl)
            .padding(.vertical, LXSpace.xl)
            .frame(maxWidth: 900, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .center)
        }
        .scrollIndicators(.never)
        .background(theme.canvas)
    }

    private var appearanceSection: some View {
        SettingsCard(title: "外观", eyebrow: "APPEARANCE") {
            VStack(alignment: .leading, spacing: LXSpace.sm) {
                Text("深色石墨是默认体验；浅色主题保留完整的对比度与层级。")
                    .font(LXFont.body)
                    .foregroundStyle(theme.textSecondary)
                HStack(spacing: 6) {
                    ForEach(LXAppearance.allCases) { appearance in
                        LXChip(title: appearance.title, isSelected: model.settings.appearance == appearance) {
                            model.settings.appearance = appearance
                            model.saveSettings()
                        }
                    }
                    Spacer()
                }
                Text("当前跟随：\(model.settings.appearance.title)")
                    .font(LXFont.caption)
                    .foregroundStyle(theme.textTertiary)
            }
        }
    }

    private var javaSection: some View {
        SettingsCard(title: "Java 运行时", eyebrow: "RUNTIME") {
            VStack(alignment: .leading, spacing: 10) {
                if model.javaRuntimes.isEmpty {
                    Text("未检测到 Java。请安装 Java 17+，或手动选择可执行文件。")
                        .font(LXFont.body)
                        .foregroundStyle(theme.warning)
                } else {
                    HStack {
                        Text("默认 Java")
                            .font(LXFont.bodyStrong)
                            .foregroundStyle(theme.text)
                        Spacer()
                        Menu {
                            ForEach(model.javaRuntimes, id: \.executable.path) { runtime in
                                Button {
                                    model.selectJava(path: runtime.executable.path)
                                } label: {
                                    if runtime.executable.path == model.selectedJavaPath {
                                        Label(runtime.displayDescription, systemImage: "checkmark")
                                    } else {
                                        Text(runtime.displayDescription)
                                    }
                                }
                            }
                        } label: {
                            menuLabel(model.selectedJavaRuntime?.displayDescription ?? "选择 Java")
                        }
                        .menuStyle(.borderlessButton)
                        .menuIndicator(.hidden)
                        .fixedSize()
                    }
                }
                HStack(spacing: 7) {
                    LXButton("重新检测", systemImage: "arrow.clockwise", kind: .secondary) {
                        Task { await model.refreshJavaRuntimes() }
                    }
                    LXButton("选择 java…", systemImage: "folder", kind: .ghost) {
                        model.chooseJavaFile()
                    }
                    Spacer()
                }
                if let runtime = model.selectedJavaRuntime {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("来源：\(model.javaSourceLabel(for: runtime))")
                            .font(LXFont.captionStrong)
                            .foregroundStyle(theme.textSecondary)
                        Text(runtime.executable.path)
                            .font(LXFont.monoSmall)
                            .foregroundStyle(theme.textTertiary)
                            .textSelection(.enabled)
                            .lineLimit(2)
                            .truncationMode(.middle)
                    }
                }
            }
        }
    }

    private var sourceSection: some View {
        SettingsCard(title: "下载源", eyebrow: "NETWORK") {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text("默认源")
                        .font(LXFont.bodyStrong)
                        .foregroundStyle(theme.text)
                    Spacer()
                    Menu {
                        ForEach(DownloadSourcePolicy.allCases, id: \.self) { policy in
                            Button {
                                model.settings.source = policy
                                model.saveSettings()
                            } label: {
                                if policy == model.settings.source {
                                    Label(policy.displayName, systemImage: "checkmark")
                                } else {
                                    Text(policy.displayName)
                                }
                            }
                        }
                    } label: {
                        menuLabel(model.settings.source.displayName)
                    }
                    .menuStyle(.borderlessButton)
                    .menuIndicator(.hidden)
                    .fixedSize()
                }
                TextField("可信镜像配置 JSON 路径", text: $model.settings.mirrorConfigPath)
                    .lxInput()
                    .onChange(of: model.settings.mirrorConfigPath) { _, _ in
                        model.saveSettings()
                    }
                HStack(spacing: 7) {
                    LXButton("选择镜像配置…", systemImage: "doc.badge.gearshape", kind: .secondary) {
                        selectMirrorConfig()
                    }
                    if model.settings.source == .mirror && model.settings.mirrorConfigPath.isEmpty {
                        LXBadge(text: "mirror 模式需要配置", tone: .warning)
                    }
                    Spacer()
                    Text("默认不内置镜像")
                        .font(LXFont.caption)
                        .foregroundStyle(theme.textTertiary)
                }
            }
        }
    }

    private var pathsSection: some View {
        SettingsCard(title: "路径", eyebrow: "STORAGE") {
            VStack(alignment: .leading, spacing: 12) {
                pathRow(title: "游戏根目录", path: model.layout.gameRoot.path)
                pathRow(title: "启动器数据目录", path: model.layout.dataRoot.path)
                HStack(spacing: 7) {
                    LXButton("打开游戏目录", systemImage: "folder", kind: .secondary) { model.openGameRoot() }
                    LXButton("打开数据目录", systemImage: "folder", kind: .secondary) { model.openDataFolder() }
                    Spacer()
                }
            }
        }
    }

    private var authSection: some View {
        SettingsCard(title: "Microsoft 认证", eyebrow: "IDENTITY") {
            VStack(alignment: .leading, spacing: 9) {
                HStack {
                    LXBadge(
                        text: model.authConfigAvailable ? "内嵌注册已启用" : "认证不可用",
                        tone: model.authConfigAvailable ? .success : .danger,
                        dot: true
                    )
                    Spacer()
                    Text("MicrosoftAppRegistration")
                        .font(LXFont.monoSmall)
                        .foregroundStyle(theme.textTertiary)
                }
                Text("Client ID 已内嵌在启动器 Core；无 auth.json、无 Client Secret。开发者可用 LINGXI_MICROSOFT_CLIENT_ID 临时覆盖。")
                    .font(LXFont.caption)
                    .foregroundStyle(theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                Text(model.authPhaseText)
                    .font(LXFont.caption)
                    .foregroundStyle(theme.textTertiary)
            }
        }
    }

    private var aboutSection: some View {
        SettingsCard(title: "关于", eyebrow: "LINGXI LAUNCHER") {
            VStack(alignment: .leading, spacing: 7) {
                HStack {
                    Text("LingXi Launcher")
                        .font(LXFont.bodyStrong)
                        .foregroundStyle(theme.text)
                    LXBadge(text: "M3 + M5-Alpha", tone: .accent)
                    Spacer()
                    Text(LauncherInfo.version)
                        .font(LXFont.monoSmall)
                        .foregroundStyle(theme.textTertiary)
                }
                Text("Minecraft 是 Mojang Studios 的商标。本项目与 Mojang/Microsoft 无隶属关系，不随包分发游戏文件、资源或修改后的 JAR。")
                    .font(LXFont.caption)
                    .foregroundStyle(theme.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func menuLabel(_ text: String) -> some View {
        HStack(spacing: 7) {
            Text(text)
                .font(LXFont.body)
                .foregroundStyle(theme.text)
                .lineLimit(1)
            Image(systemName: "chevron.up.chevron.down")
                .font(.system(size: 8, weight: .semibold))
                .foregroundStyle(theme.textTertiary)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(theme.surfaceRaised, in: RoundedRectangle(cornerRadius: LXRadius.sm, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: LXRadius.sm, style: .continuous)
                .strokeBorder(theme.border, lineWidth: 0.8)
        )
    }

    private func pathRow(title: String, path: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(LXFont.caption)
                    .foregroundStyle(theme.textTertiary)
                Text(path)
                    .font(LXFont.monoSmall)
                    .foregroundStyle(theme.textSecondary)
                    .textSelection(.enabled)
                    .lineLimit(2)
                    .truncationMode(.middle)
            }
            Spacer(minLength: 8)
            LXIconButton(systemImage: "doc.on.doc", label: "复制路径") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(path, forType: .string)
            }
        }
    }

    private func selectMirrorConfig() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        model.settings.mirrorConfigPath = url.path
        model.saveSettings()
    }
}

private struct SettingsCard<Content: View>: View {
    @Environment(\.lxTheme) private var theme
    let title: String
    let eyebrow: String
    @ViewBuilder let content: Content

    init(title: String, eyebrow: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.eyebrow = eyebrow
        self.content = content()
    }

    var body: some View {
        LXCard(padding: LXSpace.lg) {
            VStack(alignment: .leading, spacing: LXSpace.sm) {
                HStack(alignment: .firstTextBaseline) {
                    Text(title)
                        .font(LXFont.headline)
                        .foregroundStyle(theme.text)
                    Spacer()
                    LXOverline(text: eyebrow)
                }
                content
            }
        }
    }
}
