import AppKit
import OpenScreensUI
import SwiftUI

/// Connection shortcuts in the macOS menu bar, mirroring the library.
struct MacMenuBarContent: View {
    @Environment(ConnectionStore.self) private var store
    @Environment(\.openWindow) private var openWindow
    @ObservedObject var updater: AppUpdater

    private var profiles: [ConnectionProfile] {
        store.connections.sorted { lhs, rhs in
            if lhs.isFavorite != rhs.isFavorite {
                return lhs.isFavorite
            }
            return Self.title(for: lhs).localizedCaseInsensitiveCompare(Self.title(for: rhs))
                == .orderedAscending
        }
    }

    var body: some View {
        Button("Open Library") {
            openWindow(id: MacSceneID.library)
            NSApp.activate(ignoringOtherApps: true)
        }
        .keyboardShortcut("l", modifiers: [.command, .shift])

        Divider()

        if profiles.isEmpty {
            Text("No Saved Connections")
        } else {
            ForEach(profiles) { profile in
                Button {
                    open(profile)
                } label: {
                    if profile.isFavorite {
                        Label(Self.title(for: profile), systemImage: "star.fill")
                    } else {
                        Text(Self.title(for: profile))
                    }
                }
            }
        }

        Divider()

        SettingsLink {
            Text("Settings…")
        }
        Button("Check for Updates…") {
            updater.check()
        }
        .disabled(!updater.canCheck)

        Divider()

        Button("Quit OpenScreens") {
            NSApp.terminate(nil)
        }
        .keyboardShortcut("q")
    }

    private func open(_ profile: ConnectionProfile) {
        openWindow(id: MacSceneID.session, value: SessionRoute(profileID: profile.id))
        NSApp.activate(ignoringOtherApps: true)
    }

    private static func title(for profile: ConnectionProfile) -> String {
        profile.trimmedName.isEmpty ? profile.host : profile.trimmedName
    }
}
