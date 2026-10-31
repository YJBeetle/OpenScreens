import CoreGraphics
import Foundation
import Metal
import MetalKit
import os

/// Renders a remote framebuffer into any `MTKView` and owns the BGRA8 texture that
/// stores the latest frame.
///
/// The renderer is deliberately independent of the VNC engine: frames can be pushed
/// from a mock generator today and from the Rust core through UniFFI later, without
/// changing this public surface.
///
/// All methods are main-actor isolated. Callers that receive frames on a background
/// thread must hop to the main actor before uploading.
@MainActor
public final class RemoteCanvasRenderer {
    private static let logger = Logger(subsystem: "app.openscreens.canvas", category: "RemoteCanvas")
    /// Conservative 2D texture limit (the simulator aborts above 8192).
    private static let maxTextureDimension = 8192

    private let device: (any MTLDevice)?
    private let commandQueue: (any MTLCommandQueue)?
    private let pipeline: (any MTLRenderPipelineState)?
    private var texture: (any MTLTexture)?
    private(set) var frameWidth = 0
    private(set) var frameHeight = 0

    /// Intrinsic size of the current framebuffer in pixels, if a full frame has arrived.
    public private(set) var framePixelSize: CGSize?

    /// Letterboxing behaviour, applied by the hosting view on the next draw.
    public var contentMode: RemoteContentMode = .fit {
        didSet { requestRedraw() }
    }

    /// Rect the framebuffer occupies in the hosting view, in points. When set,
    /// the renderer samples that visible portion at drawable resolution instead
    /// of magnifying a fitted layer, so zoomed content stays sharp.
    public var imageRect: CGRect? {
        didSet { requestRedraw() }
    }
    /// Size of the hosting view the rect is expressed in, in points.
    public var containerSize: CGSize = .zero {
        didSet { requestRedraw() }
    }

    /// View that presents this renderer, redrawn only when content changes.
    private weak var hostView: RemoteCanvasMetalView?

    func attach(_ view: RemoteCanvasMetalView) {
        hostView = view
    }

    private func requestRedraw() {
        hostView?.requestRedraw()
    }

    /// Creates the Metal device, queue and pipeline. The renderer remains usable
    /// (uploads are accepted, draws are skipped) if Metal is unavailable.
    public init() {
        let device = MTLCreateSystemDefaultDevice()
        self.device = device

        guard let device else {
            Self.logger.error("Metal is unavailable; remote canvas will not draw")
            commandQueue = nil
            pipeline = nil
            return
        }

        commandQueue = device.makeCommandQueue()

        do {
            let library = try device.makeLibrary(source: Self.shaderSource, options: nil)
            let descriptor = MTLRenderPipelineDescriptor()
            descriptor.label = "RemoteCanvasBlit"
            descriptor.vertexFunction = library.makeFunction(name: "canvasVertex")
            descriptor.fragmentFunction = library.makeFunction(name: "canvasFragment")
            descriptor.colorAttachments[0].pixelFormat = .bgra8Unorm
            pipeline = try device.makeRenderPipelineState(descriptor: descriptor)
        } catch {
            Self.logger.error("Unable to build the remote canvas pipeline: \(error.localizedDescription, privacy: .public)")
            pipeline = nil
        }
    }

    /// Uploads a complete BGRA8 frame. `pixels` must contain at least
    /// `width * height * 4` bytes and rows are tightly packed.
    public func updateFullFrame(width: Int, height: Int, pixels: Data) {
        updateFullFrame(width: width, height: height, bytesPerRow: width * 4, pixels: pixels)
    }

    /// Uploads a complete BGRA8 frame with an explicit source stride.
    public func updateFullFrame(width: Int, height: Int, bytesPerRow: Int, pixels: Data) {
        guard width > 0, height > 0, bytesPerRow >= width * 4,
              pixels.count >= bytesPerRow * height,
              let texture = makeTextureIfNeeded(width: width, height: height)
        else { return }

        let region = MTLRegionMake2D(0, 0, width, height)
        pixels.withUnsafeBytes { buffer in
            guard let base = buffer.baseAddress else { return }
            texture.replace(region: region, mipmapLevel: 0, withBytes: base, bytesPerRow: bytesPerRow)
        }
        requestRedraw()
    }

    /// Uploads a sub-region of the current frame. `width` and `height` are the
    /// dimensions of the *whole* framebuffer; `region` and `pixels` describe the
    /// update only. Rows in `pixels` are tightly packed.
    ///
    public func update(region: RemoteRegion, width: Int, height: Int, pixels: Data) {
        update(region: region, width: width, height: height, bytesPerRow: region.width * 4, pixels: pixels)
    }

    /// Uploads a sub-region with an explicit source stride.
    public func update(region: RemoteRegion, width: Int, height: Int, bytesPerRow: Int, pixels: Data) {
        guard !region.isEmpty,
              width > 0, height > 0,
              region.isContained(inWidth: width, height: height),
              bytesPerRow >= region.width * 4,
              pixels.count >= bytesPerRow * region.height
        else { return }

        let needsInitialization = texture == nil || frameWidth != width || frameHeight != height
        guard let texture = makeTextureIfNeeded(width: width, height: height) else { return }

        if needsInitialization {
            let zeros = Data(count: width * height * 4)
            zeros.withUnsafeBytes { buffer in
                guard let base = buffer.baseAddress else { return }
                texture.replace(
                    region: MTLRegionMake2D(0, 0, width, height),
                    mipmapLevel: 0,
                    withBytes: base,
                    bytesPerRow: width * 4
                )
            }
        }

        let metalRegion = MTLRegionMake2D(region.x, region.y, region.width, region.height)
        pixels.withUnsafeBytes { buffer in
            guard let base = buffer.baseAddress else { return }
            texture.replace(region: metalRegion, mipmapLevel: 0, withBytes: base, bytesPerRow: bytesPerRow)
        }
        requestRedraw()
    }

    /// Discards the current frame, e.g. when a session disconnects.
    public func reset() {
        texture = nil
        frameWidth = 0
        frameHeight = 0
        framePixelSize = nil
        requestRedraw()
    }

    /// Copies the latest frame into an immutable image, or returns nil when no
    /// frame has arrived yet.
    public func snapshot() -> CGImage? {
        guard let texture, frameWidth > 0, frameHeight > 0 else { return nil }

        let bytesPerRow = frameWidth * 4
        var pixels = Data(count: bytesPerRow * frameHeight)
        let copied = pixels.withUnsafeMutableBytes { buffer -> Bool in
            guard let base = buffer.baseAddress else { return false }
            texture.getBytes(
                base,
                bytesPerRow: bytesPerRow,
                from: MTLRegionMake2D(0, 0, frameWidth, frameHeight),
                mipmapLevel: 0
            )
            return true
        }
        guard copied, let provider = CGDataProvider(data: pixels as CFData) else { return nil }

        let bitmapInfo = CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedFirst.rawValue)
            .union(.byteOrder32Little)
        return CGImage(
            width: frameWidth,
            height: frameHeight,
            bitsPerComponent: 8,
            bitsPerPixel: 32,
            bytesPerRow: bytesPerRow,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: bitmapInfo,
            provider: provider,
            decode: nil,
            shouldInterpolate: false,
            intent: .defaultIntent
        )
    }

    /// Draws the latest frame into the supplied view.
    func draw(in view: MTKView) {
        guard let pipeline, let commandQueue, let texture,
              let descriptor = view.currentRenderPassDescriptor,
              let drawable = view.currentDrawable
        else { return }

        let target = view.drawableSize
        guard target.width > 0, target.height > 0,
              let commandBuffer = commandQueue.makeCommandBuffer(),
              let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: descriptor)
        else { return }

        encoder.label = "RemoteCanvasDraw"
        encoder.setRenderPipelineState(pipeline)
        encoder.setFragmentTexture(texture, index: 0)

        var uniforms = canvasUniforms(for: target)
        encoder.setVertexBytes(&uniforms, length: MemoryLayout<CanvasUniforms>.stride, index: 0)
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        encoder.endEncoding()

        commandBuffer.present(drawable)
        commandBuffer.commit()
    }

    /// Device exposed to the hosting view. Internal on purpose.
    var metalDevice: (any MTLDevice)? { device }

    // MARK: - Private

    private struct CanvasUniforms {
        var origin: SIMD2<Float>
        var size: SIMD2<Float>
    }

    private func canvasUniforms(for target: CGSize) -> CanvasUniforms {
        if let imageRect, containerSize.width > 0, containerSize.height > 0,
           imageRect.width > 0, imageRect.height > 0 {
            return CanvasUniforms(
                origin: SIMD2(
                    Float(imageRect.minX / containerSize.width),
                    Float(imageRect.minY / containerSize.height)
                ),
                size: SIMD2(
                    Float(imageRect.width / containerSize.width),
                    Float(imageRect.height / containerSize.height)
                )
            )
        }
        let scale = viewportScale(for: target)
        return CanvasUniforms(
            origin: SIMD2((1 - scale.x) / 2, (1 - scale.y) / 2),
            size: scale
        )
    }

    private func makeTextureIfNeeded(width: Int, height: Int) -> (any MTLTexture)? {
        guard let device else { return nil }
        guard width <= Self.maxTextureDimension, height <= Self.maxTextureDimension else {
            Self.logger.error(
                "Framebuffer \(width)x\(height) exceeds the \(Self.maxTextureDimension) texel limit"
            )
            return nil
        }
        if let texture, frameWidth == width, frameHeight == height {
            return texture
        }

        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .bgra8Unorm,
            width: width,
            height: height,
            mipmapped: false
        )
        descriptor.usage = [.shaderRead]
        #if os(macOS)
        descriptor.storageMode = .managed
        #else
        descriptor.storageMode = .shared
        #endif

        guard let newTexture = device.makeTexture(descriptor: descriptor) else {
            Self.logger.error("Unable to allocate a \(width)x\(height) remote framebuffer texture")
            return nil
        }
        newTexture.label = "RemoteFramebuffer"
        texture = newTexture
        frameWidth = width
        frameHeight = height
        framePixelSize = CGSize(width: width, height: height)
        return newTexture
    }

    private func viewportScale(for target: CGSize) -> SIMD2<Float> {
        guard frameWidth > 0, frameHeight > 0 else { return SIMD2(1, 1) }
        let frameAspect = CGFloat(frameWidth) / CGFloat(frameHeight)
        let targetAspect = target.width / target.height

        switch contentMode {
        case .stretch:
            return SIMD2(1, 1)
        case .fit:
            // The quad shrinks on one axis and is letterboxed by the clear colour.
            if targetAspect > frameAspect {
                return SIMD2(Float(frameAspect / targetAspect), 1)
            }
            return SIMD2(1, Float(targetAspect / frameAspect))
        case .fill:
            // The quad grows past the drawable on one axis; clipping crops it.
            if targetAspect > frameAspect {
                return SIMD2(1, Float(targetAspect / frameAspect))
            }
            return SIMD2(Float(frameAspect / targetAspect), 1)
        }
    }

    private static let shaderSource = """
    #include <metal_stdlib>
    using namespace metal;

    struct CanvasVertexOut {
        float4 position [[position]];
        float2 texCoord;
    };

    struct CanvasUniforms {
        float2 origin;
        float2 size;
    };

    vertex CanvasVertexOut canvasVertex(uint vertexID [[vertex_id]],
                                        constant CanvasUniforms &uniforms [[buffer(0)]]) {
        const float2 positions[3] = {
            float2(-1.0, -1.0),
            float2( 3.0, -1.0),
            float2(-1.0,  3.0)
        };
        // Full-screen triangle; screenUV is 0..1 over the visible viewport.
        const float2 screenUVs[3] = {
            float2(0.0, 1.0),
            float2(2.0, 1.0),
            float2(0.0, -1.0)
        };

        CanvasVertexOut out;
        out.position = float4(positions[vertexID], 0.0, 1.0);
        // Map the viewport onto the image rect. Coordinates outside 0..1 fall
        // in the letterbox and are discarded by the fragment stage.
        out.texCoord = (screenUVs[vertexID] - uniforms.origin) / uniforms.size;
        return out;
    }

    fragment float4 canvasFragment(CanvasVertexOut in [[stage_in]],
                                   texture2d<float> remoteTexture [[texture(0)]]) {
        if (in.texCoord.x < 0.0 || in.texCoord.x > 1.0 ||
            in.texCoord.y < 0.0 || in.texCoord.y > 1.0) {
            discard_fragment();
        }
        constexpr sampler remoteSampler(coord::normalized,
                                        address::clamp_to_edge,
                                        filter::linear);
        return remoteTexture.sample(remoteSampler, in.texCoord);
    }
    """
}
