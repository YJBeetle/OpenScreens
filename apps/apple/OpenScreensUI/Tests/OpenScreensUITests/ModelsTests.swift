import XCTest
@testable import OpenScreensUI

final class ConnectionProfileTests: XCTestCase {
    func testValidationAndNormalization() {
        var profile = ConnectionProfile(name: "  Studio  ", host: "  studio.local  ", port: 70000)
        XCTAssertTrue(profile.trimmedName == "Studio")
        XCTAssertTrue(profile.trimmedHost == "studio.local")
        XCTAssertFalse(profile.isValid)

        profile = profile.normalized()
        XCTAssertEqual(profile.name, "Studio")
        XCTAssertEqual(profile.host, "studio.local")
        XCTAssertEqual(profile.port, 65535)
        XCTAssertTrue(profile.isValid)

        let invalid = ConnectionProfile(name: "", host: "")
        XCTAssertFalse(invalid.isValid)
    }

    func testEndpointHidesDefaultPort() {
        let defaultPort = ConnectionProfile(name: "A", host: "a.local")
        XCTAssertEqual(defaultPort.endpoint, "a.local")
        let customPort = ConnectionProfile(name: "B", host: "b.local", port: 5901)
        XCTAssertEqual(customPort.endpoint, "b.local:5901")
    }

    func testSuggestedPaletteIsStable() {
        let id = UUID(uuidString: "0F0E0D0C-0B0A-4009-8007-000504030201")!
        let first = ConnectionProfile.suggestedPalette(for: id)
        let second = ConnectionProfile.suggestedPalette(for: id)
        XCTAssertEqual(first, second)
    }
}

@MainActor
final class ConnectionStoreTests: XCTestCase {
    private func temporaryFileURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("openscreens-tests-\(UUID().uuidString)", isDirectory: true)
            .appendingPathComponent("connections.json")
    }

    private func removeStore(at url: URL) {
        try? FileManager.default.removeItem(at: url.deletingLastPathComponent())
    }

    func testCRUDPersistsToDisk() {
        let url = temporaryFileURL()
        defer { removeStore(at: url) }

        let store = ConnectionStore(fileURL: url, seedDemoData: false)
        XCTAssertTrue(store.connections.isEmpty)

        var profile = ConnectionProfile(name: "Test Host", host: "10.0.0.2", section: .custom)
        store.add(profile)
        XCTAssertEqual(store.count(in: .custom), 1)

        profile.name = "Renamed Host"
        store.update(profile)
        XCTAssertEqual(store.connection(id: profile.id)?.name, "Renamed Host")

        store.duplicate(id: profile.id)
        XCTAssertEqual(store.connections.count, 2)
        XCTAssertTrue(store.connections.contains { $0.name == "Renamed Host Copy" })

        store.toggleFavorite(id: profile.id)
        XCTAssertEqual(store.connection(id: profile.id)?.isFavorite, true)

        let reloaded = ConnectionStore(fileURL: url, seedDemoData: false)
        XCTAssertEqual(reloaded.connections.count, 2)
        XCTAssertEqual(reloaded.connection(id: profile.id)?.name, "Renamed Host")

        store.delete(id: profile.id)
        XCTAssertEqual(store.count(in: .custom), 1)
    }

    func testSearchMatchesNameHostAndUsername() {
        let url = temporaryFileURL()
        defer { removeStore(at: url) }
        let store = ConnectionStore(fileURL: url, seedDemoData: false)
        store.add(ConnectionProfile(name: "Studio Mac", host: "studio.local", username: "designer"))
        store.add(ConnectionProfile(name: "Build Box", host: "10.0.0.9"))

        XCTAssertEqual(store.search("studio").count, 1)
        XCTAssertEqual(store.search("10.0.0").count, 1)
        XCTAssertEqual(store.search("DESIGNER").count, 1)
        XCTAssertEqual(store.search("missing").count, 0)
    }

    func testSamplesAreAvailable() {
        let samples = ConnectionStore.sampleConnections()
        XCTAssertFalse(samples.isEmpty)
        XCTAssertTrue(samples.contains { $0.section == .nearby })
        XCTAssertTrue(samples.allSatisfy { $0.isValid })
    }
}
