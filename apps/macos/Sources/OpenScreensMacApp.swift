import OpenScreensUI
import SwiftUI

@main
struct OpenScreensMacApp: App {
    @State private var connections = ConnectionStore()
    @State private var settings = SettingsStore()
    @State private var sshKeys = SSHKeyVault()

    var body: some Scene {
        WindowGroup {
            MacLibraryView()
                .environment(connections)
                .environment(settings)
                .environment(sshKeys)
                .preferredColorScheme(settings.settings.appearance.colorScheme)
                .tint(Theme.Colors.accent)
        }
        .defaultSize(width: 1080, height: 700)
        .commands {
            SidebarCommands()
        }

        WindowGroup(id: MacSceneID.session, for: SessionRoute.self) { $route in
            Group {
                if let route {
                    MacSessionWindow(route: route)
                } else {
                    ContentUnavailableView(
                        "No Session",
                        systemImage: "display",
                        description: Text("Open a connection from the library.")
                    )
                }
            }
            .environment(connections)
            .environment(settings)
            .environment(sshKeys)
            .preferredColorScheme(settings.settings.appearance.colorScheme)
            .tint(Theme.Colors.accent)
        }
        .defaultSize(width: 1120, height: 760)

        Settings {
            MacSettingsView(appVersion: MacAppInfo.version)
                .environment(connections)
                .environment(settings)
                .environment(sshKeys)
                .preferredColorScheme(settings.settings.appearance.colorScheme)
                .tint(Theme.Colors.accent)
        }
    }
}

enum MacSceneID {
    static let session = "session"
}

enum MacAppInfo {
    static var version: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.1.0"
    }
}

struct SessionRoute: Codable, Hashable {
    var profileID: UUID
}

struct MacSettingsView: View {
    let appVersion: String

    var body: some View {
        SettingsView(appVersion: appVersion)
            .frame(width: 620, height: 620)
    }
}
