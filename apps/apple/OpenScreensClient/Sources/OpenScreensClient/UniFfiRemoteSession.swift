import CoreGraphics
import Foundation
import OpenScreensCanvas
import OpenScreensCore
import OpenScreensUI
import os

/// The production transport: drives the Rust RFB engine through UniFFI.
private struct SessionSetupError: LocalizedError {
    let message: String

    init(_ message: String) {
        self.message = message
    }

    var errorDescription: String? { message }
}

public struct UniFfiSessionService: OpenScreensUI.RemoteSessionService {
    public init() {}

    public func makeSession() -> any OpenScreensUI.RemoteSessionProtocol {
        UniFfiRemoteSession()
    }
}

private enum InputCommand: Sendable {
    case pointer(mask: UInt8, x: UInt16, y: UInt16)
    case key(down: Bool, keysym: UInt32)
    case clipboard(String)
}

public actor UniFfiRemoteSession: OpenScreensUI.RemoteSessionProtocol {
    public nonisolated let events: AsyncStream<OpenScreensUI.RemoteSessionEvent>

    private let continuation: AsyncStream<OpenScreensUI.RemoteSessionEvent>.Continuation
    private nonisolated let inputContinuation: AsyncStream<InputCommand>.Continuation
    private let inputStream: AsyncStream<InputCommand>

    private var session: OpenScreensCore.RemoteSession?
    private var eventTask: Task<Void, Never>?
    private var inputTask: Task<Void, Never>?

    private var width: UInt16 = 0
    private var height: UInt16 = 0
    // Framebuffer pixels are sampled down so a 6K host does not allocate a
    // full-resolution texture (and a 268 MB frame buffer copy) per frame.
    private var displayScale: UInt16 = 1
    private var scaledWidth = 0
    private var scaledHeight = 0
    private var cursor = CGPoint(x: 0.5, y: 0.5)
    private var buttonMask: UInt8 = 0
    private var observing = false
    private var finished = false

    private let logger = Logger(subsystem: "app.openscreens", category: "Session")
    private static let displayTargetWidth = 2560

    public init() {
        let (stream, continuation) = AsyncStream.makeStream(
            of: OpenScreensUI.RemoteSessionEvent.self,
            bufferingPolicy: .unbounded
        )
        self.events = stream
        self.continuation = continuation

        let (input, inputContinuation) = AsyncStream.makeStream(of: InputCommand.self)
        self.inputStream = input
        self.inputContinuation = inputContinuation
    }

    public func connect(profile: ConnectionProfile) async throws {
        guard session == nil, !finished else { return }
        observing = profile.controls.startInObserveMode
        cursor = CGPoint(x: 0.5, y: 0.5)
        buttonMask = 0
        continuation.yield(.state(.connecting))

        let storedPassword = OpenScreensCredentials.password(for: profile.id)
        let password = storedPassword ?? debugPassword()
        let username = profile.username.trimmingCharacters(in: .whitespacesAndNewlines)

        var sshHost: String?
        var sshPort: UInt16?
        var sshUsername: String?
        var sshAuth: OpenScreensCore.SshAuthConfig?
        var sshFingerprint: String?
        if let ssh = profile.ssh, ssh.enabled {
            let sshUser = ssh.username.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !sshUser.isEmpty else {
                throw SessionSetupError("SSH user name is required.")
            }
            let sshHostValue = ssh.host.trimmingCharacters(in: .whitespacesAndNewlines)
            sshHost = sshHostValue.isEmpty ? profile.trimmedHost : sshHostValue
            sshPort = UInt16(clamping: ssh.port)
            sshUsername = sshUser
            switch ssh.authMethod {
            case .password:
                let sshPassword = OpenScreensCredentials.secret(kind: "ssh-password", for: profile.id) ?? ""
                sshAuth = .password(password: sshPassword)
            case .privateKey:
                let pem: String
                if let keyID = ssh.importedKeyID,
                   let stored = OpenScreensCredentials.secret(
                       kind: SSHKeyVault.secretKind,
                       for: keyID
                   ),
                   !stored.isEmpty {
                    pem = stored
                } else {
                    let expanded = (ssh.keyPath as NSString).expandingTildeInPath
                    do {
                        pem = try String(contentsOfFile: expanded, encoding: .utf8)
                    } catch {
                        throw SessionSetupError(
                            "Choose an SSH private key for this connection."
                        )
                    }
                }
                let passphrase = OpenScreensCredentials.secret(kind: "ssh-passphrase", for: profile.id)
                sshAuth = .privateKey(pem: pem, passphrase: passphrase)
            }
            let fingerprint = ssh.hostKeyFingerprint.trimmingCharacters(in: .whitespacesAndNewlines)
            sshFingerprint = fingerprint.isEmpty ? nil : fingerprint
        }

        // macOS draws the pointer client-side; on touch platforms the remote
        // server keeps compositing it into the framebuffer.
        #if os(macOS)
        let localCursor = true
        #else
        let localCursor = false
        #endif

        let config = OpenScreensCore.SessionConfig(
            host: profile.trimmedHost,
            port: UInt16(clamping: profile.port),
            username: username.isEmpty ? nil : username,
            password: (password?.isEmpty == false) ? password : nil,
            shared: true,
            localCursor: localCursor,
            quality: 9,
            frameIntervalMs: 16,
            sshHost: sshHost,
            sshPort: sshPort,
            sshUsername: sshUsername,
            sshAuth: sshAuth,
            sshHostKeyFingerprint: sshFingerprint
        )

        do {
            let session = try await OpenScreensCore.RemoteSession.connect(config: config)
            self.session = session
            updateSize(session.size())
            continuation.yield(.displays([
                RemoteDisplay(
                    id: 0,
                    name: session.serverName(),
                    width: Int(width),
                    height: Int(height)
                ),
            ]))
            continuation.yield(.state(.connected))
            startEventPump(session)
            startInputPump(session)
        } catch {
            logger.error("connect failed: \(error.localizedDescription, privacy: .public)")
            throw error
        }
    }

    public func disconnect() async {
        finish(reason: "Connection closed")
    }

    public func sendPointer(_ event: PointerEvent) async {
        guard !observing, width > 0, height > 0 else { return }

        if event.isRelative {
            cursor.x += event.x
            cursor.y += event.y
        } else {
            cursor = CGPoint(x: event.x, y: event.y)
        }
        cursor.x = min(max(cursor.x, 0), 1)
        cursor.y = min(max(cursor.y, 0), 1)

        let bit = Self.bit(for: event.button)
        switch event.action {
        case .down:
            buttonMask |= bit
        case .up:
            buttonMask &= ~bit
        case .move:
            break
        }

        let x = UInt16(clamping: min(Int(cursor.x * Double(width)), Int(width) - 1))
        let y = UInt16(clamping: min(Int(cursor.y * Double(height)), Int(height) - 1))
        inputContinuation.yield(.pointer(mask: buttonMask, x: x, y: y))
    }

    public func sendKey(_ event: RemoteKeyEvent) async {
        guard !observing else { return }
        let modifiers = Keysym.modifiers(event.modifiers)
        for keysym in modifiers {
            inputContinuation.yield(.key(down: true, keysym: keysym))
        }

        if case .text(let text) = event.key {
            for scalar in text.unicodeScalars {
                let keysym = Keysym.keysym(for: scalar)
                inputContinuation.yield(.key(down: true, keysym: keysym))
                inputContinuation.yield(.key(down: false, keysym: keysym))
            }
        } else if let keysym = Keysym.keysym(for: event.key) {
            inputContinuation.yield(.key(down: true, keysym: keysym))
            inputContinuation.yield(.key(down: false, keysym: keysym))
        }

        for keysym in modifiers.reversed() {
            inputContinuation.yield(.key(down: false, keysym: keysym))
        }
    }

    public func sendClipboard(_ text: String) async {
        inputContinuation.yield(.clipboard(text))
    }

    public func requestClipboard() async {}

    public func setObserveMode(_ observing: Bool) async {
        self.observing = observing
    }

    private func startEventPump(_ session: OpenScreensCore.RemoteSession) {
        eventTask = Task { [weak self] in
            while let event = await session.nextEvent() {
                await self?.handle(event, session: session)
            }
            await self?.finish(reason: nil)
        }
    }

    private func handle(
        _ event: OpenScreensCore.SessionEvent,
        session: OpenScreensCore.RemoteSession
    ) {
        switch event {
        case .connected(let width, let height, let name):
            self.width = width
            self.height = height
            updateDisplayScale()
            continuation.yield(.displays([
                RemoteDisplay(id: 0, name: name, width: Int(width), height: Int(height)),
            ]))
            continuation.yield(.state(.connected))

        case .frame(_, let rects):
            guard width > 0, height > 0, displayScale > 0 else { return }
            let scale = Int(displayScale)
            for rect in rects where rect.width > 0 && rect.height > 0 {
                guard let data = session.copyRegionScaled(rect: rect, scale: displayScale)
                else { continue }
                // The renderer only allocates its texture from a full frame, so a
                // rect that covers the whole framebuffer must clear `region`.
                let coversFrame = rect.x == 0 && rect.y == 0
                    && Int(rect.width) == Int(width) && Int(rect.height) == Int(height)
                let region: RemoteRegion?
                if coversFrame {
                    region = nil
                } else {
                    let left = Int(rect.x) / scale
                    let top = Int(rect.y) / scale
                    let right = (Int(rect.x) + Int(rect.width) - 1) / scale
                    let bottom = (Int(rect.y) + Int(rect.height) - 1) / scale
                    region = RemoteRegion(
                        x: left,
                        y: top,
                        width: right - left + 1,
                        height: bottom - top + 1
                    )
                }
                continuation.yield(.frame(RemoteFrame(
                    width: scaledWidth,
                    height: scaledHeight,
                    region: region,
                    data: data
                )))
            }

        case .resized(let width, let height):
            self.width = width
            self.height = height
            updateDisplayScale()
            continuation.yield(.displays([
                RemoteDisplay(id: 0, name: "Display", width: Int(width), height: Int(height)),
            ]))

        case .clipboard(let text):
            continuation.yield(.clipboard(text))

        case .bell:
            continuation.yield(.bell)

        case .cursor(let hotspotX, let hotspotY, let width, let height, let pixels):
            let shape = scaledCursor(
                hotspotX: hotspotX,
                hotspotY: hotspotY,
                width: width,
                height: height,
                pixels: pixels
            )
            continuation.yield(.cursor(shape))

        case .pointerPosition(let x, let y):
            guard width > 0, height > 0 else { return }
            continuation.yield(.pointerPosition(
                x: Double(x) / Double(width),
                y: Double(y) / Double(height)
            ))

        case .disconnected(let reason):
            finish(reason: reason)
        }
    }

    private func startInputPump(_ session: OpenScreensCore.RemoteSession) {
        let stream = inputStream
        inputTask = Task {
            for await command in stream {
                do {
                    switch command {
                    case .pointer(let mask, let x, let y):
                        try await session.sendPointer(mask: mask, x: x, y: y)
                    case .key(let down, let keysym):
                        try await session.sendKey(down: down, keysym: keysym)
                    case .clipboard(let text):
                        try await session.sendClipboard(text: text)
                    }
                } catch {
                    return
                }
            }
        }
    }

    private func finish(reason: String?) {
        guard !finished else { return }
        finished = true
        continuation.yield(.state(.disconnected(reason: reason)))
        continuation.finish()
        eventTask?.cancel()
        eventTask = nil
        inputTask?.cancel()
        inputTask = nil
        inputContinuation.finish()
        session = nil
    }

    private func updateSize(_ size: OpenScreensCore.SessionSize?) {
        guard let size else { return }
        width = size.width
        height = size.height
        updateDisplayScale()
    }

    private func updateDisplayScale() {
        guard width > 0, height > 0 else {
            displayScale = 1
            scaledWidth = 0
            scaledHeight = 0
            return
        }
        let scale = max(1, min(8, Int(width) / Self.displayTargetWidth))
        displayScale = UInt16(scale)
        scaledWidth = (Int(width) + scale - 1) / scale
        scaledHeight = (Int(height) + scale - 1) / scale
        logger.info(
            "display sampling 1/\(scale) (\(self.scaledWidth)x\(self.scaledHeight)) for \(self.width)x\(self.height)"
        )
    }

    private func scaledCursor(
        hotspotX: UInt16,
        hotspotY: UInt16,
        width: UInt16,
        height: UInt16,
        pixels: Data
    ) -> RemoteCursorShape {
        let scale = Int(displayScale)
        let sourceWidth = Int(width)
        let sourceHeight = Int(height)
        guard scale > 1, sourceWidth > 0, sourceHeight > 0,
              pixels.count >= sourceWidth * sourceHeight * 4
        else {
            return RemoteCursorShape(
                hotspotX: Int(hotspotX),
                hotspotY: Int(hotspotY),
                width: sourceWidth,
                height: sourceHeight,
                bgraPixels: pixels
            )
        }

        let destWidth = (sourceWidth + scale - 1) / scale
        let destHeight = (sourceHeight + scale - 1) / scale
        let source = [UInt8](pixels)
        var output = [UInt8](repeating: 0, count: destWidth * destHeight * 4)
        for y in 0..<destHeight {
            let sourceY = y * scale
            guard sourceY < sourceHeight else { continue }
            for x in 0..<destWidth {
                let sourceX = x * scale
                guard sourceX < sourceWidth else { continue }
                let s = (sourceY * sourceWidth + sourceX) * 4
                let d = (y * destWidth + x) * 4
                output[d] = source[s]
                output[d + 1] = source[s + 1]
                output[d + 2] = source[s + 2]
                output[d + 3] = source[s + 3]
            }
        }
        return RemoteCursorShape(
            hotspotX: Int(hotspotX) / scale,
            hotspotY: Int(hotspotY) / scale,
            width: destWidth,
            height: destHeight,
            bgraPixels: Data(output)
        )
    }

    private static func bit(for button: PointerButton) -> UInt8 {
        switch button {
        case .left: 1 << 0
        case .middle: 1 << 1
        case .right: 1 << 2
        }
    }

    private func debugPassword() -> String? {
        #if DEBUG
        return ProcessInfo.processInfo.environment["OPENSCREENS_PASSWORD"]
        #else
        return nil
        #endif
    }
}
