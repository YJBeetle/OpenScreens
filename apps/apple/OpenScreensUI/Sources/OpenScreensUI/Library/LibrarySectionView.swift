import Foundation
import SwiftUI

/// Grid of connection tiles used by a library section or by search results.
struct ConnectionGrid: View {
    let profiles: [ConnectionProfile]
    let onConnect: (ConnectionProfile) -> Void
    let onEdit: (ConnectionProfile) -> Void
    let onDuplicate: (ConnectionProfile) -> Void
    let onDelete: (ConnectionProfile) -> Void
    var onOpenInNewWindow: ((ConnectionProfile) -> Void)? = nil
    var onMove: ((ConnectionProfile, Int) -> Void)? = nil

    @Environment(SettingsStore.self) private var settings
    @Environment(ConnectionStore.self) private var store
    @State private var pendingDeletion: ConnectionProfile?

    private var density: TileDensity { settings.settings.tileDensity }

    var body: some View {
        ScrollView {
            LazyVGrid(
                columns: [
                    GridItem(
                        .adaptive(minimum: density.minimumTileWidth, maximum: density.maximumTileWidth),
                        spacing: density.columnSpacing,
                        alignment: .top
                    )
                ],
                alignment: .leading,
                spacing: density.columnSpacing
            ) {
                ForEach(profiles) { profile in
                    Button {
                        onConnect(profile)
                    } label: {
                        ConnectionTile(profile: profile)
                    }
                    .buttonStyle(TilePressStyle())
                    .contextMenu {
                        ConnectionActionsMenu(
                            profile: profile,
                            canMove: settings.settings.librarySort == .manual,
                            onConnect: { onConnect(profile) },
                            onEdit: { onEdit(profile) },
                            onDuplicate: { onDuplicate(profile) },
                            onOpenInNewWindow: onOpenInNewWindow.map { action in
                                { action(profile) }
                            },
                            onMove: onMove.map { move in
                                { offset in move(profile, offset) }
                            },
                            onSaveDiscovered: { store.saveDiscovered(id: profile.id) },
                            onRequestDelete: { pendingDeletion = profile }
                        )
                    }
                    .accessibilityAction(named: "Edit") { onEdit(profile) }
                    .accessibilityAction(named: "Duplicate") { onDuplicate(profile) }
                }
            }
            .padding(Theme.Spacing.content)
        }
        .confirmationDialog(
            deletionTitle,
            isPresented: deletionBinding,
            titleVisibility: .visible
        ) {
            Button("Delete", role: .destructive) {
                if let profile = pendingDeletion {
                    onDelete(profile)
                }
                pendingDeletion = nil
            }
            Button("Cancel", role: .cancel) {
                pendingDeletion = nil
            }
        } message: {
            Text("This removes the connection from this device. You can add it again at any time.")
        }
    }

    private var deletionTitle: String {
        guard let profile = pendingDeletion else {
            return NSLocalizedString("Delete Connection?", comment: "Delete confirmation")
        }
        return String(
            format: NSLocalizedString("Delete “%@”?", comment: "Delete confirmation with name"),
            profile.name
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
}

private struct ConnectionActionsMenu: View {
    let profile: ConnectionProfile
    let canMove: Bool
    let onConnect: () -> Void
    let onEdit: () -> Void
    let onDuplicate: () -> Void
    let onOpenInNewWindow: (() -> Void)?
    let onMove: ((Int) -> Void)?
    let onSaveDiscovered: () -> Void
    let onRequestDelete: () -> Void

    var body: some View {
        Button(action: onConnect) {
            Label("Connect", systemImage: "play.fill")
        }

        if let onOpenInNewWindow {
            Button(action: onOpenInNewWindow) {
                Label("Open in New Window", systemImage: "rectangle.badge.plus")
            }
        }

        Button(action: onEdit) {
            Label("Edit…", systemImage: "pencil")
        }

        if profile.isDiscovered {
            Button(action: onSaveDiscovered) {
                Label("Save to Library", systemImage: "square.and.arrow.down")
            }
        } else {
            Button(action: onDuplicate) {
                Label("Duplicate", systemImage: "plus.square.on.square")
            }
        }

        if canMove, let onMove {
            Divider()
            Button {
                onMove(-1)
            } label: {
                Label("Move Up", systemImage: "chevron.up")
            }
            Button {
                onMove(1)
            } label: {
                Label("Move Down", systemImage: "chevron.down")
            }
        }

        Divider()

        Button(role: .destructive, action: onRequestDelete) {
            Label("Delete…", systemImage: "trash")
        }
    }
}

/// Compact rows shown when the library uses the list layout.
struct ConnectionList: View {
    let profiles: [ConnectionProfile]
    let onConnect: (ConnectionProfile) -> Void
    let onEdit: (ConnectionProfile) -> Void
    let onDuplicate: (ConnectionProfile) -> Void
    let onDelete: (ConnectionProfile) -> Void
    var onOpenInNewWindow: ((ConnectionProfile) -> Void)? = nil
    var onMove: ((ConnectionProfile, Int) -> Void)? = nil
    var isReordering: Bool = false
    var onReorder: ((UUID, Int) -> Void)? = nil

    @Environment(SettingsStore.self) private var settings
    @Environment(ConnectionStore.self) private var store
    @State private var pendingDeletion: ConnectionProfile?

    var body: some View {
        List {
            ForEach(profiles) { profile in
                Group {
                    if isReordering {
                        ConnectionRow(profile: profile)
                    } else {
                        Button {
                            onConnect(profile)
                        } label: {
                            ConnectionRow(profile: profile)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .contextMenu {
                    ConnectionActionsMenu(
                        profile: profile,
                        canMove: settings.settings.librarySort == .manual,
                        onConnect: { onConnect(profile) },
                        onEdit: { onEdit(profile) },
                        onDuplicate: { onDuplicate(profile) },
                        onOpenInNewWindow: onOpenInNewWindow.map { action in
                            { action(profile) }
                        },
                        onMove: onMove.map { move in
                            { offset in move(profile, offset) }
                        },
                        onSaveDiscovered: { store.saveDiscovered(id: profile.id) },
                        onRequestDelete: { pendingDeletion = profile }
                    )
                }
                .accessibilityAction(named: "Edit") { onEdit(profile) }
                .accessibilityAction(named: "Duplicate") { onDuplicate(profile) }
            }
            .onMove { offsets, destination in
                guard let source = offsets.first, let onReorder else { return }
                onReorder(profiles[source].id, destination)
            }
        }
        .listStyle(.plain)
        .modifier(ReorderEditMode(isActive: isReordering))
        .confirmationDialog(
            deletionTitle,
            isPresented: deletionBinding,
            titleVisibility: .visible
        ) {
            Button("Delete", role: .destructive) {
                if let profile = pendingDeletion {
                    onDelete(profile)
                }
                pendingDeletion = nil
            }
            Button("Cancel", role: .cancel) {
                pendingDeletion = nil
            }
        } message: {
            Text("This removes the connection from this device. You can add it again at any time.")
        }
    }

    private var deletionTitle: String {
        guard let profile = pendingDeletion else {
            return NSLocalizedString("Delete Connection?", comment: "Delete confirmation")
        }
        return String(
            format: NSLocalizedString("Delete “%@”?", comment: "Delete confirmation with name"),
            profile.name
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
}

private struct ReorderEditMode: ViewModifier {
    let isActive: Bool

    func body(content: Content) -> some View {
        #if os(iOS)
        content.environment(\.editMode, .constant(isActive ? .active : .inactive))
        #else
        content
        #endif
    }
}

private struct ConnectionRow: View {
    let profile: ConnectionProfile

    var body: some View {
        HStack(spacing: 12) {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(profile.palette.gradient)
                .frame(width: 44, height: 44)
                .overlay {
                    Image(systemName: profile.platform.symbolName)
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.92))
                }
                .overlay {
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .strokeBorder(Theme.Colors.tileStroke, lineWidth: 1)
                }

            VStack(alignment: .leading, spacing: 2) {
                Text(profile.name)
                    .font(.body.weight(.medium))
                    .foregroundStyle(.primary)
                    .lineLimit(1)

                Text(profile.subtitle)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer(minLength: 8)

            if profile.isFavorite {
                Image(systemName: "star.fill")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
            }

            if profile.section == .nearby {
                StatusDot(color: Theme.Colors.success, diameter: 7)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(profile.name), \(profile.platform.title), \(profile.subtitle)")
        .accessibilityHint("Connects to this remote screen")
        .accessibilityAddTraits(.isButton)
    }
}

/// Complete content for one library section.
public struct LibrarySectionView: View {
    private let section: LibrarySection
    private let groupID: UUID?
    private let searchText: String
    private let layout: LibraryLayout
    private let reordering: Bool
    private let onConnect: (ConnectionProfile) -> Void
    private let onEdit: (ConnectionProfile) -> Void
    private let onDuplicate: (ConnectionProfile) -> Void
    private let onDelete: (ConnectionProfile) -> Void
    private let onOpenInNewWindow: ((ConnectionProfile) -> Void)?
    private let onNewConnection: () -> Void

    @Environment(ConnectionStore.self) private var store
    @Environment(SettingsStore.self) private var settings
    @Environment(NearbyDiscovery.self) private var nearby

    public init(
        section: LibrarySection,
        groupID: UUID? = nil,
        searchText: String = "",
        layout: LibraryLayout = .grid,
        reordering: Bool = false,
        onConnect: @escaping (ConnectionProfile) -> Void,
        onEdit: @escaping (ConnectionProfile) -> Void,
        onDuplicate: @escaping (ConnectionProfile) -> Void,
        onDelete: @escaping (ConnectionProfile) -> Void,
        onOpenInNewWindow: ((ConnectionProfile) -> Void)? = nil,
        onNewConnection: @escaping () -> Void
    ) {
        self.section = section
        self.groupID = groupID
        self.searchText = searchText
        self.layout = layout
        self.reordering = reordering
        self.onConnect = onConnect
        self.onEdit = onEdit
        self.onDuplicate = onDuplicate
        self.onDelete = onDelete
        self.onOpenInNewWindow = onOpenInNewWindow
        self.onNewConnection = onNewConnection
    }

    public var body: some View {
        if section.isService {
            serviceUnavailable
        } else {
            let profiles = store.profiles(
                in: section,
                groupID: groupID,
                matching: searchText,
                sort: settings.settings.librarySort
            )
            if profiles.isEmpty {
                emptyState
            } else if layout == .list {
                ConnectionList(
                    profiles: profiles,
                    onConnect: onConnect,
                    onEdit: onEdit,
                    onDuplicate: onDuplicate,
                    onDelete: onDelete,
                    onOpenInNewWindow: onOpenInNewWindow,
                    onMove: { profile, offset in
                        store.move(id: profile.id, by: offset, within: profiles.map(\.id))
                    },
                    isReordering: reordering,
                    onReorder: { id, destination in
                        store.move(id: id, toIndex: destination, within: profiles.map(\.id))
                    }
                )
            } else {
                ConnectionGrid(
                    profiles: profiles,
                    onConnect: onConnect,
                    onEdit: onEdit,
                    onDuplicate: onDuplicate,
                    onDelete: onDelete,
                    onOpenInNewWindow: onOpenInNewWindow,
                    onMove: { profile, offset in
                        store.move(id: profile.id, by: offset, within: profiles.map(\.id))
                    }
                )
            }
        }
    }

    private var serviceUnavailable: some View {
        ContentUnavailableView {
            Label(section.title, systemImage: section.systemImage)
        } description: {
            Text(serviceExplanation)
        } actions: {
            Button("New Connection") {
                onNewConnection()
            }
            .buttonStyle(.borderedProminent)
        }
    }

    private var serviceExplanation: String {
        switch section {
        case .connect:
            NSLocalizedString(
                "OpenScreens connects directly to your computers. There is no relay account: use a LAN address, an SSH tunnel or your own VPN.",
                comment: "Connect service explanation"
            )
        default:
            ""
        }
    }

    private var displayedTitle: String {
        if let groupID, let group = store.group(id: groupID) {
            return group.name
        }
        return section.screenTitle
    }

    private var emptyState: some View {
        Group {
            if searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                ContentUnavailableView {
                    Label(
                        groupID == nil
                            ? NSLocalizedString("No Connections", comment: "Empty library")
                            : displayedTitle,
                        systemImage: groupID == nil ? section.systemImage : "folder"
                    )
                } description: {
                    Text(emptyExplanation)
                } actions: {
                    Button("New Connection") {
                        onNewConnection()
                    }
                    .buttonStyle(.borderedProminent)
                }
            } else {
                ContentUnavailableView {
                    Label("No Results", systemImage: "magnifyingglass")
                } description: {
                    Text("No connections in \(displayedTitle) match “\(searchText)”.")
                }
            }
        }
    }

    private var emptyExplanation: String {
        switch section {
        case .nearby:
            if let failure = nearby.failureMessage {
                return failure
            }
            return NSLocalizedString(
                "Computers discovered on this network appear here. You can also add one manually.",
                comment: "Empty library explanation"
            )
        case .links:
            return NSLocalizedString(
                "Connections shared with you as links appear here.",
                comment: "Empty library explanation"
            )
        default:
            if groupID != nil {
                return NSLocalizedString(
                    "Add a computer to this group.",
                    comment: "Empty library explanation"
                )
            }
            return NSLocalizedString(
                "Add a computer to start a remote session.",
                comment: "Empty library explanation"
            )
        }
    }
}

/// Global search across every local connection group.
public struct LibrarySearchResultsView: View {
    private let query: String
    private let layout: LibraryLayout
    private let onConnect: (ConnectionProfile) -> Void
    private let onEdit: (ConnectionProfile) -> Void
    private let onDuplicate: (ConnectionProfile) -> Void
    private let onDelete: (ConnectionProfile) -> Void
    private let onOpenInNewWindow: ((ConnectionProfile) -> Void)?

    @Environment(ConnectionStore.self) private var store

    public init(
        query: String,
        layout: LibraryLayout = .grid,
        onConnect: @escaping (ConnectionProfile) -> Void,
        onEdit: @escaping (ConnectionProfile) -> Void,
        onDuplicate: @escaping (ConnectionProfile) -> Void,
        onDelete: @escaping (ConnectionProfile) -> Void,
        onOpenInNewWindow: ((ConnectionProfile) -> Void)? = nil
    ) {
        self.query = query
        self.layout = layout
        self.onConnect = onConnect
        self.onEdit = onEdit
        self.onDuplicate = onDuplicate
        self.onDelete = onDelete
        self.onOpenInNewWindow = onOpenInNewWindow
    }

    public var body: some View {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            ContentUnavailableView(
                "Search Connections",
                systemImage: "magnifyingglass",
                description: Text("Find a saved computer by name, address, section or user name.")
            )
        } else {
            let results = store.search(trimmed)
            if results.isEmpty {
                ContentUnavailableView {
                    Label("No Results", systemImage: "magnifyingglass")
                } description: {
                    Text("No connections match “\(trimmed)”.")
                }
            } else if layout == .list {
                ConnectionList(
                    profiles: results,
                    onConnect: onConnect,
                    onEdit: onEdit,
                    onDuplicate: onDuplicate,
                    onDelete: onDelete,
                    onOpenInNewWindow: onOpenInNewWindow
                )
            } else {
                ConnectionGrid(
                    profiles: results,
                    onConnect: onConnect,
                    onEdit: onEdit,
                    onDuplicate: onDuplicate,
                    onDelete: onDelete,
                    onOpenInNewWindow: onOpenInNewWindow
                )
            }
        }
    }
}
