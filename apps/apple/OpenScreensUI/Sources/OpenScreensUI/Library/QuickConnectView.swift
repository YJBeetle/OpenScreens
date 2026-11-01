import SwiftUI

/// Manual `vnc://` entry shared by the iOS and macOS libraries. The entered
/// address is resolved by `ConnectionStore.resolveLink` by the caller.
public struct QuickConnectView: View {
    @Environment(\.dismiss) private var dismiss

    private let onConnect: (URL) -> Void

    @State private var address = ""
    @FocusState private var addressFocused: Bool

    public init(onConnect: @escaping (URL) -> Void) {
        self.onConnect = onConnect
    }

    private var link: VNCLink? {
        VNCLink.parse(userInput: address)
    }

    private var showsError: Bool {
        !address.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && link == nil
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 12) {
                Image(systemName: "bolt.horizontal.circle.fill")
                    .font(.system(size: 30))
                    .foregroundStyle(Theme.Colors.accent)
                    .accessibilityHidden(true)

                VStack(alignment: .leading, spacing: 2) {
                    Text("Quick Connect")
                        .font(.headline)
                    Text("Open a session by entering its vnc:// address.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }

            TextField("vnc://user@host:5900", text: $address)
                .textFieldStyle(.roundedBorder)
                .focused($addressFocused)
                .onSubmit(connect)
                #if os(iOS)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .keyboardType(.URL)
                #endif

            Text(showsError ? "Enter a valid vnc:// address." : "Port defaults to 5900.")
                .font(.footnote)
                .foregroundStyle(showsError ? Theme.Colors.danger : Color.secondary)

            HStack {
                Spacer()
                Button("Cancel", role: .cancel) {
                    dismiss()
                }
                Button("Connect", action: connect)
                    .buttonStyle(.borderedProminent)
                    .disabled(link == nil)
            }
        }
        .padding(20)
        .onAppear {
            addressFocused = true
        }
    }

    private func connect() {
        guard let url = link?.url else { return }
        dismiss()
        onConnect(url)
    }
}
