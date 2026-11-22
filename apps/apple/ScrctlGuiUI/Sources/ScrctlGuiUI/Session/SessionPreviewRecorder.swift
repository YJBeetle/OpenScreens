import CoreGraphics
import Foundation
import ScrctlGuiCanvas

/// Records the first complete remote canvas, then checkpoints changes at most once
/// per interval. A lifecycle flush captures pending damage before the texture changes.
@MainActor
final class SessionPreviewRecorder {
    private let id: UUID
    private let renderer: RemoteCanvasRenderer
    weak var store: ConnectionStore?
    private var policyRevision: Int?
    private var size: CGSize = .zero
    private var missing = IndexSet()
    private var displayAreas: [CGRect]?
    private var dirtyAt: ContinuousClock.Instant?
    private var lastCapture: ContinuousClock.Instant?
    private var checkpoint: Task<Void, Never>?
    private let interval: Duration = .seconds(30)

    init(id: UUID, renderer: RemoteCanvasRenderer) {
        self.id = id
        self.renderer = renderer
    }

    func received(_ frame: RemoteFrame, displays: [RemoteDisplay], selectedID: Int?,
                  viewport: RemoteViewport?, serverSize: CGSize?) {
        guard let store, store.previews.enabled else { return }
        if policyRevision != store.previews.policyRevision {
            beginSession()
            policyRevision = store.previews.policyRevision
        }
        let dimensions = CGSize(width: frame.width, height: frame.height)
        if dimensions != size {
            reset()
            size = dimensions
            displayAreas = Self.visibleDisplayAreas(displays, selectedID: selectedID, in: dimensions,
                                                    viewport: viewport, serverSize: serverSize)
            if let displayAreas {
                for area in displayAreas {
                    for y in Int(area.minY)..<Int(area.maxY) {
                        let start = y * frame.width + Int(area.minX)
                        missing.insert(integersIn: start..<(start + Int(area.width)))
                    }
                }
            } else {
                missing = IndexSet(integersIn: 0..<(frame.width * frame.height))
            }
        }
        guard displayAreas?.isEmpty != true else { return }
        // RFB may deliver the initial desktop as several damage rectangles. Unreceived
        // pixels in a newly allocated texture must never become a black preview.
        if !missing.isEmpty {
            if let region = frame.region {
                for y in region.y..<(region.y + region.height) {
                    let start = y * frame.width + region.x
                    missing.remove(integersIn: start..<(start + region.width))
                }
            } else {
                missing.removeAll()
            }
            guard missing.isEmpty else { return }
        }
        dirtyAt = .now
        guard let lastCapture else {
            flush()
            return
        }
        if checkpoint == nil {
            let deadline = lastCapture.advanced(by: interval)
            checkpoint = Task { [weak self] in
                do { try await ContinuousClock().sleep(until: deadline) } catch { return }
                self?.flush()
            }
        }
    }

    func flush() {
        checkpoint?.cancel()
        checkpoint = nil
        guard let dirtyAt else { return }
        self.dirtyAt = nil
        lastCapture = .now
        guard let store, store.previews.enabled, policyRevision == store.previews.policyRevision,
              store.connection(id: id)?.isDiscovered == false else { return }
        guard let image = renderer.thumbnail(maxDimension: 640) else { return }
        if let displayAreas {
            // Gaps may retain pixels from an earlier viewport in a reused Metal texture.
            guard let context = CGContext(data: nil, width: image.width, height: image.height, bitsPerComponent: 8,
                                          bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                                          bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return }
            let bounds = CGRect(x: 0, y: 0, width: image.width, height: image.height)
            context.setFillColor(gray: 0, alpha: 1)
            context.fill(bounds)
            context.clip(to: displayAreas.map { area in
                CGRect(x: area.minX / size.width * bounds.width, y: (1 - area.maxY / size.height) * bounds.height,
                       width: area.width / size.width * bounds.width, height: area.height / size.height * bounds.height)
            })
            context.draw(image, in: bounds)
            guard let masked = context.makeImage() else { return }
            store.previews.save(masked, for: id, updatedAt: dirtyAt)
        } else {
            store.previews.save(image, for: id, updatedAt: dirtyAt)
        }
    }

    /// Layout origins and the requested crop are in server pixels. Damage rectangles
    /// are relative to the sampled texture, whose origin can be in the middle of a screen.
    private static func visibleDisplayAreas(_ displays: [RemoteDisplay], selectedID: Int?, in size: CGSize,
                                            viewport: RemoteViewport?, serverSize: CGSize?) -> [CGRect]? {
        guard displays.count > 1, let serverSize else { return nil }
        // Some hosts resize to the selected monitor before sending a new layout.
        if let selected = displays.first(where: { $0.id == selectedID }),
           serverSize == CGSize(width: selected.width, height: selected.height) { return nil }
        let viewport = viewport.flatMap { value in
            CGSize(width: value.bufferWidth, height: value.bufferHeight) == size &&
            CGSize(width: value.framebufferWidth, height: value.framebufferHeight) == serverSize ? value : nil
        }
        let crop = viewport.map { CGRect(x: $0.x, y: $0.y, width: $0.width, height: $0.height) }
            ?? CGRect(origin: .zero, size: serverSize)
        let scale = viewport.map { CGFloat($0.scale) } ?? ceil(serverSize.width / size.width)
        guard scale >= 1 else { return nil }
        let bounds = CGRect(origin: .zero, size: size)
        let areas = displays.compactMap { display -> CGRect? in
            let area = CGRect(origin: display.origin, size: CGSize(width: display.width, height: display.height))
                .intersection(crop)
            guard !area.isEmpty else { return nil }
            let x = floor(area.minX / scale), y = floor(area.minY / scale)
            let rect = CGRect(x: x - floor(crop.minX / scale), y: y - floor(crop.minY / scale),
                              width: ceil(area.maxX / scale) - x, height: ceil(area.maxY / scale) - y)
                .intersection(bounds)
            return rect.isEmpty ? nil : rect
        }
        return areas.contains(bounds) ? nil : areas
    }

    func reset() {
        checkpoint?.cancel()
        checkpoint = nil
        dirtyAt = nil
        size = .zero
        missing.removeAll()
    }

    func beginSession() {
        reset()
        lastCapture = nil
    }
}
