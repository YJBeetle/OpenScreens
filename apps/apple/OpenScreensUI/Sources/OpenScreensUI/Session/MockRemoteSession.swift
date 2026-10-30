import CoreGraphics
import Foundation
import OpenScreensCanvas

/// Mock transport used until the Rust RFB engine is exposed through UniFFI.
///
/// Integration seam: implement `RemoteSessionProtocol` + `RemoteSessionService`
/// around the generated UniFFI classes and inject that service instead of
/// `MockSessionService` (see `SessionViewModel.service`). The shared UI and both
/// app targets depend only on these two protocols.
public struct MockSessionService: RemoteSessionService {
    public init() {}

    public func makeSession() -> any RemoteSessionProtocol {
        MockRemoteSession()
    }
}

/// In-memory session that streams a procedurally generated desktop, records
/// pointer/key input on the mock cursor and echoes clipboard text.
public actor MockRemoteSession: RemoteSessionProtocol {
    public nonisolated let events: AsyncStream<RemoteSessionEvent>

    private let continuation: AsyncStream<RemoteSessionEvent>.Continuation
    private let frameRate: Double
    private let frameWidth = 768
    private let frameHeight = 480

    private var renderTask: Task<Void, Never>?
    private var startedAt = Date()
    private var connecting = false
    private var stopped = false
    private var tick = 0

    private var cursor = CGPoint(x: 0.5, y: 0.55)
    private var clickPoint: CGPoint?
    private var clickTime: Date?
    private var keyTime: Date?
    private var isObserving = false
    private var localClipboard: String?

    public init(frameRate: Double = 12) {
        self.frameRate = max(1, frameRate)
        let (stream, continuation) = AsyncStream.makeStream(
            of: RemoteSessionEvent.self,
            bufferingPolicy: .bufferingNewest(24)
        )
        self.events = stream
        self.continuation = continuation
    }

    // MARK: - RemoteSessionProtocol

    public func connect(profile: ConnectionProfile) async throws {
        guard renderTask == nil, !connecting, !stopped else { return }
        connecting = true
        isObserving = profile.controls.startInObserveMode
        continuation.yield(.state(.connecting))

        try await Task.sleep(for: .milliseconds(550))
        try Task.checkCancellation()
        guard !stopped else { return }

        startedAt = Date()
        cursor = CGPoint(x: 0.5, y: 0.55)
        clickPoint = nil
        clickTime = nil
        keyTime = nil
        tick = 0

        continuation.yield(.displays([
            RemoteDisplay(id: 0, name: "Demo Display", width: frameWidth, height: frameHeight)
        ]))
        continuation.yield(.state(.connected))
        continuation.yield(.frame(currentScene(at: Date()).fullFrame(at: 0)))

        connecting = false
        renderTask = Task { await self.runFrameLoop() }
    }

    public func disconnect() async {
        guard !stopped else { return }
        stopped = true
        renderTask?.cancel()
        renderTask = nil
        connecting = false
        continuation.yield(.state(.disconnected(reason: "Connection closed")))
        continuation.finish()
    }

    public func sendPointer(_ event: PointerEvent) async {
        guard !isObserving else { return }
        var point = cursor
        if event.isRelative {
            point.x += event.x
            point.y += event.y
        } else {
            point = CGPoint(x: event.x, y: event.y)
        }
        cursor = CGPoint(
            x: min(max(point.x, 0), 1),
            y: min(max(point.y, 0), 1)
        )
        if event.action == .down {
            clickPoint = cursor
            clickTime = Date()
        }
    }

    public func sendKey(_ event: RemoteKeyEvent) async {
        guard !isObserving else { return }
        keyTime = Date()
    }

    public func sendClipboard(_ text: String) async {
        localClipboard = text
    }

    public func requestClipboard() async {
        let text = localClipboard
            ?? "Mock clipboard. Use Send Local Clipboard, then Copy Remote Clipboard to fetch it back."
        continuation.yield(.clipboard(text))
    }

    public func setObserveMode(_ observing: Bool) async {
        isObserving = observing
    }

    // MARK: - Frame generation

    private func runFrameLoop() async {
        let interval = Duration.seconds(1 / frameRate)
        while !Task.isCancelled {
            do {
                try await Task.sleep(for: interval)
            } catch {
                return
            }
            tick += 1
            let now = Date()
            let elapsed = now.timeIntervalSince(startedAt)
            let scene = currentScene(at: now)
            continuation.yield(.frame(scene.fullFrame(at: elapsed)))

            // Push an occasional sub-region update through the same pipeline the
            // real client will use for incremental framebuffer updates.
            if tick.isMultiple(of: 20) {
                continuation.yield(.frame(scene.regionFrame(cursorRegion(), at: elapsed)))
            }
        }
    }

    private func currentScene(at now: Date) -> MockDesktopScene {
        var scene = MockDesktopScene()
        scene.cursor = cursor
        scene.observing = isObserving
        if let clickPoint, let clickTime {
            scene.clickPoint = clickPoint
            scene.clickAge = now.timeIntervalSince(clickTime)
        }
        if let keyTime {
            scene.keyPulseAge = now.timeIntervalSince(keyTime)
        }
        return scene
    }

    private func cursorRegion() -> RemoteRegion {
        let regionWidth = 200
        let regionHeight = 150
        let centerX = Int(cursor.x * Double(frameWidth))
        let centerY = Int(cursor.y * Double(frameHeight))
        let x = min(max(centerX - regionWidth / 2, 0), frameWidth - regionWidth)
        let y = min(max(centerY - regionHeight / 2, 0), frameHeight - regionHeight)
        return RemoteRegion(x: x, y: y, width: regionWidth, height: regionHeight)
    }
}
