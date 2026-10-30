import OpenScreensUI
import SwiftUI

@main
struct OpenScreensIOSApp: App {
    @State private var connections = ConnectionStore()
    @State private var settings = SettingsStore()

    var body: some Scene {
        WindowGroup {
            IOSRootView()
                .environment(connections)
                .environment(settings)
                .preferredColorScheme(settings.settings.appearance.colorScheme)
                .tint(Theme.Colors.accent)
        }
    }
}

enum IOSAppInfo {
    static var version: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.1.0"
    }
}

struct IOSEditorRoute: Identifiable {
    let id = UUID()
    let mode: ConnectionEditorMode
}
