import OpenScreensUI
import SwiftUI

struct IPadLibraryView: View {
    @Environment(ConnectionStore.self) private var store
    @Environment(SettingsStore.self) private var settings
    @Environment(\.openWindow) private var openWindow

    @State private var selection: LibraryDestination? = .section(.nearby)
    @State private var searchText = ""
    @State private var activeSheet: IOSLibrarySheet?
    @State private var activeProfile: ConnectionProfile?
    @State private var pendingQuickConnect: URL?

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
                            activeSheet = .quickConnect
                        } label: {
                            Label("Quick Connect", systemImage: "bolt.horizontal")
                        }
                    }

                    ToolbarItem(placement: .primaryAction) {
                        Button {
                            activeSheet = .editor(
                                IOSEditorRoute(mode: .create(.custom), groupID: selectedGroupID)
                            )
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
    }

    @ViewBuilder
    private var detail: some View {
        if isSearching {
            LibrarySearchResultsView(
                query: searchText,
                onConnect: openSession,
                onEdit: edit,
                onDuplicate: duplicate,
                onDelete: delete,
                onOpenInNewWindow: openSessionInNewWindow
            )
        } else if let destination = selection {
            switch destination {
            case .section(let section):
                LibrarySectionView(
                    section: section,
                    onConnect: openSession,
                    onEdit: edit,
                    onDuplicate: duplicate,
                    onDelete: delete,
                    onOpenInNewWindow: openSessionInNewWindow,
                    onNewConnection: {
                        activeSheet = .editor(IOSEditorRoute(mode: .create(.custom)))
                    }
                )
            case .group(let groupID):
                LibrarySectionView(
                    section: .custom,
                    groupID: groupID,
                    onConnect: openSession,
                    onEdit: edit,
                    onDuplicate: duplicate,
                    onDelete: delete,
                    onOpenInNewWindow: openSessionInNewWindow,
                    onNewConnection: {
                        activeSheet = .editor(
                            IOSEditorRoute(mode: .create(.custom), groupID: groupID)
                        )
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

    private var selectedGroupID: UUID? {
        if case .group(let groupID) = selection {
            return groupID
        }
        return nil
    }

    private var navigationTitle: String {
        if isSearching { return NSLocalizedString("Search", comment: "Navigation title") }
        switch selection {
        case .section(let section): return section.screenTitle
        case .group(let groupID): return store.group(id: groupID)?.name ?? "OpenScreens"
        case nil: return "OpenScreens"
        }
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

    private func openSessionInNewWindow(_ profile: ConnectionProfile) {
        store.markConnected(id: profile.id)
        openWindow(id: IOSSessionScene.id, value: profile.id)
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
