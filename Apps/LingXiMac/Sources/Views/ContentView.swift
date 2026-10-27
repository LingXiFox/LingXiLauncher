import SwiftUI

struct ContentView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var theme: LXTheme { LXTheme(colorScheme: colorScheme) }

    var body: some View {
        NavigationSplitView {
            SidebarView()
                .navigationSplitViewColumnWidth(min: 220, ideal: 240, max: 280)
        } detail: {
            VStack(spacing: 0) {
                if let error = model.lastError {
                    LXErrorBanner(message: error, dismiss: model.clearError)
                        .transition(.move(edge: .top).combined(with: .opacity))
                }
                page
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .background(theme.canvas)
            .navigationTitle("LingXi Launcher")
            .toolbar {
                ToolbarItem(placement: .status) {
                    HStack(spacing: 8) {
                        if model.authState.isWorking || model.authActionInProgress {
                            ProgressView()
                                .controlSize(.small)
                                .tint(theme.orange)
                        }
                        LXBadge(
                            text: model.isGameRunning ? "游戏运行中" : "就绪",
                            tone: model.isGameRunning ? .success : .neutral,
                            dot: true
                        )
                    }
                    .accessibilityElement(children: .combine)
                }
            }
        }
        .navigationSplitViewStyle(.balanced)
        .environment(\.lxTheme, theme)
        .tint(theme.orange)
        .animation(reduceMotion ? nil : .easeOut(duration: 0.18), value: model.lastError)
        .background(theme.canvas)
    }

    @ViewBuilder
    private var page: some View {
        switch model.section {
        case .home: HomeView()
        case .instances: InstancesView()
        case .downloads: DownloadsView()
        case .accounts: AccountsView()
        case .logs: LogsView()
        case .settings: SettingsView()
        }
    }
}
