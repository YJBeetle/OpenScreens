import OpenScreensCanvas
import SwiftUI
import UniformTypeIdentifiers

#if os(macOS)
import AppKit
#endif

/// How the editor was opened: a fresh custom connection or an existing one.
public enum ConnectionEditorMode: Sendable {
    case create(LibrarySection)
    case edit(ConnectionProfile)
}

/// Connection editor with Connection / Security / Controls / Advanced groups.
/// It uses a section rail on regular widths and a single scrolling form on
/// compact widths.
public struct ConnectionEditorView: View {
    @Environment(ConnectionStore.self) private var store
    @Environment(SettingsStore.self) private var settings
    @Environment(SSHKeyVault.self) private var keyVault
    @Environment(\.dismiss) private var dismiss
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass

    @State private var draft: ConnectionProfile
    @State private var password: String = ""
    @State private var sshEnabled = false
    @State private var sshHost = ""
    @State private var sshPort = "22"
    @State private var sshUsername = ""
    @State private var sshAuthMethod: SSHAuthMethod = .password
    @State private var sshPassword = ""
    @State private var sshKeyPath = ""
    @State private var sshKeyPassphrase = ""
    @State private var sshFingerprint = ""
    @State private var sshImportedKeyID: UUID?
    @State private var importingSSHKey = false
    @State private var sshKeyImportError: String?
    #if os(macOS)
    @State private var sshKeyFiles: [SSHKeyFile] = []
    #endif
    @State private var importingWireGuard = false
    @State private var wireGuardFileName: String?
    @State private var wireGuardImportError: String?
    @State private var selectedSection: EditorSection = .connection
    @State private var appliedSettingsDefaults = false

    private static let wireGuardByteLimit = 64 * 1024

    private let mode: ConnectionEditorMode
    private let onSaved: ((ConnectionProfile) -> Void)?

    public init(mode: ConnectionEditorMode, onSaved: ((ConnectionProfile) -> Void)? = nil) {
        self.mode = mode
        self.onSaved = onSaved
        switch mode {
        case .create(let section):
            _draft = State(initialValue: ConnectionProfile.draft(section: section))
        case .edit(let profile):
            _draft = State(initialValue: profile)
        }
    }

    public var body: some View {
        Group {
            if horizontalSizeClass == .compact {
                compactLayout
            } else {
                regularLayout
            }
        }
        .onAppear {
            applySettingsDefaults()
            password = OpenScreensCredentials.password(for: draft.id) ?? ""
            if let ssh = draft.ssh {
                sshEnabled = ssh.enabled
                sshHost = ssh.host
                sshPort = String(ssh.port)
                sshUsername = ssh.username
                sshAuthMethod = ssh.authMethod
                sshKeyPath = ssh.keyPath
                sshImportedKeyID = ssh.importedKeyID
                sshFingerprint = ssh.hostKeyFingerprint
            }
            sshPassword = OpenScreensCredentials.secret(kind: "ssh-password", for: draft.id) ?? ""
            sshKeyPassphrase = OpenScreensCredentials.secret(kind: "ssh-passphrase", for: draft.id) ?? ""
            #if os(macOS)
            sshKeyFiles = SSHKeyCatalog.available()
            #endif
        }
    }

    // MARK: - Layouts

    private var regularLayout: some View {
        HStack(spacing: 0) {
            sectionRail
                .frame(width: 196)

            Divider()

            VStack(spacing: 0) {
                header
                Form {
                    sectionContent
                }
                .modifier(EditorFormStyle())
                Divider()
                actionBar
            }
        }
    }

    private var compactLayout: some View {
        VStack(spacing: 0) {
            HStack {
                Button("Cancel") {
                    dismiss()
                }
                .accessibilityLabel("Cancel editing")

                Spacer()

                Text(title)
                    .font(.headline)

                Spacer()

                Button("Save") {
                    save()
                }
                .fontWeight(.semibold)
                .disabled(!canSave)
                .accessibilityLabel("Save connection")
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)

            Divider()

            Form {
                connectionSection
                securitySection
                controlsSection
                advancedSection
            }
            .modifier(EditorFormStyle())
        }
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.title3.weight(.semibold))
                Text(isCreating ? "Configure a remote computer" : draft.endpoint)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer()
        }
        .padding(.horizontal, 20)
        .padding(.top, 16)
        .padding(.bottom, 4)
    }

    private var sectionRail: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text("Settings")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 12)
                .padding(.top, 16)
                .padding(.bottom, 4)

            ForEach(EditorSection.allCases) { section in
                Button {
                    selectedSection = section
                } label: {
                    Label(section.title, systemImage: section.systemImage)
                        .font(.subheadline.weight(selectedSection == section ? .semibold : .regular))
                        .foregroundStyle(selectedSection == section ? Theme.Colors.accent : Color.primary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.vertical, 8)
                        .padding(.horizontal, 10)
                        .background {
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .fill(selectedSection == section ? Theme.Colors.accent.opacity(0.12) : .clear)
                        }
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(selectedSection == section ? .isSelected : [])
            }

            Spacer()
        }
        .padding(.horizontal, 8)
        .background(Color.primary.opacity(0.025))
    }

    private var actionBar: some View {
        HStack {
            Button("Cancel", role: .cancel) {
                dismiss()
            }
            .controlSize(.large)
            .keyboardShortcut(.cancelAction)

            Spacer()

            Button("Save") {
                save()
            }
            .controlSize(.large)
            .buttonStyle(.borderedProminent)
            .keyboardShortcut(.defaultAction)
            .disabled(!canSave)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(.regularMaterial)
    }

    // MARK: - Editor sections

    @ViewBuilder
    private var sectionContent: some View {
        switch selectedSection {
        case .connection: connectionSection
        case .security: securitySection
        case .controls: controlsSection
        case .advanced: advancedSection
        }
    }

    @ViewBuilder
    private var connectionSection: some View {
        Section {
            TextField("Name", text: $draft.name, prompt: Text("Studio Mac"))
            Picker("System", selection: $draft.platform) {
                ForEach(RemoteOS.allCases) { platform in
                    Text(platform.title).tag(platform)
                }
            }

            if !draft.isValid {
                Label(
                    missingFieldsMessage,
                    systemImage: "exclamationmark.circle.fill"
                )
                .font(.footnote)
                .foregroundStyle(Theme.Colors.danger)
            }
        } header: {
            Text("Details")
        }

        Section {
            TextField("Hostname", text: $draft.host, prompt: Text("hostname or IP address"))
                .modifier(HostInputStyle())
            TextField("Port", value: $draft.port, format: .number)
                .monospacedDigit()
        } header: {
            Text("Address")
        } footer: {
            Text(draft.trimmedHost.isEmpty
                ? "The server's hostname or IP address. VNC uses port 5900 by default."
                : "Connects to \(draft.endpoint).")
        }

        Section {
            VStack(alignment: .leading, spacing: 10) {
                Text("Tile Colour")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                TilePalettePicker(selection: $draft.palette)
            }
            .padding(.vertical, 2)

            Toggle("Favorite", isOn: $draft.isFavorite)
        } header: {
            Text("Library")
        } footer: {
            Text("The colour appears only on this connection's library tile.")
        }
    }

    @ViewBuilder
    private var securitySection: some View {
        Section {
            Picker("Authentication", selection: $draft.authentication) {
                ForEach(AuthenticationMethod.allCases) { method in
                    Text(method.title).tag(method)
                }
            }

            if draft.authentication.requiresUsername {
                TextField("User Name", text: $draft.username, prompt: Text("Remote account"))
                    .modifier(PlainInputStyle())
            }

            if draft.authentication != .none {
                SecureField("Password", text: $password, prompt: Text("Connection password"))
                    .modifier(PlainInputStyle())
            }
        } header: {
            Text("Authentication")
        } footer: {
            Text("Passwords are stored in the system Keychain for this connection.")
        }

        Section {
            Toggle("Tunnel through SSH", isOn: $sshEnabled)

            if sshEnabled {
                TextField("SSH host", text: $sshHost, prompt: Text("Same as hostname"))
                    .modifier(PlainInputStyle())
                TextField("SSH port", text: $sshPort)
                    .modifier(PlainInputStyle())
                    .monospacedDigit()
                TextField("SSH user name", text: $sshUsername)
                    .modifier(PlainInputStyle())

                Picker("SSH authentication", selection: $sshAuthMethod) {
                    Text("Password").tag(SSHAuthMethod.password)
                    Text("Private Key").tag(SSHAuthMethod.privateKey)
                }

                if sshAuthMethod == .password {
                    SecureField("SSH password", text: $sshPassword, prompt: Text("SSH password"))
                        .modifier(PlainInputStyle())
                } else {
                    #if os(macOS)
                    Picker("Private key", selection: $sshKeyPath) {
                        Text("Choose a key…").tag("")
                        ForEach(sshKeyFiles) { file in
                            Text(file.name).tag(file.path)
                        }
                        if !sshKeyPath.isEmpty,
                           !sshKeyFiles.contains(where: { $0.path == sshKeyPath }) {
                            Text(URL(fileURLWithPath: sshKeyPath).lastPathComponent).tag(sshKeyPath)
                        }
                    }
                    HStack {
                        Text("Keys from ~/.ssh")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Spacer()
                        Button("Browse…") { chooseSSHKeyFile() }
                    }
                    #else
                    Picker("Private key", selection: $sshImportedKeyID) {
                        Text("Choose a key…").tag(UUID?.none)
                        ForEach(keyVault.keys) { key in
                            Text(key.name).tag(Optional(key.id))
                        }
                    }
                    HStack {
                        Text(
                            keyVault.keys.isEmpty
                                ? "No imported keys yet"
                                : "Keys are stored in the Keychain"
                        )
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        Spacer()
                        Button("Import Key…") { importingSSHKey = true }
                    }
                    if let error = sshKeyImportError {
                        Text(error)
                            .font(.footnote)
                            .foregroundStyle(Theme.Colors.danger)
                    }
                    #endif
                    SecureField("Key passphrase", text: $sshKeyPassphrase, prompt: Text("Optional"))
                        .modifier(PlainInputStyle())
                }

                TextField("Host key SHA-256 (optional)", text: $sshFingerprint)
                    .modifier(PlainInputStyle())

                if let error = sshValidationError {
                    Text(error)
                        .font(.footnote)
                        .foregroundStyle(Theme.Colors.danger)
                }
            }
        } header: {
            Text("SSH Tunnel")
        } footer: {
            Text("The VNC address is resolved from the SSH host. SSH secrets are stored in the Keychain.")
        }
        .fileImporter(
            isPresented: $importingSSHKey,
            allowedContentTypes: [.data]
        ) { result in
            switch result {
            case .success(let url):
                importSSHKey(from: url)
            case .failure(let error):
                sshKeyImportError = error.localizedDescription
            }
        }

        Section {
            if draft.hasWireGuardConfig {
                VStack(alignment: .leading, spacing: 3) {
                    Text(wireGuardFileName ?? "WireGuard configuration")
                        .font(.subheadline)
                        .lineLimit(1)
                    Text(wireGuardSummary)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                Button("Remove Configuration", role: .destructive) {
                    draft.wireGuardConfig = nil
                    wireGuardFileName = nil
                    wireGuardImportError = nil
                }
            } else {
                Button {
                    importingWireGuard = true
                } label: {
                    Label("Import WireGuard Configuration…", systemImage: "doc.badge.plus")
                }
            }

            if let error = wireGuardImportError {
                Text(error)
                    .font(.footnote)
                    .foregroundStyle(Theme.Colors.danger)
            }

            if tunnelConflict {
                Label(
                    "SSH and WireGuard cannot be used together. Turn one off to save.",
                    systemImage: "exclamationmark.triangle.fill"
                )
                .font(.footnote)
                .foregroundStyle(Theme.Colors.danger)
            }
        } header: {
            Text("WireGuard")
        } footer: {
            Text("Import a wg-quick .conf file (64 KiB maximum). The configuration is stored with this connection and used instead of SSH.")
        }
        .fileImporter(
            isPresented: $importingWireGuard,
            allowedContentTypes: [.data]
        ) { result in
            switch result {
            case .success(let url):
                importWireGuardConfig(from: url)
            case .failure(let error):
                wireGuardImportError = error.localizedDescription
            }
        }
    }

    private var wireGuardSummary: String {
        guard let text = draft.wireGuardConfig else { return "" }
        let size = ByteCountFormatter.string(
            fromByteCount: Int64(text.utf8.count),
            countStyle: .file
        )
        let endpoint = text
            .split(whereSeparator: \.isNewline)
            .map(String.init)
            .first { $0.trimmingCharacters(in: .whitespaces).lowercased().hasPrefix("endpoint") }
        guard let endpoint else { return size }
        return "\(endpoint.trimmingCharacters(in: .whitespaces)) · \(size)"
    }

    private func importWireGuardConfig(from url: URL) {
        let accessing = url.startAccessingSecurityScopedResource()
        defer {
            if accessing { url.stopAccessingSecurityScopedResource() }
        }

        do {
            guard url.pathExtension.lowercased() == "conf" else {
                throw WireGuardImportError("Choose a WireGuard .conf file.")
            }

            let handle = try FileHandle(forReadingFrom: url)
            defer { try? handle.close() }

            var data = Data()
            while data.count <= Self.wireGuardByteLimit,
                  let chunk = try handle.read(upToCount: 16 * 1024),
                  !chunk.isEmpty {
                data.append(chunk)
            }
            guard data.count <= Self.wireGuardByteLimit else {
                throw WireGuardImportError(
                    "WireGuard configurations must be 64 KiB or smaller."
                )
            }
            guard let text = String(data: data, encoding: .utf8) else {
                throw WireGuardImportError(
                    "The WireGuard configuration is not UTF-8 text."
                )
            }
            guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw WireGuardImportError("The WireGuard configuration is empty.")
            }

            draft.wireGuardConfig = text
            wireGuardFileName = url.lastPathComponent
            wireGuardImportError = nil
        } catch {
            wireGuardImportError = error.localizedDescription
        }
    }

    private func importSSHKey(from url: URL) {
        do {
            let key = try keyVault.importKey(contentsOf: url)
            sshImportedKeyID = key.id
            sshKeyImportError = nil
        } catch {
            sshKeyImportError = error.localizedDescription
        }
    }

    #if os(macOS)
    private func chooseSSHKeyFile() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.directoryURL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".ssh", isDirectory: true)
        if panel.runModal() == .OK, let url = panel.url {
            sshKeyPath = url.path
        }
    }
    #endif

    @ViewBuilder
    private var controlsSection: some View {
        Section {
            Picker("Cursor Mode", selection: $draft.controls.cursorMode) {
                ForEach(CursorMode.allCases) { mode in
                    Label(mode.title, systemImage: mode.systemImage).tag(mode)
                }
            }
        } header: {
            Text("Pointer")
        } footer: {
            Text(draft.controls.cursorMode.help)
        }

        Section {
            Toggle("Start in Observe Mode", isOn: $draft.controls.startInObserveMode)
            Toggle("Use Shared Clipboard", isOn: $draft.controls.sharedClipboard)
        } header: {
            Text("Session")
        } footer: {
            Text("Observe mode shows the screen without sending input. Shared clipboard enables manual send and fetch while connected.")
        }
    }

    @ViewBuilder
    private var advancedSection: some View {
        Section {
            Picker("Display Scaling", selection: $draft.controls.scaling) {
                ForEach(RemoteContentMode.allCases) { mode in
                    Text(mode.title).tag(mode)
                }
            }
            Toggle("Reconnect Automatically", isOn: $draft.controls.autoReconnect)
            Toggle("Keep Screen Awake", isOn: $draft.controls.keepScreenAwake)
        } header: {
            Text("Display")
        } footer: {
            Text("Scaling controls how the framebuffer fits the session window. Automatic reconnect retries up to three times after an unexpected close.")
        }
    }

    // MARK: - SSH validation

    private var sshPortNumber: Int? { Int(sshPort) }

    private var tunnelConflict: Bool {
        sshEnabled && draft.hasWireGuardConfig
    }

    private var sshValidationError: String? {
        guard sshEnabled else { return nil }
        if sshUsername.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return "SSH user name is required."
        }
        guard let port = sshPortNumber, (1...65535).contains(port) else {
            return "SSH port must be between 1 and 65535."
        }
        #if os(macOS)
        if sshAuthMethod == .privateKey,
           sshKeyPath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return "Choose a private key from ~/.ssh."
        }
        #else
        if sshAuthMethod == .privateKey && sshImportedKeyID == nil {
            return "Import a private key to continue."
        }
        #endif
        return nil
    }

    private var canSave: Bool {
        draft.isValid && sshValidationError == nil && !tunnelConflict
    }

    // MARK: - Actions

    private func applySettingsDefaults() {
        guard isCreating, !appliedSettingsDefaults else { return }
        appliedSettingsDefaults = true
        draft.controls.cursorMode = settings.settings.defaultCursorMode
        draft.controls.sharedClipboard = settings.settings.sharedClipboard
        draft.controls.autoReconnect = settings.settings.autoReconnect
    }

    private func save() {
        guard canSave, !tunnelConflict else { return }
        if sshEnabled {
            draft.ssh = SSHProfile(
                enabled: true,
                host: sshHost,
                port: sshPortNumber ?? 22,
                username: sshUsername,
                authMethod: sshAuthMethod,
                keyPath: sshKeyPath,
                importedKeyID: sshImportedKeyID,
                hostKeyFingerprint: sshFingerprint
            )
        } else {
            draft.ssh = nil
        }

        let profile = draft.normalized()
        guard profile.isValid else { return }
        if isCreating {
            store.add(profile)
        } else {
            store.update(profile)
        }
        if profile.authentication == .none || password.isEmpty {
            OpenScreensCredentials.deletePassword(for: profile.id)
        } else {
            OpenScreensCredentials.setPassword(password, for: profile.id)
        }
        if let ssh = profile.ssh, ssh.enabled {
            switch ssh.authMethod {
            case .password:
                OpenScreensCredentials.setSecret(sshPassword, kind: "ssh-password", for: profile.id)
                OpenScreensCredentials.deleteSecret(kind: "ssh-passphrase", for: profile.id)
            case .privateKey:
                OpenScreensCredentials.deleteSecret(kind: "ssh-password", for: profile.id)
                OpenScreensCredentials.setSecret(sshKeyPassphrase, kind: "ssh-passphrase", for: profile.id)
            }
        } else {
            OpenScreensCredentials.deleteSecret(kind: "ssh-password", for: profile.id)
            OpenScreensCredentials.deleteSecret(kind: "ssh-passphrase", for: profile.id)
        }
        onSaved?(profile)
        dismiss()
    }

    private var isCreating: Bool {
        if case .create = mode { return true }
        return false
    }

    private var title: String {
        isCreating ? "New Connection" : "Edit Connection"
    }

    private var missingFieldsMessage: String {
        if draft.trimmedName.isEmpty && draft.trimmedHost.isEmpty {
            return "Enter a name and a hostname to continue."
        }
        if draft.trimmedName.isEmpty {
            return "Enter a name to continue."
        }
        return "Enter a hostname to continue."
    }
}

private enum EditorSection: String, CaseIterable, Identifiable {
    case connection
    case security
    case controls
    case advanced

    var id: String { rawValue }

    var title: String {
        switch self {
        case .connection: "Connection"
        case .security: "Security"
        case .controls: "Controls"
        case .advanced: "Advanced"
        }
    }

    var systemImage: String {
        switch self {
        case .connection: "display"
        case .security: "lock.shield"
        case .controls: "hand.point.up.left"
        case .advanced: "slider.horizontal.3"
        }
    }
}

private struct EditorFormStyle: ViewModifier {
    @ViewBuilder
    func body(content: Content) -> some View {
        #if os(macOS)
        content.formStyle(.grouped)
        #else
        content
        #endif
    }
}

private struct HostInputStyle: ViewModifier {
    @ViewBuilder
    func body(content: Content) -> some View {
        #if os(iOS)
        content
            .keyboardType(.URL)
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
        #else
        content.autocorrectionDisabled()
        #endif
    }
}

private struct PlainInputStyle: ViewModifier {
    @ViewBuilder
    func body(content: Content) -> some View {
        #if os(iOS)
        content
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
        #else
        content.autocorrectionDisabled()
        #endif
    }
}

private struct WireGuardImportError: LocalizedError {
    let message: String

    init(_ message: String) {
        self.message = message
    }

    var errorDescription: String? { message }
}
