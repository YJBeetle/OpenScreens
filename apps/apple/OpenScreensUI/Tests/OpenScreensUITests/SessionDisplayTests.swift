import XCTest
@testable import OpenScreensUI

@MainActor
final class SessionDisplayTests: XCTestCase {
    func testRestoresOnlyReportedDisplayAndKeepsPreferenceOnFallback() async {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }

        let store = ConnectionStore(
            fileURL: directory.appendingPathComponent("connections.json"),
            seedDemoData: false
        )
        let profile = ConnectionProfile(name: "Studio", host: "studio.local", preferredDisplayID: 0)
        store.add(profile)
        let transport = DisplayTestTransport()
        let model = SessionViewModel(
            profile: profile,
            service: DisplayTestService(transport: transport),
            connectionStore: store
        )
        model.start()
        defer { model.stop() }

        let primary = RemoteDisplay(id: 12, name: "Primary", width: 1200, height: 800)
        let remembered = RemoteDisplay(id: 0, name: "Secondary", width: 1200, height: 800)
        transport.emit(.state(.connected))
        transport.emit(.framebufferSize(width: 1200, height: 800))
        transport.emit(.displays([primary]))
        await waitUntil {
            model.displays == [primary]
        }
        let initialRequests = await transport.selections
        XCTAssertTrue(initialRequests.isEmpty)

        transport.emit(.displays([primary, remembered]))
        await waitUntil {
            model.selectedDisplayID == remembered.id
        }
        transport.emit(.framebufferSize(width: 1920, height: 1080))
        await waitUntil {
            model.serverSize == CGSize(width: 1920, height: 1080)
        }
        XCTAssertEqual(model.selectedDisplayID, remembered.id)

        transport.emit(.displays([primary]))
        await waitUntil {
            model.displays == [primary] && !model.isSwitchingDisplay
        }
        XCTAssertNil(model.selectedDisplayID)
        XCTAssertEqual(store.connection(id: profile.id)?.preferredDisplayID, remembered.id)
        let fallbackRequests = await transport.selections
        XCTAssertEqual(fallbackRequests, [remembered.id, nil])

        model.selectDisplay(nil)
        XCTAssertNil(store.connection(id: profile.id)?.preferredDisplayID)
    }

    func testStartsWithLatestSavedQuality() async {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = ConnectionStore(
            fileURL: directory.appendingPathComponent("connections.json"),
            seedDemoData: false
        )
        let profile = ConnectionProfile(name: "Studio", host: "studio.local", quality: .low)
        store.add(profile)
        let transport = DisplayTestTransport()
        let model = SessionViewModel(
            profile: profile,
            service: DisplayTestService(transport: transport),
            connectionStore: store
        )

        var edited = profile
        edited.quality = .high
        store.update(edited)
        model.start()
        defer { model.stop() }
        await waitUntil { model.state.isConnected }

        let requestedQuality = await transport.requestedQuality
        XCTAssertEqual(requestedQuality, .high)
    }

    private func waitUntil(_ condition: () -> Bool, line: UInt = #line) async {
        let clock = ContinuousClock()
        let deadline = clock.now + .seconds(2)
        while !condition() && clock.now < deadline {
            try? await clock.sleep(for: .milliseconds(10))
        }
        XCTAssertTrue(condition(), line: line)
    }
}

private struct DisplayTestService: RemoteSessionService {
    let transport: DisplayTestTransport

    func makeSession() -> any RemoteSessionProtocol { transport }
}

private actor DisplayTestTransport: RemoteSessionProtocol {
    let events: AsyncStream<RemoteSessionEvent>
    private let continuation: AsyncStream<RemoteSessionEvent>.Continuation
    private(set) var selections: [Int?] = []
    private(set) var requestedQuality: ConnectionQuality?

    init() {
        (events, continuation) = AsyncStream.makeStream()
    }

    nonisolated func emit(_ event: RemoteSessionEvent) {
        continuation.yield(event)
    }

    func connect(profile: ConnectionProfile, password: String?, macSessionChoice: MacSessionChoice?) async throws {
        requestedQuality = profile.initialQuality
        emit(.state(.connected))
    }
    func disconnect() async { continuation.finish() }
    func sendPointer(_ event: PointerEvent) async {}
    func sendKey(_ event: RemoteKeyEvent) async {}
    func setClipboardSharing(_ enabled: Bool) async {}
    func sendClipboard(_ text: String, automatic: Bool) async {}
    func requestClipboard() async -> Bool { false }
    func setObserveMode(_ observing: Bool) async {}
    func selectDisplay(_ id: Int?) async throws { selections.append(id) }
}
