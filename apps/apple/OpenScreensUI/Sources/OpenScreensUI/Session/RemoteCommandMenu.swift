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
                Self("Lock Screen", .text("q"), [.command, .control]),
            ]
        case .windows:
            [
                Self("Ctrl-Alt-Delete", .deleteForward, [.control, .option]),
                Self("Task Manager", .escape, [.control, .shift]),
                Self("Show Desktop", .text("d"), .command),
                Self("Switch Applications", .tab, .option),
                Self("Lock Screen", .text("l"), .command),
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

    public init(model: SessionViewModel) {
        self.model = model
    }

    public var body: some View {
        Menu {
            ForEach(RemoteDesktopCommand.commands(for: model.profile.platform)) { command in
                Button(NSLocalizedString(command.title, comment: "Remote desktop command")) {
                    model.sendCommand(command)
                }
            }
        } label: {
            Label("Remote Commands", systemImage: "command")
        }
        .disabled(!model.state.isConnected || model.isObserving)
    }
}
