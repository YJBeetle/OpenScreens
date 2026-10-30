#if os(iOS)
import SwiftUI
import UIKit

/// Invisible first responder that owns the software keyboard for a session.
/// Its `inputAccessoryView` hosts the sticky modifier row, so the row rides
/// directly above the keyboard instead of floating in the canvas.
struct SessionKeyboardProxy: UIViewRepresentable {
    let model: SessionViewModel

    func makeUIView(context: Context) -> SessionKeyboardProxyView {
        let view = SessionKeyboardProxyView()
        view.configure(model: model)
        return view
    }

    func updateUIView(_ uiView: SessionKeyboardProxyView, context: Context) {
        uiView.configure(model: model)
        uiView.setKeyboardActive(model.isKeyboardActive)
    }

    static func dismantleUIView(_ uiView: SessionKeyboardProxyView, coordinator: ()) {
        uiView.setKeyboardActive(false)
    }
}

@MainActor
final class SessionKeyboardProxyView: UIView, UIKeyInput {
    private var model: SessionViewModel?
    private var accessoryHost: UIHostingController<SessionKeyboardAccessoryRow>?
    private var wantsKeyboard = false

    override var canBecomeFirstResponder: Bool { true }
    var hasText: Bool { true }

    override var inputAccessoryView: UIView? {
        accessoryHost?.view
    }

    override var keyCommands: [UIKeyCommand]? {
        [
            UIKeyCommand(input: UIKeyCommand.inputEscape, modifierFlags: [], action: #selector(handleEscape)),
            UIKeyCommand(input: "\t", modifierFlags: [], action: #selector(handleTab)),
            UIKeyCommand(input: UIKeyCommand.inputUpArrow, modifierFlags: [], action: #selector(handleUp)),
            UIKeyCommand(input: UIKeyCommand.inputDownArrow, modifierFlags: [], action: #selector(handleDown)),
            UIKeyCommand(input: UIKeyCommand.inputLeftArrow, modifierFlags: [], action: #selector(handleLeft)),
            UIKeyCommand(input: UIKeyCommand.inputRightArrow, modifierFlags: [], action: #selector(handleRight))
        ]
    }

    func configure(model: SessionViewModel) {
        guard self.model !== model else { return }
        self.model = model

        let host = UIHostingController(rootView: SessionKeyboardAccessoryRow(model: model))
        host.view.backgroundColor = .clear
        host.view.frame = CGRect(x: 0, y: 0, width: UIScreen.main.bounds.width, height: 48)
        host.view.autoresizingMask = [.flexibleWidth]
        accessoryHost = host
    }

    func setKeyboardActive(_ active: Bool) {
        wantsKeyboard = active
        guard active else {
            if isFirstResponder {
                resignFirstResponder()
            }
            return
        }
        guard window != nil else { return }
        DispatchQueue.main.async { [weak self] in
            guard let self, self.window != nil, !self.isFirstResponder else { return }
            self.becomeFirstResponder()
        }
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        guard wantsKeyboard, window != nil, !isFirstResponder else { return }
        DispatchQueue.main.async { [weak self] in
            guard let self, self.window != nil, !self.isFirstResponder else { return }
            self.becomeFirstResponder()
        }
    }

    // MARK: - UIKeyInput

    func insertText(_ text: String) {
        model?.type(text)
    }

    func deleteBackward() {
        model?.sendKey(.backspace)
    }

    // MARK: - Hardware key commands

    @objc private func handleEscape() {
        model?.sendKey(.escape)
    }

    @objc private func handleTab() {
        model?.sendKey(.tab)
    }

    @objc private func handleUp() {
        model?.sendKey(.arrowUp)
    }

    @objc private func handleDown() {
        model?.sendKey(.arrowDown)
    }

    @objc private func handleLeft() {
        model?.sendKey(.arrowLeft)
    }

    @objc private func handleRight() {
        model?.sendKey(.arrowRight)
    }
}
#endif
