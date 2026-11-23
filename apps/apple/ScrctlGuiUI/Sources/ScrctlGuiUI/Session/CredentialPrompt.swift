import SwiftUI

/// A system sheet keeps credential input separate from the remote keyboard.
struct CredentialPrompt: View {
    let endpoint: String
    let challenge: RemoteFailureKind
    let isConnecting: Bool
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
                if challenge.offersMacGuestAccess {
                    Section {
                        Button("Ask for Permission", action: onRequestPermission)
                            .disabled(isConnecting)
                    }
                }
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
            }
            .formStyle(.grouped)
            .navigationTitle("Authentication Required")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel", action: onCancel)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Connect", action: submit)
                        .disabled(!canConnect)
                }
            }
        }
        #if os(macOS)
        .frame(minWidth: 400, minHeight: 270)
        #endif
        .onAppear {
            showUsername = requiresUsername || !username.isEmpty
            focusInput()
        }
        .onChange(of: isConnecting) { _, connecting in
            if connecting { focused = nil } else { focusInput() }
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
