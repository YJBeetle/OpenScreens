import OpenScreensUI
import SwiftUI

struct PhoneLibraryView: View {
    private enum GroupDialog: Identifiable {
        case create
        case rename(LibraryGroup)

        var id: String {
            switch self {
            case .create: "create"
            case .rename(let group): group.id.uuidString
            }
        }

        var isRename: Bool {
            if case .rename = self { return true }
            return false
        }
    }

    @Environment(ConnectionStore.self) private var store
    @Environment(SettingsStore.self) private var settings

    @State private var tab: PhoneTab = .library
    @State private var searchText = ""
    @State private var activeSheet: IOSLibrarySheet?
    @State private var activeProfile: ConnectionProfile?
    @State private var selectedGroupID: UUID?
    @State private var groupDialog: GroupDialog?
    @State private var groupName = ""
    @State private var pendingGroupDeletion: LibraryGroup?
    @State private var pendingQuickConnect: URL?

    var body: some View {
        TabView(selection: $tab) {
            Tab(
                PhoneTab.nearby.title,
                systemImage: PhoneTab.nearby.systemImage,
                value: PhoneTab.nearby
            ) {
                NavigationStack {
                    sectionContent(.nearby)
                        .navigationTitle(PhoneTab.nearby.screenTitle)
                        .toolbar { libraryToolbar(groupID: nil) }
                }
            }
            .badge(store.count(in: .nearby))

            Tab(
                PhoneTab.links.title,
                systemImage: PhoneTab.links.systemImage,
                value: PhoneTab.links
            ) {
                NavigationStack {
                    sectionContent(.links)
                        .navigationTitle(PhoneTab.links.screenTitle)
                        .toolbar { libraryToolbar(groupID: nil) }
                }
            }

            Tab(
                PhoneTab.library.title,
                systemImage: PhoneTab.library.systemImage,
                value: PhoneTab.library
            ) {
                NavigationStack {
                    libraryContent
                        .navigationTitle(libraryTitle)
                        .toolbar { libraryToolbar(groupID: effectiveGroupID) }
                }
            }

            Tab(
                PhoneTab.search.title,
                systemImage: PhoneTab.search.systemImage,
                value: PhoneTab.search,
                role: .search
            ) {
                NavigationStack {
                    LibrarySearchResultsView(
                        query: searchText,
                        onConnect: openSession,
                        onEdit: edit,
                        onDuplicate: duplicate,
                        onDelete: delete
                    )
                    .navigationTitle(PhoneTab.search.screenTitle)
                    .searchable(text: $searchText, prompt: "Search connections")
                    .toolbar { libraryToolbar(groupID: nil) }
                }
            }
        }
        .background(Color(uiColor: .systemBackground))
        .sheet(item: $activeSheet, onDismiss: connectPendingLink) { sheet in
            switch sheet {
            case .editor(let route):
                ConnectionEditorView(mode: route.mode, defaultGroupID: route.groupID)
                    .environment(store)
                    .environment(settings)
                    .presentationDetents([.large])
                    .presentationDragIndicator(.visible)
            case .settings:
                SettingsSheet(appVersion: IOSAppInfo.version, buildVersion: IOSAppInfo.buildVersion)
                    .environment(store)
                    .environment(settings)
            case .quickConnect:
                QuickConnectView { url in
                    pendingQuickConnect = url
                }
                .presentationDetents([.height(300)])
                .presentationDragIndicator(.visible)
            }
        }
        .fullScreenCover(item: $activeProfile) { profile in
            IOSSessionPresenter(profile: profile)
                .environment(settings)
        }
        .alert(
            groupDialog?.isRename == true
                ? NSLocalizedString("Rename Group", comment: "Group dialog title")
                : NSLocalizedString("New Group", comment: "Group dialog title"),
            isPresented: groupDialogBinding
        ) {
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
            isPresented: groupDeletionBinding,
            titleVisibility: .visible,
            presenting: pendingGroupDeletion
        ) { group in
            Button("Delete", role: .destructive) {
                if selectedGroupID == group.id {
                    selectedGroupID = nil
                }
                store.deleteGroup(id: group.id)
                pendingGroupDeletion = nil
            }
            Button("Cancel", role: .cancel) {
                pendingGroupDeletion = nil
            }
        } message: { _ in
            Text("Connections in this group stay in the library.")
        }
    }

    private var groupDialogBinding: Binding<Bool> {
        Binding(
            get: { groupDialog != nil },
            set: { presented in
                if !presented { groupDialog = nil }
            }
        )
    }

    private var groupDeletionBinding: Binding<Bool> {
        Binding(
            get: { pendingGroupDeletion != nil },
            set: { presented in
                if !presented { pendingGroupDeletion = nil }
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

    private var effectiveGroupID: UUID? {
        guard let selectedGroupID, store.group(id: selectedGroupID) != nil else {
            return nil
        }
        return selectedGroupID
    }

    @ViewBuilder
    private var libraryContent: some View {
        VStack(spacing: 0) {
            groupChips
                .padding(.horizontal, 20)
                .padding(.top, 8)
                .padding(.bottom, 4)

            if let groupID = effectiveGroupID {
                LibrarySectionView(
                    section: .custom,
                    groupID: groupID,
                    onConnect: openSession,
                    onEdit: edit,
                    onDuplicate: duplicate,
                    onDelete: delete,
                    onNewConnection: {
                        activeSheet = .editor(
                            IOSEditorRoute(mode: .create(.custom), groupID: groupID)
                        )
                    }
                )
            } else {
                sectionContent(.custom)
            }
        }
    }

    private var libraryTitle: String {
        if let id = effectiveGroupID, let group = store.group(id: id) {
            return group.name
        }
        return PhoneTab.library.screenTitle
    }

    @ToolbarContentBuilder
    private func libraryToolbar(groupID: UUID?) -> some ToolbarContent {
        ToolbarItemGroup(placement: .topBarTrailing) {
            Button {
                activeSheet = .editor(IOSEditorRoute(mode: .create(.custom), groupID: groupID))
            } label: {
                Image(systemName: "plus")
            }
            .accessibilityLabel("New Connection")

            Button {
                activeSheet = .quickConnect
            } label: {
                Image(systemName: "bolt.horizontal")
            }
            .accessibilityLabel("Quick Connect")

            Button {
                activeSheet = .settings
            } label: {
                Image(systemName: "gearshape")
            }
            .accessibilityLabel("Settings")
        }
    }

    private var groupChips: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                chip(
                    NSLocalizedString("All", comment: "All library groups"),
                    selected: effectiveGroupID == nil
                ) {
                    selectedGroupID = nil
                }

                ForEach(store.groups) { group in
                    chip(group.name, selected: effectiveGroupID == group.id) {
                        selectedGroupID = group.id
                    }
                    .contextMenu {
                        Button {
                            groupName = group.name
                            groupDialog = .rename(group)
                        } label: {
                            Label("Rename…", systemImage: "pencil")
                        }
                        Button(role: .destructive) {
                            pendingGroupDeletion = group
                        } label: {
                            Label("Delete…", systemImage: "trash")
                        }
                    }
                }

                Button {
                    groupName = ""
                    groupDialog = .create
                } label: {
                    Image(systemName: "folder.badge.plus")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(Theme.Colors.accent)
                        .padding(.horizontal, 11)
                        .padding(.vertical, 7)
                        .background(.quaternary.opacity(0.5), in: Capsule())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("New Group")
            }
        }
        .scrollClipDisabled()
    }

    private func chip(_ title: String, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.footnote.weight(selected ? .semibold : .regular))
                .foregroundStyle(selected ? Color.white : Color.primary)
                .lineLimit(1)
                .padding(.horizontal, 12)
                .padding(.vertical, 7)
                .background {
                    if selected {
                        Capsule().fill(Theme.Colors.accent)
                    } else {
                        Capsule().fill(.quaternary.opacity(0.5))
                    }
                }
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private func sectionContent(_ section: LibrarySection) -> some View {
        LibrarySectionView(
            section: section,
            onConnect: openSession,
            onEdit: edit,
            onDuplicate: duplicate,
            onDelete: delete,
            onNewConnection: {
                activeSheet = .editor(IOSEditorRoute(mode: .create(.custom)))
            }
        )
    }

    private func openSession(_ profile: ConnectionProfile) {
        store.markConnected(id: profile.id)
        activeProfile = profile
    }

    private func connectPendingLink() {
        guard let url = pendingQuickConnect else { return }
        pendingQuickConnect = nil
        guard let profile = store.resolveLink(url) else { return }
        openSession(profile)
    }

    private func edit(_ profile: ConnectionProfile) {
        activeSheet = .editor(IOSEditorRoute(mode: .edit(profile)))
    }

    private func duplicate(_ profile: ConnectionProfile) {
        store.duplicate(id: profile.id)
    }

    private func delete(_ profile: ConnectionProfile) {
        store.delete(id: profile.id)
    }
}

enum PhoneTab: String, CaseIterable, Identifiable {
    case nearby
    case links
    case library
    case search

    var id: String { rawValue }

    var title: String {
        switch self {
        case .nearby: NSLocalizedString("Nearby", comment: "Library tab")
        case .links: NSLocalizedString("Links", comment: "Library tab")
        case .library: NSLocalizedString("Library", comment: "Library tab")
        case .search: NSLocalizedString("Search", comment: "Library tab")
        }
    }

    var screenTitle: String {
        switch self {
        case .library: NSLocalizedString("All Connections", comment: "Library pane title")
        default: title
        }
    }

    var systemImage: String {
        switch self {
        case .nearby: "dot.radiowaves.left.and.right"
        case .links: "link"
        case .library: "square.grid.2x2"
        case .search: "magnifyingglass"
        }
    }
}

