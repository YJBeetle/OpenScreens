import OpenScreensCanvas
import SwiftUI

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
    @Environment(\.dismiss) private var dismiss
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass

    @State private var draft: ConnectionProfile
    @State private var password: String = ""
    @State private var selectedSection: EditorSection = .connection
    @State private var appliedSettingsDefaults = false

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
                .disabled(!draft.isValid)
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
            .disabled(!draft.isValid)
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
    }

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

    // MARK: - Actions

    private func applySettingsDefaults() {
        guard isCreating, !appliedSettingsDefaults else { return }
        appliedSettingsDefaults = true
        draft.controls.cursorMode = settings.settings.defaultCursorMode
        draft.controls.sharedClipboard = settings.settings.sharedClipboard
        draft.controls.autoReconnect = settings.settings.autoReconnect
    }

    private func save() {
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
