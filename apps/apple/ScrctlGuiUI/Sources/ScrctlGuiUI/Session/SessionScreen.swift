import ScrctlGuiCanvas
import SwiftUI
import UniformTypeIdentifiers

#if os(macOS)
import AppKit
#endif

/// Full-screen remote session chrome shared by macOS and iOS.
public struct SessionScreen: View {
    @Environment(ConnectionStore.self) private var store
    @Environment(SettingsStore.self) private var settings
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.displayScale) private var displayScale
    @Environment(\.layoutDirection) private var layoutDirection
    @Environment(\.verticalSizeClass) private var verticalSizeClass
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass

    private let model: SessionViewModel
    private let onClose: () -> Void
    private let toolbarBottomSpacing: CGFloat = 8

    @State private var presentedChallenge: RemoteFailureKind?
    @State private var isDropTargeted = false
    @State private var showingUploadPicker = false
    @State private var showingDownloadDialog = false
    @State private var downloadPath = ""
    @State private var appliedChromeDefault = false
    @State private var pinchStart: (zoom: CGFloat, pan: CGSize, focal: CGPoint)?
    @State private var pressIndicator: PressIndicator?
    @State private var toolbarDrag: CGSize = .zero
    @State private var toolbarSize: CGSize = .zero

    #if os(macOS)
    @FocusState private var keyboardFocused: Bool
    #endif

    public init(
        model: SessionViewModel,
        onClose: @escaping () -> Void = {}
    ) {
        self.model = model
        self.onClose = onClose
    }

    public var body: some View {
        @Bindable var model = model
        ZStack {
            Theme.Colors.canvas
                .ignoresSafeArea()

            #if os(iOS)
            remoteCanvas
                .allowsHitTesting(false)
                .accessibilityHidden(true)
            #endif

            ZStack {
                #if os(macOS)
                remoteCanvas.accessibilityHidden(true)
                #endif
                cursorOverlay
                pointerSurface
                    .allowsHitTesting(model.state.isConnected && model.frameSize != nil)
                if let indicator = pressIndicator {
                    GeometryReader { geometry in
                        let size = geometry.size
                        Circle()
                            .fill(indicator.color.opacity(0.9))
                            .frame(width: 22, height: 22)
                            .overlay(Circle().stroke(.white.opacity(0.85), lineWidth: 2))
                            .shadow(color: indicator.color.opacity(0.55), radius: 8)
                            .position(pressIndicatorPoint(finger: indicator.point, in: size))
                            .allowsHitTesting(false)
                            .accessibilityHidden(true)
                    }
                }
            }
            #if os(iOS)
            .clipped()
            .padding(toolbarInsets)
            #endif
            #if os(macOS)
            if model.state.isConnected && model.supportsFileDownload {
                RemoteDragOutHandle(model: model)
                    .frame(width: 112, height: 38)
                    .padding(.leading, 14)
                    .padding(.bottom, 16)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
            }
            #endif
            if model.state.isConnected { hardwareKeyboardLayer }

            if model.state.isTerminal && model.credentialChallenge == nil {
                connectionClosedOverlay
            } else if (!model.state.isConnected || model.frameSize == nil) && presentedChallenge == nil && model.credentialChallenge == nil {
                connectingOverlay
            }

            if model.state.isConnected && model.frameSize != nil {
                chrome
                toast
                transferStatus
            }

            if isDropTargeted {
                dropTargetOverlay
            }
        }
        .background(Theme.Colors.canvas)
        #if os(iOS)
        .modifier(SessionExternalDisplay(model: model))
        #endif
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
        .task(id: scenePhase == .active && model.sharedClipboard && model.state.isConnected && !model.isObserving) {
            if scenePhase == .active { await model.watchLocalClipboard() }
        }
        .onAppear {
            if !appliedChromeDefault {
                appliedChromeDefault = true
                model.showsChrome = settings.settings.showToolbarOnLaunch
            }
            model.start(store: store)
        }
        #if os(macOS)
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.willTerminateNotification)) { _ in
            model.flushSessionPreview()
        }
        #endif
        .onDisappear {
            model.stop()
        }
        .onChange(of: scenePhase, initial: true) { _, phase in
            model.handleScenePhase(phase)
        }
        .onChange(of: model.state, initial: true) { _, state in
            if let challenge = model.credentialChallenge {
                presentedChallenge = challenge
            } else if state.isConnected || state.isTerminal {
                presentedChallenge = nil
            }
        }
        .sheet(isPresented: Binding(
            get: { presentedChallenge != nil },
            set: { if !$0 { presentedChallenge = nil } }
        )) {
            if let challenge = presentedChallenge {
                CredentialPrompt(
                    endpoint: model.profile.endpoint, challenge: challenge,
                    isConnecting: model.credentialChallenge == nil,
                    username: model.loginUsername, remember: model.rememberLogin,
                    onConnect: model.submitCredentials,
                    onCancel: {
                        presentedChallenge = nil
                        closeSession()
                    }
                )
                .interactiveDismissDisabled()
            }
        }
        .alert(
            "Disconnect from “\(model.profile.name)”?",
            isPresented: $model.showingDisconnectRequest,
            presenting: model.disconnectRequest
        ) { request in
            Button("Disconnect", role: .destructive) {
                if model.confirmDisconnect(request) { onClose() }
            }
            Button("Cancel", role: .cancel) { model.cancelDisconnectConfirmation() }
        } message: { request in
            Text(request.message)
        }
        .sheet(isPresented: $model.showsFileTransfers) {
            SessionFileTransfers(model: model)
        }
        .fileImporter(isPresented: $showingUploadPicker, allowedContentTypes: [.item], allowsMultipleSelection: true) {
            if case .success(let urls) = $0 { model.uploadFiles(urls) }
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
            Text("Enter the POSIX path of a file on the remote computer. You can find its save location in File Transfers.")
        }
    }

    @ViewBuilder
    private var remoteCanvas: some View {
        #if os(iOS)
        GeometryReader { safe in
            GeometryReader { render in
                let safeFrame = safe.frame(in: .global)
                let insets = toolbarInsets
                let left = layoutDirection == .leftToRight ? insets.leading : insets.trailing
                let controlSize = CGSize(
                    width: max(0, safe.size.width - insets.leading - insets.trailing),
                    height: max(0, safe.size.height - insets.top - insets.bottom)
                )
                let renderFrame = render.frame(in: .global)
                let bounds = renderFrame.offsetBy(
                    dx: -(safeFrame.minX + left), dy: -(safeFrame.minY + insets.top)
                )
                RemoteCanvasView(
                    renderer: model.renderer,
                    contentMode: model.scaling == .stretch ? .stretch : .fit,
                    imageRect: model.displayedImageRect(in: controlSize)?
                        .offsetBy(dx: -bounds.minX, dy: -bounds.minY),
                    containerSize: render.size
                )
                .frame(width: render.size.width, height: render.size.height)
                .onChange(of: [bounds, CGRect(origin: .zero, size: controlSize)], initial: true) {
                    model.scheduleViewportUpdate(
                        in: controlSize,
                        screenPixelWidth: render.size.width * displayScale,
                        renderBounds: bounds
                    )
                }
            }
            .ignoresSafeArea(.container)
        }
        #else
        RemoteCanvasView(renderer: model.renderer, contentMode: model.scaling)
        #endif
    }

    // MARK: - Layers

    private var cursorOverlay: some View {
        SessionCursorOverlay(model: model, imageRect: model.displayedImageRect(in:))
    }

    private var pointerSurface: some View {
        GeometryReader { proxy in
            #if os(macOS)
            RemoteMouseSurface(model: model, size: proxy.size, focusKeyboard: focusHardwareKeyboard)
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
                    model.scheduleCurrentViewport()
                },
                isZoomed: { model.canPanZoom(in: proxy.size) && !model.isCenteredTrackpad },
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
                    model.scheduleCurrentViewport()
                },
                onPinchEnded: {
                    guard pinchStart != nil else { return }
                    pinchStart = nil
                    model.recenterTrackpad(in: proxy.size)
                },
                onPressBegan: { button, point in
                    model.beginPress(button: button, at: point, in: proxy.size)
                    pressIndicator = PressIndicator(
                        color: Self.indicatorColor(for: button),
                        point: pressIndicatorPoint(finger: point, in: proxy.size)
                    )
                },
                onPressMoved: { point in
                    model.movePress(to: point, in: proxy.size)
                    pressIndicator?.point = pressIndicatorPoint(finger: point, in: proxy.size)
                },
                onHeldDragMoved: { delta in
                    model.moveHeldDrag(by: delta, in: proxy.size)
                    updateHeldDragIndicator(in: proxy.size)
                },
                onHeldTransformBegan: { focal in
                    pinchStart = (model.zoom, model.pan, focal)
                },
                onHeldTransformChanged: { scale, focal in
                    guard model.zoomEnabled, let start = pinchStart else { return }
                    model.applyPinch(
                        scale: scale,
                        startZoom: start.zoom,
                        startPan: start.pan,
                        startFocal: start.focal,
                        currentFocal: focal,
                        in: proxy.size
                    )
                    model.scheduleCurrentViewport()
                    updateHeldDragIndicator(in: proxy.size)
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
        #if os(macOS)
        .accessibilityHint("Click and drag to control the remote desktop")
        #else
        .accessibilityHint("Tap to click, drag to move the pointer")
        #endif
        .accessibilityAction(named: "Disconnect") {
            requestClose()
        }
        .accessibilityAction(named: "Toggle Observe Mode") {
            model.toggleObserveMode()
        }
    }

    private func updateHeldDragIndicator(in size: CGSize) {
        guard let rect = model.displayedImageRect(in: size) else { return }
        pressIndicator?.point = CGPoint(
            x: rect.minX + model.remoteCursor.x * rect.width,
            y: rect.minY + model.remoteCursor.y * rect.height
        )
    }

    private func pressIndicatorPoint(finger: CGPoint, in size: CGSize) -> CGPoint {
        guard model.isCenteredTrackpad, let rect = model.displayedImageRect(in: size) else { return finger }
        return CGPoint(
            x: rect.minX + model.remoteCursor.x * rect.width,
            y: rect.minY + model.remoteCursor.y * rect.height
        )
    }

    private static func indicatorColor(for button: PointerButton) -> Color {
        switch button {
        case .left: Color(red: 0.29, green: 0.56, blue: 1)
        case .right: Color(red: 1, green: 0.35, blue: 0.32)
        case .middle: Color(red: 0.20, green: 0.78, blue: 0.35)
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
            toolbarChrome
                .padding(.horizontal, 12)
                .padding(.top, 10)
                .padding(.bottom, toolbarBottomSpacing)
                .transition(.opacity)
        } else {
            showToolbarButton
                .padding(12)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
                .transition(.opacity)
        }
    }

    @ViewBuilder
    private var showToolbarButton: some View {
        let button = Button("Show Toolbar", systemImage: "chevron.up") { model.toggleChrome() }
            .labelStyle(.iconOnly)
            .buttonBorderShape(.circle)
            .controlSize(.large)

        #if compiler(>=6.2)
        if #available(iOS 26, macOS 26, *) {
            button.buttonStyle(.glass)
        } else {
            button.buttonStyle(.borderedProminent)
        }
        #else
        button.buttonStyle(.borderedProminent)
        #endif
    }

    private var usesVerticalToolbar: Bool {
        #if os(iOS)
        verticalSizeClass == .compact
        #else
        false
        #endif
    }

    /// iPad sessions let the toolbar dock to any edge; other layouts keep the
    /// fixed bottom bar or compact-height rail.
    private var isToolbarDockable: Bool {
        #if os(iOS)
        horizontalSizeClass == .regular
        #else
        false
        #endif
    }

    #if os(iOS)
    private var toolbarInsets: EdgeInsets {
        guard model.state.isConnected, model.showsChrome, toolbarSize != .zero else { return EdgeInsets() }
        let dock = isToolbarDockable ? settings.settings.toolbarDock : (usesVerticalToolbar ? .right : .bottom)
        switch dock {
        case .bottom:
            return EdgeInsets(top: 0, leading: 0, bottom: toolbarSize.height + toolbarBottomSpacing, trailing: 0)
        case .left:
            return EdgeInsets(top: 0, leading: toolbarSize.width + 16, bottom: 0, trailing: 0)
        case .right:
            return EdgeInsets(top: 0, leading: 0, bottom: 0, trailing: toolbarSize.width + 16)
        }
    }
    #endif

    @ViewBuilder
    private var toolbarChrome: some View {
        GeometryReader { proxy in
            if isToolbarDockable {
                let dock = settings.settings.toolbarDock
                let available = dock == .bottom ? proxy.size.width : proxy.size.height
                sessionToolbar(orientation: dock.orientation, availableLength: available)
                    .contentShape(Capsule(style: .continuous))
                    .offset(toolbarDrag)
                    .highPriorityGesture(toolbarDragGesture(in: proxy.size))
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: alignment(for: dock))
                    .padding(dockPadding(for: dock))
            } else if usesVerticalToolbar {
                sessionToolbar(orientation: .vertical, availableLength: proxy.size.height)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .trailing)
                    .padding(.trailing, 4)
            } else {
                sessionToolbar(orientation: .horizontal, availableLength: proxy.size.width)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
            }
        }
    }

    private func alignment(for dock: ToolbarDock) -> Alignment {
        switch dock {
        case .bottom: .bottom
        case .left: .leading
        case .right: .trailing
        }
    }

    private func dockPadding(for dock: ToolbarDock) -> EdgeInsets {
        switch dock {
        case .bottom: EdgeInsets()
        case .left: EdgeInsets(top: 0, leading: 4, bottom: 0, trailing: 0)
        case .right: EdgeInsets(top: 0, leading: 0, bottom: 0, trailing: 4)
        }
    }

    private func toolbarDragGesture(in size: CGSize) -> some Gesture {
        DragGesture(minimumDistance: 8)
            .onChanged { value in
                toolbarDrag = value.translation
            }
            .onEnded { value in
                let dock = snappedDock(for: value.translation, in: size)
                withAnimation(.snappy(duration: 0.22)) {
                    toolbarDrag = .zero
                    if let dock, dock != settings.settings.toolbarDock {
                        settings.settings.toolbarDock = dock
                    }
                }
            }
    }

    private func snappedDock(for translation: CGSize, in size: CGSize) -> ToolbarDock? {
        guard toolbarSize.width > 0, toolbarSize.height > 0 else { return nil }
        let origin = dockCenter(for: settings.settings.toolbarDock, in: size)
        let center = CGPoint(
            x: origin.x + translation.width,
            y: origin.y + translation.height
        )
        let distances: [(dock: ToolbarDock, distance: CGFloat)] = [
            (.left, center.x),
            (.right, size.width - center.x),
            (.bottom, size.height - center.y)
        ]
        guard let nearest = distances.min(by: { $0.distance < $1.distance }),
              nearest.distance <= 140
        else { return nil }
        return nearest.dock
    }

    private func dockCenter(for dock: ToolbarDock, in size: CGSize) -> CGPoint {
        switch dock {
        case .bottom:
            CGPoint(x: size.width / 2, y: size.height - toolbarSize.height / 2)
        case .left:
            CGPoint(x: 4 + toolbarSize.width / 2, y: size.height / 2)
        case .right:
            CGPoint(x: size.width - 4 - toolbarSize.width / 2, y: size.height / 2)
        }
    }

    private func sessionToolbar(orientation: FloatingBarOrientation, availableLength: CGFloat) -> some View {
        SessionToolbar(
            model: model,
            orientation: orientation,
            items: settings.settings.toolbarItems,
            availableLength: availableLength,
            onUpload: { showingUploadPicker = true },
            onDownload: {
                downloadPath = ""
                showingDownloadDialog = true
            },
            onDisconnect: requestClose,
            showsDragHandle: isToolbarDockable
        )
        .onGeometryChange(for: CGSize.self, of: { $0.size }) { size in
            guard toolbarSize != size else { return }
            toolbarSize = size
        }
    }

    private var connectingOverlay: some View {
        ZStack {
            Theme.Colors.canvas.opacity(0.55)
                .ignoresSafeArea()

            VStack(spacing: 14) {
                ProgressView()
                    .controlSize(.large)

                Group {
                    if model.state.isConnected {
                        Text("Waiting for the remote screen")
                    } else {
                        Text(model.state.label)
                    }
                }
                .font(.headline)
                .multilineTextAlignment(.center)

                Text(model.profile.endpoint)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)

                Button("Cancel", action: closeSession)
                    .buttonStyle(.bordered)
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

                Text(model.needsMacSessionChoice ? "Choose a Mac Session" : "Connection Closed")
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

                if model.needsMacSessionChoice {
                    Button("Open Personal Session") { model.chooseMacSession(.personal) }
                        .buttonStyle(.borderedProminent)
                    Button("Request Shared Session") { model.chooseMacSession(.share) }
                        .buttonStyle(.bordered)
                }
                HStack(spacing: 10) {
                    if !model.needsMacSessionChoice {
                        Button("Reconnect") { model.reconnect() }
                            .buttonStyle(.borderedProminent)
                    }

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
                    .foregroundStyle(.primary)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                    .glassSurface(in: Capsule())
                    .padding(.bottom, 82)
            }
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
                .padding(.top, 16)

                Spacer()
            }
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
        guard model.state.isConnected, model.supportsFileUpload, !model.isObserving else { return false }
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
        guard model.state.isConnected, model.supportsFileUpload, !model.isObserving, !urls.isEmpty else { return false }
        model.uploadFiles(urls)
        return true
    }
    #endif

    // MARK: - Actions

    private func requestClose() {
        if !model.requestDisconnectConfirmation(alwaysConfirm: settings.settings.confirmDisconnect) {
            closeSession()
        }
    }

    private func closeSession() {
        onClose()
        model.disconnect()
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

private struct PressIndicator {
    var color: Color
    var point: CGPoint
}
