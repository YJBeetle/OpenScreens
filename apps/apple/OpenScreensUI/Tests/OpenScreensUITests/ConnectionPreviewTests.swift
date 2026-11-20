import CoreGraphics
import OpenScreensCanvas
import XCTest
@testable import OpenScreensUI

@MainActor
final class ConnectionPreviewTests: XCTestCase {
    @MainActor private struct Library {
        let settings: SettingsStore
        let store: ConnectionStore
        init(_ directory: URL) {
            settings = SettingsStore(fileURL: directory.appendingPathComponent("settings.json"))
            store = ConnectionStore(fileURL: directory.appendingPathComponent("connections.json"),
                                    seedDemoData: false, settings: settings)
        }
    }

    private func session(_ profile: ConnectionProfile, in library: Library) async throws
        -> (SessionViewModel, DisplayTestTransport) {
        let transport = DisplayTestTransport()
        let model = SessionViewModel(profile: profile, service: DisplayTestService(transport: transport),
                                     connectionStore: library.store)
        model.start()
        let deadline = ContinuousClock.now + .seconds(3)
        while !model.state.isConnected, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(5)) }
        XCTAssertTrue(model.state.isConnected)
        return (model, transport)
    }

    private func deliver(_ frame: RemoteFrame, to model: SessionViewModel, via transport: DisplayTestTransport) async throws {
        let count = model.receivedFrames
        transport.emit(.frame(frame))
        let deadline = ContinuousClock.now + .seconds(3)
        while model.receivedFrames == count, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(5)) }
        XCTAssertEqual(model.receivedFrames, count + 1)
    }

    private func frame(_ gray: UInt8, region: RemoteRegion? = nil) -> RemoteFrame {
        let count = (region?.width ?? 960) * (region?.height ?? 480)
        return RemoteFrame(width: 960, height: 480, region: region, data: Data(repeating: gray, count: count * 4))
    }

    // Decode through Core Graphics. JPEG encoding may change individual sample values slightly.
    private func intensity(_ image: CGImage?, file: StaticString = #filePath, line: UInt = #line) throws -> Double {
        let image = try XCTUnwrap(image, file: file, line: line)
        XCTAssertEqual(image.width, 640, file: file, line: line)
        XCTAssertEqual(image.height, 320, file: file, line: line)
        let context = try XCTUnwrap(CGContext(data: nil, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                                               space: CGColorSpaceCreateDeviceRGB(),
                                               bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
        context.draw(image, in: CGRect(x: 0, y: 0, width: 1, height: 1))
        return Double(context.data!.load(as: UInt8.self))
    }

    func testFrameCoverageCheckpointsLastFrameIsolationAndDeletion() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let library = Library(root)
        let one = ConnectionProfile(name: "Fixture A", host: "localhost")
        let two = ConnectionProfile(name: "Fixture B", host: "localhost")
        library.store.add(one)
        library.store.add(two)
        let (a, ta) = try await session(one, in: library)
        let (b, tb) = try await session(two, in: library)
        defer { a.stop(); b.stop() }

        let top = RemoteRegion(x: 0, y: 0, width: 960, height: 240)
        let bottom = RemoteRegion(x: 0, y: 240, width: 960, height: 240)
        try await deliver(frame(0, region: top), to: a, via: ta)
        XCTAssertNil(library.store.previews.image(for: one.id))
        try await deliver(frame(0, region: bottom), to: a, via: ta)
        XCTAssertEqual(try intensity(Library(root).store.previews.image(for: one.id)), 0, accuracy: 2)
        XCTAssertNil(library.store.previews.image(for: two.id))
        try await deliver(frame(235), to: b, via: tb)
        try await deliver(frame(128), to: a, via: ta)
        XCTAssertEqual(try intensity(Library(root).store.previews.image(for: one.id)), 0, accuracy: 2)
        a.disconnect()
        b.stop()
        let reopened = Library(root)
        XCTAssertEqual(try intensity(reopened.store.previews.image(for: one.id)), 128, accuracy: 2)
        XCTAssertEqual(try intensity(reopened.store.previews.image(for: two.id)), 235, accuracy: 2)

        let (failed, tf) = try await session(one, in: reopened)
        try await deliver(frame(0, region: top), to: failed, via: tf)
        tf.emit(.state(.disconnected(reason: "Fixture closed", kind: .closed)))
        failed.stop()
        XCTAssertEqual(try intensity(Library(root).store.previews.image(for: one.id)), 128, accuracy: 2)
        let copy = try XCTUnwrap(reopened.store.duplicate(id: one.id))
        XCTAssertNil(reopened.store.previews.image(for: copy.id))
        reopened.store.delete(id: one.id)
        XCTAssertNil(Library(root).store.previews.image(for: one.id))
        XCTAssertEqual(try intensity(reopened.store.previews.image(for: two.id)), 235, accuracy: 2)
    }

    func testThreeDisplaysWithGapsAndOffsetCrop() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let library = Library(root)
        let profile = ConnectionProfile(name: "Layout fixture", host: "localhost")
        library.store.add(profile)
        let (model, transport) = try await session(profile, in: library)
        defer { model.stop() }
        let displays = [
            RemoteDisplay(id: 1, name: "Left", width: 320, height: 240),
            RemoteDisplay(id: 2, name: "Middle", width: 320, height: 480, origin: CGPoint(x: 320, y: 0)),
            RemoteDisplay(id: 3, name: "Right", width: 320, height: 240, origin: CGPoint(x: 640, y: 240))
        ]
        transport.emit(.framebufferSize(width: 960, height: 480))
        transport.emit(.displays(displays))
        for display in displays {
            let region = RemoteRegion(x: Int(display.origin.x), y: Int(display.origin.y),
                                      width: display.width, height: display.height)
            try await deliver(frame(UInt8(display.id * 60), region: region), to: model, via: transport)
        }
        let preview = try XCTUnwrap(Library(root).store.previews.image(for: profile.id))
        func sample(_ image: CGImage, x: Int, y: Int) throws -> Int {
            let pixel = try XCTUnwrap(image.cropping(to: CGRect(x: x, y: y, width: 1, height: 1)))
            let context = try XCTUnwrap(CGContext(data: nil, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                                                   space: CGColorSpaceCreateDeviceRGB(),
                                                   bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
            context.draw(pixel, in: CGRect(x: 0, y: 0, width: 1, height: 1))
            return Int(context.data!.load(as: UInt8.self))
        }
        XCTAssertEqual(try sample(preview, x: 50, y: 25), 60, accuracy: 2)
        XCTAssertEqual(try sample(preview, x: 50, y: 285), 0, accuracy: 2)
        XCTAssertEqual(try sample(preview, x: 320, y: 285), 120, accuracy: 2)
        XCTAssertEqual(try sample(preview, x: 565, y: 25), 0, accuracy: 2)
        XCTAssertEqual(try sample(preview, x: 565, y: 285), 180, accuracy: 2)

        model.selectDisplay(3)
        let deadline = ContinuousClock.now + .seconds(3)
        while model.selectedDisplayID != 3 && ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(5)) }
        XCTAssertEqual(model.selectedDisplayID, 3)
        transport.emit(.viewport(RemoteViewport(x: 650, y: 250, width: 200, height: 180, scale: 2,
                                               bufferWidth: 100, bufferHeight: 90,
                                               framebufferWidth: 960, framebufferHeight: 480)))
        try await deliver(RemoteFrame(width: 100, height: 90, data: Data(repeating: 202, count: 100 * 90 * 4)),
                          to: model, via: transport)
        model.stop()
        let cropped = try XCTUnwrap(Library(root).store.previews.image(for: profile.id))
        XCTAssertEqual(cropped.width, 100)
        XCTAssertEqual(cropped.height, 90)
        XCTAssertEqual(try sample(cropped, x: 50, y: 45), 202, accuracy: 2)
    }

    func testOldSettingsEnablePreviewsWithoutChangingAppearance() throws {
        let original = AppSettings(appearance: .dark)
        var legacy = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(original)) as? [String: Any])
        legacy.removeValue(forKey: "showSessionPreviews")
        let decoded = try JSONDecoder().decode(AppSettings.self, from: JSONSerialization.data(withJSONObject: legacy))
        XCTAssertTrue(decoded.showSessionPreviews)
        XCTAssertEqual(decoded.appearance, .dark)
    }

    func testGlobalPreviewSettingSurvivesReopenAndInvalidatesPendingCapture() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let library = Library(root)
        let profile = ConnectionProfile(name: "Fixture", host: "localhost")
        library.store.add(profile)
        let (model, transport) = try await session(profile, in: library)
        defer { model.stop() }
        try await deliver(frame(80), to: model, via: transport)
        try await deliver(frame(230), to: model, via: transport)
        library.settings.settings.showSessionPreviews = false
        XCTAssertNil(library.store.previews.image(for: profile.id))
        model.handleScenePhase(.background)
        let reopened = Library(root)
        XCTAssertFalse(reopened.settings.settings.showSessionPreviews)
        XCTAssertNil(reopened.store.previews.image(for: profile.id))
        let unseen = ConnectionProfile(name: "Hidden fixture", host: "localhost")
        reopened.store.add(unseen)
        let (otherModel, otherTransport) = try await session(unseen, in: reopened)
        try await deliver(frame(230), to: otherModel, via: otherTransport)
        otherModel.stop()
        try await deliver(frame(128), to: model, via: transport)
        library.settings.settings.showSessionPreviews = true
        model.handleScenePhase(.background)
        XCTAssertNil(Library(root).store.previews.image(for: unseen.id))
        XCTAssertEqual(try intensity(Library(root).store.previews.image(for: profile.id)), 80, accuracy: 2)
        try await deliver(frame(0), to: model, via: transport)
        XCTAssertEqual(try intensity(Library(root).store.previews.image(for: profile.id)), 0, accuracy: 2)
        try await deliver(frame(180), to: model, via: transport)
        model.handleScenePhase(.background)
        XCTAssertEqual(try intensity(Library(root).store.previews.image(for: profile.id)), 180, accuracy: 2)
    }
}
