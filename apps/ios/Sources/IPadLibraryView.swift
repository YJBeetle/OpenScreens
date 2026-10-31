import OpenScreensUI
import SwiftUI

struct IPadLibraryView: View {
    @Environment(ConnectionStore.self) private var store
    @Environment(SettingsStore.self) private var settings

    @State private var selection: LibrarySection? = .nearby
    @State private var searchText = ""
    @State private var activeSheet: IOSLibrarySheet?
    @State private var activeProfile: ConnectionProfile?

    private var isSearching: Bool {
        !searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        NavigationSplitView {
            LibrarySidebar(selection: $selection)
                .navigationSplitViewColumnWidth(min: 220, ideal: 250, max: 320)
        } detail: {
            detail
                .navigationTitle(navigationTitle)
                .searchable(text: $searchText, prompt: "Search connections")
                .toolbar {
                    ToolbarItem(placement: .primaryAction) {
                        Button {
                            activeSheet = .editor(IOSEditorRoute(mode: .create(.custom)))
                        } label: {
                            Label("New Connection", systemImage: "plus")
                        }
                    }

                    ToolbarItem(placement: .primaryAction) {
                        Button {
                            activeSheet = .settings
                        } label: {
                            Label("Settings", systemImage: "gearshape")
                        }
                    }
                }
        }
        .navigationSplitViewStyle(.balanced)
        .sheet(item: $activeSheet) { sheet in
            switch sheet {
            case .editor(let route):
                ConnectionEditorView(mode: route.mode)
                    .environment(store)
                    .environment(settings)
                    .presentationDetents([.large])
                    .presentationDragIndicator(.visible)
            case .settings:
                SettingsSheet(appVersion: IOSAppInfo.version)
                    .environment(store)
                    .environment(settings)
            }
        }
        .fullScreenCover(item: $activeProfile) { profile in
            IOSSessionPresenter(profile: profile)
                .environment(settings)
        }
    }

    @ViewBuilder
    private var detail: some View {
        if isSearching {
            LibrarySearchResultsView(
                query: searchText,
                onConnect: openSession,
                onEdit: edit,
                onDuplicate: duplicate,
                onDelete: delete
            )
        } else if let section = selection {
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
        return selection?.screenTitle ?? "OpenScreens"
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
