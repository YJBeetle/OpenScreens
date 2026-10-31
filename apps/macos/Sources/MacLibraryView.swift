import OpenScreensUI
import SwiftUI

struct MacLibraryView: View {
    @Environment(ConnectionStore.self) private var store
    @Environment(SettingsStore.self) private var settings
    @Environment(\.openWindow) private var openWindow

    @State private var selection: LibraryDestination? = .section(.nearby)
    @State private var searchText = ""
    @State private var editorRoute: EditorRoute?

    private var isSearching: Bool {
        !searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        NavigationSplitView {
            LibrarySidebar(selection: $selection)
                .navigationSplitViewColumnWidth(min: 190, ideal: 210, max: 260)
        } detail: {
            detailView
                .navigationTitle(navigationTitle)
                .searchable(text: $searchText, placement: .toolbar, prompt: "Search connections")
                .toolbar {
                    ToolbarItem(placement: .primaryAction) {
                        Button {
                            editorRoute = EditorRoute(mode: .create(.custom))
                        } label: {
                            Label("New Connection", systemImage: "plus")
                        }
                        .help("New Connection")
                    }

                    ToolbarItem(placement: .primaryAction) {
                        SettingsLink {
                            Label("Settings", systemImage: "gearshape")
                        }
                        .help("Settings")
                    }
                }
        }
        .navigationSplitViewStyle(.balanced)
        .sheet(item: $editorRoute) { route in
            ConnectionEditorView(mode: route.mode, defaultGroupID: route.groupID)
                .environment(store)
                .environment(settings)
                .frame(width: 720, height: 620)
        }
        .onAppear(perform: autoConnectForTesting)
        .onOpenURL { url in
            guard let profile = store.resolveLink(url) else { return }
            connect(profile)
        }
    }

    @ViewBuilder
    private var detailView: some View {
        if isSearching {
            LibrarySearchResultsView(
                query: searchText,
                onConnect: connect,
                onEdit: edit,
                onDuplicate: duplicate,
                onDelete: delete
            )
        } else if let destination = selection {
            switch destination {
            case .section(let section):
                LibrarySectionView(
                    section: section,
                    onConnect: connect,
                    onEdit: edit,
                    onDuplicate: duplicate,
                    onDelete: delete,
                    onNewConnection: { editorRoute = EditorRoute(mode: .create(.custom)) }
                )
            case .group(let groupID):
                LibrarySectionView(
                    section: .custom,
                    groupID: groupID,
                    onConnect: connect,
                    onEdit: edit,
                    onDuplicate: duplicate,
                    onDelete: delete,
                    onNewConnection: {
                        editorRoute = EditorRoute(mode: .create(.custom), groupID: groupID)
                    }
                )
            }
        } else {
            ContentUnavailableView(
                "Choose a Library",
                systemImage: "square.grid.2x2",
                description: Text("Select a section in the sidebar to see its connections.")
            )
        }
    }

    private var navigationTitle: String {
        if isSearching { return NSLocalizedString("Search", comment: "Navigation title") }
        switch selection {
        case .section(let section): return section.screenTitle
        case .group(let groupID): return store.group(id: groupID)?.name ?? "OpenScreens"
        case nil: return "OpenScreens"
        }
    }

    private func connect(_ profile: ConnectionProfile) {
        store.markConnected(id: profile.id)
        openWindow(id: MacSceneID.session, value: SessionRoute(profileID: profile.id))
    }

    private func autoConnectForTesting() {
        #if DEBUG
        guard ProcessInfo.processInfo.environment["OPENSCREENS_AUTOCONNECT"] == "1",
              let host = ProcessInfo.processInfo.environment["OPENSCREENS_AUTOCONNECT_HOST"],
              let profile = store.connections.first(where: { $0.host == host })
        else { return }
        connect(profile)
        #endif
    }

    private func edit(_ profile: ConnectionProfile) {
        editorRoute = EditorRoute(mode: .edit(profile))
    }

    private func duplicate(_ profile: ConnectionProfile) {
        store.duplicate(id: profile.id)
    }

    private func delete(_ profile: ConnectionProfile) {
        store.delete(id: profile.id)
    }
}

private struct EditorRoute: Identifiable {
    let id = UUID()
    let mode: ConnectionEditorMode
    var groupID: UUID?
}
