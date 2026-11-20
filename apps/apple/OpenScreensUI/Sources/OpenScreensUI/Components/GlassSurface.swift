import SwiftUI

/// The shared backdrop for controls floating over a remote desktop.
private struct GlassSurface<S: InsettableShape>: ViewModifier {
    let shape: S
    let tint: Color?

    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    func body(content: Content) -> some View {
        if reduceTransparency {
            content.background(.background, in: shape)
        } else {
            #if compiler(>=6.2)
            if #available(iOS 26, macOS 26, *) {
                content.glassEffect(.regular.tint(tint), in: shape)
            } else {
                materialBackground(content)
            }
            #else
            materialBackground(content)
            #endif
        }
    }

    private func materialBackground(_ content: Content) -> some View {
        content
            .background(tint ?? .clear, in: shape)
            .background(.regularMaterial, in: shape)
    }
}

extension View {
    public func glassSurface<S: InsettableShape>(in shape: S, tint: Color? = nil) -> some View {
        modifier(GlassSurface(shape: shape, tint: tint))
    }
}
