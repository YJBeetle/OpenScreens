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
                        Button {
                            onConnect(profile)
                        } label: {
                            Label("Connect", systemImage: "play.fill")
                        }

                        if let onOpenInNewWindow {
                            Button {
                                onOpenInNewWindow(profile)
                            } label: {
                                Label("Open in New Window", systemImage: "rectangle.badge.plus")
                            }
                        }

                        Button {
                            onEdit(profile)
                        } label: {
                            Label("Edit…", systemImage: "pencil")
                        }

                        Button {
                            onDuplicate(profile)
                        } label: {
                            Label("Duplicate", systemImage: "plus.square.on.square")
                        }

                        if settings.settings.librarySort == .manual, let onMove {
                            Divider()
                            Button {
                                onMove(profile, -1)
                            } label: {
                                Label("Move Up", systemImage: "chevron.up")
                            }
                            Button {
                                onMove(profile, 1)
                            } label: {
                                Label("Move Down", systemImage: "chevron.down")
                            }
                        }

                        Divider()

                        Button(role: .destructive) {
                            pendingDeletion = profile
                        } label: {
                            Label("Delete…", systemImage: "trash")
                        }
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

/// Complete content for one library section.
public struct LibrarySectionView: View {
    private let section: LibrarySection
    private let groupID: UUID?
    private let searchText: String
    private let onConnect: (ConnectionProfile) -> Void
    private let onEdit: (ConnectionProfile) -> Void
    private let onDuplicate: (ConnectionProfile) -> Void
    private let onDelete: (ConnectionProfile) -> Void
    private let onOpenInNewWindow: ((ConnectionProfile) -> Void)?
    private let onNewConnection: () -> Void

    @Environment(ConnectionStore.self) private var store
    @Environment(SettingsStore.self) private var settings

    public init(
        section: LibrarySection,
        groupID: UUID? = nil,
        searchText: String = "",
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
    private let onConnect: (ConnectionProfile) -> Void
    private let onEdit: (ConnectionProfile) -> Void
    private let onDuplicate: (ConnectionProfile) -> Void
    private let onDelete: (ConnectionProfile) -> Void
    private let onOpenInNewWindow: ((ConnectionProfile) -> Void)?

    @Environment(ConnectionStore.self) private var store

    public init(
        query: String,
        onConnect: @escaping (ConnectionProfile) -> Void,
        onEdit: @escaping (ConnectionProfile) -> Void,
        onDuplicate: @escaping (ConnectionProfile) -> Void,
        onDelete: @escaping (ConnectionProfile) -> Void,
        onOpenInNewWindow: ((ConnectionProfile) -> Void)? = nil
    ) {
        self.query = query
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
