import SwiftUI

/// Shortcuts use the platform selected in the connection profile.
struct RemoteDesktopCommand: Identifiable {
    let title: String
    let event: RemoteKeyEvent

    var id: String { title }

    private init(_ title: String, _ key: RemoteKey, _ modifiers: RemoteModifiers = []) {
        self.title = title
        self.event = RemoteKeyEvent(key: key, modifiers: modifiers)
    }

    static let lockMac = Self("Lock Screen", .text("q"), [.command, .control])
    static let lockWindows = Self("Lock Screen", .text("l"), .command)
    static let ctrlAltDelete = Self("Ctrl-Alt-Delete", .deleteForward, [.control, .option])
    static let logOutMac = Self("Log Out Remote User", .text("q"), [.option, .shift, .command])

    static func commands(for platform: RemoteOS) -> [Self] {
        switch platform {
        case .macos:
            [
                Self("Mission Control", .arrowUp, .control),
                Self("Application Windows", .arrowDown, .control),
                Self("Move Left a Space", .arrowLeft, .control),
                Self("Move Right a Space", .arrowRight, .control),
                Self("Show Desktop", .function(11)),
                Self("Switch Applications", .tab, .command),
                Self("Spotlight", .text(" "), .command),
                Self("Force Quit…", .escape, [.command, .option]),
                .lockMac,
            ]
        case .windows:
            [
                .ctrlAltDelete,
                Self("Task Manager", .escape, [.control, .shift]),
                Self("Show Desktop", .text("d"), .command),
                Self("Switch Applications", .tab, .option),
                .lockWindows,
            ]
        case .linux, .unix:
            [Self("Switch Applications", .tab, .option), Self("Insert", .insert)]
        case .generic:
            [Self("Escape", .escape), Self("Insert", .insert)]
        }
    }
}

public struct RemoteCommandMenu: View {
    private let model: SessionViewModel
    private let buttonSize: CGFloat?

    public init(model: SessionViewModel) {
        self.init(model: model, buttonSize: nil)
    }

    init(model: SessionViewModel, buttonSize: CGFloat?) {
        self.model = model
        self.buttonSize = buttonSize
    }

    public var body: some View {
        Menu {
            ForEach(RemoteDesktopCommand.commands(for: model.isAppleRemote ? .macos : model.profile.platform)) { command in
                Button(NSLocalizedString(command.title, comment: "Remote desktop command")) {
                    model.sendCommand(command)
                }
            }
        } label: {
            if let buttonSize {
                Label("Remote Commands", systemImage: "command")
                    .labelStyle(.iconOnly)
                    .frame(width: buttonSize, height: buttonSize)
                    .contentShape(Rectangle())
            } else {
                Label("Remote Commands", systemImage: "command")
            }
        }
        .disabled(!model.state.isConnected || model.isObserving)
    }
}
