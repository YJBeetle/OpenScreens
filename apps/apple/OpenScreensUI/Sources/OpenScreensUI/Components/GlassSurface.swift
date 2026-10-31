import SwiftUI

/// Translucent session chrome: blur, dark tint, top sheen and a bright rim.
/// Mirrors the layered glass Screens uses instead of relying on system bars.
struct GlassSurface<S: InsettableShape>: ViewModifier {
    let shape: S
    var tint: Color?

    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorScheme) private var colorScheme

    private var resolvedTint: Color {
        tint ?? (colorScheme == .dark ? Color.black.opacity(0.32) : Color.black.opacity(0.05))
    }

    func body(content: Content) -> some View {
        content
            .background {
                if reduceTransparency {
                    shape.fill(colorScheme == .dark ? Color(white: 0.13) : Color(white: 0.95))
                } else {
                    ZStack {
                        shape.fill(.ultraThinMaterial)
                        shape.fill(resolvedTint)
                        shape.fill(
                            LinearGradient(
                                stops: [
                                    .init(color: .white.opacity(0.12), location: 0),
                                    .init(color: .white.opacity(0.03), location: 0.45),
                                    .init(color: .clear, location: 1),
                                ],
                                startPoint: .top,
                                endPoint: .bottom
                            )
                        )
                    }
                }
            }
            .overlay {
                shape.strokeBorder(
                    LinearGradient(
                        stops: [
                            .init(color: .white.opacity(0.30), location: 0),
                            .init(color: .white.opacity(0.08), location: 0.55),
                            .init(color: .white.opacity(0.14), location: 1),
                        ],
                        startPoint: .top,
                        endPoint: .bottom
                    ),
                    lineWidth: 0.8
                )
            }
    }
}

extension View {
    public func glassSurface<S: InsettableShape>(in shape: S, tint: Color? = nil) -> some View {
        modifier(GlassSurface(shape: shape, tint: tint))
    }
}
