import SwiftUI

struct CredentialPrompt: View {
    let endpoint: String
    let challenge: RemoteFailureKind
    @State var username: String
    @State var remember: Bool
    let onConnect: (String, String, Bool) -> Void
    let onCancel: () -> Void

    @State private var password = ""
    @State private var showUsername = false
    @FocusState private var focused: Field?
    private enum Field { case username, password }

    private var requiresUsername: Bool { challenge == .missingUsername }
    private var canConnect: Bool {
        !password.isEmpty && (!requiresUsername || !username.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
    }

    var body: some View {
        Group {
            if #available(iOS 26, macOS 26, *) {
                fittedForm.glassEffect(.regular, in: RoundedRectangle(cornerRadius: Theme.Radius.sheet))
            } else {
                fittedForm.background(.regularMaterial, in: RoundedRectangle(cornerRadius: Theme.Radius.sheet))
            }
        }
        .padding()
        .onAppear {
            showUsername = requiresUsername || !username.isEmpty
            focused = requiresUsername && username.isEmpty ? .username : .password
        }
    }

    private var fittedForm: some View {
        ViewThatFits(in: .vertical) {
            form
            ScrollView { form }
        }
        .frame(maxWidth: 360)
    }

    private var form: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Authentication Required").font(.headline)
            Text(verbatim: endpoint).foregroundStyle(.secondary)
            if challenge == .authenticationFailed {
                Text("Authentication failed. Try again.").foregroundStyle(.red)
            }
            if showUsername || requiresUsername {
                TextField("User Name", text: $username)
                    .textContentType(.username)
                    .autocorrectionDisabled()
                    #if os(iOS)
                    .textInputAutocapitalization(.never)
                    #endif
                    .focused($focused, equals: .username)
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
                .onSubmit(submit)
            Toggle("Remember Credentials", isOn: $remember)
            HStack {
                Spacer()
                Button("Cancel", action: onCancel).keyboardShortcut(.cancelAction)
                Button("Connect", action: submit)
                    .buttonStyle(.borderedProminent)
                    .disabled(!canConnect)
            }
        }
        .textFieldStyle(.roundedBorder)
        .padding(20)
    }

    private func submit() {
        guard canConnect else { return }
        onConnect(username, password, remember)
    }
}
