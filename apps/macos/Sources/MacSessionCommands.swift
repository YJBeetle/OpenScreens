import OpenScreensUI
import SwiftUI

struct SessionCommands {
    let reconnect: @MainActor () -> Void
    let disconnect: @MainActor () -> Void
    let takeScreenshot: @MainActor () -> Void
    let toggleToolbar: @MainActor () -> Void
    let toggleObserveMode: @MainActor () -> Void
    let setCursorMode: @MainActor (CursorMode) -> Void

    let showsToolbar: Bool
    let isObserving: Bool
    let cursorMode: CursorMode
    let isConnected: Bool
}

private struct SessionCommandsKey: FocusedValueKey {
    typealias Value = SessionCommands
}

extension FocusedValues {
    var sessionCommands: SessionCommands? {
        get { self[SessionCommandsKey.self] }
        set { self[SessionCommandsKey.self] = newValue }
    }
}

struct SessionMenuCommands: Commands {
    @FocusedValue(\.sessionCommands) private var session

    var body: some Commands {
        CommandMenu("Session") {
            Button("Reconnect") {
                session?.reconnect()
            }
            .keyboardShortcut("r", modifiers: .command)
            .disabled(session == nil)

            Button("Disconnect") {
                session?.disconnect()
            }
            .keyboardShortcut("d", modifiers: [.command, .shift])
            .disabled(session == nil)

            Divider()

            Button("Screenshot") {
                session?.takeScreenshot()
            }
            .keyboardShortcut("s", modifiers: [.command, .shift])
            .disabled(session?.isConnected != true)

            Toggle("Show Toolbar", isOn: Binding(
                get: { session?.showsToolbar ?? false },
                set: { _ in session?.toggleToolbar() }
            ))
            .keyboardShortcut("t", modifiers: [.command, .option])
            .disabled(session == nil)

            Toggle("Observe Mode", isOn: Binding(
                get: { session?.isObserving ?? false },
                set: { _ in session?.toggleObserveMode() }
            ))
            .keyboardShortcut("o", modifiers: [.command, .option])
            .disabled(session == nil)

            Menu("Cursor Mode") {
                ForEach(CursorMode.allCases) { mode in
                    Toggle(mode.title, isOn: Binding(
                        get: { session?.cursorMode == mode },
                        set: { _ in session?.setCursorMode(mode) }
                    ))
                }
            }
            .disabled(session == nil)
        }
    }
}
