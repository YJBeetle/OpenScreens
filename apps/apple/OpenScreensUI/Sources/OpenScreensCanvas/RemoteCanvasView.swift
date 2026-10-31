import MetalKit
import SwiftUI

#if os(macOS)
import AppKit
#else
import UIKit
#endif

/// MTKView subclass shared by both platform wrappers.
@MainActor
final class RemoteCanvasMetalView: MTKView {
    private weak var renderer: RemoteCanvasRenderer?

    init(renderer: RemoteCanvasRenderer) {
        self.renderer = renderer
        super.init(frame: .zero, device: renderer.metalDevice)

        colorPixelFormat = .bgra8Unorm
        framebufferOnly = true
        preferredFramesPerSecond = 30
        isPaused = false
        enableSetNeedsDisplay = false
        autoResizeDrawable = true
        clearColor = MTLClearColor(red: 0.015, green: 0.017, blue: 0.022, alpha: 1)
        #if os(macOS)
        wantsLayer = true
        #else
        isOpaque = true
        isMultipleTouchEnabled = false
        #endif
    }

    @available(*, unavailable)
    required init(coder: NSCoder) {
        fatalError("RemoteCanvasMetalView is only created programmatically")
    }

    #if os(macOS)
    override func draw(_ dirtyRect: NSRect) {
        renderer?.draw(in: self)
    }
    #else
    override func draw(_ rect: CGRect) {
        renderer?.draw(in: self)
    }
    #endif
}

#if os(macOS)
/// A Metal-backed remote framebuffer surface for macOS.
public struct RemoteCanvasView: NSViewRepresentable {
    private let renderer: RemoteCanvasRenderer
    private let contentMode: RemoteContentMode

    public init(renderer: RemoteCanvasRenderer, contentMode: RemoteContentMode = .fit) {
        self.renderer = renderer
        self.contentMode = contentMode
    }

    public func makeNSView(context: Context) -> NSView {
        renderer.contentMode = contentMode
        return RemoteCanvasMetalView(renderer: renderer)
    }

    public func updateNSView(_ nsView: NSView, context: Context) {
        renderer.contentMode = contentMode
    }
}
#else
/// A Metal-backed remote framebuffer surface for iOS and iPadOS.
public struct RemoteCanvasView: UIViewRepresentable {
    private let renderer: RemoteCanvasRenderer
    private let contentMode: RemoteContentMode
    private let imageRect: CGRect?
    private let containerSize: CGSize

    public init(
        renderer: RemoteCanvasRenderer,
        contentMode: RemoteContentMode = .fit,
        imageRect: CGRect? = nil,
        containerSize: CGSize = .zero
    ) {
        self.renderer = renderer
        self.contentMode = contentMode
        self.imageRect = imageRect
        self.containerSize = containerSize
    }

    public func makeUIView(context: Context) -> UIView {
        renderer.contentMode = contentMode
        renderer.imageRect = imageRect
        renderer.containerSize = containerSize
        return RemoteCanvasMetalView(renderer: renderer)
    }

    public func updateUIView(_ uiView: UIView, context: Context) {
        renderer.contentMode = contentMode
        renderer.imageRect = imageRect
        renderer.containerSize = containerSize
    }
}
#endif
