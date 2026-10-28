import SwiftUI

struct ContentView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var debugTokens: [UUID] = []

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
                ToolbarItem(placement: .primaryAction) {
                    LXButton("安装游戏", systemImage: "plus", kind: .primary) {
                        model.installWizardInitialVersion = nil
                        model.showInstallWizard = true
                    }
                }
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
        .sheet(isPresented: $model.showInstallWizard) {
            InstallWizardView()
                .environmentObject(model)
                .environment(\.lxTheme, theme)
        }
        .task { registerDebugActions() }
        .onDisappear { unregisterDebugActions() }
    }

    private func registerDebugActions() {
        let center = DebugAutomationCenter.shared
        center.startIfEnabled()
        guard center.isEnabled else { return }
        debugTokens.append(center.register("app.state") { _ in
            [
                "section": model.section.rawValue,
                "selectedInstance": model.selectedInstanceID ?? "",
                "modsOpen": model.showModsForInstance?.id ?? "",
                "instances": model.instances.map { ["id": $0.id, "name": $0.manifest.displayName, "version": $0.manifest.versionID ?? ""] },
            ]
        })
        debugTokens.append(center.register("app.section") { params in
            guard let raw = params["section"], let section = AppModel.Section(rawValue: raw) else {
                return ["ok": false, "error": "unknown section"]
            }
            model.section = section
            return ["section": model.section.rawValue]
        })
        debugTokens.append(center.register("mods.open") { params in
            guard let id = params["instanceID"], let instance = model.instances.first(where: { $0.id == id }) else {
                return ["ok": false, "error": "instance not found"]
            }
            model.openMods(instance: instance)
            return ["instance": id, "modsOpen": model.showModsForInstance?.id ?? ""]
        })
        debugTokens.append(center.register("mrpack.open") { params in
            let url = params["path"].flatMap { $0.isEmpty ? nil : URL(fileURLWithPath: $0) }
            model.openMrpackImport(url: url)
            return ["mrpackOpen": model.showMrpackImport, "path": url?.path ?? ""]
        })
    }

    private func unregisterDebugActions() {
        for token in debugTokens { DebugAutomationCenter.shared.unregister(token) }
        debugTokens.removeAll()
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
