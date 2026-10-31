import OpenScreensCanvas
import SwiftUI

/// Floating/docked session controls.
struct SessionToolbar: View {
    let model: SessionViewModel
    let orientation: FloatingBarOrientation
    let items: [SessionToolbarItem]
    let onDownload: () -> Void
    let onDisconnect: () -> Void

    @Environment(\.horizontalSizeClass) private var horizontalSizeClass

    private var buttonSize: CGFloat {
        #if os(iOS)
        orientation == .vertical || horizontalSizeClass == .compact ? 34 : 40
        #else
        40
        #endif
    }

    var body: some View {
        FloatingBar(orientation: orientation) {
            ForEach(items) { item in
                toolbarItem(item)
            }

            FloatingIconButton(
                systemImage: "chevron.down",
                title: "Hide Toolbar",
                size: buttonSize
            ) {
                model.toggleChrome()
            }

            FloatingIconButton(
                systemImage: "rectangle.portrait.and.arrow.right",
                title: "Disconnect",
                size: buttonSize
            ) {
                onDisconnect()
            }
        }
    }

    @ViewBuilder
    private func toolbarItem(_ item: SessionToolbarItem) -> some View {
        switch item {
        case .pointer:
            cursorMenu
        case .displays:
            if model.displays.count > 1 {
                displayPickerMenu
            }
        case .keyboard:
            #if os(iOS)
            FloatingIconButton(
                systemImage: "keyboard",
                title: model.isKeyboardActive ? "Hide Keyboard" : "Show Keyboard",
                isSelected: model.isKeyboardActive,
                size: buttonSize
            ) {
                model.toggleKeyboard()
            }
            #endif
        case .clipboard:
            clipboardMenu
        case .download:
            FloatingIconButton(
                systemImage: "arrow.down.doc",
                title: "Download Remote File",
                size: buttonSize
            ) {
                onDownload()
            }
        case .display:
            displayMenu
        case .observe:
            FloatingIconButton(
                systemImage: model.isObserving ? "eye.fill" : "eye",
                title: model.isObserving ? "Observe Mode On" : "Observe Mode Off",
                isSelected: model.isObserving,
                size: buttonSize
            ) {
                model.toggleObserveMode()
            }
        case .screenshot:
            FloatingIconButton(
                systemImage: "camera",
                title: "Screenshot",
                size: buttonSize
            ) {
                model.grabScreenshot()
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
        else { return NSLocalizedString("All Displays", comment: "Display picker") }
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
        .accessibilityHint(clipboardHint)
    }

    private var clipboardHint: String {
        model.profile.controls.sharedClipboard
            ? NSLocalizedString("Send or fetch clipboard text", comment: "Clipboard hint")
            : NSLocalizedString("Shared clipboard is turned off for this connection", comment: "Clipboard hint")
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
            .frame(width: buttonSize, height: buttonSize)
            .contentShape(Rectangle())
    }
}
