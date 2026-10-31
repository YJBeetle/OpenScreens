import Foundation
import SwiftUI

/// Colour palettes for the screen-shaped connection tiles. These are original
/// abstract gradients; no remote-desktop artwork is bundled.
public enum TilePalette: String, Codable, CaseIterable, Identifiable, Sendable {
    case ocean
    case plum
    case forest
    case ember
    case midnight
    case orchid
    case sand
    case slate

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .ocean: NSLocalizedString("Ocean", comment: "Tile colour")
        case .plum: NSLocalizedString("Plum", comment: "Tile colour")
        case .forest: NSLocalizedString("Forest", comment: "Tile colour")
        case .ember: NSLocalizedString("Ember", comment: "Tile colour")
        case .midnight: NSLocalizedString("Midnight", comment: "Tile colour")
        case .orchid: NSLocalizedString("Orchid", comment: "Tile colour")
        case .sand: NSLocalizedString("Sand", comment: "Tile colour")
        case .slate: NSLocalizedString("Slate", comment: "Tile colour")
        }
    }

    public var colors: [Color] {
        switch self {
        case .ocean:
            [Color(hex: 0x0B3D5C), Color(hex: 0x146C8A), Color(hex: 0x52B3A3)]
        case .plum:
            [Color(hex: 0x2A1240), Color(hex: 0x6B2B6E), Color(hex: 0xC25A8A)]
        case .forest:
            [Color(hex: 0x10261C), Color(hex: 0x255A3A), Color(hex: 0x74A76A)]
        case .ember:
            [Color(hex: 0x3A1508), Color(hex: 0x9B3B12), Color(hex: 0xE58A3A)]
        case .midnight:
            [Color(hex: 0x111826), Color(hex: 0x243B55), Color(hex: 0x4C6B8A)]
        case .orchid:
            [Color(hex: 0x24133A), Color(hex: 0x4B2A78), Color(hex: 0x8B5FC9)]
        case .sand:
            [Color(hex: 0x3B2E1E), Color(hex: 0x8A6A3C), Color(hex: 0xD9B574)]
        case .slate:
            [Color(hex: 0x1A1D22), Color(hex: 0x3A414D), Color(hex: 0x6C7787)]
        }
    }

    public var gradient: LinearGradient {
        LinearGradient(
            colors: colors,
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
    }

    public var highlight: Color {
        colors.last ?? .white
    }
}
