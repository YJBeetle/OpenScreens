import OpenScreensUI
import SwiftUI

struct PhoneLibraryView: View {
    @Environment(ConnectionStore.self) private var store
    @Environment(SettingsStore.self) private var settings

    @State private var tab: PhoneTab = .library
    @State private var searchText = ""
    @State private var activeSheet: IOSLibrarySheet?
    @State private var activeProfile: ConnectionProfile?

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

    private var header: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .center, spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(tab.screenTitle)
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
                        activeSheet = .editor(IOSEditorRoute(mode: .create(.custom)))
                    }
                    FloatingIconButton(systemImage: "gearshape", title: "Settings") {
                        activeSheet = .settings
                    }
                }
            }

            if tab == .search {
                searchField
            }
        }
        .padding(.horizontal, 20)
        .padding(.top, 10)
        .padding(.bottom, 6)
    }

    @ViewBuilder
    private var content: some View {
        switch tab {
        case .nearby:
            sectionContent(.nearby)
        case .links:
            sectionContent(.links)
        case .library:
            sectionContent(.custom)
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

    private var subtitle: String {
        switch tab {
        case .nearby:
            let count = store.count(in: .nearby)
            return count == 1 ? "1 computer discovered" : "\(count) computers discovered"
        case .links:
            return "Connections shared with you"
        case .library:
            let count = store.count(in: .custom)
            return count == 1 ? "1 saved computer" : "\(count) saved computers"
        case .search:
            return "Across every section of your library"
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
        case .nearby: "Nearby"
        case .links: "Links"
        case .library: "Library"
        case .search: "Search"
        }
    }

    var screenTitle: String {
        switch self {
        case .library: "All Connections"
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
        .background(.ultraThinMaterial, in: Capsule(style: .continuous))
        .overlay {
            Capsule(style: .continuous)
                .strokeBorder(Theme.Colors.hairline, lineWidth: 1)
        }
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
