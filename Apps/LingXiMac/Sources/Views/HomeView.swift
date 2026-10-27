import SwiftUI

struct HomeView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                HStack(alignment: .firstTextBaseline) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("LingXi Launcher")
                            .font(.largeTitle.weight(.semibold))
                        Text("原生 macOS Minecraft: Java Edition 启动器")
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    StatusPill(
                        text: model.isGameRunning ? "运行中" : "就绪",
                        color: model.isGameRunning ? .green : .secondary
                    )
                }

                SectionCard(title: "当前实例") {
                    if let instance = model.selectedInstance {
                        HStack(alignment: .top, spacing: 32) {
                            LabeledValue(title: "实例", value: instance.manifest.displayName)
                            LabeledValue(title: "版本", value: instance.manifest.versionID ?? "未指定")
                            LabeledValue(title: "内存", value: instance.manifest.memoryMiB.map { "\($0) MiB" } ?? "未设置")
                        }
                        Text(instance.gameDirectory.path)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                            .padding(.top, 4)
                    } else {
                        Text("还没有实例。请先在“游戏实例”中创建，或到“版本下载”安装一个版本。")
                            .foregroundStyle(.secondary)
                    }
                }

                SectionCard(title: "启动") {
                    HStack(spacing: 14) {
                        if model.isGameRunning {
                            Button {
                                model.stopGame()
                            } label: {
                                Label("停止游戏", systemImage: "stop.fill")
                                    .frame(minWidth: 120)
                            }
                            .buttonStyle(.borderedProminent)
                            .tint(.red)
                        } else {
                            Button {
                                model.launchSelectedInstance()
                            } label: {
                                Label("启动 Minecraft", systemImage: "play.fill")
                                    .frame(minWidth: 150)
                            }
                            .buttonStyle(.borderedProminent)
                            .disabled(model.selectedInstance == nil || model.activeMicrosoftAccount == nil || model.selectedJavaRuntime == nil)
                        }
                        VStack(alignment: .leading, spacing: 2) {
                            Text(model.isGameRunning ? "游戏进程运行中" : "启动前会校验文件与 Java 运行时")
                                .font(.callout)
                            if let pid = model.gamePID {
                                Text("PID \(pid)")
                                    .font(.caption.monospaced())
                                    .foregroundStyle(.secondary)
                            }
                            if model.activeMicrosoftAccount == nil {
                                Text("需要先在“账户管理”中登录 Microsoft 账户；GUI 不提供本地离线启动。")
                                    .font(.caption)
                                    .foregroundStyle(.orange)
                            }
                        }
                    }
                }

                HStack(alignment: .top, spacing: 16) {
                    SectionCard(title: "账户") {
                        HStack {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(model.activeAccountDescription)
                                    .font(.body.weight(.medium))
                                Text(model.authPhaseText)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            if model.activeMicrosoftAccount == nil {
                                Button("登录") { model.signInMicrosoft() }
                                    .disabled(model.authActionInProgress)
                            }
                        }
                    }
                    SectionCard(title: "Java") {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(model.selectedJavaRuntime?.displayDescription ?? "未选择")
                                .font(.body.weight(.medium))
                            Text(model.selectedJavaRuntime?.executable.path ?? "请在设置中选择 Java 运行时")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .textSelection(.enabled)
                        }
                    }
                }

                SectionCard(title: "最近一次启动") {
                    if let exit = model.lastExit {
                        HStack(spacing: 10) {
                            StatusPill(
                                text: exit.isSuccess ? "正常退出" : "异常退出",
                                color: exit.isSuccess ? .green : .red
                            )
                            Text("退出码 \(exit.code) · \(exit.reason.rawValue)")
                                .font(.callout)
                            Spacer()
                            if let date = model.lastLaunchAt {
                                Text(date.formatted(date: .abbreviated, time: .shortened))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    } else {
                        Text(model.lastLaunchAt == nil ? "尚未启动过游戏" : "正在启动…")
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .padding(22)
        }
    }
}
