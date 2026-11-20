import AppKit
import OpenScreensUI
import SwiftUI

/// Adds the transfer check to the native close button and Command-W.
struct SessionWindowCloseGuard: NSViewRepresentable {
    let model: SessionViewModel

    static func hasActiveTransfers(in window: NSWindow) -> Bool {
        (window.delegate as? CloseDelegate)?.model?.hasActiveTransfers == true
    }

    func makeNSView(context: Context) -> CloseGuardView {
        CloseGuardView(model: model)
    }

    func updateNSView(_ view: CloseGuardView, context: Context) {
        view.model = model
        view.installGuard()
    }

    static func dismantleNSView(_ view: CloseGuardView, coordinator: ()) {
        view.restoreDelegate()
    }

    final class CloseGuardView: NSView {
        var model: SessionViewModel
        private let closeDelegate = CloseDelegate()
        private weak var guardedWindow: NSWindow?

        init(model: SessionViewModel) {
            self.model = model
            super.init(frame: .zero)
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) {
            fatalError("init(coder:) is unavailable")
        }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            installGuard()
        }

        func installGuard() {
            if guardedWindow !== window { restoreDelegate() }
            guard let window, window.delegate !== closeDelegate else { return }
            guardedWindow = window
            closeDelegate.original = window.delegate
            closeDelegate.model = model
            window.delegate = closeDelegate
        }

        func restoreDelegate() {
            if let guardedWindow, guardedWindow.delegate === closeDelegate {
                guardedWindow.delegate = closeDelegate.original
            }
            guardedWindow = nil
        }
    }

    private final class CloseDelegate: NSObject, NSWindowDelegate {
        weak var original: (any NSWindowDelegate)?
        weak var model: SessionViewModel?

        func windowShouldClose(_ sender: NSWindow) -> Bool {
            if model?.requestDisconnectConfirmation() == true {
                return false
            }
            return original?.windowShouldClose?(sender) ?? true
        }

        override func responds(to selector: Selector!) -> Bool {
            super.responds(to: selector) || original?.responds(to: selector) == true
        }

        override func forwardingTarget(for selector: Selector!) -> Any? {
            if original?.responds(to: selector) == true { return original }
            return super.forwardingTarget(for: selector)
        }
    }
}
