import XCTest
@testable import OpenScreensUI

final class VNCLinkTests: XCTestCase {
    func testParsesHostPortAndUser() {
        XCTAssertEqual(
            VNCLink.parse(URL(string: "vnc://studio.local")!),
            VNCLink(host: "studio.local")
        )
        XCTAssertEqual(
            VNCLink.parse(URL(string: "vnc://10.0.0.2:5901")!),
            VNCLink(host: "10.0.0.2", port: 5901)
        )
        XCTAssertEqual(
            VNCLink.parse(URL(string: "vnc://designer@studio.local:5902")!),
            VNCLink(host: "studio.local", port: 5902, username: "designer")
        )
    }

    func testBuildsLinksThatParseBack() {
        XCTAssertEqual(
            VNCLink(host: "studio.local").url?.absoluteString,
            "vnc://studio.local"
        )
        XCTAssertEqual(
            VNCLink(host: "10.0.0.2", port: 5901).url?.absoluteString,
            "vnc://10.0.0.2:5901"
        )
        let userLink = VNCLink(host: "build.local", port: 5901, username: "ci")
        XCTAssertEqual(userLink.url?.absoluteString, "vnc://ci@build.local:5901")
        XCTAssertEqual(userLink.url.flatMap(VNCLink.parse), userLink)

        let ipv6 = VNCLink(host: "::1", port: 5901)
        XCTAssertEqual(ipv6.url?.absoluteString, "vnc://[::1]:5901")
        XCTAssertEqual(ipv6.url.flatMap(VNCLink.parse), ipv6)
    }

    func testRejectsMalformedLinks() {
        XCTAssertNil(VNCLink.parse(URL(string: "https://studio.local")!))
        XCTAssertNil(VNCLink.parse(URL(string: "vnc://")!))
        XCTAssertNil(VNCLink.parse(URL(string: "vnc://host:70000")!))
        XCTAssertNil(VNCLink.parse(URL(string: "vnc://host:0")!))
    }

    func testParsesQuickConnectInput() {
        XCTAssertEqual(
            VNCLink.parse(userInput: "  studio.local  "),
            VNCLink(host: "studio.local")
        )
        XCTAssertEqual(
            VNCLink.parse(userInput: "designer@studio.local:5902"),
            VNCLink(host: "studio.local", port: 5902, username: "designer")
        )
        XCTAssertEqual(
            VNCLink.parse(userInput: "VNC://studio.local:5903"),
            VNCLink(host: "studio.local", port: 5903)
        )
        XCTAssertEqual(
            VNCLink.parse(userInput: "[::1]:5901"),
            VNCLink(host: "::1", port: 5901)
        )
        XCTAssertNil(VNCLink.parse(userInput: ""))
        XCTAssertNil(VNCLink.parse(userInput: "   "))
        XCTAssertNil(VNCLink.parse(userInput: "https://studio.local"))
        XCTAssertNil(VNCLink.parse(userInput: "vnc://host:70000"))
    }
}

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

final class RemoteHotCornerTests: XCTestCase {
    func testCornersParkOnFramebufferEdges() {
        XCTAssertEqual(RemoteHotCorner.topLeft.normalizedPoint, CGPoint(x: 0, y: 0))
        XCTAssertEqual(RemoteHotCorner.topRight.normalizedPoint, CGPoint(x: 1, y: 0))
        XCTAssertEqual(RemoteHotCorner.bottomLeft.normalizedPoint, CGPoint(x: 0, y: 1))
        XCTAssertEqual(RemoteHotCorner.bottomRight.normalizedPoint, CGPoint(x: 1, y: 1))
        XCTAssertEqual(RemoteHotCorner.dock.normalizedPoint, CGPoint(x: 0.5, y: 1))
        XCTAssertEqual(
            RemoteHotCorner.corners,
            [.topLeft, .topRight, .bottomLeft, .bottomRight]
        )
    }
}

final class AppSettingsTests: XCTestCase {
    func testToolbarDockRoundTripsAndDefaultsToBottom() throws {
        let encoded = try JSONEncoder().encode(AppSettings(toolbarDock: .left))
        var object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: encoded) as? [String: Any]
        )
        XCTAssertEqual(object["toolbarDock"] as? String, "left")

        var legacy = object
        legacy.removeValue(forKey: "toolbarDock")
        let decoded = try JSONDecoder().decode(
            AppSettings.self,
            from: JSONSerialization.data(withJSONObject: legacy)
        )
        XCTAssertEqual(decoded.toolbarDock, .bottom)

        object["toolbarDock"] = "right"
        let right = try JSONDecoder().decode(
            AppSettings.self,
            from: JSONSerialization.data(withJSONObject: object)
        )
        XCTAssertEqual(right.toolbarDock, .right)
        XCTAssertEqual(right.toolbarDock.orientation, .vertical)
        XCTAssertEqual(ToolbarDock.bottom.orientation, .horizontal)
    }

    func testLibraryLayoutRoundTripsAndDefaultsToGrid() throws {
        let encoded = try JSONEncoder().encode(AppSettings(libraryLayout: .list))
        var object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: encoded) as? [String: Any]
        )
        XCTAssertEqual(object["libraryLayout"] as? String, "list")

        object.removeValue(forKey: "libraryLayout")
        let decoded = try JSONDecoder().decode(
            AppSettings.self,
            from: JSONSerialization.data(withJSONObject: object)
        )
        XCTAssertEqual(decoded.libraryLayout, .grid)
    }

    func testNearbyDiscoveryDefaultsOn() throws {
        let encoded = try JSONEncoder().encode(AppSettings(discoverNearby: false))
        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: encoded) as? [String: Any]
        )
        XCTAssertEqual(object["discoverNearby"] as? Bool, false)

        var legacy = object
        legacy.removeValue(forKey: "discoverNearby")
        let decoded = try JSONDecoder().decode(
            AppSettings.self,
            from: JSONSerialization.data(withJSONObject: legacy)
        )
        XCTAssertTrue(decoded.discoverNearby)
    }

    func testBiometricLockRoundTripsAndDefaultsOff() throws {
        let encoded = try JSONEncoder().encode(AppSettings(requireBiometrics: true))
        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: encoded) as? [String: Any]
        )
        XCTAssertEqual(object["requireBiometrics"] as? Bool, true)

        var legacy = object
        legacy.removeValue(forKey: "requireBiometrics")
        let decoded = try JSONDecoder().decode(
            AppSettings.self,
            from: JSONSerialization.data(withJSONObject: legacy)
        )
        XCTAssertFalse(decoded.requireBiometrics)

        let enabled = try JSONDecoder().decode(AppSettings.self, from: encoded)
        XCTAssertTrue(enabled.requireBiometrics)
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

    func testMoveToIndexReordersManualList() {
        let url = temporaryFileURL()
        defer { removeStore(at: url) }
        let store = ConnectionStore(fileURL: url, seedDemoData: false)
        let a = ConnectionProfile(name: "A", host: "a.local")
        let b = ConnectionProfile(name: "B", host: "b.local")
        let c = ConnectionProfile(name: "C", host: "c.local")
        store.add(a)
        store.add(b)
        store.add(c)

        let ids = [a.id, b.id, c.id]
        store.move(id: c.id, toIndex: 0, within: ids)
        XCTAssertEqual(
            store.profiles(in: .custom, sort: .manual).map(\.name),
            ["C", "A", "B"]
        )

        store.move(id: c.id, toIndex: 3, within: [c.id, a.id, b.id])
        XCTAssertEqual(
            store.profiles(in: .custom, sort: .manual).map(\.name),
            ["A", "B", "C"]
        )
    }

    func testConnectionCountTracksSessionsAndSorts() {
        let url = temporaryFileURL()
        defer { removeStore(at: url) }
        let store = ConnectionStore(fileURL: url, seedDemoData: false)
        let quiet = ConnectionProfile(name: "Quiet", host: "quiet.local")
        let busy = ConnectionProfile(name: "Busy", host: "busy.local")
        store.add(quiet)
        store.add(busy)

        store.markConnected(id: busy.id)
        store.markConnected(id: busy.id)
        store.markConnected(id: quiet.id)

        XCTAssertEqual(store.connection(id: busy.id)?.connectionCount, 2)
        XCTAssertEqual(store.connection(id: quiet.id)?.connectionCount, 1)
        XCTAssertEqual(
            store.profiles(in: .custom, sort: .connectionCount).map(\.name),
            ["Busy", "Quiet"]
        )

        let reloaded = ConnectionStore(fileURL: url, seedDemoData: false)
        XCTAssertEqual(reloaded.connection(id: busy.id)?.connectionCount, 2)
    }

    func testSamplesAreAvailable() {
        let samples = ConnectionStore.sampleConnections()
        XCTAssertFalse(samples.isEmpty)
        XCTAssertTrue(samples.allSatisfy { $0.isValid })
        XCTAssertTrue(samples.allSatisfy { !$0.isDiscovered && $0.section != .nearby })
    }

    func testDiscoverySyncsIntoTemporaryNearbyEntries() throws {
        let url = temporaryFileURL()
        defer { removeStore(at: url) }
        let store = ConnectionStore(fileURL: url, seedDemoData: false)

        store.syncDiscovered([
            DiscoveredComputer(name: "Studio", host: "Studio.local", port: 5900),
            DiscoveredComputer(name: "Studio Duplicate", host: "studio.local", port: 5900),
            DiscoveredComputer(name: "Lab", host: "lab.local", port: 5901),
        ])
        XCTAssertEqual(store.count(in: .nearby), 2)
        XCTAssertEqual(store.profiles(in: .nearby, sort: .name).map(\.name), ["Lab", "Studio"])

        let studio = try XCTUnwrap(store.profiles(in: .nearby).first { $0.name == "Studio" })
        XCTAssertTrue(studio.isDiscovered)
        XCTAssertEqual(studio.host, "Studio.local")
        XCTAssertEqual(studio.endpoint, "Studio.local")

        store.syncDiscovered([DiscoveredComputer(name: "Studio Renamed", host: "studio.local", port: 5900)])
        XCTAssertEqual(store.count(in: .nearby), 1)
        XCTAssertEqual(store.connection(id: studio.id)?.name, "Studio Renamed")

        let reloaded = ConnectionStore(fileURL: url, seedDemoData: false)
        XCTAssertTrue(reloaded.connections.isEmpty)
        XCTAssertEqual(reloaded.count(in: .nearby), 0)
    }

    func testDiscoveredEntriesCanBeSavedOrDismissed() throws {
        let url = temporaryFileURL()
        defer { removeStore(at: url) }
        let store = ConnectionStore(fileURL: url, seedDemoData: false)

        store.syncDiscovered([
            DiscoveredComputer(name: "Studio", host: "studio.local", port: 5900),
            DiscoveredComputer(name: "Lab", host: "lab.local", port: 5901),
        ])
        let studio = try XCTUnwrap(store.profiles(in: .nearby).first { $0.host == "studio.local" })
        let lab = try XCTUnwrap(store.profiles(in: .nearby).first { $0.host == "lab.local" })

        let saved = try XCTUnwrap(store.saveDiscovered(id: studio.id))
        XCTAssertFalse(saved.isDiscovered)
        XCTAssertEqual(saved.section, .custom)
        XCTAssertEqual(store.count(in: .custom), 1)

        store.delete(id: lab.id)
        XCTAssertEqual(store.count(in: .nearby), 0)

        store.syncDiscovered([
            DiscoveredComputer(name: "Studio", host: "studio.local", port: 5900),
            DiscoveredComputer(name: "Lab", host: "lab.local", port: 5901),
        ])
        XCTAssertEqual(store.count(in: .nearby), 0)
        XCTAssertEqual(store.count(in: .custom), 1)

        let reloaded = ConnectionStore(fileURL: url, seedDemoData: false)
        XCTAssertEqual(reloaded.connections.count, 1)
        XCTAssertEqual(reloaded.profiles(in: .custom).first?.host, "studio.local")
    }

    func testSavingEditedDiscoveredConnectionPromotesIt() throws {
        let url = temporaryFileURL()
        defer { removeStore(at: url) }
        let store = ConnectionStore(fileURL: url, seedDemoData: false)

        store.syncDiscovered([DiscoveredComputer(name: "Studio", host: "studio.local", port: 5900)])
        var profile = try XCTUnwrap(store.profiles(in: .nearby).first)
        profile.name = "My Studio"
        profile.username = "designer"
        store.update(profile)

        XCTAssertEqual(store.count(in: .nearby), 0)
        XCTAssertEqual(store.count(in: .custom), 1)
        XCTAssertEqual(store.profiles(in: .custom).first?.name, "My Studio")
        XCTAssertEqual(store.profiles(in: .custom).first?.isDiscovered, false)
    }

    func testEditingDiscoveredConnectionAfterServiceDisappearsStillSaves() throws {
        let url = temporaryFileURL()
        defer { removeStore(at: url) }
        let store = ConnectionStore(fileURL: url, seedDemoData: false)

        store.syncDiscovered([DiscoveredComputer(name: "Studio", host: "studio.local", port: 5900)])
        var profile = try XCTUnwrap(store.profiles(in: .nearby).first)
        store.syncDiscovered([])
        XCTAssertTrue(store.connections.isEmpty)

        profile.name = "Studio Saved"
        store.update(profile)
        XCTAssertEqual(store.count(in: .custom), 1)
        XCTAssertEqual(store.profiles(in: .custom).first?.name, "Studio Saved")
    }

    func testGroupsPersistAndFilterConnections() {
        let url = temporaryFileURL()
        defer { removeStore(at: url) }
        let store = ConnectionStore(fileURL: url, seedDemoData: false)

        let group = store.addGroup(name: "  Work  ")
        XCTAssertEqual(group.name, "Work")

        let grouped = ConnectionProfile(name: "Office", host: "office.local", groupID: group.id)
        let loose = ConnectionProfile(name: "Home", host: "home.local")
        store.add(grouped)
        store.add(loose)

        XCTAssertEqual(store.count(in: group.id), 1)
        XCTAssertEqual(store.profiles(in: .custom, groupID: group.id).map(\.name), ["Office"])
        XCTAssertEqual(store.profiles(in: .custom).count, 2)

        let reloaded = ConnectionStore(fileURL: url, seedDemoData: false)
        XCTAssertEqual(reloaded.groups.map(\.name), ["Work"])
        XCTAssertEqual(reloaded.connection(id: grouped.id)?.groupID, group.id)

        reloaded.deleteGroup(id: group.id)
        XCTAssertTrue(reloaded.groups.isEmpty)
        XCTAssertNil(reloaded.connection(id: grouped.id)?.groupID)
        XCTAssertEqual(reloaded.count(in: .custom), 2)
    }

    func testManualOrderFollowsStoreSequence() {
        let url = temporaryFileURL()
        defer { removeStore(at: url) }
        let store = ConnectionStore(fileURL: url, seedDemoData: false)

        let alpha = ConnectionProfile(name: "Alpha", host: "a.local")
        let bravo = ConnectionProfile(name: "Bravo", host: "b.local")
        let charlie = ConnectionProfile(name: "Charlie", host: "c.local")
        [alpha, bravo, charlie].forEach { store.add($0) }

        XCTAssertEqual(
            store.profiles(in: .custom, sort: .manual).map(\.name),
            ["Alpha", "Bravo", "Charlie"]
        )

        let ids = store.profiles(in: .custom, sort: .manual).map(\.id)
        store.move(id: alpha.id, by: 1, within: ids)
        XCTAssertEqual(
            store.profiles(in: .custom, sort: .manual).map(\.name),
            ["Bravo", "Alpha", "Charlie"]
        )

        store.move(id: alpha.id, by: -1, within: store.profiles(in: .custom, sort: .manual).map(\.id))
        XCTAssertEqual(
            store.profiles(in: .custom, sort: .manual).map(\.name),
            ["Alpha", "Bravo", "Charlie"]
        )
    }

    func testResolveLinkReusesAndCreatesProfiles() {
        let url = temporaryFileURL()
        defer { removeStore(at: url) }
        let store = ConnectionStore(fileURL: url, seedDemoData: false)

        let first = store.resolveLink(URL(string: "vnc://studio.local")!)
        XCTAssertEqual(first?.host, "studio.local")
        XCTAssertEqual(first?.port, 5900)
        XCTAssertEqual(first?.section, .custom)
        XCTAssertEqual(first?.authentication, .vncPassword)
        XCTAssertEqual(store.connections.count, 1)

        let again = store.resolveLink(URL(string: "vnc://STUDIO.local:5900")!)
        XCTAssertEqual(again?.id, first?.id)
        XCTAssertEqual(store.connections.count, 1)

        let account = store.resolveLink(URL(string: "vnc://designer@build.local:5901")!)
        XCTAssertEqual(account?.username, "designer")
        XCTAssertEqual(account?.port, 5901)
        XCTAssertEqual(account?.authentication, .macOSAccount)
        XCTAssertEqual(store.connections.count, 2)

        XCTAssertNil(store.resolveLink(URL(string: "vnc://host:70000")!))
        XCTAssertNil(store.resolveLink(URL(string: "https://host")!))
        XCTAssertEqual(store.connections.count, 2)

        let reloaded = ConnectionStore(fileURL: url, seedDemoData: false)
        XCTAssertEqual(reloaded.connections.count, 2)
        XCTAssertTrue(reloaded.connections.contains { $0.username == "designer" })
    }

    func testSortOrdersCompareNamesAndLastConnected() {
        let url = temporaryFileURL()
        defer { removeStore(at: url) }
        let store = ConnectionStore(fileURL: url, seedDemoData: false)

        let old = ConnectionProfile(
            name: "Old",
            host: "old.local",
            lastConnectedAt: Date(timeIntervalSince1970: 100)
        )
        let recent = ConnectionProfile(
            name: "Recent",
            host: "recent.local",
            lastConnectedAt: Date(timeIntervalSince1970: 200)
        )
        let never = ConnectionProfile(name: "Never", host: "never.local")
        [old, recent, never].forEach { store.add($0) }

        XCTAssertEqual(
            store.profiles(in: .custom, sort: .name).map(\.name),
            ["Never", "Old", "Recent"]
        )
        XCTAssertEqual(
            store.profiles(in: .custom, sort: .lastConnected).map(\.name),
            ["Recent", "Old", "Never"]
        )
    }
}
