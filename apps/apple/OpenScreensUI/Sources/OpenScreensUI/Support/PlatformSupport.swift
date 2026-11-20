import CoreGraphics
import Foundation
import SwiftUI

#if os(macOS)
import AppKit
import IOKit.pwr_mgt
import os
#else
import Photos
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

    public static func setImage(_ image: CGImage) {
        #if os(macOS)
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        let representation = NSBitmapImageRep(cgImage: image)
        if let png = representation.representation(using: .png, properties: [:]) {
            pasteboard.setData(png, forType: .png)
        }
        #else
        UIPasteboard.general.image = UIImage(cgImage: image)
        #endif
    }
}

/// Delivers captured remote screenshots: Photos on iOS, the pasteboard on macOS.
public enum PlatformScreenshot {
    #if os(iOS)
    public static func save(_ image: CGImage, completion: @escaping @MainActor (Bool) -> Void) {
        PHPhotoLibrary.requestAuthorization(for: .addOnly) { status in
            guard status == .authorized || status == .limited else {
                Task { @MainActor in completion(false) }
                return
            }
            let photo = UIImage(cgImage: image)
            PHPhotoLibrary.shared().performChanges {
                PHAssetChangeRequest.creationRequestForAsset(from: photo)
            } completionHandler: { success, _ in
                Task { @MainActor in completion(success) }
            }
        }
    }
    #else
    @MainActor
    public static func save(_ image: CGImage, completion: @escaping @MainActor (Bool) -> Void) {
        PlatformClipboard.setImage(image)
        completion(true)
    }
    #endif
}

/// Keeps the local device awake while any participating session needs it.
@MainActor
enum PlatformScreen {
    private static var awakeSessions: Set<UUID> = []

    #if os(macOS)
    private static var assertion: IOPMAssertionID?
    private static let logger = Logger(subsystem: "app.openscreens", category: "PlatformScreen")
    #endif

    static func setIdleTimerDisabled(_ disabled: Bool, for sessionID: UUID) {
        if disabled {
            awakeSessions.insert(sessionID)
        } else {
            awakeSessions.remove(sessionID)
        }

        #if os(macOS)
        if awakeSessions.isEmpty {
            if let assertion {
                IOPMAssertionRelease(assertion)
                self.assertion = nil
            }
        } else if assertion == nil {
            var newAssertion = IOPMAssertionID()
            let result = IOPMAssertionCreateWithName(
                kIOPMAssertionTypePreventUserIdleSystemSleep as CFString,
                IOPMAssertionLevel(kIOPMAssertionLevelOn),
                "OpenScreens session" as CFString,
                &newAssertion
            )
            if result == kIOReturnSuccess {
                assertion = newAssertion
            } else {
                logger.error("Could not prevent idle sleep: \(result)")
            }
        }
        #else
        UIApplication.shared.isIdleTimerDisabled = !awakeSessions.isEmpty
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
