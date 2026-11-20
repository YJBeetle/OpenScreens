import CoreGraphics
import Foundation
import SwiftUI

#if os(macOS)
import AppKit
import UniformTypeIdentifiers
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

    @MainActor
    static func saveAsPNG(_ image: CGImage) async throws -> URL? {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.png]
        panel.canCreateDirectories = true
        panel.nameFieldStringValue = NSLocalizedString("Screenshot.png", comment: "Default screenshot filename")

        let response = await withCheckedContinuation { continuation in
            if let window = NSApp.keyWindow {
                panel.beginSheetModal(for: window) { continuation.resume(returning: $0) }
            } else {
                panel.begin { continuation.resume(returning: $0) }
            }
        }
        guard response == .OK, let url = panel.url else { return nil }
        let bitmap = NSBitmapImageRep(cgImage: image)
        guard let png = bitmap.representation(using: .png, properties: [:]) else {
            throw CocoaError(.fileWriteUnknown)
        }
        try png.write(to: url, options: .atomic)
        return url
    }
    #endif
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
