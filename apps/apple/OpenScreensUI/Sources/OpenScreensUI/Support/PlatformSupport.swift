import CoreGraphics
import Foundation
import SwiftUI

#if os(macOS)
import AppKit
#else
import UIKit
#endif

// MARK: - Small platform wrappers

/// Clipboard access used by the session layer. Isolating it keeps the rest of
/// the shared UI free of AppKit/UIKit imports.
@MainActor
public enum PlatformClipboard {
    public static var string: String? {
        #if os(macOS)
        NSPasteboard.general.string(forType: .string)
        #else
        UIPasteboard.general.string
        #endif
    }

    public static func setString(_ value: String) {
        #if os(macOS)
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(value, forType: .string)
        #else
        UIPasteboard.general.string = value
        #endif
    }
}

/// Idle-timer control for full-screen sessions.
@MainActor
public enum PlatformScreen {
    public static func setIdleTimerDisabled(_ disabled: Bool) {
        #if os(iOS)
        UIApplication.shared.isIdleTimerDisabled = disabled
        #endif
    }
}

/// Light haptic on platforms that support it.
@MainActor
public enum PlatformFeedback {
    public static func selection() {
        #if os(iOS)
        UISelectionFeedbackGenerator().selectionChanged()
        #endif
    }
}

/// Keyboard modifier state that the platform currently reports, if any.
public enum PlatformInput {
    @MainActor
    public static var currentModifiers: RemoteModifiers {
        #if os(macOS)
        let flags = NSEvent.modifierFlags
        var modifiers: RemoteModifiers = []
        if flags.contains(.control) { modifiers.insert(.control) }
        if flags.contains(.option) { modifiers.insert(.option) }
        if flags.contains(.command) { modifiers.insert(.command) }
        if flags.contains(.shift) { modifiers.insert(.shift) }
        return modifiers
        #else
        return []
        #endif
    }
}
