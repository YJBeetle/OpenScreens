import OpenScreensUI
import SwiftUI

@main
struct OpenScreensMacApp: App {
    @State private var connections = ConnectionStore()
    @State private var settings = SettingsStore()
    @State private var sshKeys = SSHKeyVault()
    @State private var updater = AppUpdater()

    var body: some Scene {
        WindowGroup {
            MacLibraryView()
                .environment(connections)
                .environment(settings)
                .environment(sshKeys)
                .preferredColorScheme(settings.settings.appearance.colorScheme)
                .tint(Theme.Colors.accent)
                .onAppear {
                    updater.start(channel: settings.settings.updateChannel)
                }
        }
        .defaultSize(width: 1080, height: 700)
        .commands {
            SidebarCommands()
            CommandGroup(after: .appInfo) {
                Button("Check for Updates…") {
                    updater.check()
                }
                .disabled(!updater.canCheck)
            }
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
            MacSettingsView(
                appVersion: MacAppInfo.version,
                buildVersion: MacAppInfo.buildVersion,
                updater: updater
            )
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

struct SessionRoute: Codable, Hashable {
    var profileID: UUID
}

struct MacSettingsView: View {
    @Environment(SettingsStore.self) private var settings

    let appVersion: String
    let buildVersion: String
    let updater: AppUpdater

    var body: some View {
        SettingsView(appVersion: appVersion, buildVersion: buildVersion)
            .frame(width: 620, height: 620)
            .onChange(of: settings.settings.updateChannel) { _, channel in
                updater.setChannel(channel)
            }
    }
}
