import OpenScreensUI

/// Maps the shared UI's key model onto X11 keysyms used by RFB.
enum Keysym {
    static func modifiers(_ modifiers: RemoteModifiers) -> [UInt32] {
        var result: [UInt32] = []
        if modifiers.contains(.shift) { result.append(0xffe1) }
        if modifiers.contains(.control) { result.append(0xffe3) }
        if modifiers.contains(.option) { result.append(0xffe9) }
        if modifiers.contains(.command) { result.append(0xffeb) }
        return result
    }

    static func keysym(for key: RemoteKey) -> UInt32? {
        switch key {
        case .text(let text):
            guard let scalar = text.unicodeScalars.first else { return nil }
            return keysym(for: scalar)
        case .escape: return 0xff1b
        case .tab: return 0xff09
        case .returnKey: return 0xff0d
        case .backspace: return 0xff08
        case .deleteForward: return 0xffff
        case .insert: return 0xff63
        case .arrowUp: return 0xff52
        case .arrowDown: return 0xff54
        case .arrowLeft: return 0xff51
        case .arrowRight: return 0xff53
        case .home: return 0xff50
        case .end: return 0xff57
        case .pageUp: return 0xff55
        case .pageDown: return 0xff56
        case .function(let number):
            guard (1...12).contains(number) else { return nil }
            return 0xffbe + UInt32(number - 1)
        }
    }

    static func keysym(for scalar: Unicode.Scalar) -> UInt32 {
        switch scalar.value {
        case 0x0a, 0x0d: return 0xff0d
        case 0x09: return 0xff09
        case 0x20...0x7e, 0xa0...0xff: return scalar.value
        default: return 0x0100_0000 + scalar.value
        }
    }
}
