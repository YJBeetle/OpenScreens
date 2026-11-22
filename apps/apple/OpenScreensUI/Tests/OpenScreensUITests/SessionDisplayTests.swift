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

    func testProjectionUsesWholeDesktopAndRestoresZoomedSubscription() async {
        let transport = DisplayTestTransport()
        let model = SessionViewModel(profile: ConnectionProfile(name: "Studio", host: "localhost"),
                                     service: DisplayTestService(transport: transport))
        model.start()
        defer { model.stop() }
        transport.emit(.state(.connected))
        transport.emit(.framebufferSize(width: 1600, height: 1200))
        await waitUntil { model.serverSize != nil }
        let size = CGSize(width: 400, height: 300)
        let center = CGPoint(x: 200, y: 150)
        model.applyPinch(scale: 2, startZoom: 1, startPan: .zero,
                         startFocal: center, currentFocal: center, in: size)
        model.scheduleViewportUpdate(in: size, screenPixelWidth: 800)
        let crop = CGRect(x: 0.25, y: 0.25, width: 0.5, height: 0.5)
        await waitUntil { await transport.viewport?.rect == crop }

        model.setExternalDisplayPixelWidth(1920)
        await waitUntil {
            let request = await transport.viewport
            return request?.rect == CGRect(x: 0, y: 0, width: 1, height: 1) && request?.pixels == 1920
        }
        XCTAssertEqual(model.zoom, 2)
        model.setExternalDisplayPixelWidth(nil)
        await waitUntil {
            let request = await transport.viewport
            return request?.rect == crop && request?.pixels == 800
        }
    }

    func testTrackpadSendsThePositionShownByTheLocalCursor() async throws {
        let transport = DisplayTestTransport()
        let profile = ConnectionProfile(name: "Pointer fixture", host: "localhost")
        let model = SessionViewModel(profile: profile, service: DisplayTestService(transport: transport))
        model.cursorMode = .trackpad
        model.start()
        defer { model.stop() }
        transport.emit(.framebufferSize(width: 1200, height: 800))
        await waitUntil { model.state.isConnected && model.serverSize != nil }

        let canvas = CGSize(width: 400, height: 800)
        model.drag(to: CGPoint(x: 180, y: 390), in: canvas)
        model.drag(to: CGPoint(x: 205, y: 410), in: canvas)

        await waitUntil { await transport.lastPointer != nil }
        let lastPointer = await transport.lastPointer
        let event = try XCTUnwrap(lastPointer)
        XCTAssertFalse(event.isRelative)
        XCTAssertEqual(event.x, model.remoteCursor.x, accuracy: 0.0001)
        XCTAssertEqual(event.y, model.remoteCursor.y, accuracy: 0.0001)
    }

    private func waitUntil(_ condition: () async -> Bool, line: UInt = #line) async {
        let clock = ContinuousClock()
        let deadline = clock.now + .seconds(2)
        while !(await condition()) && clock.now < deadline {
            try? await clock.sleep(for: .milliseconds(10))
        }
        let met = await condition()
        XCTAssertTrue(met, line: line)
    }
}

struct DisplayTestService: RemoteSessionService {
    let transport: DisplayTestTransport

    func makeSession() -> any RemoteSessionProtocol { transport }
}

actor DisplayTestTransport: RemoteSessionProtocol {
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
    private(set) var lastPointer: PointerEvent?
    func sendPointer(_ event: PointerEvent) async { lastPointer = event }
    func sendKey(_ event: RemoteKeyEvent) async {}
    func setClipboardSharing(_ enabled: Bool) async {}
    func sendClipboard(_ text: String, automatic: Bool) async {}
    func requestClipboard() async -> Bool { false }
    func setObserveMode(_ observing: Bool) async {}
    private(set) var viewport: (rect: CGRect?, pixels: Int)?
    func setViewport(_ normalizedRect: CGRect?, screenPixelWidth: Int) async {
        viewport = (normalizedRect, screenPixelWidth)
    }

    func selectDisplay(_ id: Int?) async throws { selections.append(id) }
}
