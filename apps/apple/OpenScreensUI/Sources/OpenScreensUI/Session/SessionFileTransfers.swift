import SwiftUI

#if os(macOS)
import AppKit
#else
import QuickLook
#endif

struct SessionTransferItem: Identifiable {
    let id = UUID()
    let name: String
    let folder: String
    var url: URL?
}

struct SessionFileTransfers: View {
    let model: SessionViewModel

    @Environment(\.dismiss) private var dismiss
    @State private var previewURL: URL?

    var body: some View {
        NavigationStack {
            Group {
                if model.sentFiles.isEmpty && model.receivedFiles.isEmpty {
                    ContentUnavailableView("No File Transfers", systemImage: "arrow.up.arrow.down")
                } else {
                    List {
                        if !model.receivedFiles.isEmpty {
                            Section("Received Files") {
                                ForEach(model.receivedFiles) { item in
                                    receivedRow(item)
                                }
                            }
                        }
                        if !model.sentFiles.isEmpty {
                            Section("Sent Files") {
                                ForEach(model.sentFiles) { item in
                                    VStack(alignment: .leading, spacing: 4) {
                                        Text(item.name)
                                        Text("Sent to \(item.folder)")
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                            .textSelection(.enabled)
                                    }
                                }
                            }
                        }
                    }
                }
            }
            .navigationTitle("File Transfers")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        #if os(macOS)
        .frame(minWidth: 480, minHeight: 320)
        #else
        .quickLookPreview($previewURL)
        #endif
    }

    private func receivedRow(_ item: SessionTransferItem) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 4) {
                Text(item.name)
                Text("Saved in \(localFolder(for: item))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
            Spacer()
            if let url = item.url, FileManager.default.fileExists(atPath: url.path) {
                #if os(macOS)
                Menu {
                    Button("Open", systemImage: "arrow.up.forward.app") {
                        NSWorkspace.shared.open(url)
                    }
                    Button("Show in Finder", systemImage: "folder") {
                        NSWorkspace.shared.activateFileViewerSelecting([url])
                    }
                } label: {
                    fileActionsLabel
                }
                #else
                if (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true {
                    Menu {
                        Button("Open", systemImage: "eye") { previewURL = url }
                        ShareLink(item: url)
                    } label: {
                        fileActionsLabel
                    }
                }
                #endif
            }
        }
    }

    private var fileActionsLabel: some View {
        Label("File Actions", systemImage: "ellipsis.circle")
            .labelStyle(.iconOnly)
    }

    private func localFolder(for item: SessionTransferItem) -> String {
        #if os(iOS)
        return String(
            format: NSLocalizedString("On My iPhone or iPad / OpenScreens / Downloads / %@", comment: "Location in the Files app"),
            item.url?.deletingLastPathComponent().lastPathComponent ?? ""
        )
        #else
        return item.folder
        #endif
    }
}
