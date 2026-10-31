import OpenScreensCanvas
import SwiftUI

/// Floating/docked session controls.
struct SessionToolbar: View {
    let model: SessionViewModel
    let onDisconnect: () -> Void

    var body: some View {
        FloatingBar {
            cursorMenu

            if model.displays.count > 1 {
                displayPickerMenu
            }

            #if os(iOS)
            FloatingIconButton(
                systemImage: "keyboard",
                title: model.isKeyboardActive ? "Hide Keyboard" : "Show Keyboard",
                isSelected: model.isKeyboardActive
            ) {
                model.toggleKeyboard()
            }
            #endif

            clipboardMenu
            displayMenu

            FloatingIconButton(
                systemImage: model.isObserving ? "eye.fill" : "eye",
                title: model.isObserving ? "Observe Mode On" : "Observe Mode Off",
                isSelected: model.isObserving
            ) {
                model.toggleObserveMode()
            }

            FloatingIconButton(
                systemImage: "chevron.down",
                title: "Hide Toolbar"
            ) {
                model.toggleChrome()
            }

            FloatingIconButton(
                systemImage: "rectangle.portrait.and.arrow.right",
                title: "Disconnect"
            ) {
                onDisconnect()
            }
        }
    }

    private var cursorMenu: some View {
        Menu {
            Picker("Cursor Mode", selection: cursorModeBinding) {
                ForEach(CursorMode.allCases) { mode in
                    Label(mode.title, systemImage: mode.systemImage).tag(mode)
                }
            }
        } label: {
            menuIcon(model.cursorMode.systemImage, title: "Cursor mode")
        }
        .menuIndicator(.hidden)
        .buttonStyle(.plain)
        .accessibilityLabel("Cursor mode")
        .accessibilityValue(model.cursorMode.title)
    }

    /// Chooses between the host's displays. Only offered when the host reports
    /// more than one screen.
    private var displayPickerMenu: some View {
        Menu {
            Picker("Display", selection: displayBinding) {
                Text("All Displays").tag(Int?.none)
                ForEach(model.displays) { display in
                    Text("\(display.name) — \(display.resolutionLabel)")
                        .tag(Optional(display.id))
                }
            }
        } label: {
            menuIcon("rectangle.on.rectangle", title: "Select display")
        }
        .menuIndicator(.hidden)
        .buttonStyle(.plain)
        .accessibilityLabel("Select display")
        .accessibilityValue(selectedDisplayLabel)
    }

    private var selectedDisplayLabel: String {
        guard let id = model.selectedDisplayID,
              let display = model.displays.first(where: { $0.id == id })
        else { return "All Displays" }
        return display.name
    }

    private var clipboardMenu: some View {
        Menu {
            Button {
                model.sendLocalClipboard()
            } label: {
                Label("Send Local Clipboard", systemImage: "arrow.up.doc")
            }

            Button {
                model.fetchRemoteClipboard()
            } label: {
                Label("Copy Remote Clipboard", systemImage: "arrow.down.doc")
            }
        } label: {
            menuIcon("doc.on.clipboard", title: "Clipboard")
        }
        .menuIndicator(.hidden)
        .buttonStyle(.plain)
        .disabled(!model.profile.controls.sharedClipboard)
        .opacity(model.profile.controls.sharedClipboard ? 1 : 0.4)
        .accessibilityLabel("Clipboard")
        .accessibilityHint(model.profile.controls.sharedClipboard
            ? "Send or fetch clipboard text"
            : "Shared clipboard is turned off for this connection")
    }

    private var displayMenu: some View {
        Menu {
            Section("Scaling") {
                Picker("Scaling", selection: scalingBinding) {
                    ForEach(RemoteContentMode.allCases) { mode in
                        Text(mode.title).tag(mode)
                    }
                }
            }
        } label: {
            menuIcon("display", title: "Display options")
        }
        .menuIndicator(.hidden)
        .buttonStyle(.plain)
        .accessibilityLabel("Display options")
        .accessibilityValue(model.scaling.title)
    }

    private var cursorModeBinding: Binding<CursorMode> {
        Binding(
            get: { model.cursorMode },
            set: { model.setCursorMode($0) }
        )
    }

    private var displayBinding: Binding<Int?> {
        Binding(
            get: { model.selectedDisplayID },
            set: { model.selectDisplay($0) }
        )
    }

    private var scalingBinding: Binding<RemoteContentMode> {
        Binding(
            get: { model.scaling },
            set: { model.setScaling($0) }
        )
    }

    private func menuIcon(_ systemImage: String, title: String) -> some View {
        Image(systemName: systemImage)
            .font(.system(size: 16, weight: .medium))
            .foregroundStyle(.primary)
            .frame(width: 40, height: 40)
            .contentShape(Rectangle())
    }
}
