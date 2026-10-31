import SwiftUI

#if os(macOS)
import AppKit
#endif

/// Settings form shared by the macOS Settings scene and the iOS settings sheet.
public struct SettingsView: View {
    @Environment(SettingsStore.self) private var settings
    @Environment(ConnectionStore.self) private var connections

    private let appVersion: String
    @State private var confirmingRestore = false
    #if os(macOS)
    @State private var updateStatus: MacUpdateStatus = .idle
    @State private var isDownloadingUpdate = false
    #endif

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


            #if os(macOS)
            Section {
                Picker("Update channel", selection: $settings.settings.updateChannel) {
                    ForEach(UpdateChannel.allCases) { channel in
                        Text(channel.title).tag(channel)
                    }
                }
                .pickerStyle(.segmented)
                .onChange(of: settings.settings.updateChannel) { _, _ in
                    updateStatus = .idle
                }

                HStack(alignment: .firstTextBaseline) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(updateStatusText)
                            .foregroundStyle(.secondary)
                        if case .available(let release) = updateStatus {
                            Text("Version \(release.label) is available")
                                .font(.callout.weight(.medium))
                        }
                    }
                    Spacer()
                    Button(isChecking ? "Checking…" : "Check for Updates") {
                        checkForUpdates()
                    }
                    .disabled(isChecking || isDownloadingUpdate)
                }

                if case .available(let release) = updateStatus {
                    if !release.notes.isEmpty {
                        Text(release.notes)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(6)
                    }
                    HStack {
                        if let pageURL = release.pageURL {
                            Link("Release Notes", destination: pageURL)
                        }
                        if release.downloadURL != nil {
                            Button(isDownloadingUpdate ? "Downloading…" : "Download & Open Installer") {
                                downloadUpdate(release)
                            }
                            .disabled(isDownloadingUpdate)
                        } else {
                            Text("No macOS asset in this release")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            } header: {
                Text("Updates")
            } footer: {
                Text("Release receives stable builds, pre-release includes betas, and snapshot follows development builds. Installers are downloaded from GitHub Releases.")
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
                LabeledContent("Version", value: appVersion)
                LabeledContent("Protocol", value: "RFB (VNC)")
                LabeledContent("Transport", value: "Direct connection")

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

    #if os(macOS)
    private var isChecking: Bool {
        if case .checking = updateStatus { return true }
        return false
    }

    private var updateStatusText: String {
        switch updateStatus {
        case .idle: "Check GitHub Releases for a newer build."
        case .checking: "Checking…"
        case .upToDate: "You're on the latest version for this channel."
        case .noReleases: "No releases published for this channel yet."
        case .available: "A new build is available."
        case .failed(let message): "Couldn't check for updates: \(message)"
        }
    }

    private func checkForUpdates() {
        guard !isChecking else { return }
        updateStatus = .checking
        let channel = settings.settings.updateChannel
        let installed = UpdateStateStore.installedSnapshot()
        Task {
            do {
                let result = try await UpdateChecker.check(
                    currentVersion: appVersion,
                    channel: channel,
                    installedSnapshot: installed
                )
                switch result {
                case .available(let release):
                    updateStatus = .available(release)
                case .upToDate:
                    updateStatus = .upToDate
                case .noReleases:
                    updateStatus = .noReleases
                }
            } catch {
                updateStatus = .failed(error.localizedDescription)
            }
        }
    }

    private func downloadUpdate(_ release: AppRelease) {
        guard let url = release.downloadURL else { return }
        isDownloadingUpdate = true
        Task {
            do {
                let (temporary, response) = try await URLSession.shared.download(from: url)
                if let http = response as? HTTPURLResponse,
                   !(200..<300).contains(http.statusCode) {
                    throw URLError(.badServerResponse)
                }
                let directory = FileManager.default.urls(
                    for: .downloadsDirectory,
                    in: .userDomainMask
                ).first ?? temporary.deletingLastPathComponent()
                let destination = directory.appendingPathComponent(url.lastPathComponent)
                try? FileManager.default.removeItem(at: destination)
                try FileManager.default.moveItem(at: temporary, to: destination)
                NSWorkspace.shared.open(destination)
                if release.tag.caseInsensitiveCompare("snapshot") == .orderedSame {
                    UpdateStateStore.markInstallStarted(release.label)
                }
            } catch {
                updateStatus = .failed(error.localizedDescription)
            }
            isDownloadingUpdate = false
        }
    }
    #endif
}

#if os(macOS)
private enum MacUpdateStatus {
    case idle
    case checking
    case upToDate
    case noReleases
    case available(AppRelease)
    case failed(String)
}
#endif

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
