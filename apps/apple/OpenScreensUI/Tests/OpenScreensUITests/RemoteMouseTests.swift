#if os(macOS)
import AppKit
import XCTest
@testable import OpenScreensUI

private actor InputRecorder: RemoteSessionProtocol, RemoteSessionService {
    enum Event: Equatable {
        case pointer(PointerAction, PointerButton, CGPoint)
        case scroll(CGPoint, Int32, Int32)
        case key(RemoteKey, RemoteModifiers)
        case observe(Bool)
    }

    let (events, continuation) = AsyncStream<RemoteSessionEvent>.makeStream()
    let (disconnected, disconnectSignal) = AsyncStream<Void>.makeStream()
    private(set) var recorded: [Event] = []
    nonisolated func makeSession() -> any RemoteSessionProtocol { self }
    func connect(profile: ConnectionProfile) {
        continuation.yield(.frame(RemoteFrame(width: 200, height: 100, data: Data(count: 80000))))
        continuation.yield(.state(.connected))
    }
    func disconnect() {
        continuation.finish()
        disconnectSignal.finish()
    }
    func sendPointer(_ event: PointerEvent) {
        recorded.append(.pointer(event.action, event.button, CGPoint(x: event.x, y: event.y)))
    }
    func sendScroll(at point: CGPoint, stepsX: Int32, stepsY: Int32) { recorded.append(.scroll(point, stepsX, stepsY)) }
    func sendKey(_ event: RemoteKeyEvent) { recorded.append(.key(event.key, event.modifiers)) }
    func setObserveMode(_ observing: Bool) { recorded.append(.observe(observing)) }
    func sendClipboard(_ text: String) {}
    func requestClipboard() {}
}

@MainActor
final class RemoteMouseTests: XCTestCase {
    let size = CGSize(width: 100, height: 100)

    private func connected() async throws -> (SessionViewModel, InputRecorder) {
        let recorder = InputRecorder()
        let model = SessionViewModel(profile: ConnectionProfile(), service: recorder)
        model.start()
        let deadline = ContinuousClock.now + .seconds(3)
        while !model.state.isConnected && ContinuousClock.now < deadline { await Task.yield() }
        XCTAssertTrue(model.state.isConnected)
        model.setScaling(.fit)
        return (model, recorder)
    }

    private func verify(_ expected: [InputRecorder.Event], model: SessionViewModel, recorder: InputRecorder) async {
        model.stop()
        // The queue closes the transport only after flushing releases.
        for await _ in recorder.disconnected {}
        let recorded = await recorder.recorded
        XCTAssertEqual(recorded, expected)
    }

    func testAppKitWindowCoordinatesAndFocusLossRelease() async throws {
        let (model, recorder) = try await connected()
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 150, height: 160),
                              styleMask: .borderless, backing: .buffered, defer: true)
        let view = RemoteMouseView(frame: CGRect(origin: CGPoint(x: 10, y: 20), size: size))
        view.model = model
        window.contentView?.addSubview(view)
        // In window coordinates (35, 90) is (25, 30) in the flipped surface.
        let event = try XCTUnwrap(NSEvent.mouseEvent(with: .leftMouseDown, location: CGPoint(x: 35, y: 90),
            modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber, context: nil,
            eventNumber: 1, clickCount: 1, pressure: 1))
        view.mouseDown(with: event)
        NotificationCenter.default.post(name: NSWindow.didResignKeyNotification, object: window)
        view.removeFromSuperview()
        let target = CGPoint(x: 0.25, y: 0.1)
        await verify([.pointer(.down, .left, target), .pointer(.up, .left, target)], model: model, recorder: recorder)
    }

    func testMouseChordsAndOutsideReleaseUseFramebufferCoordinates() async throws {
        let (model, recorder) = try await connected()
        model.setCursorMode(.trackpad)
        let mouse = model.mouseInput
        let p = CGPoint(x: 25, y: 30)
        let target = CGPoint(x: 0.25, y: 0.1)
        mouse.down(0, control: false, at: CGPoint(x: 25, y: 15), size: size) // letterbox
        mouse.move(at: p, size: size)
        mouse.down(0, control: false, at: p, size: size)
        mouse.down(2, control: false, at: p, size: size)
        mouse.move(at: CGPoint(x: 80, y: 70), size: size, dragging: 0)
        mouse.up(0, at: CGPoint(x: 130, y: -8), size: size)
        let edge = CGPoint(x: 1, y: 0)
        await verify([.pointer(.move, .left, target), .pointer(.down, .left, target),
                      .pointer(.down, .middle, target), .pointer(.move, .left, CGPoint(x: 0.8, y: 0.9)),
                      .pointer(.up, .left, edge), .pointer(.up, .middle, edge)], model: model, recorder: recorder)
    }

    func testObserveReleasesRightButtonAndBlocksMouseWheelAndCommands() async throws {
        let (model, recorder) = try await connected()
        let mouse = model.mouseInput
        model.setScaling(.fill)
        let p = CGPoint(x: 20, y: 10)
        let target = CGPoint(x: 0.35, y: 0.1)
        let cmd = try XCTUnwrap(RemoteDesktopCommand.commands(for: .macos).first)
        mouse.down(0, control: true, at: p, size: size)
        mouse.down(1, control: false, at: p, size: size)
        mouse.up(0, at: p, size: size)
        model.toggleObserveMode()
        mouse.up(1, at: p, size: size)
        mouse.down(2, control: false, at: p, size: size)
        mouse.move(at: p, size: size)
        mouse.scroll(at: p, size: size, precise: false, delta: CGSize(width: 1, height: 2), began: false)
        model.sendCommand(cmd)
        model.toggleObserveMode()
        mouse.move(at: p, size: size, dragging: 2)
        model.toggleStickyModifier(.option)
        model.sendCommand(cmd)
        await verify([.pointer(.down, .right, target), .pointer(.move, .right, target), .pointer(.move, .right, target),
                      .pointer(.up, .right, target), .observe(true), .observe(false), .key(.arrowUp, .control)],
                     model: model, recorder: recorder)
    }

    func testDiscreteAndPreciseWheelAtEventPosition() async throws {
        let (model, recorder) = try await connected()
        model.setScaling(.stretch)
        let mouse = model.mouseInput
        let p = CGPoint(x: 16, y: 74)
        let target = CGPoint(x: 0.16, y: 0.74)
        mouse.scroll(at: p, size: size, precise: false, delta: CGSize(width: 1, height: -2), began: false)
        mouse.scroll(at: p, size: size, precise: true, delta: CGSize(width: -12, height: 12), began: true)
        mouse.scroll(at: p, size: size, precise: true, delta: CGSize(width: -12, height: 12), began: false)
        await verify([.scroll(target, 1, -2), .scroll(target, -1, 1)], model: model, recorder: recorder)
    }
}
#endif
