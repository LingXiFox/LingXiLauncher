import SwiftUI
import MacPlatform

@main
struct LingXiMacApp: App {
    @StateObject private var model: AppModel

    init() {
        MacPlatform.install()
        _model = StateObject(wrappedValue: AppModel())
    }

    var body: some Scene {
        WindowGroup("LingXi Launcher") {
            ContentView()
                .environmentObject(model)
                .frame(minWidth: 960, minHeight: 640)
                .preferredColorScheme(model.settings.appearance.colorScheme)
        }
        .defaultSize(width: 1240, height: 820)
        .windowResizability(.contentMinSize)
        .commands {
            CommandGroup(replacing: .newItem) {}
        }

        Settings {
            SettingsSceneView()
                .environmentObject(model)
        }
    }
}

private struct SettingsSceneView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        SettingsView()
            .environment(\.lxTheme, LXTheme(colorScheme: colorScheme))
            .preferredColorScheme(model.settings.appearance.colorScheme)
            .frame(width: 680, height: 640)
    }
}
