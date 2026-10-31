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

    var body: some View {
        VStack(spacing: 0) {
            header
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(Color(uiColor: .systemBackground))
        .safeAreaInset(edge: .bottom, spacing: 0) {
            PhoneTabBar(selection: $tab)
                .padding(.horizontal, 16)
                .padding(.top, 6)
                .padding(.bottom, 4)
        }
        .sheet(item: $activeSheet) { sheet in
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

    private var header: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .center, spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(headerTitle)
                        .font(.largeTitle.weight(.bold))
                        .lineLimit(1)
                        .minimumScaleFactor(0.62)

                    Text(subtitle)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                Spacer(minLength: 4)

                FloatingBar {
                    FloatingIconButton(systemImage: "plus", title: "New Connection") {
                        activeSheet = .editor(
                            IOSEditorRoute(mode: .create(.custom), groupID: effectiveGroupID)
                        )
                    }
                    FloatingIconButton(systemImage: "gearshape", title: "Settings") {
                        activeSheet = .settings
                    }
                }
            }

            if tab == .library {
                groupChips
            }

            if tab == .search {
                searchField
            }
        }
        .padding(.horizontal, 20)
        .padding(.top, 10)
        .padding(.bottom, 6)
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

    @ViewBuilder
    private var content: some View {
        switch tab {
        case .nearby:
            sectionContent(.nearby)
        case .links:
            sectionContent(.links)
        case .library:
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
        case .search:
            LibrarySearchResultsView(
                query: searchText,
                onConnect: openSession,
                onEdit: edit,
                onDuplicate: duplicate,
                onDelete: delete
            )
        }
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

    private var searchField: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)

            TextField("Search connections", text: $searchText)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .submitLabel(.search)
                .accessibilityLabel("Search connections")

            if !searchText.isEmpty {
                Button {
                    searchText = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Clear search")
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    private var headerTitle: String {
        if tab == .library, let id = effectiveGroupID, let group = store.group(id: id) {
            return group.name
        }
        return tab.screenTitle
    }

    private var subtitle: String {
        switch tab {
        case .nearby:
            let count = store.count(in: .nearby)
            guard count != 1 else {
                return NSLocalizedString("1 computer discovered", comment: "Library subtitle")
            }
            return String(
                format: NSLocalizedString("%lld computers discovered", comment: "Library subtitle"),
                count
            )
        case .links:
            return NSLocalizedString("Connections shared with you", comment: "Library subtitle")
        case .library:
            let count = effectiveGroupID.map { store.count(in: $0) } ?? store.count(in: .custom)
            guard count != 1 else {
                return NSLocalizedString("1 saved computer", comment: "Library subtitle")
            }
            return String(
                format: NSLocalizedString("%lld saved computers", comment: "Library subtitle"),
                count
            )
        case .search:
            return NSLocalizedString("Across every section of your library", comment: "Library subtitle")
        }
    }

    private func openSession(_ profile: ConnectionProfile) {
        store.markConnected(id: profile.id)
        activeProfile = profile
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

struct PhoneTabBar: View {
    @Binding var selection: PhoneTab
    @Environment(ConnectionStore.self) private var store

    var body: some View {
        HStack(spacing: 2) {
            ForEach(PhoneTab.allCases) { tab in
                tabButton(tab)
            }
        }
        .padding(6)
        .glassSurface(in: Capsule(style: .continuous))
        .shadow(color: .black.opacity(0.2), radius: 18, y: 8)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Library tabs")
    }

    private func tabButton(_ tab: PhoneTab) -> some View {
        let isSelected = selection == tab
        return Button {
            withAnimation(.snappy(duration: 0.22)) {
                selection = tab
            }
            PlatformFeedback.selection()
        } label: {
            VStack(spacing: 3) {
                ZStack(alignment: .topTrailing) {
                    Image(systemName: tab.systemImage)
                        .font(.system(size: 17, weight: isSelected ? .semibold : .regular))

                    if tab == .nearby {
                        let count = store.count(in: .nearby)
                        if count > 0 {
                            Text("\(count)")
                                .font(.system(size: 9, weight: .bold))
                                .foregroundStyle(.white)
                                .padding(.horizontal, 4)
                                .padding(.vertical, 1)
                                .background(Capsule().fill(Theme.Colors.danger))
                                .offset(x: 9, y: -7)
                        }
                    }
                }
                .frame(height: 20)

                Text(tab.title)
                    .font(.system(size: 10, weight: .medium))
            }
            .foregroundStyle(isSelected ? Color.white : Color.secondary)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 6)
            .background(
                isSelected ? AnyShapeStyle(Theme.Colors.accent) : AnyShapeStyle(Color.clear),
                in: Capsule(style: .continuous)
            )
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(tab.title)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}
