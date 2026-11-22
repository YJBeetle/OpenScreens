import SwiftUI

/// Settings form shared by the macOS Settings scene and the iOS settings sheet.
public struct SettingsView: View {
    @Environment(SettingsStore.self) private var settings
    @Environment(ConnectionStore.self) private var connections

    private let appVersion: String
    private let buildVersion: String?
    @State private var confirmingRestore = false

    @State private var editingToolbar = false

    public init(appVersion: String = "1.0", buildVersion: String? = nil) {
        self.appVersion = appVersion
        self.buildVersion = buildVersion
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

                Toggle("Show Last Session Preview", isOn: $settings.settings.showSessionPreviews)

                Picker("Sort Connections", selection: $settings.settings.librarySort) {
                    ForEach(LibrarySortOrder.allCases) { order in
                        Text(order.title).tag(order)
                    }
                }
            } header: {
                Text("Appearance")
            } footer: {
                if settings.settings.librarySort == .manual {
                    Text("Long-press a connection and choose Move Up or Move Down to arrange it.")
                }
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
                Toggle("Show Toolbar on Launch", isOn: $settings.settings.showToolbarOnLaunch)

                Button {
                    editingToolbar = true
                } label: {
                    Label("Customize Session Toolbar", systemImage: "slider.horizontal.3")
                }
            } header: {
                Text("Toolbar")
            }

            #if os(macOS)
            Section {
                Picker("Update channel", selection: $settings.settings.updateChannel) {
                    ForEach(UpdateChannel.allCases) { channel in
                        Text(channel.title).tag(channel)
                    }
                }
                .pickerStyle(.segmented)
            } header: {
                Text("Updates")
            } footer: {
                Text("Release receives stable builds, pre-release includes betas, and snapshot follows development builds. Use Check for Updates in the Scrctl menu.")
            }
            #endif

            #if os(iOS)
            Section {
                if AppLock.isAvailable {
                    Toggle(AppLock.settingTitle, isOn: $settings.settings.requireBiometrics)
                }

                NavigationLink("SSH Keys") {
                    SSHKeyManagerView()
                }
            } header: {
                Text("Security")
            } footer: {
                if AppLock.isAvailable {
                    Text("Scrctl locks when you leave the app. Unlock with \(AppLock.biometryName). Imported SSH keys are kept in the Keychain.")
                } else {
                    Text("Private keys imported for SSH tunnels are kept in the Keychain.")
                }
            }
            #endif

            Section {
                Toggle("Discover Nearby Computers", isOn: $settings.settings.discoverNearby)

                Button("Restore Sample Connections") {
                    confirmingRestore = true
                }
            } header: {
                Text("Library")
            } footer: {
                Text("Scrctl uses Bonjour to find computers sharing their screen on your local network. Local network access may be requested the first time. Restoring samples adds the demo computers without removing anything you saved.")
            }

            Section {
                LabeledContent("Version", value: buildVersion ?? appVersion)
                LabeledContent("Protocol", value: "RFB (VNC)")
                LabeledContent("Transport", value: NSLocalizedString("Direct connection", comment: "Transport kind"))

                Text("Scrctl is open source software, licensed under AGPL-3.0.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } header: {
                Text("About")
            }
        }
        .modifier(SettingsFormStyle())
        .navigationTitle("Settings")
        .sheet(isPresented: $editingToolbar) {
            NavigationStack {
                SessionToolbarSettings()
            }
        }
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
    private let buildVersion: String?

    public init(appVersion: String = "1.0", buildVersion: String? = nil) {
        self.appVersion = appVersion
        self.buildVersion = buildVersion
    }

    public var body: some View {
        NavigationStack {
            SettingsView(appVersion: appVersion, buildVersion: buildVersion)
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
