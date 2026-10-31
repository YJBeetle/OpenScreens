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
        case .changed:
            let translation = gesture.translation(in: self)
            if (translation.x * translation.x + translation.y * translation.y).squareRoot() > 3 {
                handlers?.onDrag(location)
            }
        case .ended:
            let translation = gesture.translation(in: self)
            if (translation.x * translation.x + translation.y * translation.y).squareRoot() <= 6 {
                handlers?.onTap(location)
            }
            handlers?.onDragEnd()
        case .cancelled, .failed:
            handlers?.onDragEnd()
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
            guard !pinchActive else {
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
            pinchActive = true
            handlers?.onPinchChanged(gesture.scale, focal)
        case .ended, .cancelled, .failed:
            pinchActive = false
            handlers?.onPinchEnded()
        default:
            break
        }
    }
}
#endif
