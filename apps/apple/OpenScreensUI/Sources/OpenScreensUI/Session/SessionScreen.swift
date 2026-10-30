import OpenScreensCanvas
import SwiftUI

/// Full-screen remote session chrome shared by macOS and iOS.
public struct SessionScreen: View {
    @Environment(SettingsStore.self) private var settings

    private let model: SessionViewModel
    private let showsCloseButton: Bool
    private let onClose: () -> Void

    @State private var confirmingDisconnect = false

    #if os(macOS)
    @FocusState private var keyboardFocused: Bool
    #endif

    public init(
        model: SessionViewModel,
        showsCloseButton: Bool = true,
        onClose: @escaping () -> Void = {}
    ) {
        self.model = model
        self.showsCloseButton = showsCloseButton
        self.onClose = onClose
    }

    public var body: some View {
        ZStack {
            Theme.Colors.canvas
                .ignoresSafeArea()

            RemoteCanvasView(renderer: model.renderer, contentMode: model.scaling)
                .ignoresSafeArea()
                .accessibilityHidden(true)

            pointerSurface
            hardwareKeyboardLayer

            if model.state.isTerminal {
                connectionClosedOverlay
            } else if !model.state.isConnected {
                connectingOverlay
            }

            if model.state.isConnected {
                chrome
                toast
            }
        }
        .background(Theme.Colors.canvas)
        .onAppear {
            model.start()
            focusHardwareKeyboard()
        }
        .onDisappear {
            model.stop()
        }
        .confirmationDialog(
            "Disconnect from “\(model.profile.name)”?",
            isPresented: $confirmingDisconnect,
            titleVisibility: .visible
        ) {
            Button("Disconnect", role: .destructive) {
                closeSession()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("The remote session ends. You can reconnect from the library at any time.")
        }
    }

    // MARK: - Layers

    private var pointerSurface: some View {
        GeometryReader { proxy in
            Color.clear
                .contentShape(Rectangle())
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { value in
                            let dx = value.translation.width
                            let dy = value.translation.height
                            if (dx * dx + dy * dy).squareRoot() > 3 {
                                model.drag(to: value.location, in: proxy.size)
                            }
                        }
                        .onEnded { value in
                            let dx = value.translation.width
                            let dy = value.translation.height
                            if (dx * dx + dy * dy).squareRoot() <= 6 {
                                model.tap(at: value.location, in: proxy.size)
                            }
                            model.endDrag()
                            focusHardwareKeyboard()
                        }
                )
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Remote screen for \(model.profile.name)")
        .accessibilityValue(accessibilityStatus)
        .accessibilityHint("Tap to click, drag to move the pointer")
        .accessibilityAction(named: "Disconnect") {
            requestClose()
        }
        .accessibilityAction(named: "Toggle Observe Mode") {
            model.toggleObserveMode()
        }
    }

    @ViewBuilder
    private var hardwareKeyboardLayer: some View {
        #if os(macOS)
        Color.clear
            .frame(width: 1, height: 1)
            .focusable()
            .focused($keyboardFocused)
            .focusEffectDisabled()
            .onKeyPress(phases: .down) { press in
                handleKeyPress(press)
            }
            .onAppear {
                DispatchQueue.main.async {
                    keyboardFocused = true
                }
            }
            .accessibilityHidden(true)
        #else
        SessionKeyboardProxy(model: model)
            .frame(width: 0, height: 0)
            .accessibilityHidden(true)
        #endif
    }

    @ViewBuilder
    private var chrome: some View {
        if model.showsChrome {
            VStack(spacing: 0) {
                HStack(alignment: .top) {
                    statusHeader
                    Spacer(minLength: 0)
                }
                Spacer(minLength: 0)
                HStack {
                    Spacer(minLength: 0)
                    SessionToolbar(model: model, onDisconnect: requestClose)
                    Spacer(minLength: 0)
                }
            }
            .padding(.horizontal, 12)
            .padding(.top, 10)
            .padding(.bottom, 10)
            .transition(.opacity)
        } else {
            VStack {
                HStack {
                    Spacer()
                    FloatingBar {
                        FloatingIconButton(
                            systemImage: "chevron.up",
                            title: "Show Toolbar"
                        ) {
                            model.toggleChrome()
                        }
                    }
                }
                Spacer()
            }
            .padding(12)
            .transition(.opacity)
        }
    }

    private var statusHeader: some View {
        HStack(spacing: 10) {
            StatusDot(color: statusColor, diameter: 9)

            VStack(alignment: .leading, spacing: 1) {
                Text(model.profile.name)
                    .font(Theme.Typography.overlayTitle)
                    .lineLimit(1)

                Text(connectionDetail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            if model.isObserving {
                Text("Observe")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(Theme.Colors.warning)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 2)
                    .background(Theme.Colors.warning.opacity(0.16), in: Capsule())
                    .accessibilityLabel("Observe mode is on")
            }

            if showsCloseButton {
                Button {
                    requestClose()
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(.secondary)
                        .frame(width: 28, height: 28)
                        .background(.quaternary.opacity(0.6), in: Circle())
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Close session")
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(Theme.Colors.hairline, lineWidth: 1)
        }
        .frame(maxWidth: 430)
        .accessibilityElement(children: .combine)
    }

    private var connectingOverlay: some View {
        ZStack {
            Theme.Colors.canvas.opacity(0.55)
                .ignoresSafeArea()

            VStack(spacing: 14) {
                ProgressView()
                    .controlSize(.large)

                Text(model.state.label)
                    .font(.headline)

                Text("Connecting to \(model.profile.endpoint)")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Button("Cancel") {
                    closeSession()
                }
                .padding(.top, 4)
            }
            .padding(28)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: Theme.Radius.sheet, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: Theme.Radius.sheet, style: .continuous)
                    .strokeBorder(Theme.Colors.hairline, lineWidth: 1)
            }
            .frame(maxWidth: 320)
            .padding(24)
        }
        .transition(.opacity)
    }

    private var connectionClosedOverlay: some View {
        ZStack {
            Theme.Colors.canvas.opacity(0.5)
                .ignoresSafeArea()

            VStack(spacing: 12) {
                Image(systemName: "bolt.horizontal.circle")
                    .font(.system(size: 34, weight: .light))
                    .foregroundStyle(.secondary)

                Text("Connection Closed")
                    .font(.headline)

                if let failure = model.failureMessage, !failure.isEmpty {
                    Text(failure)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                } else {
                    Text("The remote computer ended the session.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }

                HStack(spacing: 10) {
                    Button("Reconnect") {
                        model.reconnect()
                    }
                    .buttonStyle(.borderedProminent)

                    Button("Close") {
                        closeSession()
                    }
                    .buttonStyle(.bordered)
                }
                .padding(.top, 4)
            }
            .padding(24)
            .frame(maxWidth: 340)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: Theme.Radius.sheet, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: Theme.Radius.sheet, style: .continuous)
                    .strokeBorder(Theme.Colors.hairline, lineWidth: 1)
            }
            .padding(24)
        }
        .transition(.opacity)
    }

    @ViewBuilder
    private var toast: some View {
        if let message = model.clipboardMessage {
            VStack {
                Spacer()
                Text(message)
                    .font(.footnote.weight(.medium))
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                    .background(.ultraThinMaterial, in: Capsule())
                    .overlay {
                        Capsule().strokeBorder(Theme.Colors.hairline, lineWidth: 1)
                    }
                    .padding(.bottom, 82)
            }
            .allowsHitTesting(false)
            .transition(.opacity)
            .animation(.snappy, value: model.clipboardMessage)
            .accessibilityAddTraits(.isStaticText)
        }
    }

    // MARK: - State helpers

    private var statusColor: Color {
        switch model.state {
        case .connected: Theme.Colors.success
        case .connecting, .reconnecting: Theme.Colors.warning
        case .disconnected: Theme.Colors.danger
        case .idle: .secondary
        }
    }

    private var connectionDetail: String {
        if let size = model.frameSize {
            return "\(Int(size.width)) × \(Int(size.height)) · \(model.cursorMode.title)"
        }
        return model.state.label
    }

    private var accessibilityStatus: String {
        "\(model.state.label), \(model.cursorMode.title) cursor mode"
    }

    // MARK: - Actions

    private func requestClose() {
        if settings.settings.confirmDisconnect, model.state.isConnected {
            confirmingDisconnect = true
        } else {
            closeSession()
        }
    }

    private func closeSession() {
        model.disconnect()
        onClose()
    }

    private func focusHardwareKeyboard() {
        #if os(macOS)
        DispatchQueue.main.async {
            keyboardFocused = true
        }
        #endif
    }

    // MARK: - Hardware keyboard (macOS)

    #if os(macOS)
    private func handleKeyPress(_ press: KeyPress) -> KeyPress.Result {
        let modifiers = RemoteModifiers(eventModifiers: press.modifiers)

        switch press.key.character {
        case "\u{1B}":
            model.sendKey(.escape, extraModifiers: modifiers)
            return .handled
        case "\t":
            model.sendKey(.tab, extraModifiers: modifiers)
            return .handled
        case "\r", "\n":
            model.sendKey(.returnKey, extraModifiers: modifiers)
            return .handled
        case "\u{7F}":
            model.sendKey(.backspace, extraModifiers: modifiers)
            return .handled
        case "\u{F728}":
            model.sendKey(.deleteForward, extraModifiers: modifiers)
            return .handled
        case "\u{F700}":
            model.sendKey(.arrowUp, extraModifiers: modifiers)
            return .handled
        case "\u{F701}":
            model.sendKey(.arrowDown, extraModifiers: modifiers)
            return .handled
        case "\u{F702}":
            model.sendKey(.arrowLeft, extraModifiers: modifiers)
            return .handled
        case "\u{F703}":
            model.sendKey(.arrowRight, extraModifiers: modifiers)
            return .handled
        case "\u{F729}":
            model.sendKey(.home, extraModifiers: modifiers)
            return .handled
        case "\u{F72B}":
            model.sendKey(.end, extraModifiers: modifiers)
            return .handled
        case "\u{F72C}":
            model.sendKey(.pageUp, extraModifiers: modifiers)
            return .handled
        case "\u{F72D}":
            model.sendKey(.pageDown, extraModifiers: modifiers)
            return .handled
        case "\u{F727}":
            model.sendKey(.insert, extraModifiers: modifiers)
            return .handled
        default:
            break
        }

        guard !press.characters.isEmpty else { return .ignored }

        let commandish = modifiers.intersection([.control, .option, .command])
        if commandish.isEmpty {
            model.type(press.characters)
        } else {
            model.sendKey(.text(press.characters), extraModifiers: modifiers)
        }
        return .handled
    }
    #endif
}

private extension RemoteModifiers {
    init(eventModifiers: EventModifiers) {
        var value: RemoteModifiers = []
        if eventModifiers.contains(.control) { value.insert(.control) }
        if eventModifiers.contains(.option) { value.insert(.option) }
        if eventModifiers.contains(.command) { value.insert(.command) }
        if eventModifiers.contains(.shift) { value.insert(.shift) }
        self = value
    }
}
