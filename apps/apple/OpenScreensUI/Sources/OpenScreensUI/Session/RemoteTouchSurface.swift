#if os(iOS)
import SwiftUI
import UIKit

/// UIKit-backed touch surface for the remote screen. SwiftUI gestures cannot
/// express touch counts, so the multi-finger vocabulary of Screens lives here:
/// one finger moves the cursor, two fingers scroll or pan a zoomed image,
/// two-finger taps click the right button, three-finger taps the middle one,
/// and a pinch magnifies.
struct RemoteTouchSurface: UIViewRepresentable {
    var onTap: (CGPoint) -> Void
    var onDrag: (CGPoint) -> Void
    var onDragEnd: () -> Void
    var onRightClick: (CGPoint) -> Void
    var onMiddleClick: () -> Void
    var onToggleChrome: () -> Void
    var onScroll: (CGSize) -> Void
    var onDragZoomed: (CGSize) -> Void
    var isZoomed: () -> Bool
    var onPinchBegan: (CGPoint) -> Void
    var onPinchChanged: (CGFloat, CGPoint) -> Void
    var onPinchEnded: () -> Void
    var onPressBegan: (PointerButton, CGPoint) -> Void
    var onPressMoved: (CGPoint) -> Void
    var onPressEnded: () -> Void
    var onThreeFingerSwipe: (UISwipeGestureRecognizer.Direction) -> Void

    func makeUIView(context: Context) -> TouchGestureView {
        let view = TouchGestureView()
        view.handlers = self
        return view
    }

    func updateUIView(_ uiView: TouchGestureView, context: Context) {
        uiView.handlers = self
    }
}

final class TouchGestureView: UIView, UIGestureRecognizerDelegate {
    var handlers: RemoteTouchSurface?

    private var twoPanTranslation = CGPoint.zero
    private var pinchActive = false
    private var pressActive = false
    private var suppressSingleTap = false
    private var twoPan: UIPanGestureRecognizer!
    private var pinch: UIPinchGestureRecognizer!

    init() {
        super.init(frame: .zero)
        isMultipleTouchEnabled = true
        backgroundColor = .clear
        isAccessibilityElement = false

        let singlePan = UIPanGestureRecognizer(target: self, action: #selector(handleSinglePan))
        singlePan.minimumNumberOfTouches = 1
        singlePan.maximumNumberOfTouches = 1
        singlePan.delegate = self
        addGestureRecognizer(singlePan)

        let twoPan = UIPanGestureRecognizer(target: self, action: #selector(handleTwoPan))
        twoPan.minimumNumberOfTouches = 2
        twoPan.maximumNumberOfTouches = 2
        twoPan.delegate = self
        addGestureRecognizer(twoPan)
        self.twoPan = twoPan

        let twoTap = UITapGestureRecognizer(target: self, action: #selector(handleTwoTap))
        twoTap.numberOfTouchesRequired = 2
        twoTap.numberOfTapsRequired = 1
        addGestureRecognizer(twoTap)

        let twoDoubleTap = UITapGestureRecognizer(target: self, action: #selector(handleTwoDoubleTap))
        twoDoubleTap.numberOfTouchesRequired = 2
        twoDoubleTap.numberOfTapsRequired = 2
        addGestureRecognizer(twoDoubleTap)
        twoTap.require(toFail: twoDoubleTap)

        let threeTap = UITapGestureRecognizer(target: self, action: #selector(handleThreeTap))
        threeTap.numberOfTouchesRequired = 3
        addGestureRecognizer(threeTap)

        let pinch = UIPinchGestureRecognizer(target: self, action: #selector(handlePinch))
        pinch.delegate = self
        addGestureRecognizer(pinch)
        self.pinch = pinch

        let held = UILongPressGestureRecognizer(target: self, action: #selector(handleLongPress))
        held.numberOfTouchesRequired = 1
        held.allowableMovement = 12
        held.minimumPressDuration = 0.45
        addGestureRecognizer(held)

        let heldRight = UILongPressGestureRecognizer(target: self, action: #selector(handleLongPress))
        heldRight.numberOfTouchesRequired = 2
        heldRight.allowableMovement = 12
        heldRight.minimumPressDuration = 0.45
        addGestureRecognizer(heldRight)
        twoTap.require(toFail: heldRight)

        let heldMiddle = UILongPressGestureRecognizer(target: self, action: #selector(handleLongPress))
        heldMiddle.numberOfTouchesRequired = 3
        heldMiddle.allowableMovement = 12
        heldMiddle.minimumPressDuration = 0.45
        addGestureRecognizer(heldMiddle)
        threeTap.require(toFail: heldMiddle)

        for direction: UISwipeGestureRecognizer.Direction in [.up, .down, .left, .right] {
            let swipe = UISwipeGestureRecognizer(target: self, action: #selector(handleThreeFingerSwipe))
            swipe.numberOfTouchesRequired = 3
            swipe.direction = direction
            addGestureRecognizer(swipe)
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("TouchGestureView is only created programmatically")
    }

    func gestureRecognizer(
        _ gestureRecognizer: UIGestureRecognizer,
        shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer
    ) -> Bool {
        // A pinch and a two-finger drag start with the same touches; the pinch
        // wins while it is active, then dragging resumes on the next gesture.
        let pair: [UIGestureRecognizer] = [gestureRecognizer, otherGestureRecognizer]
        return pair.contains { $0 === pinch } && pair.contains { $0 === twoPan }
    }

    @objc private func handleSinglePan(_ gesture: UIPanGestureRecognizer) {
        let location = gesture.location(in: self)
        switch gesture.state {
        case .began:
            suppressSingleTap = false
        case .changed:
            guard !pressActive else { return }
            let translation = gesture.translation(in: self)
            if (translation.x * translation.x + translation.y * translation.y).squareRoot() > 3 {
                handlers?.onDrag(location)
            }
        case .ended:
            let translation = gesture.translation(in: self)
            let tapped = (translation.x * translation.x + translation.y * translation.y).squareRoot() <= 6
            if suppressSingleTap {
                suppressSingleTap = false
            } else if tapped && !pressActive {
                handlers?.onTap(location)
            }
            if !pressActive {
                handlers?.onDragEnd()
            }
        case .cancelled, .failed:
            if !pressActive {
                handlers?.onDragEnd()
            }
        default:
            break
        }
    }

    @objc private func handleTwoPan(_ gesture: UIPanGestureRecognizer) {
        let translation = gesture.translation(in: self)
        switch gesture.state {
        case .began:
            twoPanTranslation = .zero
        case .changed:
            guard !pinchActive, !pressActive else {
                twoPanTranslation = translation
                return
            }
            let delta = CGSize(
                width: translation.x - twoPanTranslation.x,
                height: translation.y - twoPanTranslation.y
            )
            twoPanTranslation = translation
            if handlers?.isZoomed() == true {
                handlers?.onDragZoomed(delta)
            } else {
                handlers?.onScroll(CGSize(width: -delta.width, height: -delta.height))
            }
        case .ended, .cancelled, .failed:
            twoPanTranslation = .zero
        default:
            break
        }
    }

    @objc private func handleTwoTap(_ gesture: UITapGestureRecognizer) {
        handlers?.onRightClick(gesture.location(in: self))
    }

    @objc private func handleTwoDoubleTap(_ gesture: UITapGestureRecognizer) {
        handlers?.onToggleChrome()
    }

    @objc private func handleThreeTap(_ gesture: UITapGestureRecognizer) {
        handlers?.onMiddleClick()
    }

    @objc private func handlePinch(_ gesture: UIPinchGestureRecognizer) {
        let focal = gesture.location(in: self)
        switch gesture.state {
        case .began:
            pinchActive = true
            handlers?.onPinchBegan(focal)
        case .changed:
            guard !pressActive else { return }
            pinchActive = true
            handlers?.onPinchChanged(gesture.scale, focal)
        case .ended, .cancelled, .failed:
            pinchActive = false
            handlers?.onPinchEnded()
        default:
            break
        }
    }

    @objc private func handleLongPress(_ gesture: UILongPressGestureRecognizer) {
        let button: PointerButton = switch gesture.numberOfTouchesRequired {
        case 1: .left
        case 2: .right
        default: .middle
        }
        let location = gesture.location(in: self)
        switch gesture.state {
        case .began:
            pressActive = true
            suppressSingleTap = true
            handlers?.onPressBegan(button, location)
        case .changed:
            handlers?.onPressMoved(location)
        case .ended, .cancelled, .failed:
            pressActive = false
            handlers?.onPressEnded()
        default:
            break
        }
    }

    @objc private func handleThreeFingerSwipe(_ gesture: UISwipeGestureRecognizer) {
        handlers?.onThreeFingerSwipe(gesture.direction)
    }
}
#endif
