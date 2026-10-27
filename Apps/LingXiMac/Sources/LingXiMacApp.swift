import SwiftUI

@main
struct LingXiMacApp: App {
    @StateObject private var model = AppModel()

    var body: some Scene {
        WindowGroup("LingXi Launcher") {
            ContentView()
                .environmentObject(model)
                .frame(minWidth: 980, minHeight: 640)
                .tint(Color.lingxiOrange)
        }
        .defaultSize(width: 1180, height: 760)
        .commands {
            CommandGroup(replacing: .newItem) {}
        }

        Settings {
            SettingsView()
                .environmentObject(model)
                .frame(width: 620, height: 520)
                .tint(Color.lingxiOrange)
        }
    }
}
