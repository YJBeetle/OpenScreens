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

    @ObservationIgnored private let fileURL: URL
    @ObservationIgnored private let encoder: JSONEncoder
    @ObservationIgnored private let decoder: JSONDecoder

    public init(fileURL: URL? = nil, seedDemoData: Bool = true) {
        self.fileURL = fileURL ?? Self.defaultFileURL()
        self.encoder = Self.makeEncoder()
        self.decoder = Self.makeDecoder()

        if let stored = Self.load(from: self.fileURL, decoder: decoder) {
            self.connections = stored
        } else if seedDemoData {
            self.connections = Self.sampleConnections()
            persist()
        } else {
            self.connections = []
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

    public func profiles(in section: LibrarySection, matching query: String = "") -> [ConnectionProfile] {
        guard !section.isService else { return [] }
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return connections
            .filter { profile in
                profile.section == section && (needle.isEmpty || profile.searchIndex.contains(needle))
            }
            .sorted(by: Self.libraryOrder)
    }

    /// Global search across local connection groups.
    public func search(_ query: String) -> [ConnectionProfile] {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return connections
            .filter { !$0.section.isService && (needle.isEmpty || $0.searchIndex.contains(needle)) }
            .sorted(by: Self.libraryOrder)
    }

    // MARK: - Mutations

    public func add(_ profile: ConnectionProfile) {
        connections.append(profile)
        persist()
    }

    public func update(_ profile: ConnectionProfile) {
        guard let index = connections.firstIndex(where: { $0.id == profile.id }) else { return }
        connections[index] = profile
        persist()
    }

    public func delete(id: UUID) {
        connections.removeAll { $0.id == id }
        persist()
    }

    @discardableResult
    public func duplicate(id: UUID) -> ConnectionProfile? {
        guard var copy = connection(id: id) else { return nil }
        copy.id = UUID()
        copy.name += " Copy"
        copy.createdAt = .now
        copy.lastConnectedAt = nil
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
                name: "Studio Mac",
                host: "studio-mac.local",
                platform: .macos,
                section: .nearby,
                palette: .ocean,
                authentication: .macOSAccount,
                username: "designer",
                isFavorite: true,
                isDiscovered: true,
                createdAt: referenceDate.addingTimeInterval(-86_400 * 21),
                lastConnectedAt: referenceDate.addingTimeInterval(-3_600)
            ),
            ConnectionProfile(
                name: "Lab Workstation",
                host: "10.20.0.14",
                platform: .linux,
                section: .links,
                palette: .forest,
                authentication: .vncPassword,
                username: "lab",
                createdAt: referenceDate.addingTimeInterval(-86_400 * 12),
                lastConnectedAt: referenceDate.addingTimeInterval(-86_400 * 2)
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
                lastConnectedAt: referenceDate.addingTimeInterval(-86_400)
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
                createdAt: referenceDate.addingTimeInterval(-86_400 * 45)
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
    }

    private func persist() {
        let payload = StoreFile(version: 1, connections: connections)
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

    private static func load(from url: URL, decoder: JSONDecoder) -> [ConnectionProfile]? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? decoder.decode(StoreFile.self, from: data).connections
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

    private static func libraryOrder(_ lhs: ConnectionProfile, _ rhs: ConnectionProfile) -> Bool {
        if lhs.isFavorite != rhs.isFavorite {
            return lhs.isFavorite
        }
        return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
    }
}
