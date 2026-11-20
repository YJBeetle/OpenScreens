import SwiftUI

struct SessionCursorOverlay: View {
    let model: SessionViewModel
    let imageRect: (CGSize) -> CGRect?

    private struct CursorPlacement {
        var image: CGImage
        var size: CGSize
        var center: CGPoint
    }

    /// Client-side pointer bitmap, positioned over the scaled framebuffer.
    var body: some View {
        GeometryReader { proxy in
            if let placement = cursorPlacement(in: proxy.size) {
                Image(decorative: placement.image, scale: 1)
                    .resizable()
                    .interpolation(.none)
                    .frame(width: placement.size.width, height: placement.size.height)
                    .position(placement.center)
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    private func cursorPlacement(in viewSize: CGSize) -> CursorPlacement? {
        guard model.state.isConnected,
              let image = model.remoteCursorImage,
              let shape = model.remoteCursorShape,
              let rect = imageRect(viewSize),
              let frame = model.framebufferSize,
              frame.width > 0, frame.height > 0
        else { return nil }

        let scale = rect.width / frame.width
        let cursorSize = CGSize(
            width: CGFloat(shape.width) * scale,
            height: CGFloat(shape.height) * scale
        )
        let anchorX = rect.minX + model.remoteCursor.x * rect.width
        let anchorY = rect.minY + model.remoteCursor.y * rect.height
        let left = anchorX - CGFloat(shape.hotspotX) * scale
        let top = anchorY - CGFloat(shape.hotspotY) * scale
        let center = CGPoint(
            x: left + cursorSize.width / 2,
            y: top + cursorSize.height / 2
        )
        return CursorPlacement(image: image, size: cursorSize, center: center)
    }
}
