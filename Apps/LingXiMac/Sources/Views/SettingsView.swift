import AppKit
import LauncherCore
import SwiftUI

struct SettingsView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        Form {
            Section("Java 运行时") {
                if model.javaRuntimes.isEmpty {
                    Text("未检测到 Java。请安装 Java 17+ 或手动选择可执行文件。")
                        .foregroundStyle(.secondary)
                } else {
                    Picker("默认 Java", selection: Binding(
                        get: { model.selectedJavaPath },
                        set: { model.selectJava(path: $0) }
                    )) {
                        ForEach(model.javaRuntimes, id: \.executable.path) { runtime in
                            Text(runtime.displayDescription)
                                .tag(runtime.executable.path)
                        }
                    }
                }
                HStack {
                    Button("重新检测") {
                        Task { await model.refreshJavaRuntimes() }
                    }
                    Button("选择 java…") { model.chooseJavaFile() }
                }
                if let runtime = model.selectedJavaRuntime {
                    Text(runtime.executable.path)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
            }

            Section("下载源") {
                Picker("默认源", selection: $model.settings.source) {
                    ForEach(DownloadSourcePolicy.allCases, id: \.self) { policy in
                        Text(policy.displayName).tag(policy)
                    }
                }
                .onChange(of: model.settings.sourceRaw) { _, _ in
                    model.saveSettings()
                    Task { await model.loadVersions() }
                }
                TextField("可信镜像配置 JSON", text: $model.settings.mirrorConfigPath)
                    .onChange(of: model.settings.mirrorConfigPath) { _, _ in
                        model.saveSettings()
                    }
                HStack {
                    Button("选择镜像配置…") { selectMirrorConfig() }
                    if model.settings.source == .mirror && model.settings.mirrorConfigPath.isEmpty {
                        Text("mirror 模式需要显式配置")
                            .font(.caption)
                            .foregroundStyle(.orange)
                    }
                }
            }

            Section("路径") {
                LabeledValue(title: "游戏根目录", value: model.layout.gameRoot.path)
                LabeledValue(title: "启动器数据目录", value: model.layout.dataRoot.path)
                HStack {
                    Button("打开游戏目录") { model.openGameRoot() }
                    Button("打开数据目录") { model.openDataFolder() }
                }
            }

            Section("Microsoft 认证") {
                HStack {
                    StatusPill(
                        text: model.authConfigAvailable ? "内嵌注册已启用" : "不可用",
                        color: model.authConfigAvailable ? .green : .orange
                    )
                    Spacer()
                    Text("MicrosoftAppRegistration")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Text("Client ID 内嵌于启动器；无 auth.json，绝不使用 Client Secret。开发者可用 LINGXI_MICROSOFT_CLIENT_ID 临时覆盖。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("关于") {
                LabeledValue(title: "LingXi Launcher", value: "\(LauncherInfo.version) · M3/M5 Alpha")
                Text("Minecraft 是 Mojang Studios 的商标；本项目与 Mojang/Microsoft 无隶属关系，不随包分发游戏文件。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .padding(.vertical, 8)
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
