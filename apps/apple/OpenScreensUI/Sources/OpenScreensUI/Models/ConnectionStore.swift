import Foundation
import Observation
import os

/// File-backed connection library. The on-disk format is plain Codable JSON so
/// it can be moved to SwiftData or a shared core store later without touching
/// the views.
@MainActor
@Observable
public final class ConnectionStore {
    private static let logger = Logger(subsystem: "app.openscreens", category: "ConnectionStore")

    public private(set) var connections: [ConnectionProfile]
    public private(set) var groups: [LibraryGroup]

    @ObservationIgnored private let fileURL: URL
    @ObservationIgnored private let encoder: JSONEncoder
    @ObservationIgnored private let decoder: JSONDecoder
    @ObservationIgnored private var dismissedDiscovered: Set<String> = []

    public init(fileURL: URL? = nil, seedDemoData: Bool = true) {
        self.fileURL = fileURL ?? Self.defaultFileURL()
        self.encoder = Self.makeEncoder()
        self.decoder = Self.makeDecoder()

        if let stored = Self.load(from: self.fileURL, decoder: decoder) {
            self.connections = stored.connections.filter { !$0.isDiscovered }
            self.groups = stored.groups ?? []
            if self.connections.count != stored.connections.count {
                persist()
            }
        } else if seedDemoData {
            self.connections = Self.sampleConnections()
            self.groups = []
            persist()
        } else {
            self.connections = []
            self.groups = []
        }
    }

    // MARK: - Queries

    public func connection(id: UUID) -> ConnectionProfile? {
        connections.first { $0.id == id }
    }

    public func count(in section: LibrarySection) -> Int {
        guard !section.isService else { return 0 }
        return connections.count { $0.section == section }
    }

    public func count(in groupID: UUID) -> Int {
        connections.count { $0.section == .custom && $0.groupID == groupID }
    }

    public func group(id: UUID) -> LibraryGroup? {
        groups.first { $0.id == id }
    }

    public func profiles(
        in section: LibrarySection,
        groupID: UUID? = nil,
        matching query: String = "",
        sort: LibrarySortOrder = .name
    ) -> [ConnectionProfile] {
        guard !section.isService else { return [] }
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let filtered = connections.filter { profile in
            guard profile.section == section else { return false }
            if let groupID, profile.groupID != groupID { return false }
            return needle.isEmpty || profile.searchIndex.contains(needle)
        }
        if sort == .manual {
            return filtered
        }
        return filtered.sorted { Self.libraryOrder($0, $1, sort: sort) }
    }

    /// Global search across local connection groups.
    public func search(_ query: String) -> [ConnectionProfile] {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return connections
            .filter { !$0.section.isService && (needle.isEmpty || $0.searchIndex.contains(needle)) }
            .sorted { Self.libraryOrder($0, $1, sort: .name) }
    }

    /// Moves a connection to a new position in the supplied manual order.
    public func move(id: UUID, toIndex destination: Int, within orderedIDs: [UUID]) {
        guard let source = orderedIDs.firstIndex(of: id),
              let sourceIndex = connections.firstIndex(where: { $0.id == id })
        else { return }

        var reordered = orderedIDs
        reordered.move(
            fromOffsets: IndexSet(integer: source),
            toOffset: min(max(destination, 0), orderedIDs.count)
        )
        guard let position = reordered.firstIndex(of: id) else { return }

        let profile = connections.remove(at: sourceIndex)
        if position + 1 < reordered.count,
           let anchor = connections.firstIndex(where: { $0.id == reordered[position + 1] }) {
            connections.insert(profile, at: anchor)
        } else if position > 0,
                  let anchor = connections.firstIndex(where: { $0.id == reordered[position - 1] }) {
            connections.insert(profile, at: anchor + 1)
        } else {
            connections.append(profile)
        }
        persist()
    }

    /// Moves a connection past its neighbour in the supplied manual order.
    public func move(id: UUID, by offset: Int, within orderedIDs: [UUID]) {
        guard let position = orderedIDs.firstIndex(of: id),
              orderedIDs.indices.contains(position + offset)
        else { return }
        let neighbourID = orderedIDs[position + offset]
        guard let source = connections.firstIndex(where: { $0.id == id }),
              let target = connections.firstIndex(where: { $0.id == neighbourID })
        else { return }
        connections.swapAt(source, target)
        persist()
    }

    // MARK: - Mutations

    public func add(_ profile: ConnectionProfile) {
        connections.append(profile)
        persist()
    }

    public func update(_ profile: ConnectionProfile) {
        var stored = profile
        if stored.isDiscovered {
            stored.isDiscovered = false
            stored.section = .custom
        }
        if let index = connections.firstIndex(where: { $0.id == profile.id }) {
            connections[index] = stored
        } else if profile.isDiscovered {
            // The service can disappear while its editor is open.
            connections.append(stored)
        } else {
            return
        }
        persist()
    }

    public func delete(id: UUID) {
        guard let profile = connections.first(where: { $0.id == id }) else { return }
        connections.removeAll { $0.id == id }
        if profile.isDiscovered {
            dismissedDiscovered.insert(Self.endpointKey(host: profile.host, port: profile.port))
            return
        }
        persist()
    }

    /// Keeps a discovered computer in the saved library.
    @discardableResult
    public func saveDiscovered(id: UUID) -> ConnectionProfile? {
        guard let index = connections.firstIndex(where: { $0.id == id }),
              connections[index].isDiscovered
        else { return nil }
        connections[index].isDiscovered = false
        connections[index].section = .custom
        persist()
        return connections[index]
    }

    /// Reconciles the transient Nearby section with the current Bonjour results.
    public func syncDiscovered(_ computers: [DiscoveredComputer]) {
        let savedKeys = Set(
            connections
                .filter { !$0.isDiscovered }
                .map { Self.endpointKey(host: $0.host, port: $0.port) }
        )
        var previous: [String: ConnectionProfile] = [:]
        for profile in connections where profile.isDiscovered {
            previous[Self.endpointKey(host: profile.host, port: profile.port)] = profile
        }

        var seen = Set<String>()
        var discovered: [ConnectionProfile] = []
        for computer in computers {
            let key = Self.endpointKey(host: computer.host, port: computer.port)
            guard !savedKeys.contains(key),
                  !dismissedDiscovered.contains(key),
                  seen.insert(key).inserted
            else { continue }

            if var existing = previous[key] {
                existing.name = computer.name
                existing.host = computer.host
                existing.port = computer.port
                discovered.append(existing)
            } else {
                discovered.append(
                    ConnectionProfile(
                        name: computer.name,
                        host: computer.host,
                        port: computer.port,
                        section: .nearby,
                        authentication: .vncPassword,
                        isDiscovered: true
                    )
                )
            }
        }

        connections = connections.filter { !$0.isDiscovered } + discovered
    }

    private static func endpointKey(host: String, port: Int) -> String {
        "\(host.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()):\(port)"
    }

    @discardableResult
    public func addGroup(name: String) -> LibraryGroup {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let group = LibraryGroup(name: trimmed.isEmpty ? defaultGroupName : trimmed)
        groups.append(group)
        persist()
        return group
    }

    public func renameGroup(id: UUID, to name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              let index = groups.firstIndex(where: { $0.id == id })
        else { return }
        groups[index].name = trimmed
        persist()
    }

    /// Removes a group; its connections stay in the library without a group.
    public func deleteGroup(id: UUID) {
        groups.removeAll { $0.id == id }
        for index in connections.indices where connections[index].groupID == id {
            connections[index].groupID = nil
        }
        persist()
    }

    private var defaultGroupName: String {
        NSLocalizedString("Untitled Group", comment: "Default name for a library group")
    }

    @discardableResult
    public func duplicate(id: UUID) -> ConnectionProfile? {
        guard var copy = connection(id: id) else { return nil }
        copy.id = UUID()
        copy.name += " Copy"
        copy.createdAt = .now
        copy.lastConnectedAt = nil
        copy.connectionCount = nil
        copy.isDiscovered = false
        copy.section = .custom
        connections.append(copy)
        persist()
        return copy
    }

    public func toggleFavorite(id: UUID) {
        guard let index = connections.firstIndex(where: { $0.id == id }) else { return }
        connections[index].isFavorite.toggle()
        persist()
    }

    public func markConnected(id: UUID) {
        guard let index = connections.firstIndex(where: { $0.id == id }) else { return }
        connections[index].lastConnectedAt = .now
        connections[index].connectionCount = (connections[index].connectionCount ?? 0) + 1
        persist()
    }

    /// Adds any missing built-in sample hosts. Existing connections are kept.
    public func restoreSamples() {
        let samples = Self.sampleConnections()
        for sample in samples where !connections.contains(where: {
            $0.name == sample.name && $0.host == sample.host
        }) {
            connections.append(sample)
        }
        persist()
    }

    // MARK: - Sample data

    public static func sampleConnections(referenceDate: Date = .now) -> [ConnectionProfile] {
        [
            ConnectionProfile(
                name: "Lab Workstation",
                host: "10.20.0.14",
                platform: .linux,
                section: .links,
                palette: .forest,
                authentication: .vncPassword,
                username: "lab",
                createdAt: referenceDate.addingTimeInterval(-86_400 * 12),
                lastConnectedAt: referenceDate.addingTimeInterval(-86_400 * 2),
                connectionCount: 14
            ),
            ConnectionProfile(
                name: "Living Room PC",
                host: "media-center.local",
                platform: .windows,
                section: .links,
                palette: .midnight,
                authentication: .vncPassword,
                createdAt: referenceDate.addingTimeInterval(-86_400 * 30)
            ),
            ConnectionProfile(
                name: "Build Runner",
                host: "build-01.internal",
                port: 5901,
                platform: .linux,
                section: .custom,
                palette: .ember,
                authentication: .vncPassword,
                username: "ci",
                createdAt: referenceDate.addingTimeInterval(-86_400 * 8),
                lastConnectedAt: referenceDate.addingTimeInterval(-86_400),
                connectionCount: 6
            ),
            ConnectionProfile(
                name: "Design Studio",
                host: "192.168.1.32",
                platform: .macos,
                section: .custom,
                palette: .plum,
                authentication: .macOSAccount,
                username: "studio",
                isFavorite: true,
                createdAt: referenceDate.addingTimeInterval(-86_400 * 45),
                connectionCount: 2
            ),
            ConnectionProfile(
                name: "Archive Server",
                host: "archive.local",
                platform: .unix,
                section: .custom,
                palette: .slate,
                authentication: .vncPassword,
                createdAt: referenceDate.addingTimeInterval(-86_400 * 60)
            )
        ]
    }

    // MARK: - Persistence

    private struct StoreFile: Codable {
        var version: Int
        var connections: [ConnectionProfile]
        var groups: [LibraryGroup]?
    }

    private func persist() {
        let payload = StoreFile(
            version: 2,
            connections: connections.filter { !$0.isDiscovered },
            groups: groups
        )
        do {
            try FileManager.default.createDirectory(
                at: fileURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            let data = try encoder.encode(payload)
            try data.write(to: fileURL, options: .atomic)
        } catch {
            Self.logger.error("Unable to save connections: \(error.localizedDescription, privacy: .public)")
        }
    }

    private static func load(from url: URL, decoder: JSONDecoder) -> StoreFile? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? decoder.decode(StoreFile.self, from: data)
    }

    private static func defaultFileURL() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        let directory = base.appendingPathComponent("OpenScreens", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory.appendingPathComponent("connections.json")
    }

    private static func makeEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }

    private static func makeDecoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }

    private static func libraryOrder(
        _ lhs: ConnectionProfile,
        _ rhs: ConnectionProfile,
        sort: LibrarySortOrder
    ) -> Bool {
        if lhs.isFavorite != rhs.isFavorite {
            return lhs.isFavorite
        }
        switch sort {
        case .name, .manual:
            return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
        case .lastConnected:
            let left = lhs.lastConnectedAt ?? .distantPast
            let right = rhs.lastConnectedAt ?? .distantPast
            if left != right {
                return left > right
            }
            return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
        case .connectionCount:
            let left = lhs.connectionCount ?? 0
            let right = rhs.connectionCount ?? 0
            if left != right {
                return left > right
            }
            return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
        }
    }
}
