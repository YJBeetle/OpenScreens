import CoreGraphics
import Foundation
import Observation
import OpenScreensCanvas
import SwiftUI

/// Drives one remote session: transport lifecycle, frame uploads, pointer and
/// keyboard input, clipboard actions and reconnection.
@MainActor
@Observable
public final class SessionViewModel {
    public let profile: ConnectionProfile
    public let renderer: RemoteCanvasRenderer

    public private(set) var state: RemoteSessionState = .idle
    public private(set) var displays: [RemoteDisplay] = []
    public var selectedDisplayID: Int?
    /// Size of the server framebuffer; frames may be sampled down from this.
    public private(set) var serverSize: CGSize?
    public private(set) var frameSize: CGSize?

    public var cursorMode: CursorMode
    public var isObserving: Bool
    public var scaling: RemoteContentMode
    public var showsChrome = true
    public var isKeyboardActive = false
    public var keyboardModifiers: RemoteModifiers = []

    public private(set) var clipboardMessage: String?
    public private(set) var failureMessage: String?
    public private(set) var receivedFrames = 0
    public private(set) var remoteCursorShape: RemoteCursorShape?
    public private(set) var remoteCursorImage: CGImage?
    /// Name of the file currently being received by the remote desktop.
    public private(set) var uploadFileName: String?
    /// Overall transfer progress (0...1) when the server reports it.
    public private(set) var uploadFraction: Double?
    /// Name of the file currently being downloaded from the remote desktop.
    public private(set) var downloadFileName: String?
    /// Download progress (0...1) when the server reports the total size.
    public private(set) var downloadFraction: Double?
    /// Destination folder of the last successful download, shown in an alert.
    public private(set) var downloadSavedPath: String?
    /// Last known pointer position, normalized to the remote framebuffer.
    public private(set) var remoteCursor = CGPoint(x: 0.5, y: 0.55)
    /// Magnification applied to the remote image; 1 shows the whole desktop.
    public private(set) var zoom: CGFloat = 1
    /// On-screen translation of the zoomed image, in points.
    public private(set) var pan: CGSize = .zero

    @ObservationIgnored private let service: any RemoteSessionService
    @ObservationIgnored private var session: (any RemoteSessionProtocol)?
    @ObservationIgnored private var eventTask: Task<Void, Never>?
    @ObservationIgnored private var connectTask: Task<Void, Never>?
    @ObservationIgnored private var reconnectTask: Task<Void, Never>?
    @ObservationIgnored private var messageTask: Task<Void, Never>?
    @ObservationIgnored private var dragAnchor: CGPoint?
    @ObservationIgnored private var isStopping = false
    @ObservationIgnored private var reconnectAttempts = 0
    @ObservationIgnored private var lastHoverPixel: CGPoint?
    @ObservationIgnored private var backgroundedAt: Date?
    @ObservationIgnored private var scrollRemainder = CGSize.zero

    private static let resumeReconnectDelay: TimeInterval = 5
    private static let maxZoom: CGFloat = 6
    /// Points of two-finger travel that make one wheel click.
    private static let scrollStepPoints: CGFloat = 24

    public init(
        profile: ConnectionProfile,
        service: any RemoteSessionService = MockSessionService()
    ) {
        self.profile = profile
        self.service = service
        self.cursorMode = profile.controls.cursorMode
        self.isObserving = profile.controls.startInObserveMode
        self.scaling = profile.controls.scaling
        self.renderer = RemoteCanvasRenderer()
    }

    // MARK: - Lifecycle

    public func start() {
        guard eventTask == nil, connectTask == nil else { return }
        isStopping = false
        reconnectAttempts = 0
        failureMessage = nil
        PlatformScreen.setIdleTimerDisabled(profile.controls.keepScreenAwake)
        beginSession(isReconnect: false)
    }

    public func stop() {
        isStopping = true
        isKeyboardActive = false
        reconnectTask?.cancel()
        reconnectTask = nil
        endTransport()
        PlatformScreen.setIdleTimerDisabled(false)
    }

    public func disconnect() {
        isStopping = true
        isKeyboardActive = false
        reconnectTask?.cancel()
        reconnectTask = nil
        state = .disconnected(reason: NSLocalizedString("Disconnected", comment: "Session state"))
        endTransport()
        PlatformScreen.setIdleTimerDisabled(false)
    }

    public func reconnect() {
        guard state.isTerminal else { return }
        restartTransport()
    }

    /// Scene phase hook. A suspended app can return with a socket that never
    /// reports an error, which would leave the last frame on screen forever.
    public func handleScenePhase(_ phase: ScenePhase) {
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
            if needsRestart {
                restartTransport()
            }
        default:
            break
        }
        #endif
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
        state = isReconnect ? .reconnecting(attempt: reconnectAttempts) : .connecting
        remoteCursorShape = nil
        remoteCursorImage = nil
        lastHoverPixel = nil

        eventTask = Task { [weak self, session] in
            for await event in session.events {
                guard let self else { return }
                self.handle(event)
            }
        }

        let profile = profile
        connectTask = Task { [weak self, session, profile] in
            do {
                try await session.connect(profile: profile)
            } catch is CancellationError {
                // The user stopped the session while it was connecting.
            } catch {
                self?.handleTransportFailure(error.localizedDescription)
            }
        }
    }

    private func endTransport() {
        let active = session
        session = nil
        connectTask?.cancel()
        connectTask = nil
        eventTask?.cancel()
        eventTask = nil
        clearUploadState()
        clearDownloadState()
        if let active {
            Task { await active.disconnect() }
        }
    }

    // MARK: - Events

    private func handle(_ event: RemoteSessionEvent) {
        switch event {
        case .state(let newState):
            state = newState
            if newState.isConnected {
                reconnectAttempts = 0
                failureMessage = nil
            }
            if case .disconnected(let reason) = newState {
                clearUploadState()
                clearDownloadState()
                handleRemoteClose(reason: reason)
            }

        case .displays(let list):
            displays = list
            if let display = list.first {
                serverSize = CGSize(width: display.width, height: display.height)
            }
            // `nil` means every display is shown; only drop a selection the
            // host stopped reporting.
            if let selectedDisplayID,
               !list.contains(where: { $0.id == selectedDisplayID }) {
                self.selectedDisplayID = nil
            }

        case .frame(let frame):
            receivedFrames += 1
            frameSize = CGSize(width: frame.width, height: frame.height)
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

        case .cursor(let shape):
            if shape.isEmpty {
                remoteCursorShape = nil
                remoteCursorImage = nil
            } else {
                remoteCursorShape = shape
                remoteCursorImage = makeCursorImage(shape)
            }

        case .pointerPosition(let x, let y):
            remoteCursor = CGPoint(
                x: min(max(x, 0), 1),
                y: min(max(y, 0), 1)
            )

        case .clipboard(let text):
            PlatformClipboard.setString(text)
            showMessage(NSLocalizedString("Remote clipboard copied.", comment: "Clipboard toast"))

        case .bell:
            PlatformFeedback.selection()

        case .transferProgress(let name, let fraction):
            if let name, !name.isEmpty {
                uploadFileName = name
            }
            if let fraction {
                uploadFraction = min(max(fraction, 0), 1)
            }

        case .transferFinished:
            clearUploadState()

        case .downloadProgress(let name, let received, let total):
            if let name, !name.isEmpty {
                downloadFileName = name
            }
            if total > 0 {
                downloadFraction = min(max(Double(received) / Double(total), 0), 1)
            }

        case .downloadComplete(let savedPath, let error):
            clearDownloadState()
            if error == nil, let savedPath, !savedPath.isEmpty {
                downloadSavedPath = savedPath
            }

        case .failure(let message):
            failureMessage = message
            showMessage(message)
        }
    }

    private func handleRemoteClose(reason: String?) {
        guard !isStopping else { return }
        eventTask = nil
        connectTask = nil
        if let reason, !reason.isEmpty {
            failureMessage = reason
        }
        guard profile.controls.autoReconnect, reconnectAttempts < 3 else { return }
        reconnectAttempts += 1
        state = .reconnecting(attempt: reconnectAttempts)
        reconnectTask?.cancel()
        reconnectTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled, let self else { return }
            self.beginSession(isReconnect: true)
        }
    }

    private func handleTransportFailure(_ message: String) {
        failureMessage = message
        state = .disconnected(reason: message)
        connectTask = nil
        eventTask?.cancel()
        eventTask = nil
    }

    // MARK: - Pointer input

    public func tap(at point: CGPoint, in size: CGSize) {
        guard state.isConnected, !isObserving, size.width > 0, size.height > 0 else { return }
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
                PointerEvent(action: .down, button: button, x: remoteCursor.x, y: remoteCursor.y),
                PointerEvent(action: .up, button: button, x: remoteCursor.x, y: remoteCursor.y)
            ])
        }
    }

    public func drag(to point: CGPoint, in size: CGSize) {
        guard state.isConnected, !isObserving, size.width > 0, size.height > 0 else { return }
        let normalized = normalized(point, in: size)
        defer { dragAnchor = normalized }

        switch cursorMode {
        case .touch:
            remoteCursor = normalized
            queuePointer([PointerEvent(action: .move, x: normalized.x, y: normalized.y)])

        case .trackpad, .trackpadAndMouse:
            guard let anchor = dragAnchor else { return }
            let deltaX = (normalized.x - anchor.x) * 1.6
            let deltaY = (normalized.y - anchor.y) * 1.6
            guard abs(deltaX) + abs(deltaY) > 0.0004 else { return }
            remoteCursor = CGPoint(
                x: min(max(remoteCursor.x + deltaX, 0), 1),
                y: min(max(remoteCursor.y + deltaY, 0), 1)
            )
            queuePointer([PointerEvent(action: .move, x: deltaX, y: deltaY, isRelative: true)])
        }
    }

    public func endDrag() {
        dragAnchor = nil
    }

    /// Tracks the pointer on pointer-capable platforms and forwards absolute
    /// moves, so the remote desktop follows hover without a button held.
    public func hover(at point: CGPoint, in size: CGSize) {
        guard state.isConnected, !isObserving, size.width > 0, size.height > 0 else { return }
        guard cursorMode != .trackpad, dragAnchor == nil else { return }

        let normalized = normalized(point, in: size)
        remoteCursor = normalized

        if let frameSize, frameSize.width >= 1, frameSize.height >= 1 {
            let pixel = CGPoint(
                x: (normalized.x * frameSize.width).rounded(.down),
                y: (normalized.y * frameSize.height).rounded(.down)
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
        guard state.isConnected, !isObserving, let session,
              delta.width != 0 || delta.height != 0
        else { return }
        scrollRemainder.width += delta.width
        scrollRemainder.height += delta.height
        let stepsX = Int(scrollRemainder.width / Self.scrollStepPoints)
        let stepsY = Int(scrollRemainder.height / Self.scrollStepPoints)
        guard stepsX != 0 || stepsY != 0 else { return }
        scrollRemainder.width -= CGFloat(stepsX) * Self.scrollStepPoints
        scrollRemainder.height -= CGFloat(stepsY) * Self.scrollStepPoints
        let point = remoteCursor
        Task { await session.sendScroll(at: point, stepsX: Int32(stepsX), stepsY: Int32(stepsY)) }
    }

    /// Moves the zoomed image while two fingers drag it.
    public func panZoom(by delta: CGSize, in size: CGSize) {
        guard zoom > 1.001 else { return }
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
        let newZoom = min(max(startZoom * scale, 1), Self.maxZoom)
        guard newZoom > 1.001 else {
            zoom = 1
            pan = .zero
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

    public func resetZoom() {
        zoom = 1
        pan = .zero
    }

    private func clampedPan(_ value: CGSize, in size: CGSize) -> CGSize {
        guard let base = remoteImageRect(in: size) else { return .zero }
        let maxX = max(0, (base.width * zoom - size.width) / 2)
        let maxY = max(0, (base.height * zoom - size.height) / 2)
        return CGSize(
            width: min(max(value.width, -maxX), maxX),
            height: min(max(value.height, -maxY), maxY)
        )
    }

    private func queuePointer(_ events: [PointerEvent]) {
        guard let session else { return }
        Task {
            for event in events {
                await session.sendPointer(event)
            }
        }
    }

    /// Rect the remote framebuffer occupies inside the view, mirroring the
    /// canvas renderer's fit/fill layout.
    public func remoteImageRect(in size: CGSize) -> CGRect? {
        guard let frameSize, frameSize.width > 0, frameSize.height > 0,
              size.width > 0, size.height > 0
        else { return nil }

        let imageAspect = frameSize.width / frameSize.height
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
        return CGPoint(
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
        guard !text.isEmpty, state.isConnected, !isObserving, let session else { return }
        Task { await session.sendKey(RemoteKeyEvent(key: .text(text))) }
    }

    public func sendKey(_ key: RemoteKey, extraModifiers: RemoteModifiers = []) {
        guard state.isConnected, !isObserving else { return }
        let modifiers = keyboardModifiers.union(extraModifiers)
        keyboardModifiers = []
        guard let session else { return }
        let event = RemoteKeyEvent(key: key, modifiers: modifiers)
        Task { await session.sendKey(event) }
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

    public func sendLocalClipboard() {
        guard state.isConnected, !isObserving else { return }
        guard let text = PlatformClipboard.string, !text.isEmpty else {
            showMessage(NSLocalizedString("Local clipboard is empty.", comment: "Clipboard toast"))
            return
        }
        guard let session else { return }
        Task {
            await session.sendClipboard(text)
            self.showMessage(NSLocalizedString("Sent local clipboard.", comment: "Clipboard toast"))
        }
    }

    public func fetchRemoteClipboard() {
        guard state.isConnected, !isObserving, let session else { return }
        Task { await session.requestClipboard() }
    }

    // MARK: - File transfer

    /// Sends files dropped onto the remote screen. The transport announces the
    /// drag first and uploads once the server answers with a destination.
    public func uploadFiles(_ urls: [URL]) {
        guard state.isConnected, !urls.isEmpty, let session else { return }
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
        guard state.isConnected, let session else { return }
        let path = remotePath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !path.isEmpty else { return }
        downloadFileName = Self.fileName(inRemotePath: path)
        downloadFraction = nil
        downloadSavedPath = nil
        Task { await session.download(remotePath: path) }
    }

    private static func fileName(inRemotePath path: String) -> String {
        let trimmed = path.count > 1 && path.hasSuffix("/") ? String(path.dropLast()) : path
        let name = (trimmed as NSString).lastPathComponent
        return name.isEmpty ? path : name
    }

    private func clearDownloadState() {
        downloadFileName = nil
        downloadFraction = nil
        downloadSavedPath = nil
    }

    // MARK: - Drag out

    /// Asks the remote server for the files on its drag pasteboard. The caller
    /// (macOS drag source) turns them into file promises.
    public func beginDragOut() async -> [RemoteFile] {
        guard state.isConnected, let session else { return [] }
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
        downloadFileName = file.name
        downloadFraction = nil
        defer { clearDownloadState() }
        return try await session.download(remotePath: file.path, toDirectory: directory)
    }

    /// Dismisses the download completion alert.
    public func clearDownloadResult() {
        downloadSavedPath = nil
    }

    // MARK: - Session controls

    public func toggleObserveMode() {
        isObserving.toggle()
        guard let session else { return }
        let observing = isObserving
        Task { await session.setObserveMode(observing) }
    }

    public func setCursorMode(_ mode: CursorMode) {
        cursorMode = mode
        dragAnchor = nil
    }

    public func setScaling(_ mode: RemoteContentMode) {
        scaling = mode
    }

    public func selectDisplay(_ id: Int?) {
        guard state.isConnected, let session else { return }
        selectedDisplayID = id
        Task { await session.selectDisplay(id) }
    }

    public func toggleChrome() {
        showsChrome.toggle()
    }

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
