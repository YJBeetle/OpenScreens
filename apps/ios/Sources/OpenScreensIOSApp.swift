import OpenScreensUI
import SwiftUI

@main
struct OpenScreensIOSApp: App {
    @State private var connections = ConnectionStore()
    @State private var settings = SettingsStore()
    @State private var sshKeys = SSHKeyVault()

    var body: some Scene {
        WindowGroup {
            IOSRootView()
                .environment(connections)
                .environment(settings)
                .environment(sshKeys)
                .preferredColorScheme(settings.settings.appearance.colorScheme)
                .tint(Theme.Colors.accent)
        }
    }
}

enum IOSAppInfo {
    static var version: String {
        infoString("CFBundleShortVersionString") ?? "0.1.0"
    }

    static var buildVersion: String {
        infoString("OpenScreensBuildVersion") ?? version
    }

    private static func infoString(_ key: String) -> String? {
        guard let value = Bundle.main.object(forInfoDictionaryKey: key) as? String,
              !value.isEmpty,
              !value.hasPrefix("$(") else { return nil }
        return value
    }
}

struct IOSEditorRoute: Identifiable {
    let id = UUID()
    let mode: ConnectionEditorMode
    var groupID: UUID?
}
