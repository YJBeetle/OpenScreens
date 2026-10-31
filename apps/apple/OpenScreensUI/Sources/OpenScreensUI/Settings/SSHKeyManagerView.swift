import SwiftUI
import UniformTypeIdentifiers

/// Manage private keys imported for SSH jump hosts. The PEM stays in the
/// Keychain; this screen only lists what is available.
public struct SSHKeyManagerView: View {
    @Environment(SSHKeyVault.self) private var vault

    @State private var importing = false
    @State private var importError: String?

    public init() {}

    public var body: some View {
        List {
            if vault.keys.isEmpty {
                ContentUnavailableView(
                    "No SSH Keys",
                    systemImage: "key",
                    description: Text("Import a private key to use key authentication over SSH.")
                )
                .listRowBackground(Color.clear)
            } else {
                ForEach(vault.keys) { key in
                    VStack(alignment: .leading, spacing: 3) {
                        Text(key.name)
                        Text(key.createdAt, format: .dateTime.year().month().day().hour().minute())
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .onDelete { offsets in
                    offsets.map { vault.keys[$0] }.forEach(vault.delete)
                }
            }
        }
        .navigationTitle("SSH Keys")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    importing = true
                } label: {
                    Label("Import", systemImage: "plus")
                }
            }
        }
        .fileImporter(
            isPresented: $importing,
            allowedContentTypes: [.data]
        ) { result in
            switch result {
            case .success(let url):
                do {
                    try vault.importKey(contentsOf: url)
                    importError = nil
                } catch {
                    importError = error.localizedDescription
                }
            case .failure(let error):
                importError = error.localizedDescription
            }
        }
        .alert(
            "Import Failed",
            isPresented: Binding(
                get: { importError != nil },
                set: { presented in
                    if !presented { importError = nil }
                }
            )
        ) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(importError ?? "")
        }
    }
}
