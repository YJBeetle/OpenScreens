import CoreGraphics
import Foundation
import Observation

/// Screen-edge pointer targets: the four hot corners and the Dock edge.
public enum RemoteHotCorner: String, CaseIterable, Identifiable, Sendable {
    case topLeft
    case topRight
    case bottomLeft
    case bottomRight
    case dock

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .topLeft: NSLocalizedString("Top Left", comment: "Hot corner")
        case .topRight: NSLocalizedString("Top Right", comment: "Hot corner")
        case .bottomLeft: NSLocalizedString("Bottom Left", comment: "Hot corner")
        case .bottomRight: NSLocalizedString("Bottom Right", comment: "Hot corner")
        case .dock: NSLocalizedString("Show Dock", comment: "Hot corner")
        }
    }

    public var systemImage: String {
        switch self {
        case .topLeft: "arrow.up.left"
        case .topRight: "arrow.up.right"
        case .bottomLeft: "arrow.down.left"
        case .bottomRight: "arrow.down.right"
        case .dock: "dock.rectangle"
        }
    }

    /// Normalized framebuffer position on the target edge. The transport
    /// clamps 1.0 to the last pixel column or row.
    public var normalizedPoint: CGPoint {
        switch self {
        case .topLeft: CGPoint(x: 0, y: 0)
        case .topRight: CGPoint(x: 1, y: 0)
        case .bottomLeft: CGPoint(x: 0, y: 1)
        case .bottomRight: CGPoint(x: 1, y: 1)
        case .dock: CGPoint(x: 0.5, y: 1)
        }
    }

    public static var corners: [RemoteHotCorner] {
        [.topLeft, .topRight, .bottomLeft, .bottomRight]
    }
}
import ScrctlGuiCanvas
import SwiftUI

/// Drives one remote session: transport lifecycle, frame uploads, pointer and
/// keyboard input, clipboard actions and reconnection.
@MainActor
@Observable
public final class SessionViewModel {
    public let profile: ConnectionProfile
    private var qualityOverride: ConnectionQuality?
    private(set) var changingQuality = false
    private(set) var isAppleRemote = false
    public private(set) var supportsFileUpload = false
    public private(set) var supportsFileDownload = false

    public var supportsFileTransfer: Bool { supportsFileUpload || supportsFileDownload }

    var quality: ConnectionQuality {
        qualityOverride ?? (store?.connection(id: profile.id) ?? profile).initialQuality
    }
    public let renderer: RemoteCanvasRenderer

    public private(set) var state: RemoteSessionState = .idle {
        didSet {
            updateIdleTimer()
        }
    }
    public private(set) var displays: [RemoteDisplay] = []
    public private(set) var selectedDisplayID: Int?
    public var isSwitchingDisplay: Bool { displaySelectionTask != nil }
    /// Size of the server framebuffer; frames may be sampled down from this.
    public private(set) var serverSize: CGSize?
    public private(set) var frameSize: CGSize?
    /// Crop of the framebuffer currently delivered to the canvas.
    public private(set) var viewport: RemoteViewport?

    /// Full framebuffer size in pixels, independent of the delivered crop.
    public var framebufferSize: CGSize? {
        if let viewport {
            return CGSize(width: viewport.framebufferWidth, height: viewport.framebufferHeight)
        }
        return frameSize ?? serverSize
    }

    public var cursorMode: CursorMode
    public private(set) var sharedClipboard: Bool
    public var isObserving: Bool
    public var scaling: RemoteContentMode
    public var showsChrome = true
    public var zoomEnabled: Bool { profile.controls.zoomEnabled ?? true }
    public var isKeyboardActive = false
    public var keyboardModifiers: RemoteModifiers = []

    public private(set) var clipboardMessage: String?
    public private(set) var failureMessage: String?
    private(set) var credentialChallenge: RemoteFailureKind?
    private(set) var loginUsername: String
    @ObservationIgnored private var sessionPassword: String?
    private(set) var rememberLogin = false
    @ObservationIgnored private weak var store: ConnectionStore?
    @ObservationIgnored private let previewRecorder: SessionPreviewRecorder
    @ObservationIgnored private var recordedConnection = false
    public private(set) var receivedFrames = 0
    #if DEBUG
    @ObservationIgnored private var firstSequence: UInt64?
    private(set) var firstUpdateHasColor: Bool?
    #endif
    public private(set) var remoteCursorShape: RemoteCursorShape?
    public private(set) var remoteCursorImage: CGImage?
    private(set) var remoteCursorHidden = false
    /// Name of the file currently being received by the remote desktop.
    public private(set) var uploadFileName: String?
    /// Overall transfer progress (0...1) when the server reports it.
    public private(set) var uploadFraction: Double?
    /// Name of the file currently being downloaded from the remote desktop.
    public private(set) var downloadFileName: String?
    /// Download progress (0...1) when the server reports the total size.
    public private(set) var downloadFraction: Double?
    private var activeUploads = 0
    private var activeDownloads = 0
    private var promiseDownloads: Set<UUID> = []
    var sentFiles: [SessionTransferItem] = []
    var receivedFiles: [SessionTransferItem] = []
    public var showsFileTransfers = false
    private(set) var disconnectRequest: SessionDisconnectRequest?
    var showingDisconnectRequest = false
    public var hasActiveTransfers: Bool {
        activeUploads > 0 || activeDownloads > 0 || !promiseDownloads.isEmpty
    }
    /// Last known pointer position, normalized to the remote framebuffer.
    public private(set) var remoteCursor = CGPoint(x: 0.5, y: 0.55)
    /// Magnification applied to the remote image; 1 shows the whole desktop.
    public private(set) var zoom: CGFloat = 1
    /// On-screen translation of the zoomed image, in points.
    public private(set) var pan: CGSize = .zero

    @ObservationIgnored private let idleTimerOwner = UUID()
    private var displaySelectionTask: Task<Void, Never>?
    @ObservationIgnored private var pendingDisplayRestore: Int?
    @ObservationIgnored private let readClipboardChangeCount: @MainActor () -> Int
    @ObservationIgnored private let readClipboard: @MainActor () -> String?
    @ObservationIgnored private let writeClipboard: @MainActor (String) -> Void
    @ObservationIgnored private var latestRemoteText: String?
    @ObservationIgnored private var clipboardChangeCount: Int?
    @ObservationIgnored private var fetchTask: Task<Void, Never>?
    @ObservationIgnored private let service: any RemoteSessionService
    @ObservationIgnored private var session: (any RemoteSessionProtocol)?
    @ObservationIgnored private var inputQueue: SessionInputQueue?
    #if os(macOS)
    @ObservationIgnored lazy var mouseInput = RemoteMouseInput(model: self)
    #endif
    @ObservationIgnored private var eventTask: Task<Void, Never>?
    @ObservationIgnored private var connectTask: Task<Void, Never>?
    @ObservationIgnored private var reconnectTask: Task<Void, Never>?
    @ObservationIgnored private var messageTask: Task<Void, Never>?
    @ObservationIgnored private var dragAnchor: CGPoint?
    @ObservationIgnored private var recenterTask: Task<Void, Never>?
    @ObservationIgnored private var recenterStart: CGSize?
    @ObservationIgnored private var recenterProgress: CGFloat = 1
    @ObservationIgnored private var pressedButton: PointerButton?
    @ObservationIgnored private var isStopping = false
    @ObservationIgnored private var reconnectAttempts = 0
    @ObservationIgnored private var lastHoverPixel: CGPoint?
    @ObservationIgnored private var sceneIsActive = true
    @ObservationIgnored private var backgroundedAt: Date?
    @ObservationIgnored private var scrollRemainder = CGSize.zero
    @ObservationIgnored private var viewportTask: Task<Void, Never>?
    @ObservationIgnored private var canvasSize: CGSize = .zero
    @ObservationIgnored private var renderBounds: CGRect = .zero
    @ObservationIgnored private var canvasPixelWidth = 0
    @ObservationIgnored private var lastViewportRect: CGRect?
    @ObservationIgnored private var lastViewportPixelWidth = 0

    private static let resumeReconnectDelay: TimeInterval = 5
    private static let maxLogicalZoom: CGFloat = 4
    /// Points of two-finger travel that make one wheel click.
    private static let scrollStepPoints: CGFloat = 24

    public init(
        profile: ConnectionProfile,
        service: any RemoteSessionService = MockSessionService(),
        connectionStore: ConnectionStore? = nil,
        readClipboardChangeCount: @escaping @MainActor () -> Int = { PlatformClipboard.changeCount },
        readClipboard: @escaping @MainActor () -> String? = { PlatformClipboard.string },
        writeClipboard: @escaping @MainActor (String) -> Void = { PlatformClipboard.setString($0) }
    ) {
        self.loginUsername = profile.username
        self.profile = profile
        self.service = service
        self.store = connectionStore
        self.readClipboardChangeCount = readClipboardChangeCount
        self.readClipboard = readClipboard
        self.writeClipboard = writeClipboard
        self.sharedClipboard = profile.controls.sharedClipboard
        self.cursorMode = connectionStore?.cursorMode(for: profile) ?? profile.controls.cursorMode
        self.isObserving = profile.controls.startInObserveMode
        self.scaling = profile.controls.scaling
        let renderer = RemoteCanvasRenderer()
        self.renderer = renderer
        self.previewRecorder = SessionPreviewRecorder(id: profile.id, renderer: renderer)
    }

    // MARK: - Lifecycle

    public func start(store: ConnectionStore? = nil) {
        guard credentialChallenge == nil, eventTask == nil, connectTask == nil else { return }
        if let store {
            self.store = store
            cursorMode = store.cursorMode(for: profile)
        }
        previewRecorder.store = self.store
        recordedConnection = false
        isStopping = false
        reconnectAttempts = 0
        failureMessage = nil
        beginSession(isReconnect: false)
    }

    func flushSessionPreview() { previewRecorder.flush() }

    public func stop() {
        stopRecentering()
        isStopping = true
        clearCredentials()
        isKeyboardActive = false
        reconnectTask?.cancel()
        reconnectTask = nil
        endTransport()
        PlatformScreen.setIdleTimerDisabled(false, for: idleTimerOwner)
    }

    /// Return true when a native confirmation owns this close request.
    public func requestDisconnectConfirmation(alwaysConfirm: Bool = false) -> Bool {
        guard !isStopping else { return false }
        let action: DisconnectAction = state.isConnected && !isObserving ? profile.supportedDisconnectAction : .none
        guard hasActiveTransfers || action != .none || (alwaysConfirm && state.isConnected) else { return false }
        disconnectRequest = SessionDisconnectRequest(action: action, interruptsTransfers: hasActiveTransfers)
        showingDisconnectRequest = true
        return true
    }

    func cancelDisconnectConfirmation() {
        disconnectRequest = nil
        showingDisconnectRequest = false
    }

    func confirmDisconnect(_ request: SessionDisconnectRequest) -> Bool {
        guard request.id == disconnectRequest?.id else { return false }
        cancelDisconnectConfirmation()
        if state.isConnected, !isObserving, request.action == profile.supportedDisconnectAction {
            releasePointerInput()
            clearStickyModifiers()
            switch request.action {
            case .lockScreen: sendCommand(profile.platform == .windows ? .lockWindows : .lockMac)
            case .logOut: sendCommand(.logOutMac)
            case .ctrlAltDelete: sendCommand(.ctrlAltDelete)
            default:
                if let corner = request.action.corner { jumpPointer(to: corner.normalizedPoint) }
            }
        }
        disconnect()
        return true
    }

    public func disconnect() {
        isStopping = true
        clearCredentials()
        isKeyboardActive = false
        reconnectTask?.cancel()
        reconnectTask = nil
        state = .disconnected(reason: NSLocalizedString("Disconnected", comment: "Session state"))
        endTransport()
    }

    @ObservationIgnored private var selectedMacSession: MacSessionChoice?

    var needsMacSessionChoice: Bool {
        if case .disconnected(_, .macSessionChoiceRequired) = state { return true }
        return false
    }

    func chooseMacSession(_ choice: MacSessionChoice) {
        guard needsMacSessionChoice, !isStopping else { return }
        endTransport()
        failureMessage = nil
        selectedMacSession = choice
        beginSession(isReconnect: false)
    }

    public func reconnect() {
        guard credentialChallenge == nil, !needsMacSessionChoice, state.isTerminal else { return }
        restartTransport()
    }

    /// Scene phase hook. A suspended app can return with a socket that never
    /// reports an error, which would leave the last frame on screen forever.
    public func handleScenePhase(_ phase: ScenePhase) {
        sceneIsActive = phase == .active
        if !sceneIsActive { cancelClipboardFetch() }
        if phase == .background { previewRecorder.flush() }
        #if os(iOS)
        switch phase {
        case .background:
            backgroundedAt = Date()
        case .active:
            guard let backgroundedAt else { return }
            self.backgroundedAt = nil
            let away = Date().timeIntervalSince(backgroundedAt)
            let needsRestart: Bool
            switch state {
            case .disconnected, .reconnecting:
                needsRestart = true
            case .connected:
                needsRestart = away >= Self.resumeReconnectDelay
            case .idle, .connecting:
                needsRestart = false
            }
            if needsRestart && credentialChallenge == nil && !needsMacSessionChoice {
                restartTransport()
            }
        default:
            break
        }
        #endif
    }

    private func updateIdleTimer() {
        let isActive = !isStopping && state != .idle && !state.isTerminal
        PlatformScreen.setIdleTimerDisabled(profile.controls.keepScreenAwake && isActive, for: idleTimerOwner)
    }

    private func restartTransport() {
        guard !isStopping else { return }
        reconnectTask?.cancel()
        reconnectTask = nil
        endTransport()
        reconnectAttempts = 0
        failureMessage = nil
        beginSession(isReconnect: false)
    }

    private func beginSession(isReconnect: Bool) {
        guard !isStopping else { return }
        let session = service.makeSession()
        self.session = session
        resetDisplaySelection()
        serverSize = nil
        let saved = store?.connection(id: profile.id) ?? profile
        pendingDisplayRestore = saved.remembersSelectedDisplay ? saved.preferredDisplayID : nil
        inputQueue?.events.finish()
        inputQueue = SessionInputQueue(session: session)
        previewRecorder.beginSession()
        renderer.reset()
        receivedFrames = 0
        #if DEBUG
        firstSequence = nil
        firstUpdateHasColor = nil
        #endif
        frameSize = nil
        lastViewportRect = nil
        viewport = nil
        state = isReconnect ? .reconnecting(attempt: reconnectAttempts) : .connecting
        remoteCursorShape = nil
        remoteCursorImage = nil
        remoteCursorHidden = false
        #if os(iOS)
        remoteCursor = CGPoint(x: 0.5, y: isCenteredTrackpad ? 0.5 : 0.55)
        #endif
        lastHoverPixel = nil

        eventTask = Task { [weak self, session] in
            for await event in session.events {
                guard !Task.isCancelled, let self else { return }
                self.handle(event)
            }
        }

        var profile = profile
        profile.quality = qualityOverride ?? saved.quality
        profile.controls.startInObserveMode = isObserving
        profile.username = loginUsername
        let password = sessionPassword
        let macSessionChoice = selectedMacSession
        profile.controls.sharedClipboard = sharedClipboard
        connectTask = Task { [weak self, session, profile] in
            do {
                try await session.connect(profile: profile, password: password, macSessionChoice: macSessionChoice)
            } catch is CancellationError {
                // The user stopped the session while it was connecting.
            } catch {
                guard !Task.isCancelled else { return }
                self?.handleTransportFailure(error, isReconnect: isReconnect)
            }
        }
    }

    private(set) var supportsCurtainMode = false

    private func endTransport() {
        previewRecorder.flush()
        previewRecorder.reset()
        cancelDisconnectConfirmation()
        supportsCurtainMode = false
        isAppleRemote = false
        supportsFileUpload = false
        supportsFileDownload = false
        releasePointerInput()
        inputQueue?.events.finish()
        inputQueue = nil
        resetClipboard()
        session = nil
        resetDisplaySelection()
        connectTask?.cancel()
        connectTask = nil
        eventTask?.cancel()
        eventTask = nil
        viewportTask?.cancel()
        viewportTask = nil
        lastViewportRect = nil
        viewport = nil
        resetTransferProgress()
    }

    // MARK: - Events

    private func handle(_ event: RemoteSessionEvent) {
        switch event {
        case .state(let newState):
            let wasConnected = state.isConnected
            state = newState
            if newState.isConnected {
                if !wasConnected { scheduleCurrentViewport() }
                if rememberLogin, let sessionPassword {
                    if store?.rememberLogin(for: profile, username: loginUsername, password: sessionPassword) != true {
                        showMessage(NSLocalizedString("The credentials could not be saved.", comment: "Credential storage failure"))
                    }
                    rememberLogin = false
                }
                if !recordedConnection {
                    store?.markConnected(id: profile.id)
                    recordedConnection = true
                }
                reconnectAttempts = 0
                failureMessage = nil
                reconcileDisplaySelection()
            }
            if case .disconnected(let reason, let kind) = newState {
                resetDisplaySelection()
                resetTransferProgress()
                resetClipboard()
                handleRemoteClose(reason: reason, kind: kind)
            }

        case .curtainModeSupport(let supported):
            supportsCurtainMode = supported
        case .serverFeatures(let appleRemote, let fileUpload, let fileDownload):
            isAppleRemote = appleRemote
            supportsFileUpload = fileUpload
            supportsFileDownload = fileDownload

        case .framebufferSize(let width, let height):
            let size = CGSize(width: width, height: height)
            if serverSize != size {
                previewRecorder.reset()
                serverSize = size
                if canvasSize.width > 0, canvasSize.height > 0 { constrainViewZoom(in: canvasSize) }
                lastViewportRect = nil
                scheduleCurrentViewport()
            }

        case .displays(let list):
            if displays != list { previewRecorder.reset() }
            displays = list
            // Some transports report a single display before the first frame.
            if serverSize == nil, list.count == 1, let display = list.first {
                serverSize = CGSize(width: display.width, height: display.height)
                scheduleCurrentViewport()
            }
            reconcileDisplaySelection()

        case .frame(let frame):
            #if DEBUG
            if CanvasPresentation.isEnabled {
                if receivedFrames == 0 { firstSequence = frame.sequence }
                if receivedFrames == 0 || (firstSequence != nil && frame.sequence == firstSequence && firstUpdateHasColor == false) {
                    firstUpdateHasColor = Self.containsNonblackPixel(frame.data)
                }
            }
            #endif
            receivedFrames += 1
            frameSize = CGSize(width: frame.width, height: frame.height)
            let revision = renderer.frameRevision
            if let region = frame.region {
                renderer.update(
                    region: region,
                    width: frame.width,
                    height: frame.height,
                    pixels: frame.data
                )
            } else {
                renderer.updateFullFrame(width: frame.width, height: frame.height, pixels: frame.data)
            }

            guard renderer.frameRevision != revision else { return }
            if viewport != frame.viewport {
                viewport = frame.viewport
                renderer.textureCrop = frame.viewport.map {
                    CGRect(
                        x: CGFloat($0.x) / CGFloat($0.framebufferWidth),
                        y: CGFloat($0.y) / CGFloat($0.framebufferHeight),
                        width: CGFloat($0.width) / CGFloat($0.framebufferWidth),
                        height: CGFloat($0.height) / CGFloat($0.framebufferHeight)
                    )
                }
                previewRecorder.reset()
            }
            if state.isConnected, !isSwitchingDisplay {
                previewRecorder.received(frame, displays: displays, selectedID: selectedDisplayID,
                                         viewport: viewport, serverSize: serverSize)
            }

        case .cursor(let shape):
            remoteCursorHidden = shape.width == 0 || shape.height == 0
            if shape.isEmpty {
                remoteCursorShape = nil
                remoteCursorImage = nil
            } else {
                remoteCursorShape = shape
                remoteCursorImage = makeCursorImage(shape)
            }

        case .pointerPosition(let x, let y):
            #if os(macOS)
            remoteCursor = CGPoint(
                x: min(max(x, 0), 1),
                y: min(max(y, 0), 1)
            )
            #else
            _ = (x, y)
            #endif

        case .clipboard(let text):
            guard state.isConnected else { return }
            latestRemoteText = text
            guard sceneIsActive, sharedClipboard || fetchTask != nil else { return }
            cancelClipboardFetch()
            writeClipboard(text)
            if sharedClipboard { clipboardChangeCount = readClipboardChangeCount() }

        case .clipboardRequest:
            shareLocalClipboardIfNeeded()

        case .bell:
            PlatformFeedback.selection()

        case .transferProgress(let name, let fraction):
            if let name, !name.isEmpty {
                uploadFileName = name
            }
            if let fraction {
                uploadFraction = min(max(fraction, 0), 1)
            }

        case .transferFinished(let names, let destination):
            activeUploads = max(0, activeUploads - 1)
            if activeUploads == 0 { clearUploadState() }
            sentFiles.insert(contentsOf: names.map {
                SessionTransferItem(name: $0, folder: destination)
            }, at: 0)

        case .downloadProgress(let name, let received, let total):
            if let name, !name.isEmpty {
                downloadFileName = name
            }
            if total > 0 {
                downloadFraction = min(max(Double(received) / Double(total), 0), 1)
            }

        case .downloadComplete(let items, let error):
            activeDownloads = max(0, activeDownloads - 1)
            clearDownloadProgressIfIdle()
            if error == nil, !items.isEmpty {
                recordReceivedFiles(items)
            }

        case .failure(let message):
            failureMessage = message
            showMessage(message)
        }
    }

    #if DEBUG
    /// Inspect only the BGRA payloads already going to Metal in the first RFB
    /// update. Alpha varies by encoding and carries no colour information.
    static func containsNonblackPixel(_ pixels: Data) -> Bool {
        pixels.withUnsafeBytes { bytes in
            guard bytes.count >= 4, let base = bytes.baseAddress else { return false }
            if bytes.loadUnaligned(as: UInt32.self) & 0x00ff_ffff != 0 { return true }
            // A uniform black desktop is common. libc can compare its repeated
            // pixels in bulk even in an unoptimised diagnostic build.
            if memcmp(base, base + 4, bytes.count - 4) == 0 { return false }
            for offset in stride(from: 4, to: bytes.count - 3, by: 4) {
                if bytes.loadUnaligned(fromByteOffset: offset, as: UInt32.self) & 0x00ff_ffff != 0 {
                    return true
                }
            }
            return false
        }
    }
    #endif

    private func handleRemoteClose(reason: String?, kind: RemoteFailureKind) {
        guard !isStopping else { return }
        if challengeIfNeeded(kind) { return }
        endTransport()
        if let reason, !reason.isEmpty {
            failureMessage = SessionFailureText.localized(kind, reason: reason)
        }
        if !needsMacSessionChoice { scheduleReconnect() }
    }

    private func scheduleReconnect() {
        guard !isStopping, profile.controls.autoReconnect, reconnectAttempts < 3 else { return }
        reconnectAttempts += 1
        state = .reconnecting(attempt: reconnectAttempts)
        reconnectTask?.cancel()
        reconnectTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled, let self else { return }
            self.reconnectTask = nil
            self.beginSession(isReconnect: true)
        }
    }

    private func handleTransportFailure(_ error: Error, isReconnect: Bool) {
        let failure = error as? RemoteSessionFailure
        if let failure, challengeIfNeeded(failure.kind) { return }
        let localized = failure.map {
            SessionFailureText.localized($0.kind, reason: $0.reason)
        } ?? error.localizedDescription
        failureMessage = localized
        let kind = failure?.kind ?? .unknown
        state = .disconnected(reason: localized, kind: kind)
        endTransport()
        if isReconnect && (kind == .network || kind == .connectionRefused || kind == .closed) {
            scheduleReconnect()
        }
    }

    private func challengeIfNeeded(_ kind: RemoteFailureKind) -> Bool {
        guard kind == .missingUsername || kind == .missingPassword || kind == .authenticationFailed else { return false }
        endTransport()
        sessionPassword = nil
        credentialChallenge = kind
        state = .disconnected(reason: nil, kind: kind)
        return true
    }

    func submitCredentials(username: String, password: String, remember: Bool) {
        let username = username.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let credentialChallenge, !password.isEmpty,
              credentialChallenge != .missingUsername || !username.isEmpty else { return }
        self.credentialChallenge = nil
        loginUsername = username
        sessionPassword = password
        rememberLogin = remember
        restartTransport()
    }

    private func clearCredentials() {
        credentialChallenge = nil
        sessionPassword = nil
        loginUsername = profile.username
        selectedMacSession = nil
        rememberLogin = false
    }

    // MARK: - Pointer input

    var isCenteredTrackpad: Bool { cursorMode == .trackpad && !isObserving }

    private func trackpadPan(in size: CGSize) -> CGSize {
        guard let base = remoteImageRect(in: size) else { return pan }
        let width = base.width * zoom
        let height = base.height * zoom
        let maxX = max(0, (width - size.width) / 2)
        let maxY = max(0, (height - size.height) / 2)
        return CGSize(
            width: min(max((0.5 - remoteCursor.x) * width, -maxX), maxX),
            height: min(max((0.5 - remoteCursor.y) * height, -maxY), maxY)
        )
    }

    private func followTrackpadCursor(in size: CGSize) {
        let target = trackpadPan(in: size)
        guard let start = recenterStart else {
            pan = target
            return
        }
        pan = CGSize(
            width: start.width + (target.width - start.width) * recenterProgress,
            height: start.height + (target.height - start.height) * recenterProgress
        )
    }

    private func startRecentering(in size: CGSize) {
        stopRecentering()
        let target = trackpadPan(in: size)
        guard hypot(target.width - pan.width, target.height - pan.height) >= 0.5 else { return }
        recenterStart = pan
        recenterProgress = 0
        recenterTask = Task { [weak self] in
            let clock = ContinuousClock()
            let start = clock.now
            while !Task.isCancelled {
                guard let self else { return }
                let elapsed = start.duration(to: clock.now).components
                let seconds = Double(elapsed.seconds) + Double(elapsed.attoseconds) / 1e18
                let t = CGFloat(min(seconds / 0.5, 1))
                self.recenterProgress = t * t * (3 - 2 * t)
                self.followTrackpadCursor(in: size)
                self.scheduleCurrentViewport()
                if t == 1 {
                    self.recenterStart = nil
                    return
                }
                try? await Task.sleep(for: .milliseconds(16))
            }
        }
    }

    private func stopRecentering() {
        recenterTask?.cancel()
        recenterTask = nil
        recenterStart = nil
        scheduleCurrentViewport()
    }

    private func moveCenteredTrackpad(to point: CGPoint, in size: CGSize) {
        defer { dragAnchor = point }
        guard let anchor = dragAnchor else {
            if cursorMode == .trackpadAndMouse { startRecentering(in: size) }
            return
        }
        guard let rect = displayedImageRect(in: size) else { return }
        remoteCursor = CGPoint(
            x: min(max(remoteCursor.x + (point.x - anchor.x) / rect.width, 0), 1),
            y: min(max(remoteCursor.y + (point.y - anchor.y) / rect.height, 0), 1)
        )
        followTrackpadCursor(in: size)
        queuePointer([PointerEvent(action: .move, x: remoteCursor.x, y: remoteCursor.y)])
        scheduleCurrentViewport()
    }

    public func tap(at point: CGPoint, in size: CGSize) {
        guard state.isConnected, !isObserving, size.width > 0, size.height > 0 else { return }
        stopRecentering()
        let normalized = normalized(point, in: size)
        let button: PointerButton = PlatformInput.currentModifiers.contains(.control) ? .right : .left

        switch cursorMode {
        case .touch, .trackpadAndMouse:
            remoteCursor = normalized
            queuePointer([
                PointerEvent(action: .move, x: normalized.x, y: normalized.y),
                PointerEvent(action: .down, button: button, x: normalized.x, y: normalized.y),
                PointerEvent(action: .up, button: button, x: normalized.x, y: normalized.y)
            ])
        case .trackpad:
            queuePointer([
                PointerEvent(action: .move, x: remoteCursor.x, y: remoteCursor.y),
                PointerEvent(action: .down, button: button, x: remoteCursor.x, y: remoteCursor.y),
                PointerEvent(action: .up, button: button, x: remoteCursor.x, y: remoteCursor.y)
            ])
        }
    }

    public func drag(to point: CGPoint, in size: CGSize) {
        guard state.isConnected, !isObserving, size.width > 0, size.height > 0 else { return }
        if cursorMode == .touch {
            let target = normalized(point, in: size)
            remoteCursor = target
            queuePointer([PointerEvent(action: .move, x: target.x, y: target.y)])
        } else {
            moveCenteredTrackpad(to: point, in: size)
        }
    }

    public func endDrag() {
        dragAnchor = nil
    }

    /// Starts a held-button drag (long press): the button goes down under the
    /// finger and stays down until `endPress`.
    public func beginPress(button: PointerButton, at point: CGPoint, in size: CGSize) {
        guard state.isConnected, !isObserving, size.width > 0, size.height > 0 else { return }
        stopRecentering()
        let target = isCenteredTrackpad ? remoteCursor : normalized(point, in: size)
        if isCenteredTrackpad { dragAnchor = point }
        remoteCursor = target
        pressedButton = button
        queuePointer([
            PointerEvent(action: .move, x: target.x, y: target.y),
            PointerEvent(action: .down, button: button, x: target.x, y: target.y)
        ])
    }

    public func movePress(to point: CGPoint, in size: CGSize) {
        guard pressedButton != nil, state.isConnected, !isObserving else { return }
        if isCenteredTrackpad {
            moveCenteredTrackpad(to: point, in: size)
            return
        }
        let target = normalized(point, in: size)
        remoteCursor = target
        queuePointer([PointerEvent(action: .move, x: target.x, y: target.y)])
    }

    public func endPress() {
        guard let button = pressedButton else { return }
        dragAnchor = nil
        pressedButton = nil
        queuePointer([
            PointerEvent(action: .up, button: button, x: remoteCursor.x, y: remoteCursor.y)
        ])
    }

    /// Parks the remote pointer on a normalized framebuffer point without
    /// clicking, so remote hot corners and an auto-hidden Dock react. Works in
    /// trackpad mode too, where an absolute move would otherwise be unavailable.
    public func jumpPointer(to normalized: CGPoint) {
        guard state.isConnected, !isObserving else { return }
        let target = CGPoint(
            x: min(max(normalized.x, 0), 1),
            y: min(max(normalized.y, 0), 1)
        )
        stopRecentering()
        remoteCursor = target
        dragAnchor = nil
        if isCenteredTrackpad, canvasSize.width > 0, canvasSize.height > 0 {
            followTrackpadCursor(in: canvasSize)
            scheduleCurrentViewport()
        }
        queuePointer([PointerEvent(action: .move, x: target.x, y: target.y)])
    }

    /// Tracks the pointer on pointer-capable platforms and forwards absolute
    /// moves, so the remote desktop follows hover without a button held.
    public func hover(at point: CGPoint, in size: CGSize) {
        guard state.isConnected, !isObserving, size.width > 0, size.height > 0 else { return }
        guard cursorMode != .trackpad, dragAnchor == nil else { return }

        let normalized = normalized(point, in: size)
        remoteCursor = normalized

        if let framebufferSize, framebufferSize.width >= 1, framebufferSize.height >= 1 {
            let pixel = CGPoint(
                x: (normalized.x * framebufferSize.width).rounded(.down),
                y: (normalized.y * framebufferSize.height).rounded(.down)
            )
            if pixel == lastHoverPixel { return }
            lastHoverPixel = pixel
        }

        queuePointer([PointerEvent(action: .move, x: normalized.x, y: normalized.y)])
    }

    /// Two-finger tap. In touch mode the click lands under the fingers; in
    /// trackpad mode it clicks whatever the virtual cursor points at.
    public func rightClick(at point: CGPoint? = nil, in size: CGSize) {
        click(button: .right, at: point, in: size)
    }

    /// Three-finger tap.
    public func middleClick(at point: CGPoint? = nil, in size: CGSize) {
        click(button: .middle, at: point, in: size)
    }

    private func click(button: PointerButton, at point: CGPoint?, in size: CGSize) {
        guard state.isConnected, !isObserving else { return }
        let target: CGPoint
        if let point, cursorMode != .trackpad, size.width > 0, size.height > 0 {
            target = normalized(point, in: size)
            remoteCursor = target
        } else {
            target = remoteCursor
        }
        queuePointer([
            PointerEvent(action: .move, x: target.x, y: target.y),
            PointerEvent(action: .down, button: button, x: target.x, y: target.y),
            PointerEvent(action: .up, button: button, x: target.x, y: target.y)
        ])
    }

    /// Translates two-finger travel into wheel clicks. Callers pass natural
    /// deltas: dragging fingers down scrolls the remote content down.
    public func scroll(by delta: CGSize) {
        guard state.isConnected, !isObserving,
              delta.width != 0 || delta.height != 0
        else { return }
        scrollRemainder.width += delta.width
        scrollRemainder.height += delta.height
        let stepsX = Int(scrollRemainder.width / Self.scrollStepPoints)
        let stepsY = Int(scrollRemainder.height / Self.scrollStepPoints)
        guard stepsX != 0 || stepsY != 0 else { return }
        scrollRemainder.width -= CGFloat(stepsX) * Self.scrollStepPoints
        scrollRemainder.height -= CGFloat(stepsY) * Self.scrollStepPoints
        inputQueue?.events.yield(.scroll(remoteCursor, Int32(stepsX), Int32(stepsY)))
    }

    /// Moves the zoomed image while two fingers drag it.
    public func panZoom(by delta: CGSize, in size: CGSize) {
        guard canPanZoom(in: size), !isCenteredTrackpad else { return }
        pan = clampedPan(
            CGSize(width: pan.width + delta.width, height: pan.height + delta.height),
            in: size
        )
    }

    /// Applies a pinch around the touches' midpoint. The remote point under
    /// `startFocal` stays under `currentFocal`, so the content follows fingers.
    public func applyPinch(
        scale: CGFloat,
        startZoom: CGFloat,
        startPan: CGSize,
        startFocal: CGPoint,
        currentFocal: CGPoint,
        in size: CGSize
    ) {
        guard let base = remoteImageRect(in: size) else { return }
        stopRecentering()
        let bounds = zoomBounds(in: size)
        let newZoom = min(max(startZoom * scale, bounds.minimum), bounds.maximum)
        if newZoom <= bounds.minimum * 1.001 {
            zoom = bounds.minimum
            pan = .zero
            return
        }
        if isCenteredTrackpad {
            zoom = newZoom
            followTrackpadCursor(in: size)
            return
        }
        let center = CGPoint(x: base.midX, y: base.midY)
        let content = CGPoint(
            x: center.x + (startFocal.x - center.x - startPan.width) / startZoom,
            y: center.y + (startFocal.y - center.y - startPan.height) / startZoom
        )
        zoom = newZoom
        pan = clampedPan(
            CGSize(
                width: currentFocal.x - center.x - (content.x - center.x) * newZoom,
                height: currentFocal.y - center.y - (content.y - center.y) * newZoom
            ),
            in: size
        )
    }

    private func zoomBounds(in size: CGSize) -> (minimum: CGFloat, actual: CGFloat, maximum: CGFloat) {
        guard let base = remoteImageRect(in: size), let framebuffer = serverSize ?? framebufferSize else {
            return (1, 1, Self.maxLogicalZoom)
        }
        let minimum = min(size.width / base.width, size.height / base.height)
        // UIKit already measures the local canvas in logical points.
        let remoteScale = CGFloat(max(1, profile.controls.remoteScalePercent ?? 100)) / 100
        let actual = framebuffer.width / remoteScale / base.width
        return (minimum, actual, max(minimum, actual * Self.maxLogicalZoom))
    }

    func canPanZoom(in size: CGSize) -> Bool {
        zoom > zoomBounds(in: size).minimum * 1.001
    }

    public func resetZoom() {
        setViewZoom(zoomBounds(in: canvasSize).minimum)
    }

    func showActualSize() {
        setViewZoom(zoomBounds(in: canvasSize).actual)
    }

    private func setViewZoom(_ newZoom: CGFloat) {
        stopRecentering()
        let bounds = zoomBounds(in: canvasSize)
        zoom = min(max(newZoom, bounds.minimum), bounds.maximum)
        pan = .zero
        if isCenteredTrackpad { followTrackpadCursor(in: canvasSize) }
        scheduleCurrentViewport()
    }

    private func constrainViewZoom(in size: CGSize) {
        let bounds = zoomBounds(in: size)
        zoom = min(max(zoom, bounds.minimum), bounds.maximum)
        if !canPanZoom(in: size) { pan = .zero }
    }

    /// Debounces a viewport subscription for the visible part of the image, so
    /// a pinch or pan settles before the server is re-asked.
    public func scheduleViewportUpdate(
        in size: CGSize, screenPixelWidth: CGFloat, renderBounds: CGRect? = nil
    ) {
        if canvasSize != size { stopRecentering() }
        constrainViewZoom(in: size)
        if isCenteredTrackpad { followTrackpadCursor(in: size) }
        canvasSize = size
        self.renderBounds = renderBounds ?? CGRect(origin: .zero, size: size)
        canvasPixelWidth = Int(max(1, screenPixelWidth.rounded()))
        scheduleCurrentViewport()
    }

    // While a projector is showing the full desktop, keep a single full-frame
    // subscription. The iPad still applies its own zoom and pan when drawing.
    @ObservationIgnored private var externalDisplayPixelWidth: Int?

    func setExternalDisplayPixelWidth(_ width: Int?) {
        guard externalDisplayPixelWidth != width else { return }
        externalDisplayPixelWidth = width
        scheduleCurrentViewport()
    }

    func scheduleCurrentViewport() {
        guard state.isConnected, serverSize != nil, canvasSize.width > 0, canvasSize.height > 0 else { return }
        viewportTask?.cancel()
        viewportTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(150))
            guard !Task.isCancelled else { return }
            await self?.updateViewport()
        }
    }

    private func updateViewport() async {
        let size = canvasSize
        guard let session,
              let displayed = displayedImageRect(in: size),
              displayed.width > 0, displayed.height > 0
        else { return }

        let visible = displayed.intersection(renderBounds)
        guard !visible.isNull, visible.width >= 1, visible.height >= 1 else { return }

        let unit = CGRect(x: 0, y: 0, width: 1, height: 1)
        let normalized = externalDisplayPixelWidth != nil ? unit : CGRect(
            x: (visible.minX - displayed.minX) / displayed.width,
            y: (visible.minY - displayed.minY) / displayed.height,
            width: visible.width / displayed.width,
            height: visible.height / displayed.height
        ).intersection(unit)
        guard normalized.width > 0, normalized.height > 0 else { return }
        let pixelWidth = max(canvasPixelWidth, externalDisplayPixelWidth ?? 0)
        guard normalized != lastViewportRect || pixelWidth != lastViewportPixelWidth else { return }
        lastViewportRect = normalized
        lastViewportPixelWidth = pixelWidth
        await session.setViewport(normalized, screenPixelWidth: pixelWidth)
    }

    private func clampedPan(_ value: CGSize, in size: CGSize) -> CGSize {
        guard let base = remoteImageRect(in: size) else { return .zero }
        // When the image covers the viewport, keep its edges outside; when it
        // is smaller, let it move inside so a pinch can stay anchored between
        // the fingers instead of snapping back to the centre.
        let maxX = abs(base.width * zoom - size.width) / 2
        let maxY = abs(base.height * zoom - size.height) / 2
        return CGSize(
            width: min(max(value.width, -maxX), maxX),
            height: min(max(value.height, -maxY), maxY)
        )
    }

    private func queuePointer(_ events: [PointerEvent]) {
        for event in events { inputQueue?.events.yield(.pointer(event)) }
    }

    #if os(macOS)
    func sendMousePointer(_ action: PointerAction, button: PointerButton, to point: CGPoint) {
        remoteCursor = point
        inputQueue?.events.yield(.pointer(PointerEvent(action: action, button: button, x: point.x, y: point.y)))
    }

    func sendMouseScroll(at point: CGPoint, x: Int32, y: Int32) {
        remoteCursor = point
        inputQueue?.events.yield(.scroll(point, x, y))
    }
    #endif

    private func releasePointerInput() {
        #if os(macOS)
        mouseInput.cancel()
        #endif
        endPress()
        endDrag()
        scrollRemainder = .zero
        lastHoverPixel = nil
    }

    /// Rect the remote framebuffer occupies inside the view, mirroring the
    /// canvas renderer's fit/fill layout.
    public func remoteImageRect(in size: CGSize) -> CGRect? {
        guard let framebufferSize = serverSize ?? self.framebufferSize,
              framebufferSize.width > 0, framebufferSize.height > 0,
              size.width > 0, size.height > 0
        else { return nil }

        let imageAspect = framebufferSize.width / framebufferSize.height
        let viewAspect = size.width / size.height
        let imageSize: CGSize
        switch scaling {
        case .stretch:
            imageSize = size
        case .fit:
            imageSize = viewAspect > imageAspect
                ? CGSize(width: size.height * imageAspect, height: size.height)
                : CGSize(width: size.width, height: size.width / imageAspect)
        case .fill:
            imageSize = viewAspect > imageAspect
                ? CGSize(width: size.width, height: size.width / imageAspect)
                : CGSize(width: size.height * imageAspect, height: size.height)
        }
        return CGRect(
            x: (size.width - imageSize.width) / 2,
            y: (size.height - imageSize.height) / 2,
            width: imageSize.width,
            height: imageSize.height
        )
    }

    /// Rect the remote image occupies after the current zoom and pan.
    public func displayedImageRect(in size: CGSize) -> CGRect? {
        guard let base = remoteImageRect(in: size) else { return nil }
        let width = base.width * zoom
        let height = base.height * zoom
        return CGRect(
            x: base.midX + pan.width - width / 2,
            y: base.midY + pan.height - height / 2,
            width: width,
            height: height
        )
    }


    private func normalized(_ point: CGPoint, in size: CGSize) -> CGPoint {
        guard let rect = displayedImageRect(in: size), rect.width > 0, rect.height > 0 else {
            return CGPoint(x: 0.5, y: 0.5)
        }
        return Self.normalized(point, in: rect)
    }

    static func normalized(_ point: CGPoint, in rect: CGRect) -> CGPoint {
        CGPoint(
            x: min(max((point.x - rect.minX) / rect.width, 0), 1),
            y: min(max((point.y - rect.minY) / rect.height, 0), 1)
        )
    }

    private func makeCursorImage(_ shape: RemoteCursorShape) -> CGImage? {
        guard !shape.isEmpty,
              shape.bgraPixels.count >= shape.width * shape.height * 4,
              let provider = CGDataProvider(data: shape.bgraPixels as CFData)
        else { return nil }

        let bitmapInfo = CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedFirst.rawValue)
            .union(.byteOrder32Little)
        return CGImage(
            width: shape.width,
            height: shape.height,
            bitsPerComponent: 8,
            bitsPerPixel: 32,
            bytesPerRow: shape.width * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: bitmapInfo,
            provider: provider,
            decode: nil,
            shouldInterpolate: false,
            intent: .defaultIntent
        )
    }

    // MARK: - Keyboard input

    public func type(_ text: String) {
        guard !text.isEmpty, state.isConnected, !isObserving else { return }
        inputQueue?.events.yield(.key(RemoteKeyEvent(key: .text(text))))
    }

    public func sendKey(_ key: RemoteKey, extraModifiers: RemoteModifiers = []) {
        guard state.isConnected, !isObserving else { return }
        let modifiers = keyboardModifiers.union(extraModifiers)
        keyboardModifiers = []
        inputQueue?.events.yield(.key(RemoteKeyEvent(key: key, modifiers: modifiers)))
    }

    /// A menu command has an exact chord, independent of the accessory row's sticky modifiers.
    func sendCommand(_ command: RemoteDesktopCommand) {
        guard state.isConnected, !isObserving else { return }
        inputQueue?.events.yield(.key(command.event))
    }

    public func toggleStickyModifier(_ modifier: RemoteModifiers) {
        if keyboardModifiers.contains(modifier) {
            keyboardModifiers.remove(modifier)
        } else {
            keyboardModifiers.insert(modifier)
        }
    }

    public func clearStickyModifiers() {
        keyboardModifiers = []
    }

    public func setKeyboardActive(_ active: Bool) {
        isKeyboardActive = active
        if active {
            isKeyboardActive = true
        }
    }

    public func toggleKeyboard() {
        isKeyboardActive.toggle()
    }

    // MARK: - Clipboard

    private func cancelClipboardFetch() {
        fetchTask?.cancel()
        fetchTask = nil
    }

    private func resetClipboard() {
        cancelClipboardFetch()
        latestRemoteText = nil
        clipboardChangeCount = nil
    }

    public func setClipboardSharing(_ enabled: Bool) {
        sharedClipboard = enabled
        clipboardChangeCount = enabled ? readClipboardChangeCount() : nil
        guard let session else { return }
        Task {
            do {
                try await session.setClipboardSharing(enabled)
            } catch {
                showMessage(NSLocalizedString("Could not update clipboard sharing.", comment: "Clipboard toast"))
            }
        }
    }

    private func shareLocalClipboardIfNeeded() {
        guard sharedClipboard, sceneIsActive, state.isConnected, !isObserving, let session,
              let text = readClipboard(), !text.isEmpty else { return }
        Task { try? await session.sendClipboard(text, automatic: true) }
    }

    /// Poll the change counter only while the session scene is active. Starting
    /// a new session skips existing text. Resuming detects changes since it was active.
    func watchLocalClipboard() async {
        guard state.isConnected, sharedClipboard, !isObserving else { return }
        while !Task.isCancelled {
            let current = readClipboardChangeCount()
            if let previous = clipboardChangeCount, current != previous {
                shareLocalClipboardIfNeeded()
            }
            clipboardChangeCount = current
            do { try await Task.sleep(for: .milliseconds(750)) } catch { return }
        }
    }

    public func sendLocalClipboard() {
        guard state.isConnected, !isObserving, let session else { return }
        guard let text = readClipboard(), !text.isEmpty else {
            showMessage(NSLocalizedString("The local clipboard has no readable text, or clipboard access is unavailable.", comment: "Clipboard toast"))
            return
        }
        Task {
            do {
                try await session.sendClipboard(text, automatic: false)
            } catch let error as RemoteSessionFailure where error.kind == .invalidInput {
                showMessage(NSLocalizedString("This server’s clipboard supports only Latin-1 text.", comment: "Legacy RFB clipboard"))
            } catch {
                showMessage(NSLocalizedString("Could not send clipboard text.", comment: "Clipboard toast"))
            }
        }
    }

    public func fetchRemoteClipboard() {
        guard sceneIsActive, state.isConnected, let session else { return }
        fetchTask?.cancel()
        fetchTask = Task {
            defer { if !Task.isCancelled { fetchTask = nil } }
            do {
                try Task.checkCancellation()
                let requested = try await session.requestClipboard()
                try Task.checkCancellation()
                if requested {
                    // The clipboard event cancels this timeout, including a reply
                    // that arrived while the native call was still returning.
                    try await Task.sleep(for: .seconds(5))
                    showMessage(NSLocalizedString("No clipboard text received.", comment: "Clipboard toast"))
                } else if let latestRemoteText {
                    writeClipboard(latestRemoteText)
                } else {
                    showMessage(NSLocalizedString("Copy text on the remote computer first.", comment: "Clipboard toast"))
                }
            } catch {
                guard !Task.isCancelled else { return }
                showMessage(NSLocalizedString("Could not request remote clipboard.", comment: "Clipboard toast"))
            }
        }
    }

    // MARK: - File transfer

    /// Sends files dropped onto the remote screen. The transport announces the
    /// drag first and uploads once the server answers with a destination.
    public func uploadFiles(_ urls: [URL]) {
        guard state.isConnected, supportsFileUpload, !isObserving, !urls.isEmpty, let session else { return }
        if urls.count == 1 {
            let name = urls[0].lastPathComponent
            uploadFileName = name.isEmpty
                ? NSLocalizedString("file", comment: "Fallback file name")
                : name
        } else {
            uploadFileName = String(
                format: NSLocalizedString("%lld files", comment: "Upload label for several files"),
                urls.count
            )
        }
        activeUploads += 1
        uploadFraction = nil
        Task { await session.uploadFiles(urls) }
    }

    private func clearUploadState() {
        uploadFileName = nil
        uploadFraction = nil
    }

    /// Downloads one remote POSIX path into the local Downloads folder. The
    /// transport reports progress and completion as events.
    public func download(remotePath: String) {
        guard state.isConnected, supportsFileDownload, let session else { return }
        let path = remotePath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !path.isEmpty else { return }
        downloadFileName = Self.fileName(inRemotePath: path)
        downloadFraction = nil
        activeDownloads += 1
        Task { await session.download(remotePath: path) }
    }

    private static func fileName(inRemotePath path: String) -> String {
        let trimmed = path.count > 1 && path.hasSuffix("/") ? String(path.dropLast()) : path
        let name = (trimmed as NSString).lastPathComponent
        return name.isEmpty ? path : name
    }

    private func clearDownloadProgressIfIdle() {
        guard activeDownloads == 0, promiseDownloads.isEmpty else { return }
        downloadFileName = nil
        downloadFraction = nil
    }

    private func resetTransferProgress() {
        activeUploads = 0
        activeDownloads = 0
        promiseDownloads.removeAll()
        clearUploadState()
        clearDownloadProgressIfIdle()
    }

    func recordReceivedFiles(_ urls: [URL]) {
        receivedFiles.insert(contentsOf: urls.map {
            SessionTransferItem(name: $0.lastPathComponent, folder: $0.deletingLastPathComponent().path, url: $0)
        }, at: 0)
        showMessage(NSLocalizedString("Download complete. Open File Transfers to view saved items.", comment: "Transfer toast"))
    }

    // MARK: - Drag out

    /// Asks the remote server for the files on its drag pasteboard. The caller
    /// (macOS drag source) turns them into file promises.
    public func beginDragOut() async -> [RemoteFile] {
        guard state.isConnected, supportsFileDownload, let session else { return [] }
        return await session.beginDragOut()
    }

    /// Materialises one remote drag item in `directory` for a file promise.
    /// The transfer reports progress through the normal download status.
    public func downloadRemoteFile(
        _ file: RemoteFile,
        toDirectory directory: URL
    ) async throws -> URL {
        guard state.isConnected, let session else {
            throw RemoteTransferError.notConnected
        }
        guard supportsFileDownload else { throw RemoteTransferError.unsupported }
        downloadFileName = file.name
        downloadFraction = nil
        let id = UUID()
        promiseDownloads.insert(id)
        defer {
            promiseDownloads.remove(id)
            clearDownloadProgressIfIdle()
        }
        return try await session.download(remotePath: file.path, toDirectory: directory)
    }

    // MARK: - Session controls

    public func toggleObserveMode() {
        cancelDisconnectConfirmation()
        if !isObserving {
            releasePointerInput()
            clearStickyModifiers()
        }
        isObserving.toggle()
        inputQueue?.events.yield(.observe(isObserving))
    }

    public func setCursorMode(_ mode: CursorMode) {
        stopRecentering()
        cursorMode = mode
        store?.setCursorMode(mode, for: profile)
        dragAnchor = nil
        if canvasSize.width > 0, canvasSize.height > 0 {
            if isCenteredTrackpad {
                remoteCursor = normalized(
                    CGPoint(x: canvasSize.width / 2, y: canvasSize.height / 2),
                    in: canvasSize
                )
                followTrackpadCursor(in: canvasSize)
            } else {
                pan = canPanZoom(in: canvasSize) ? clampedPan(pan, in: canvasSize) : .zero
            }
            scheduleCurrentViewport()
        }
    }

    func setQuality(_ quality: ConnectionQuality) {
        guard state.isConnected, let session, self.quality != quality, !changingQuality else { return }
        changingQuality = true
        Task {
            defer { changingQuality = false }
            do {
                try await session.setQuality(quality)
                qualityOverride = quality
                store?.setQuality(quality, for: profile.id)
            } catch {
                showMessage(NSLocalizedString("Could not change picture quality.", comment: "Picture quality"))
            }
        }
    }

    public func setScaling(_ mode: RemoteContentMode) {
        scaling = mode
        setViewZoom(1)
    }

    func requestCurtainMode(_ enabled: Bool) {
        guard state.isConnected, !isObserving, supportsCurtainMode, let session else { return }
        Task { await session.requestCurtainMode(enabled) }
    }

    public func selectDisplay(_ id: Int?) {
        guard id == nil || displays.contains(where: { $0.id == id }) else { return }
        switchDisplay(to: id, userInitiated: true)
    }

    private func resetDisplaySelection() {
        displaySelectionTask?.cancel()
        displaySelectionTask = nil
        pendingDisplayRestore = nil
        selectedDisplayID = nil
        displays = []
    }

    private func reconcileDisplaySelection() {
        guard state.isConnected, !isSwitchingDisplay else { return }
        if let selectedDisplayID, !displays.contains(where: { $0.id == selectedDisplayID }) {
            self.selectedDisplayID = nil
            switchDisplay(to: nil, userInitiated: false)
        } else if let id = pendingDisplayRestore, displays.contains(where: { $0.id == id }) {
            pendingDisplayRestore = nil
            switchDisplay(to: id, userInitiated: false)
        }
    }

    private func switchDisplay(to id: Int?, userInitiated: Bool) {
        guard let session, state.isConnected, !isSwitchingDisplay else { return }
        if userInitiated {
            pendingDisplayRestore = nil
            if id == selectedDisplayID {
                store?.setPreferredDisplay(id, for: profile.id)
                return
            }
        }
        previewRecorder.flush()
        previewRecorder.reset()
        displaySelectionTask = Task { [weak self] in
            do {
                try await session.selectDisplay(id)
                guard let self, !Task.isCancelled else { return }
                selectedDisplayID = id
                if userInitiated {
                    store?.setPreferredDisplay(id, for: profile.id)
                }
            } catch {
                guard let self, !Task.isCancelled else { return }
                if userInitiated {
                    showMessage(String(
                        format: NSLocalizedString("Could not switch display: %@", comment: "Display switch error"),
                        error.localizedDescription
                    ))
                }
            }
            guard let self, !Task.isCancelled else { return }
            displaySelectionTask = nil
            reconcileDisplaySelection()
        }
    }

    public func toggleChrome() {
        showsChrome.toggle()
    }

    public func grabScreenshot() {
        guard state.isConnected, let image = renderer.snapshot() else {
            showMessage(NSLocalizedString("No remote frame to capture.", comment: "Screenshot toast"))
            return
        }
        PlatformScreenshot.save(image) { [weak self] saved in
            guard let self else { return }
            if !saved {
                PlatformClipboard.setImage(image)
            }
            #if os(iOS)
            let message = saved
                ? "Screenshot saved to Photos."
                : "Screenshot copied to clipboard."
            #else
            let message = "Screenshot copied to clipboard."
            #endif
            self.showMessage(NSLocalizedString(message, comment: "Screenshot toast"))
        }
    }

    #if os(macOS)
    public func saveScreenshotAs() {
        guard state.isConnected, let image = renderer.snapshot() else {
            showMessage(NSLocalizedString("No remote frame to capture.", comment: "Screenshot toast"))
            return
        }
        Task {
            do {
                if let url = try await PlatformScreenshot.saveAsPNG(image) {
                    showMessage(String(
                        format: NSLocalizedString("Screenshot saved to %@.", comment: "Screenshot toast"),
                        url.path
                    ))
                }
            } catch {
                showMessage(String(
                    format: NSLocalizedString("Could not save screenshot: %@", comment: "Screenshot error"),
                    error.localizedDescription
                ))
            }
        }
    }
    #endif

    public func clearMessages() {
        clipboardMessage = nil
        messageTask?.cancel()
        messageTask = nil
    }

    private func showMessage(_ text: String) {
        clipboardMessage = text
        messageTask?.cancel()
        messageTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(3))
            guard !Task.isCancelled else { return }
            self?.clipboardMessage = nil
        }
    }
}
