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
    /// Last known pointer position, normalized to the remote framebuffer.
    public private(set) var remoteCursor = CGPoint(x: 0.5, y: 0.55)

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

    private static let resumeReconnectDelay: TimeInterval = 5

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
        state = .disconnected(reason: "Disconnected")
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
                handleRemoteClose(reason: reason)
            }

        case .displays(let list):
            displays = list
            if selectedDisplayID == nil || !list.contains(where: { $0.id == selectedDisplayID }) {
                selectedDisplayID = list.first?.id
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
            showMessage("Remote clipboard copied.")

        case .bell:
            PlatformFeedback.selection()

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

    private func normalized(_ point: CGPoint, in size: CGSize) -> CGPoint {
        guard let rect = remoteImageRect(in: size) else {
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
            showMessage("Local clipboard is empty.")
            return
        }
        guard let session else { return }
        Task {
            await session.sendClipboard(text)
            self.showMessage("Sent local clipboard.")
        }
    }

    public func fetchRemoteClipboard() {
        guard state.isConnected, !isObserving, let session else { return }
        Task { await session.requestClipboard() }
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

    public func selectDisplay(id: Int) {
        selectedDisplayID = id
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
