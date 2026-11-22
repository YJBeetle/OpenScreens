import OpenScreensCanvas
import SwiftUI

/// Floating/docked session controls.
struct SessionToolbar: View {
    @Environment(\.externalDisplayMirroring) private var externalDisplayMirroring

    let model: SessionViewModel
    let orientation: FloatingBarOrientation
    let items: [SessionToolbarItem]
    let onUpload: () -> Void
    let onDownload: () -> Void
    let onDisconnect: () -> Void
    var showsDragHandle = false

    #if os(iOS)
    private let buttonSize: CGFloat = 44
    #else
    private let buttonSize: CGFloat = 40
    #endif

    private var visibleItems: [SessionToolbarItem] {
        items.filter { item in
            if item == .displays {
                return model.displays.count > 1 || model.selectedDisplayID != nil
            }
            #if os(macOS)
            if item == .keyboard { return false }
            #endif
            return true
        }
    }

    var body: some View {
        #if os(iOS)
        ViewThatFits(in: orientation == .horizontal ? .horizontal : .vertical) {
            bar(items: visibleItems, primaryLimit: nil)
            bar(items: visibleItems, primaryLimit: 3)
            bar(items: visibleItems, primaryLimit: 0)
        }
        #else
        bar(items: visibleItems, primaryLimit: nil)
        #endif
    }

    private func bar(items: [SessionToolbarItem], primaryLimit: Int?) -> some View {
        let primaryItems = items.prefix(primaryLimit ?? items.count)
        return FloatingBar(orientation: orientation) {
            if showsDragHandle {
                ToolbarDragHandle(orientation: orientation)
            }

            ForEach(primaryItems) { item in
                control(item, inMenu: false)
            }

            if primaryLimit != nil {
                Menu {
                    Section {
                        if let externalDisplayMirroring {
                            Toggle("Mirror to External Display", systemImage: "airplayvideo", isOn: externalDisplayMirroring)
                        }
                        RemoteCommandMenu(model: model)
                        Button("Hide Toolbar", systemImage: "chevron.down") { model.toggleChrome() }
                        Button("Disconnect", systemImage: "rectangle.portrait.and.arrow.right",
                               role: .destructive, action: onDisconnect)
                    }
                    ForEach(items.dropFirst(primaryItems.count)) { item in
                        control(item, inMenu: true)
                    }
                } label: {
                    Label("More", systemImage: "ellipsis")
                        .labelStyle(.iconOnly)
                        .frame(width: buttonSize, height: buttonSize)
                        .contentShape(Rectangle())
                }
                .menuOrder(.fixed)
                .menuIndicator(.hidden)
                .buttonStyle(.plain)
                .accessibilityLabel("More")
            } else {
                if let externalDisplayMirroring {
                    Toggle("Mirror to External Display", systemImage: "airplayvideo", isOn: externalDisplayMirroring)
                        .labelStyle(.iconOnly)
                        .toggleStyle(.button)
                        .frame(minWidth: buttonSize, minHeight: buttonSize)
                }
                FloatingIconButton(systemImage: "chevron.down", title: "Hide Toolbar", size: buttonSize) {
                    model.toggleChrome()
                }
                FloatingIconButton(systemImage: "rectangle.portrait.and.arrow.right", title: "Disconnect",
                                   size: buttonSize, action: onDisconnect)
            }
        }
        .fixedSize()
    }

    private func control(_ item: SessionToolbarItem, inMenu: Bool) -> some View {
        SessionToolbarControl(model: model, item: item, buttonSize: buttonSize, inMenu: inMenu,
                              onUpload: onUpload, onDownload: onDownload)
    }

    /// Grab area for moving the floating toolbar between screen edges.
    private struct ToolbarDragHandle: View {
        let orientation: FloatingBarOrientation

        var body: some View {
            Group {
                if orientation == .horizontal {
                    VStack(spacing: 3) { dot; dot; dot }
                        .frame(width: 10, height: 30)
                } else {
                    HStack(spacing: 3) { dot; dot; dot }
                        .frame(width: 30, height: 10)
                }
            }
            .accessibilityHidden(true)
        }

        private var dot: some View {
            Circle()
                .fill(.secondary.opacity(0.7))
                .frame(width: 3, height: 3)
        }
    }
}

private struct SessionToolbarControl: View {
    let model: SessionViewModel
    let item: SessionToolbarItem
    let buttonSize: CGFloat
    let inMenu: Bool
    let onUpload: () -> Void
    let onDownload: () -> Void

    @ViewBuilder
    var body: some View {
        switch item {
        case .pointer:
            cursorMenu
        case .displays:
            displayPickerMenu
        case .keyboard:
            #if os(iOS)
            if inMenu {
                keyboardButton
            } else {
                keyboardButton.contextMenu { RemoteCommandMenu(model: model) }
            }
            #endif
        case .clipboard:
            clipboardMenu
        case .download:
            Menu {
                Button("Send Files…", systemImage: "arrow.up.doc", action: onUpload)
                    .disabled(model.isObserving)
                Button("Download Remote File", systemImage: "arrow.down.doc", action: onDownload)
                Button("File Transfers", systemImage: "arrow.up.arrow.down") {
                    model.showsFileTransfers = true
                }
            } label: {
                menuIcon("arrow.up.arrow.down", title: "File Transfers")
            }
            .menuIndicator(.hidden)
            .buttonStyle(.plain)
            .accessibilityLabel("File Transfers")
        case .display:
            displayMenu
        case .hotCorners:
            hotCornersMenu
        case .observe:
            actionButton(
                systemImage: model.isObserving ? "eye.fill" : "eye",
                title: model.isObserving ? "Observe Mode On" : "Observe Mode Off",
                isSelected: model.isObserving
            ) {
                model.toggleObserveMode()
            }
        case .screenshot:
            #if os(macOS)
            Menu {
                Button("Copy Screenshot") { model.grabScreenshot() }
                Button("Save Screenshot As…") { model.saveScreenshotAs() }
            } label: {
                menuIcon("camera", title: "Screenshot")
            }
            .menuIndicator(.hidden)
            .buttonStyle(.plain)
            .accessibilityLabel("Screenshot")
            #else
            actionButton(
                systemImage: "camera",
                title: "Screenshot"
            ) {
                model.grabScreenshot()
            }
            #endif
        }
    }

    #if os(iOS)
    private var keyboardButton: some View {
        actionButton(systemImage: "keyboard",
                     title: model.isKeyboardActive ? "Hide Keyboard" : "Show Keyboard",
                     isSelected: model.isKeyboardActive) {
            model.toggleKeyboard()
        }
    }
    #endif

    @ViewBuilder
    private func actionButton(systemImage: String, title: String, isSelected: Bool = false,
                              action: @escaping () -> Void) -> some View {
        if inMenu {
            Button(NSLocalizedString(title, comment: "Session control"), systemImage: systemImage, action: action)
                .accessibilityAddTraits(isSelected ? .isSelected : [])
        } else {
            FloatingIconButton(systemImage: systemImage, title: title, isSelected: isSelected,
                               size: buttonSize, action: action)
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
        .menuOrder(.fixed)
        .menuIndicator(.hidden)
        .buttonStyle(.plain)
        .accessibilityLabel("Cursor mode")
        .accessibilityValue(model.cursorMode.title)
    }

    /// Chooses between the host's displays. Only offered when the host reports
    /// more than one screen.
    private var displayPickerMenu: some View {
        Menu {
            displayMenuItem(NSLocalizedString("All Displays", comment: "Display picker"), id: nil)
            ForEach(model.displays) { display in
                displayMenuItem("\(display.name) — \(display.resolutionLabel)", id: display.id)
            }
        } label: {
            menuIcon("rectangle.on.rectangle", title: "Select display")
        }
        .menuIndicator(.hidden)
        .buttonStyle(.plain)
        .accessibilityLabel("Select display")
        .accessibilityValue(selectedDisplayLabel)
        .disabled(model.isSwitchingDisplay)
    }

    private func displayMenuItem(_ title: String, id: Int?) -> some View {
        Button {
            model.selectDisplay(id)
        } label: {
            if model.selectedDisplayID == id {
                Label(title, systemImage: "checkmark")
            } else {
                Text(title)
            }
        }
        .accessibilityAddTraits(model.selectedDisplayID == id ? .isSelected : [])
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
            .disabled(model.isObserving)

            Button {
                model.fetchRemoteClipboard()
            } label: {
                Label("Copy Remote Clipboard", systemImage: "arrow.down.doc")
            }
            Divider()
            Toggle("Use Shared Clipboard", isOn: Binding(
                get: { model.sharedClipboard },
                set: { model.setClipboardSharing($0) }
            ))
        } label: {
            menuIcon("doc.on.clipboard", title: "Clipboard")
        }
        .menuIndicator(.hidden)
        .buttonStyle(.plain)
        .disabled(!model.state.isConnected)
        .accessibilityLabel("Clipboard")
        .accessibilityHint(Text("Send or fetch clipboard text"))
    }

    /// Parks the remote pointer on a screen edge, so the host's hot corners
    /// fire and an auto-hidden Dock appears without pixel-hunting.
    private var hotCornersMenu: some View {
        Menu {
            ForEach(RemoteHotCorner.corners) { corner in
                Button {
                    model.jumpPointer(to: corner.normalizedPoint)
                } label: {
                    Label(corner.title, systemImage: corner.systemImage)
                }
            }

            Divider()

            Button {
                model.jumpPointer(to: RemoteHotCorner.dock.normalizedPoint)
            } label: {
                Label(
                    RemoteHotCorner.dock.title,
                    systemImage: RemoteHotCorner.dock.systemImage
                )
            }
        } label: {
            menuIcon("square.grid.3x3", title: "Hot Corners")
        }
        .menuIndicator(.hidden)
        .buttonStyle(.plain)
        .accessibilityLabel("Hot Corners")
    }

    private var displayMenu: some View {
        Menu {
            if model.state.isConnected && !model.isObserving && model.supportsCurtainMode {
                Section("Curtain Mode") {
                    Button("Enable Curtain Mode") { model.requestCurtainMode(true) }
                    Button("Disable Curtain Mode") { model.requestCurtainMode(false) }
                }
            }
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

    private var scalingBinding: Binding<RemoteContentMode> {
        Binding(
            get: { model.scaling },
            set: { model.setScaling($0) }
        )
    }

    @ViewBuilder
    private func menuIcon(_ systemImage: String, title: String) -> some View {
        if inMenu {
            Label(NSLocalizedString(title, comment: "Session control"), systemImage: systemImage)
        } else {
            Image(systemName: systemImage)
                .font(.system(size: 16, weight: .medium))
                .foregroundStyle(.primary)
                .frame(width: buttonSize, height: buttonSize)
                .contentShape(Rectangle())
        }
    }
}
