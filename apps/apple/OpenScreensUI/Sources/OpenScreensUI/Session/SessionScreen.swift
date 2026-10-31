import OpenScreensCanvas
import SwiftUI
import UniformTypeIdentifiers

#if os(macOS)
import AppKit
#endif

/// Full-screen remote session chrome shared by macOS and iOS.
public struct SessionScreen: View {
    @Environment(SettingsStore.self) private var settings
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.displayScale) private var displayScale

    private let model: SessionViewModel
    private let onClose: () -> Void

    @State private var confirmingDisconnect = false
    @State private var isDropTargeted = false
    @State private var showingDownloadDialog = false
    @State private var downloadPath = ""
    @State private var pinchStart: (zoom: CGFloat, pan: CGSize, focal: CGPoint)?
    @State private var pressIndicator: PressIndicator?

    #if os(macOS)
    @FocusState private var keyboardFocused: Bool
    @State private var hidesSystemCursor = false
    #endif

    public init(
        model: SessionViewModel,
        onClose: @escaping () -> Void = {}
    ) {
        self.model = model
        self.onClose = onClose
    }

    public var body: some View {
        ZStack {
            Theme.Colors.canvas
                .ignoresSafeArea()

            remoteCanvas
                .ignoresSafeArea()
                .accessibilityHidden(true)
                .alert(
                    "Download Complete",
                    isPresented: downloadCompleteBinding,
                    presenting: model.downloadSavedPath
                ) { _ in
                    Button("OK", role: .cancel) {}
                } message: { path in
                    Text("Saved to \(path)")
                }

            cursorOverlay
            pointerSurface
            if let indicator = pressIndicator {
                Circle()
                    .fill(indicator.color.opacity(0.9))
                    .frame(width: 22, height: 22)
                    .overlay(Circle().stroke(.white.opacity(0.85), lineWidth: 2))
                    .shadow(color: indicator.color.opacity(0.55), radius: 8)
                    .position(indicator.point)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
            }
            #if os(macOS)
            if model.state.isConnected {
                RemoteDragOutHandle(model: model)
                    .frame(width: 112, height: 38)
                    .padding(.leading, 14)
                    .padding(.bottom, 16)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
            }
            #endif
            hardwareKeyboardLayer

            if model.state.isTerminal {
                connectionClosedOverlay
            } else if !model.state.isConnected {
                connectingOverlay
            }

            if model.state.isConnected {
                chrome
                    .environment(\.colorScheme, .dark)
                toast
                transferStatus
            }

            if isDropTargeted {
                dropTargetOverlay
            }
        }
        .background(Theme.Colors.canvas)
        #if os(macOS)
        .onDrop(of: [.fileURL], isTargeted: $isDropTargeted) { providers in
            handleDrop(providers: providers)
        }
        #else
        .dropDestination(for: URL.self) { urls, _ in
            handleDrop(urls: urls)
        } isTargeted: { targeted in
            isDropTargeted = targeted
        }
        #endif
        .onAppear {
            model.start()
            focusHardwareKeyboard()
        }
        .onDisappear {
            model.stop()
            #if os(macOS)
            showSystemCursor()
            #endif
        }
        .onChange(of: model.state.isConnected) { _, connected in
            #if os(macOS)
            if !connected { showSystemCursor() }
            #endif
        }
        .onChange(of: scenePhase) { _, phase in
            model.handleScenePhase(phase)
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
        .alert("Download Remote File", isPresented: $showingDownloadDialog) {
            TextField("/path/on/remote/computer", text: $downloadPath)
            Button("Download") {
                let path = downloadPath.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !path.isEmpty else { return }
                model.download(remotePath: path)
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Enter the POSIX path of a file on the remote computer. It is saved to your Downloads folder.")
        }
    }

    @ViewBuilder
    private var remoteCanvas: some View {
        #if os(iOS)
        GeometryReader { proxy in
            RemoteCanvasView(
                renderer: model.renderer,
                contentMode: model.scaling == .stretch ? .stretch : .fit,
                imageRect: model.displayedViewportRect(in: proxy.size)
                    ?? model.displayedImageRect(in: proxy.size),
                containerSize: proxy.size
            )
            .frame(width: proxy.size.width, height: proxy.size.height)
            .onChange(of: proxy.size) { _, size in
                model.scheduleViewportUpdate(
                    in: size,
                    screenPixelWidth: size.width * displayScale
                )
            }
        }
        #else
        RemoteCanvasView(renderer: model.renderer, contentMode: model.scaling)
        #endif
    }

    private var downloadCompleteBinding: Binding<Bool> {
        Binding(
            get: { model.downloadSavedPath != nil },
            set: { presented in
                if !presented { model.clearDownloadResult() }
            }
        )
    }

    // MARK: - Layers

    private struct CursorPlacement {
        var image: CGImage
        var size: CGSize
        var center: CGPoint
    }

    /// Client-side pointer bitmap, positioned over the scaled framebuffer.
    private var cursorOverlay: some View {
        GeometryReader { proxy in
            if let placement = cursorPlacement(in: proxy.size) {
                Image(decorative: placement.image, scale: 1)
                    .resizable()
                    .interpolation(.none)
                    .frame(width: placement.size.width, height: placement.size.height)
                    .position(placement.center)
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    private func cursorPlacement(in viewSize: CGSize) -> CursorPlacement? {
        guard model.state.isConnected,
              let image = model.remoteCursorImage,
              let shape = model.remoteCursorShape,
              let rect = model.displayedImageRect(in: viewSize),
              let frame = model.framebufferSize,
              frame.width > 0, frame.height > 0
        else { return nil }

        let scale = rect.width / frame.width
        let cursorSize = CGSize(
            width: CGFloat(shape.width) * scale,
            height: CGFloat(shape.height) * scale
        )
        let anchorX = rect.minX + model.remoteCursor.x * rect.width
        let anchorY = rect.minY + model.remoteCursor.y * rect.height
        let left = anchorX - CGFloat(shape.hotspotX) * scale
        let top = anchorY - CGFloat(shape.hotspotY) * scale
        let center = CGPoint(
            x: left + cursorSize.width / 2,
            y: top + cursorSize.height / 2
        )
        return CursorPlacement(image: image, size: cursorSize, center: center)
    }

    private var pointerSurface: some View {
        GeometryReader { proxy in
            #if os(macOS)
            Color.clear
                .contentShape(Rectangle())
                .gesture(dragGesture(in: proxy.size))
                .onContinuousHover { phase in
                    handleHover(phase, in: proxy.size)
                }
            #else
            RemoteTouchSurface(
                onTap: { model.tap(at: $0, in: proxy.size) },
                onDrag: { model.drag(to: $0, in: proxy.size) },
                onDragEnd: {
                    model.endDrag()
                    focusHardwareKeyboard()
                },
                onRightClick: { model.rightClick(at: $0, in: proxy.size) },
                onMiddleClick: { model.middleClick(in: proxy.size) },
                onToggleChrome: {
                    withAnimation(.easeInOut(duration: 0.18)) {
                        model.showsChrome.toggle()
                    }
                },
                onScroll: { model.scroll(by: $0) },
                onDragZoomed: {
                    model.panZoom(by: $0, in: proxy.size)
                    model.scheduleViewportUpdate(
                        in: proxy.size,
                        screenPixelWidth: proxy.size.width * displayScale
                    )
                },
                isZoomed: { model.zoom > 1.001 },
                onPinchBegan: { focal in
                    guard model.zoomEnabled else { return }
                    pinchStart = (model.zoom, model.pan, focal)
                },
                onPinchChanged: { scale, focal in
                    guard model.zoomEnabled, let start = pinchStart else { return }
                    model.applyPinch(
                        scale: scale,
                        startZoom: start.zoom,
                        startPan: start.pan,
                        startFocal: start.focal,
                        currentFocal: focal,
                        in: proxy.size
                    )
                    model.scheduleViewportUpdate(
                        in: proxy.size,
                        screenPixelWidth: proxy.size.width * displayScale
                    )
                },
                onPinchEnded: { pinchStart = nil },
                onPressBegan: { button, point in
                    model.beginPress(button: button, at: point, in: proxy.size)
                    pressIndicator = PressIndicator(
                        color: Self.indicatorColor(for: button),
                        point: point
                    )
                },
                onPressMoved: { point in
                    model.movePress(to: point, in: proxy.size)
                    pressIndicator?.point = point
                },
                onPressEnded: {
                    model.endPress()
                    pressIndicator = nil
                },
                onThreeFingerSwipe: { direction in
                    let key: RemoteKey = switch direction {
                    case .up: .arrowUp
                    case .down: .arrowDown
                    case .left: .arrowLeft
                    default: .arrowRight
                    }
                    model.sendKey(key, extraModifiers: [.control])
                }
            )
            #endif
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

    private static func indicatorColor(for button: PointerButton) -> Color {
        switch button {
        case .left: Color(red: 0.29, green: 0.56, blue: 1)
        case .right: Color(red: 1, green: 0.35, blue: 0.32)
        case .middle: Color(red: 0.20, green: 0.78, blue: 0.35)
        }
    }

    private func dragGesture(in size: CGSize) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                let dx = value.translation.width
                let dy = value.translation.height
                if (dx * dx + dy * dy).squareRoot() > 3 {
                    model.drag(to: value.location, in: size)
                }
            }
            .onEnded { value in
                let dx = value.translation.width
                let dy = value.translation.height
                if (dx * dx + dy * dy).squareRoot() <= 6 {
                    model.tap(at: value.location, in: size)
                }
                model.endDrag()
                focusHardwareKeyboard()
            }
    }

    #if os(macOS)
    private func handleHover(_ phase: HoverPhase, in size: CGSize) {
        switch phase {
        case .active(let location):
            model.hover(at: location, in: size)
            hideSystemCursorIfNeeded()
        case .ended:
            showSystemCursor()
        @unknown default:
            break
        }
    }
    #endif

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
                    Spacer(minLength: 0)
                    statusHeader
                    Spacer(minLength: 0)
                }
                Spacer(minLength: 0)
                HStack {
                    Spacer(minLength: 0)
                    SessionToolbar(
                        model: model,
                        items: SessionToolbarItem.allCases.filter {
                            settings.settings.toolbarItems.contains($0)
                        },
                        onDownload: {
                            downloadPath = ""
                            showingDownloadDialog = true
                        },
                        onDisconnect: requestClose
                    )
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
                    .foregroundStyle(.white)
                    .lineLimit(1)

                Text(connectionDetail)
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.7))
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

        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .glassSurface(in: RoundedRectangle(cornerRadius: 14, style: .continuous))
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
                    .foregroundStyle(.white)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                    .glassSurface(in: Capsule())
                    .padding(.bottom, 82)
            }
            .environment(\.colorScheme, .dark)
            .allowsHitTesting(false)
            .transition(.opacity)
            .animation(.snappy, value: model.clipboardMessage)
            .accessibilityAddTraits(.isStaticText)
        }
    }

    /// Upload/download status for file transfers, below the session header.
    @ViewBuilder
    private var transferStatus: some View {
        if let text = transferStatusText {
            VStack {
                HStack(spacing: 8) {
                    ProgressView()
                        .controlSize(.small)

                    Text(text)
                        .font(.footnote.weight(.medium))
                        .lineLimit(1)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .glassSurface(in: Capsule())
                .frame(maxWidth: 420)
                .padding(.top, model.showsChrome ? 74 : 16)

                Spacer()
            }
            .environment(\.colorScheme, .dark)
            .allowsHitTesting(false)
            .transition(.opacity)
            .animation(.snappy, value: text)
            .accessibilityAddTraits(.isStaticText)
        }
    }

    private var transferStatusText: String? {
        if let name = model.uploadFileName {
            return uploadStatusText(name)
        }
        if let name = model.downloadFileName {
            return downloadStatusText(name)
        }
        return nil
    }

    private func uploadStatusText(_ name: String) -> String {
        if let fraction = model.uploadFraction {
            return String(
                format: NSLocalizedString("Sending %@… %lld%%", comment: "Upload progress"),
                name,
                Int((fraction * 100).rounded())
            )
        }
        return String(
            format: NSLocalizedString("Sending %@…", comment: "Upload status"),
            name
        )
    }

    private func downloadStatusText(_ name: String) -> String {
        if let fraction = model.downloadFraction {
            return String(
                format: NSLocalizedString("Downloading %@… %lld%%", comment: "Download progress"),
                name,
                Int((fraction * 100).rounded())
            )
        }
        return String(
            format: NSLocalizedString("Downloading %@…", comment: "Download status"),
            name
        )
    }

    private var dropTargetOverlay: some View {
        RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous)
            .strokeBorder(
                Theme.Colors.accent,
                style: StrokeStyle(lineWidth: 3, dash: [10, 6])
            )
            .padding(10)
            .overlay(alignment: .bottom) {
                Label("Drop files to send", systemImage: "arrow.up.doc.fill")
                    .font(.footnote.weight(.semibold))
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                    .background(.ultraThinMaterial, in: Capsule())
                    .overlay {
                        Capsule().strokeBorder(Theme.Colors.hairline, lineWidth: 1)
                    }
                    .padding(.bottom, 96)
            }
            .allowsHitTesting(false)
            .accessibilityHidden(true)
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
        if let size = model.serverSize ?? model.framebufferSize {
            return "\(Int(size.width)) × \(Int(size.height)) · \(model.cursorMode.title)"
        }
        return model.state.label
    }

    private var accessibilityStatus: String {
        String(
            format: NSLocalizedString("%@, %@ cursor mode", comment: "Session accessibility value"),
            model.state.label,
            model.cursorMode.title
        )
    }

    // MARK: - Drop to send

    #if os(macOS)
    private func handleDrop(providers: [NSItemProvider]) -> Bool {
        guard model.state.isConnected else { return false }
        let fileProviders = providers.filter {
            $0.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier)
        }
        guard !fileProviders.isEmpty else { return false }

        Task { @MainActor in
            var urls: [URL] = []
            for provider in fileProviders {
                if let url = await loadFileURL(from: provider) {
                    urls.append(url)
                }
            }
            if !urls.isEmpty {
                model.uploadFiles(urls)
            }
        }
        return true
    }

    private func loadFileURL(from provider: NSItemProvider) async -> URL? {
        await withCheckedContinuation { continuation in
            provider.loadItem(
                forTypeIdentifier: UTType.fileURL.identifier,
                options: nil
            ) { item, _ in
                if let url = item as? URL {
                    continuation.resume(returning: url)
                } else if let data = item as? Data,
                          let url = URL(dataRepresentation: data, relativeTo: nil) {
                    continuation.resume(returning: url)
                } else if let string = item as? String,
                          let url = URL(string: string) {
                    continuation.resume(returning: url)
                } else {
                    continuation.resume(returning: nil)
                }
            }
        }
    }
    #else
    private func handleDrop(urls: [URL]) -> Bool {
        guard model.state.isConnected, !urls.isEmpty else { return false }
        model.uploadFiles(urls)
        return true
    }
    #endif

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

    #if os(macOS)
    private func hideSystemCursorIfNeeded() {
        guard model.remoteCursorImage != nil, !hidesSystemCursor else { return }
        NSCursor.hide()
        hidesSystemCursor = true
    }

    private func showSystemCursor() {
        guard hidesSystemCursor else { return }
        NSCursor.unhide()
        hidesSystemCursor = false
    }
    #endif

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

private struct PressIndicator {
    var color: Color
    var point: CGPoint
}
