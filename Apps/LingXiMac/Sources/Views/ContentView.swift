import SwiftUI

struct ContentView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        NavigationSplitView {
            List(AppModel.Section.allCases, selection: $model.section) { section in
                Label(section.title, systemImage: section.icon)
                    .tag(section)
            }
            .navigationSplitViewColumnWidth(min: 180, ideal: 200, max: 260)
            .safeAreaInset(edge: .bottom) {
                VStack(alignment: .leading, spacing: 6) {
                    Divider()
                    HStack(spacing: 6) {
                        Circle()
                            .fill(model.isGameRunning ? Color.green : Color.secondary.opacity(0.5))
                            .frame(width: 7, height: 7)
                        Text(model.isGameRunning ? "游戏运行中" : "未运行")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Text(model.activeAccountDescription)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                }
                .padding(.horizontal, 12)
                .padding(.bottom, 10)
            }
        } detail: {
            Group {
                switch model.section {
                case .home:
                    HomeView()
                case .instances:
                    InstancesView()
                case .downloads:
                    DownloadsView()
                case .accounts:
                    AccountsView()
                case .logs:
                    LogsView()
                case .settings:
                    SettingsView()
                }
            }
            .navigationTitle(model.section.title)
            .toolbar {
                ToolbarItem(placement: .status) {
                    if model.authState.isWorking || model.authActionInProgress {
                        ProgressView()
                            .controlSize(.small)
                            .help(model.authPhaseText)
                    }
                }
            }
        }
        .alert(
            "出错了",
            isPresented: Binding(
                get: { model.lastError != nil },
                set: { if !$0 { model.clearError() } }
            )
        ) {
            Button("好") { model.clearError() }
        } message: {
            Text(model.lastError ?? "")
        }
    }
}
