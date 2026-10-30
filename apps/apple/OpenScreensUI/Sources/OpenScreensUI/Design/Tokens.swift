import SwiftUI

#if os(macOS)
import AppKit
#else
import UIKit
#endif

/// Design tokens shared by the macOS and iOS frontends.
public enum Theme {
    public enum Spacing {
        public static let xxs: CGFloat = 2
        public static let xs: CGFloat = 4
        public static let s: CGFloat = 8
        public static let m: CGFloat = 12
        public static let l: CGFloat = 16
        public static let xl: CGFloat = 24
        public static let xxl: CGFloat = 32
        public static let content: CGFloat = 28
        public static let tileGap: CGFloat = 16
    }

    public enum Radius {
        public static let control: CGFloat = 8
        public static let card: CGFloat = 12
        public static let tile: CGFloat = 14
        public static let sheet: CGFloat = 16
        public static let toolbar: CGFloat = 22
    }

    public enum Colors {
        public static var accent: Color { .adaptive(light: 0x6A4FD8, dark: 0xA694FF) }
        public static var success: Color { .adaptive(light: 0x1C9B5C, dark: 0x40D68A) }
        public static var warning: Color { .adaptive(light: 0xB26A00, dark: 0xFFB340) }
        public static var danger: Color { .adaptive(light: 0xC6352C, dark: 0xFF6B61) }
        public static var hairline: Color { .adaptive(light: 0x00000014, dark: 0xFFFFFF1A) }
        public static var tileStroke: Color { Color.white.opacity(0.16) }
        public static var canvas: Color { Color.black }
        public static var overlayScrim: Color { Color.black.opacity(0.45) }
    }

    public enum Typography {
        public static var screenTitle: Font { .system(.largeTitle, weight: .bold) }
        public static var paneTitle: Font { .system(.title2, weight: .semibold) }
        public static var sectionTitle: Font { .headline }
        public static var rowLabel: Font { .body }
        public static var tileName: Font { .headline }
        public static var tileDetail: Font { .caption }
        public static var caption: Font { .caption }
        public static var overlayTitle: Font { .subheadline.weight(.semibold) }
    }
}

// MARK: - Colour helpers

public extension Color {
    /// Creates a fixed sRGB colour from a six-digit RGB value.
    init(hex: UInt32) {
        self.init(
            .sRGB,
            red: Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255,
            opacity: 1
        )
    }

    /// Creates a colour that follows the system appearance.
    static func adaptive(light: UInt32, dark: UInt32) -> Color {
        #if os(macOS)
        return Color(nsColor: NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            return NSColor(srgbHex: isDark ? dark : light)
        })
        #else
        return Color(uiColor: UIColor { traits in
            UIColor(srgbHex: traits.userInterfaceStyle == .dark ? dark : light)
        })
        #endif
    }
}

#if os(macOS)
private extension NSColor {
    convenience init(srgbHex hex: UInt32) {
        self.init(
            srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
            green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255,
            alpha: 1
        )
    }
}
#else
private extension UIColor {
    convenience init(srgbHex hex: UInt32) {
        self.init(
            red: CGFloat((hex >> 16) & 0xFF) / 255,
            green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255,
            alpha: 1
        )
    }
}
#endif
