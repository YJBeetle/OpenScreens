import SwiftUI

/// Settings form shared by the macOS Settings scene and the iOS settings sheet.
public struct SettingsView: View {
    @Environment(SettingsStore.self) private var settings
    @Environment(ConnectionStore.self) private var connections

    private let appVersion: String
    @State private var confirmingRestore = false

    public init(appVersion: String = "1.0") {
        self.appVersion = appVersion
    }

    public var body: some View {
        @Bindable var settings = settings

        Form {
            Section {
                Picker("Theme", selection: $settings.settings.appearance) {
                    ForEach(AppAppearance.allCases) { appearance in
                        Text(appearance.title).tag(appearance)
                    }
                }

                Picker("Library Tile Size", selection: $settings.settings.tileDensity) {
                    ForEach(TileDensity.allCases) { density in
                        Text(density.title).tag(density)
                    }
                }
            } header: {
                Text("Appearance")
            }

            Section {
                Picker("Cursor Mode", selection: $settings.settings.defaultCursorMode) {
                    ForEach(CursorMode.allCases) { mode in
                        Label(mode.title, systemImage: mode.systemImage).tag(mode)
                    }
                }

                Toggle("Use Shared Clipboard", isOn: $settings.settings.sharedClipboard)
                Toggle("Reconnect Automatically", isOn: $settings.settings.autoReconnect)
                Toggle("Confirm Before Disconnecting", isOn: $settings.settings.confirmDisconnect)
            } header: {
                Text("Session Defaults")
            } footer: {
                Text("Defaults apply to new connections. Existing connections keep their own settings.")
            }

            Section {
                Button("Restore Sample Connections") {
                    confirmingRestore = true
                }
            } header: {
                Text("Library")
            } footer: {
                Text("Adds the demo computers back to your library without removing anything you saved.")
            }

            Section {
                LabeledContent("Version", value: appVersion)
                LabeledContent("Protocol", value: "RFB (VNC)")
                LabeledContent("Transport", value: "Direct connection")

                Text("OpenScreens is open source software, licensed under Apache-2.0. This build uses a local mock session; the Rust RFB engine plugs in behind the same session interface.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } header: {
                Text("About")
            }
        }
        .modifier(SettingsFormStyle())
        .navigationTitle("Settings")
        .confirmationDialog(
            "Restore sample connections?",
            isPresented: $confirmingRestore,
            titleVisibility: .visible
        ) {
            Button("Restore Samples") {
                connections.restoreSamples()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("The demo hosts are added to your library again. Existing connections are kept.")
        }
    }
}

/// Settings presented as a sheet from the iOS library.
public struct SettingsSheet: View {
    @Environment(\.dismiss) private var dismiss

    private let appVersion: String

    public init(appVersion: String = "1.0") {
        self.appVersion = appVersion
    }

    public var body: some View {
        NavigationStack {
            SettingsView(appVersion: appVersion)
                .toolbar {
                    ToolbarItem(placement: .primaryAction) {
                        Button("Done") {
                            dismiss()
                        }
                        .fontWeight(.semibold)
                    }
                }
        }
    }
}

private struct SettingsFormStyle: ViewModifier {
    @ViewBuilder
    func body(content: Content) -> some View {
        #if os(macOS)
        content.formStyle(.grouped)
        #else
        content
        #endif
    }
}
