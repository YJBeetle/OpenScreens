import CoreGraphics
import Foundation

/// A rectangular sub-region of a remote framebuffer, expressed in pixels.
public struct RemoteRegion: Hashable, Sendable, Codable {
    public var x: Int
    public var y: Int
    public var width: Int
    public var height: Int

    public init(x: Int, y: Int, width: Int, height: Int) {
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }

    public var isEmpty: Bool { width <= 0 || height <= 0 }

    /// Tightly packed BGRA8 byte count for this region.
    public var byteCount: Int { width * height * 4 }

    public func isContained(inWidth frameWidth: Int, height frameHeight: Int) -> Bool {
        x >= 0 && y >= 0 && width > 0 && height > 0
            && x + width <= frameWidth && y + height <= frameHeight
    }
}

/// How the remote framebuffer is mapped into the canvas bounds.
public enum RemoteContentMode: String, CaseIterable, Codable, Sendable, Identifiable {
    case fit
    case fill
    case stretch

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .fit: NSLocalizedString("Scale to Fit", comment: "Display scaling")
        case .fill: NSLocalizedString("Scale to Fill", comment: "Display scaling")
        case .stretch: NSLocalizedString("Stretch", comment: "Display scaling")
        }
    }
}
