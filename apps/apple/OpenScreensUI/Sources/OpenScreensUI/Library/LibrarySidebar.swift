import SwiftUI

/// Source list shared by the macOS split view and iPad navigation.
public struct LibrarySidebar: View {
    private enum GroupDialog: Identifiable {
        case create
        case rename(LibraryGroup)

        var id: String {
            switch self {
            case .create: "create"
            case .rename(let group): group.id.uuidString
            }
        }
    }

    @Binding private var selection: LibraryDestination?
    @Environment(ConnectionStore.self) private var store
    @State private var groupDialog: GroupDialog?
    @State private var groupName = ""
    @State private var pendingDeletion: LibraryGroup?

    public init(selection: Binding<LibraryDestination?>) {
        _selection = selection
    }

    public var body: some View {
        List(selection: $selection) {
            Section {
                row(.nearby)
                row(.links)
            }
            Section("Services") {
                row(.connect)
            }
            Section("Custom") {
                row(.custom)
                ForEach(store.groups) { group in
                    groupRow(group)
                }
                Button {
                    groupName = ""
                    groupDialog = .create
                } label: {
                    Label("New Group", systemImage: "folder.badge.plus")
                        .font(.callout)
                }
                .buttonStyle(.plain)
                .foregroundStyle(Theme.Colors.accent)
            }
        }
        .listStyle(.sidebar)
        .navigationTitle("OpenScreens")
        .alert(dialogTitle, isPresented: dialogBinding) {
            TextField("Group Name", text: $groupName)
            Button("Save") {
                commitGroupDialog()
            }
            Button("Cancel", role: .cancel) {
                groupDialog = nil
            }
        }
        .confirmationDialog(
            "Delete Group?",
            isPresented: deletionBinding,
            titleVisibility: .visible,
            presenting: pendingDeletion
        ) { group in
            Button("Delete", role: .destructive) {
                if selection == .group(group.id) {
                    selection = .section(.custom)
                }
                store.deleteGroup(id: group.id)
                pendingDeletion = nil
            }
            Button("Cancel", role: .cancel) {
                pendingDeletion = nil
            }
        } message: { _ in
            Text("Connections in this group stay in the library.")
        }
    }

    private var dialogTitle: String {
        switch groupDialog {
        case .rename: NSLocalizedString("Rename Group", comment: "Group dialog title")
        default: NSLocalizedString("New Group", comment: "Group dialog title")
        }
    }

    private var dialogBinding: Binding<Bool> {
        Binding(
            get: { groupDialog != nil },
            set: { presented in
                if !presented { groupDialog = nil }
            }
        )
    }

    private var deletionBinding: Binding<Bool> {
        Binding(
            get: { pendingDeletion != nil },
            set: { presented in
                if !presented { pendingDeletion = nil }
            }
        )
    }

    private func commitGroupDialog() {
        switch groupDialog {
        case .create:
            store.addGroup(name: groupName)
        case .rename(let group):
            store.renameGroup(id: group.id, to: groupName)
        case nil:
            break
        }
        groupDialog = nil
    }

    private func row(_ section: LibrarySection) -> some View {
        HStack(spacing: 8) {
            Image(systemName: section.systemImage)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.secondary)
                .frame(width: 20)

            VStack(alignment: .leading, spacing: 1) {
                Text(section.title)
                if let status = section.serviceStatus {
                    Text(status)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }

            Spacer(minLength: 4)

            let count = store.count(in: section)
            if count > 0 {
                CountBadge(count: count)
            }
        }
        .tag(LibraryDestination.section(section))
        .accessibilityElement(children: .combine)
    }

    private func groupRow(_ group: LibraryGroup) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "folder")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.secondary)
                .frame(width: 20)

            Text(group.name)

            Spacer(minLength: 4)

            let count = store.count(in: group.id)
            if count > 0 {
                CountBadge(count: count)
            }
        }
        .tag(LibraryDestination.group(group.id))
        .accessibilityElement(children: .combine)
        .contextMenu {
            Button {
                groupName = group.name
                groupDialog = .rename(group)
            } label: {
                Label("Rename…", systemImage: "pencil")
            }

            Button(role: .destructive) {
                pendingDeletion = group
            } label: {
                Label("Delete…", systemImage: "trash")
            }
        }
    }
}
