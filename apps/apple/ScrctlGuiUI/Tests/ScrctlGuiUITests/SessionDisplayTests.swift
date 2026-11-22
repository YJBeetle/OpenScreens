import XCTest
@testable import ScrctlGuiUI

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
        model.start()
        defer { model.stop() }
        transport.emit(.framebufferSize(width: 1200, height: 800))
        await waitUntil { model.state.isConnected && model.serverSize != nil }

        let canvas = CGSize(width: 400, height: 800)
        model.scheduleViewportUpdate(in: canvas, screenPixelWidth: 400)
        model.setCursorMode(.trackpad)
        model.applyPinch(
            scale: 4, startZoom: 1, startPan: .zero,
            startFocal: .zero, currentFocal: .zero, in: canvas
        )
        model.drag(to: CGPoint(x: 180, y: 390), in: canvas)
        model.drag(to: CGPoint(x: 205, y: 410), in: canvas)

        await waitUntil { await transport.lastPointer != nil }
        let lastPointer = await transport.lastPointer
        let event = try XCTUnwrap(lastPointer)
        XCTAssertFalse(event.isRelative)
        let rect = try XCTUnwrap(model.displayedImageRect(in: canvas))
        XCTAssertEqual(rect.minX + event.x * rect.width, canvas.width / 2, accuracy: 0.0001)
        XCTAssertEqual(rect.minY + event.y * rect.height, canvas.height / 2, accuracy: 0.0001)
        XCTAssertEqual(model.pan.width, -25, accuracy: 0.0001)
        XCTAssertEqual(model.pan.height, -20, accuracy: 0.0001)
        XCTAssertEqual(event.x, model.remoteCursor.x, accuracy: 0.0001)
        XCTAssertEqual(event.y, model.remoteCursor.y, accuracy: 0.0001)

        model.drag(to: CGPoint(x: 5000, y: 5000), in: canvas)
        let edge = try XCTUnwrap(model.displayedImageRect(in: canvas))
        XCTAssertEqual(model.remoteCursor, CGPoint(x: 1, y: 1))
        XCTAssertEqual(edge.maxX, canvas.width, accuracy: 0.0001)
        XCTAssertEqual(edge.maxY, canvas.height, accuracy: 0.0001)

        model.drag(to: CGPoint(x: -5000, y: -5000), in: canvas)
        let oppositeEdge = try XCTUnwrap(model.displayedImageRect(in: canvas))
        XCTAssertEqual(model.remoteCursor, .zero)
        XCTAssertEqual(oppositeEdge.minX, 0, accuracy: 0.0001)
        XCTAssertEqual(oppositeEdge.minY, 0, accuracy: 0.0001)
    }

    func testHybridTapStaysInPlaceAndDragRecentersWithinExpandedRenderingArea() async throws {
        let transport = DisplayTestTransport()
        let model = SessionViewModel(
            profile: ConnectionProfile(name: "Hybrid", host: "localhost"),
            service: DisplayTestService(transport: transport)
        )
        model.start()
        defer { model.stop() }
        transport.emit(.framebufferSize(width: 800, height: 800))
        await waitUntil { model.state.isConnected && model.serverSize != nil }

        let canvas = CGSize(width: 400, height: 400)
        model.scheduleViewportUpdate(
            in: canvas, screenPixelWidth: 500,
            renderBounds: CGRect(x: -60, y: -20, width: 500, height: 500)
        )
        model.applyPinch(
            scale: 2, startZoom: 1, startPan: .zero,
            startFocal: CGPoint(x: 200, y: 200), currentFocal: CGPoint(x: 200, y: 200), in: canvas
        )
        model.tap(at: CGPoint(x: 300, y: 280), in: canvas)
        XCTAssertEqual(model.pan, .zero)
        await waitUntil { await transport.viewport?.rect?.width == 0.625 }
        let requested = await transport.viewport
        let viewport = try XCTUnwrap(requested?.rect)
        XCTAssertEqual(viewport.minX, 0.175, accuracy: 0.0001)
        XCTAssertEqual(viewport.minY, 0.225, accuracy: 0.0001)

        model.drag(to: CGPoint(x: 220, y: 220), in: canvas)
        XCTAssertEqual(model.pan, .zero)
        await waitUntil { model.pan.width < -1 }
        XCTAssertGreaterThan(model.pan.width, -100)
        await waitUntil { abs(model.pan.width + 100) < 0.001 }
        XCTAssertEqual(model.pan.height, -80, accuracy: 0.001)
    }

    func testLastCursorModePersistsForSavedAndNearbyDevices() {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appendingPathComponent("connections.json")
        let store = ConnectionStore(fileURL: file, seedDemoData: false)
        let saved = ConnectionProfile(name: "Saved", host: "saved.local")
        let nearby = ConnectionProfile(name: "Nearby", host: "nearby.local")
        store.add(saved)
        store.setCursorMode(.touch, for: saved)
        store.setCursorMode(.trackpad, for: nearby)

        let reloaded = ConnectionStore(fileURL: file, seedDemoData: false)
        let rediscovered = ConnectionProfile(name: "Nearby", host: "nearby.local")
        XCTAssertEqual(SessionViewModel(profile: saved, connectionStore: reloaded).cursorMode, .touch)
        XCTAssertEqual(SessionViewModel(profile: rediscovered, connectionStore: reloaded).cursorMode, .trackpad)
        XCTAssertEqual(reloaded.connections.count, 1)
        reloaded.syncDiscovered([DiscoveredComputer(name: "Nearby", host: "NEARBY.local.", port: 5900)])
        let discovered = try? XCTUnwrap(reloaded.connections.first { $0.isDiscovered })
        XCTAssertEqual(discovered.flatMap { reloaded.saveDiscovered(id: $0.id) }?.controls.cursorMode, .trackpad)
        XCTAssertEqual(SessionViewModel(profile: ConnectionProfile(name: "New", host: "new.local")).cursorMode, .trackpadAndMouse)
    }

    func testChangesQualityAndReadsFileCapabilitiesInTheActiveSession() async {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = ConnectionStore(fileURL: directory.appendingPathComponent("connections.json"), seedDemoData: false)
        let profile = ConnectionProfile(name: "Capabilities", host: "localhost", quality: .high)
        store.add(profile)
        let transport = DisplayTestTransport()
        let model = SessionViewModel(profile: profile, service: DisplayTestService(transport: transport), connectionStore: store)
        model.start()
        defer { model.stop() }
        await waitUntil { model.state.isConnected }
        XCTAssertFalse(model.supportsFileTransfer)

        transport.emit(.serverFeatures(appleRemote: true, fileUpload: true, fileDownload: false))
        await waitUntil { model.supportsFileUpload }
        XCTAssertTrue(model.isAppleRemote)
        XCTAssertFalse(model.supportsFileDownload)

        model.setQuality(.low)
        await waitUntil { model.quality == .low }
        let setQuality = await transport.changedQuality
        XCTAssertEqual(setQuality, .low)
        XCTAssertEqual(store.connection(id: profile.id)?.quality, .low)

        transport.emit(.state(.disconnected(reason: nil)))
        await waitUntil { !model.supportsFileTransfer }
    }

    func testFillCanZoomOutToTheWholeDesktopAndInToFourLogicalTimes() async throws {
        let transport = DisplayTestTransport()
        var profile = ConnectionProfile(name: "HiDPI", host: "localhost")
        profile.controls.remoteScalePercent = 200
        profile.controls.scaling = .fill
        let model = SessionViewModel(profile: profile, service: DisplayTestService(transport: transport))
        model.start()
        defer { model.stop() }
        transport.emit(.framebufferSize(width: 1200, height: 600))
        await waitUntil { model.state.isConnected && model.serverSize != nil }
        let canvas = CGSize(width: 400, height: 400)
        let center = CGPoint(x: 200, y: 200)
        model.scheduleViewportUpdate(in: canvas, screenPixelWidth: 1200)

        model.showActualSize()
        XCTAssertEqual(try XCTUnwrap(model.displayedImageRect(in: canvas)).width, 600, accuracy: 0.001)

        model.applyPinch(scale: 10, startZoom: model.zoom, startPan: .zero,
                         startFocal: center, currentFocal: center, in: canvas)
        XCTAssertEqual(try XCTUnwrap(model.displayedImageRect(in: canvas)).width, 2400, accuracy: 0.001)

        model.applyPinch(scale: 0.01, startZoom: model.zoom, startPan: .zero,
                         startFocal: center, currentFocal: center, in: canvas)
        XCTAssertEqual(model.displayedImageRect(in: canvas), CGRect(x: 0, y: 100, width: 400, height: 200))
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
    private(set) var changedQuality: ConnectionQuality?

    func setQuality(_ quality: ConnectionQuality) async throws { changedQuality = quality }

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
