import SwiftUI

/// A system sheet keeps credential input separate from the remote keyboard.
struct CredentialPrompt: View {
    let endpoint: String
    let challenge: RemoteFailureKind
    let isConnecting: Bool
    let isAwaitingMacPermission: Bool
    @State var username: String
    @State var remember: Bool
    let onConnect: (String, String, Bool) -> Void
    let onRequestPermission: () -> Void
    let onCancel: () -> Void

    @State private var password = ""
    @State private var showUsername = false
    @FocusState private var focused: Field?
    private enum Field { case username, password }

    private var requiresUsername: Bool { challenge.requiresMacAccount }
    private var canConnect: Bool {
        !isConnecting && !password.isEmpty && (!requiresUsername || !username.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
    }

    var body: some View {
        NavigationStack {
            Form {
                if isAwaitingMacPermission {
                    Section {
                        VStack(spacing: 10) {
                            ProgressView()
                            Text("Requesting Permission…")
                                .font(.headline)
                            Text("Approve the screen sharing request on the Mac.")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        }
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 12)
                    } header: {
                        Text(verbatim: endpoint)
                    }
                } else {
                    credentialFields
                }
            }
            .formStyle(.grouped)
            .navigationTitle(isAwaitingMacPermission ? "Ask for Permission" : "Authentication Required")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel", action: onCancel)
                }
                if !isAwaitingMacPermission {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Connect", action: submit)
                            .disabled(!canConnect)
                    }
                }
            }
        }
        #if os(macOS)
        .frame(minWidth: 400, minHeight: 270)
        #endif
        .onAppear {
            showUsername = requiresUsername || !username.isEmpty
            if !isConnecting { focusInput() }
        }
        .onChange(of: isConnecting) { _, connecting in
            if connecting { focused = nil } else { focusInput() }
        }
    }

    @ViewBuilder
    private var credentialFields: some View {
        Section {
            Group {
                if showUsername || requiresUsername {
                    TextField("User Name", text: $username)
                        .textContentType(.username)
                        .autocorrectionDisabled()
                    #if os(iOS)
                        .textInputAutocapitalization(.never)
                    #endif
                        .focused($focused, equals: .username)
                        .submitLabel(.next)
                        .onSubmit { focused = .password }
                } else {
                    Button("Use a Mac account") {
                        showUsername = true
                        focused = .username
                    }
                }
                SecureField("Password", text: $password)
                    .textContentType(.password)
                    .focused($focused, equals: .password)
                    .submitLabel(.go)
                    .onSubmit(submit)
                Toggle("Remember Credentials", isOn: $remember)
            }
            .disabled(isConnecting)
        } header: {
            Text(verbatim: endpoint)
        } footer: {
            if isConnecting {
                ProgressView("Connecting…")
            } else if challenge == .macGuestRequestFailed {
                Text("The Mac did not grant screen sharing permission.")
                    .foregroundStyle(.red)
            } else if challenge == .authenticationFailed {
                Text("Authentication failed. Try again.")
                    .foregroundStyle(.red)
            }
        }
        if challenge.offersMacGuestAccess {
            Section {
                Button(action: onRequestPermission) {
                    Text("Ask for Permission")
                        .frame(maxWidth: .infinity)
                }
                .disabled(isConnecting)
            } header: {
                HStack(spacing: 12) {
                    Rectangle()
                        .fill(Color.secondary.opacity(0.25))
                        .frame(height: 1)
                    Text("Or")
                    Rectangle()
                        .fill(Color.secondary.opacity(0.25))
                        .frame(height: 1)
                }
                .frame(maxWidth: .infinity)
                .textCase(nil)
            }
        }
    }

    private func focusInput() {
        focused = requiresUsername && username.isEmpty ? .username : .password
    }

    private func submit() {
        guard canConnect else { return }
        let entered = password
        password = ""
        onConnect(username, entered, remember)
    }
}
