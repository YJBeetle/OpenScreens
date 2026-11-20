#if os(macOS)
import AppKit
import SwiftUI

struct RemoteMouseSurface: NSViewRepresentable {
    let model: SessionViewModel
    let size: CGSize
    let focusKeyboard: () -> Void

    func makeNSView(context: Context) -> RemoteMouseView {
        RemoteMouseView()
    }

    func updateNSView(_ view: RemoteMouseView, context: Context) {
        view.model = model
        view.focusKeyboard = focusKeyboard
        view.cursorRect = model.state.isConnected && !model.isObserving && model.remoteCursorImage != nil
            ? model.displayedImageRect(in: size) : nil
    }

    static func dismantleNSView(_ view: RemoteMouseView, coordinator: ()) {
        view.model?.mouseInput.cancel()
    }
}

@MainActor
final class RemoteMouseView: NSView {
    weak var model: SessionViewModel?
    var focusKeyboard: (() -> Void)?
    var cursorRect: CGRect? {
        didSet {
            if cursorRect != oldValue { window?.invalidateCursorRects(for: self) }
        }
    }

    private var tracking: NSTrackingArea?
    private static let invisibleCursor = NSCursor(image: NSImage(size: NSSize(width: 1, height: 1)), hotSpot: .zero)

    override var isFlipped: Bool { true }
    override var mouseDownCanMoveWindow: Bool { false }

    override func resetCursorRects() {
        super.resetCursorRects()
        if let cursorRect { addCursorRect(cursorRect.intersection(visibleRect), cursor: Self.invisibleCursor) }
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect: .zero, options: [.inVisibleRect, .mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow], owner: self)
        addTrackingArea(area)
        tracking = area
    }

    override func viewWillMove(toWindow newWindow: NSWindow?) {
        if let window {
            NotificationCenter.default.removeObserver(self, name: NSWindow.didResignKeyNotification, object: window)
            model?.mouseInput.cancel()
        }
        super.viewWillMove(toWindow: newWindow)
        if let newWindow {
            NotificationCenter.default.addObserver(self, selector: #selector(windowResignedKey),
                name: NSWindow.didResignKeyNotification, object: newWindow)
        }
    }

    @objc private func windowResignedKey() { model?.mouseInput.cancel() }

    private func position(_ event: NSEvent) -> CGPoint {
        convert(event.locationInWindow, from: nil)
    }

    override func mouseDown(with event: NSEvent) {
        focusKeyboard?()
        model?.mouseInput.down(event.buttonNumber, control: event.modifierFlags.contains(.control),
                               at: position(event), size: bounds.size)
    }

    override func mouseDragged(with event: NSEvent) {
        model?.mouseInput.move(at: position(event), size: bounds.size, dragging: event.buttonNumber)
    }

    override func mouseUp(with event: NSEvent) {
        model?.mouseInput.up(event.buttonNumber, at: position(event), size: bounds.size)
    }

    override func rightMouseDown(with event: NSEvent) { mouseDown(with: event) }
    override func rightMouseDragged(with event: NSEvent) { mouseDragged(with: event) }
    override func rightMouseUp(with event: NSEvent) { mouseUp(with: event) }
    override func otherMouseDown(with event: NSEvent) { mouseDown(with: event) }
    override func otherMouseDragged(with event: NSEvent) { mouseDragged(with: event) }
    override func otherMouseUp(with event: NSEvent) { mouseUp(with: event) }

    override func mouseMoved(with event: NSEvent) {
        model?.mouseInput.move(at: position(event), size: bounds.size)
    }

    override func mouseEntered(with event: NSEvent) { mouseMoved(with: event) }

    override func scrollWheel(with event: NSEvent) {
        // AppKit reports content movement; the transport takes wheel steps (positive = down/right).
        model?.mouseInput.scroll(at: position(event), size: bounds.size, precise: event.hasPreciseScrollingDeltas,
                                 delta: CGSize(width: -event.scrollingDeltaX, height: -event.scrollingDeltaY),
                                 began: event.phase.contains(.began))
    }
}

/// Tracks physical button ownership so control-click stays a right press until
/// mouse-up, even if Control is released or a second mouse button is held.
@MainActor
final class RemoteMouseInput {
    private unowned let model: SessionViewModel
    private var held: [Int: PointerButton] = [:]
    private var lastPosition = CGPoint.zero
    private var wheelRemainder = CGSize.zero

    init(model: SessionViewModel) { self.model = model }

    private func target(_ point: CGPoint, size: CGSize, clamp: Bool = false) -> CGPoint? {
        guard model.state.isConnected, !model.isObserving,
              let rect = model.displayedImageRect(in: size),
              clamp || (CGRect(origin: .zero, size: size).contains(point) && rect.contains(point))
        else { return nil }
        return SessionViewModel.normalized(point, in: rect)
    }

    func down(_ number: Int, control: Bool, at point: CGPoint, size: CGSize) {
        guard held[number] == nil, let target = target(point, size: size) else { return }
        let button: PointerButton
        switch number {
        case 0: button = control ? .right : .left
        case 1: button = .right
        case 2: button = .middle
        default: return
        }
        let alreadyPressed = held.values.contains(button)
        held[number] = button
        send(alreadyPressed ? .move : .down, button: button, to: target)
    }

    func move(at point: CGPoint, size: CGSize, dragging number: Int? = nil) {
        if let number, held[number] == nil { return }
        guard let target = target(point, size: size, clamp: number != nil) else { return }
        send(.move, to: target)
    }

    func up(_ number: Int, at point: CGPoint, size: CGSize) {
        guard let button = held.removeValue(forKey: number) else { return }
        send(held.values.contains(button) ? .move : .up, button: button,
             to: target(point, size: size, clamp: true) ?? lastPosition)
    }

    func cancel() {
        for button in Set(held.values).sorted(by: { $0.rawValue < $1.rawValue }) {
            send(.up, button: button, to: lastPosition)
        }
        held.removeAll()
        wheelRemainder = .zero
    }

    private func send(_ action: PointerAction, button: PointerButton = .left, to position: CGPoint) {
        lastPosition = position
        model.sendMousePointer(action, button: button, to: position)
    }

    func scroll(at point: CGPoint, size: CGSize, precise: Bool, delta: CGSize, began: Bool) {
        guard let target = target(point, size: size) else { return }
        if began { wheelRemainder = .zero }
        // Precise trackpad deltas are points. A conventional wheel supplies line units.
        let unit: CGFloat = precise ? 24 : 1
        wheelRemainder.width += delta.width / unit
        wheelRemainder.height += delta.height / unit
        let x = Int32(wheelRemainder.width)
        let y = Int32(wheelRemainder.height)
        guard x != 0 || y != 0 else { return }
        wheelRemainder.width -= CGFloat(x)
        wheelRemainder.height -= CGFloat(y)
        lastPosition = target
        model.sendMouseScroll(at: target, x: x, y: y)
    }
}
#endif
