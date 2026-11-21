import AppKit
import OpenScreensUI
import SwiftUI

@main
struct OpenScreensMacApp: App {
    @NSApplicationDelegateAdaptor(MacAppDelegate.self) private var appDelegate

    @State private var connections: ConnectionStore
    @State private var settings: SettingsStore
    @State private var sshKeys = SSHKeyVault()
    @State private var updater = AppUpdater()
    @State private var nearby = NearbyDiscovery()

    init() {
        let settings = SettingsStore()
        _settings = State(initialValue: settings)
        _connections = State(initialValue: ConnectionStore(settings: settings))
    }

    var body: some Scene {
        Window("Scrctl", id: MacSceneID.library) {
            MacLibraryView()
                .nearbyDiscoveryLifecycle()
                .environment(connections)
                .environment(settings)
                .environment(sshKeys)
                .environment(nearby)
                .preferredColorScheme(settings.settings.appearance.colorScheme)
                .tint(Theme.Colors.accent)
                .onAppear {
                    updater.start(channel: settings.settings.updateChannel)
                }
        }
        .defaultSize(width: 1080, height: 700)
        .commands {
            SidebarCommands()
            LibraryMenuCommands()
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
        .commands { SessionMenuCommands() }

        #if SCRCTL_XDB
        WindowGroup(id: MacSceneID.xdbSession, for: XdbDevice.self) { $device in
            if let device { MacXdbSessionView(device: device) }
        }
        .defaultSize(width: 480, height: 760)
        #endif

        MenuBarExtra("Scrctl", systemImage: "display") {
            MacMenuBarContent(updater: updater)
                .environment(connections)
        }
        .menuBarExtraStyle(.menu)

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

private final class MacAppDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard sender.windows.contains(where: SessionWindowCloseGuard.hasActiveTransfers(in:)) else {
            return .terminateNow
        }

        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = NSLocalizedString("File Transfer in Progress", comment: "Quit confirmation")
        alert.informativeText = NSLocalizedString("Quitting will cancel the current file transfers.", comment: "Quit confirmation")
        alert.addButton(withTitle: NSLocalizedString("Cancel", comment: "Quit confirmation"))
        alert.addButton(withTitle: NSLocalizedString("Quit", comment: "Quit confirmation"))
        return alert.runModal() == .alertSecondButtonReturn ? .terminateNow : .terminateCancel
    }
}

enum MacSceneID {
    static let library = "library"
    static let xdbSession = "xdb-session"
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
    var observeRequestID: UUID? = nil
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
