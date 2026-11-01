import SwiftUI

struct LibraryCommands {
    let quickConnect: @MainActor () -> Void
}

private struct LibraryCommandsKey: FocusedValueKey {
    typealias Value = LibraryCommands
}

extension FocusedValues {
    var libraryCommands: LibraryCommands? {
        get { self[LibraryCommandsKey.self] }
        set { self[LibraryCommandsKey.self] = newValue }
    }
}

struct LibraryMenuCommands: Commands {
    @FocusedValue(\.libraryCommands) private var library

    var body: some Commands {
        CommandGroup(after: .newItem) {
            Button("Quick Connect…") {
                library?.quickConnect()
            }
            .keyboardShortcut("k", modifiers: .command)
            .disabled(library == nil)
        }
    }
}
