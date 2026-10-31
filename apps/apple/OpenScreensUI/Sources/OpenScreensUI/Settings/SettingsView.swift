import SwiftUI

/// Settings form shared by the macOS Settings scene and the iOS settings sheet.
public struct SettingsView: View {
    @Environment(SettingsStore.self) private var settings
    @Environment(ConnectionStore.self) private var connections

    private let appVersion: String
    private let buildVersion: String?
    @State private var confirmingRestore = false

    private var visibleToolbarItems: [SessionToolbarItem] {
        #if os(macOS)
        SessionToolbarItem.allCases.filter { $0 != .keyboard }
        #else
        SessionToolbarItem.allCases
        #endif
    }

    private var orderedToolbarItems: [SessionToolbarItem] {
        let enabled = settings.settings.toolbarItems.filter { visibleToolbarItems.contains($0) }
        let hidden = visibleToolbarItems.filter { !enabled.contains($0) }
        return enabled + hidden
    }

    private func moveToolbarItem(_ item: SessionToolbarItem, by offset: Int) {
        var items = settings.settings.toolbarItems
        guard let index = items.firstIndex(of: item),
              items.indices.contains(index + offset) else { return }
        items.swapAt(index, index + offset)
        settings.settings.toolbarItems = items
    }

    private func isFirstToolbarItem(_ item: SessionToolbarItem) -> Bool {
        settings.settings.toolbarItems.first == item
    }

    private func isLastToolbarItem(_ item: SessionToolbarItem) -> Bool {
        settings.settings.toolbarItems.last == item
    }

    private func toolbarBinding(_ item: SessionToolbarItem) -> Binding<Bool> {
        Binding(
            get: { settings.settings.toolbarItems.contains(item) },
            set: { isOn in
                var items = settings.settings.toolbarItems
                if isOn {
                    if !items.contains(item) { items.append(item) }
                } else {
                    items.removeAll { $0 == item }
                }
                settings.settings.toolbarItems = items
            }
        )
    }

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

                ForEach(orderedToolbarItems) { item in
                    HStack(spacing: 6) {
                        Toggle(isOn: toolbarBinding(item)) {
                            Label(item.title, systemImage: item.systemImage)
                        }

                        if settings.settings.toolbarItems.contains(item) {
                            Button {
                                moveToolbarItem(item, by: -1)
                            } label: {
                                Image(systemName: "chevron.up")
                            }
                            .buttonStyle(.borderless)
                            .disabled(isFirstToolbarItem(item))

                            Button {
                                moveToolbarItem(item, by: 1)
                            } label: {
                                Image(systemName: "chevron.down")
                            }
                            .buttonStyle(.borderless)
                            .disabled(isLastToolbarItem(item))
                        }
                    }
                }
            } header: {
                Text("Toolbar")
            } footer: {
                Text("Choose the buttons shown in the session toolbar.")
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
                Text("Release receives stable builds, pre-release includes betas, and snapshot follows development builds. Use Check for Updates in the OpenScreens menu.")
            }
            #endif

            #if os(iOS)
            Section {
                NavigationLink("SSH Keys") {
                    SSHKeyManagerView()
                }
            } header: {
                Text("Security")
            } footer: {
                Text("Private keys imported for SSH tunnels are kept in the Keychain.")
            }
            #endif

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
                LabeledContent("Version", value: buildVersion ?? appVersion)
                LabeledContent("Protocol", value: "RFB (VNC)")
                LabeledContent("Transport", value: NSLocalizedString("Direct connection", comment: "Transport kind"))

                Text("OpenScreens is open source software, licensed under AGPL-3.0. This build uses a local mock session; the Rust RFB engine plugs in behind the same session interface.")
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
