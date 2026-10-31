import Foundation
import OpenScreensCanvas

// MARK: - Session state

/// Classification of a session failure reported by the core. Frontends
/// localize on this value; the reason string is only a diagnostic fallback.
public enum RemoteFailureKind: Equatable, Sendable {
    case unknown
    case network
    case connectionRefused
    case missingUsername
    case missingPassword
    case authenticationFailed
    case unsupportedVersion
    case unsupportedSecurityType
    case protocolViolation
    case decode
    case tunnel
    case sshTunnel
    case closed
    case invalidInput
}

/// A failure raised while opening a session, carrying the core's error code
/// alongside its diagnostic text.
public struct RemoteSessionFailure: Error, LocalizedError, Sendable {
    public let kind: RemoteFailureKind
    public let reason: String

    public init(kind: RemoteFailureKind, reason: String) {
        self.kind = kind
        self.reason = reason
    }

    public var errorDescription: String? { reason }
}

public enum RemoteSessionState: Equatable, Sendable {
    case idle
    case connecting
    case connected
    case reconnecting(attempt: Int)
    case disconnected(reason: String?, kind: RemoteFailureKind = .unknown)

    public var isConnected: Bool {
        if case .connected = self { return true }
        return false
    }

    public var isTerminal: Bool {
        if case .disconnected = self { return true }
        return false
    }

    public var label: String {
        switch self {
        case .idle: NSLocalizedString("Idle", comment: "Session state")
        case .connecting: NSLocalizedString("Connecting…", comment: "Session state")
        case .connected: NSLocalizedString("Connected", comment: "Session state")
        case .reconnecting(let attempt):
            String(
                format: NSLocalizedString("Reconnecting… (%lld)", comment: "Session state with attempt"),
                attempt
            )
        case .disconnected: NSLocalizedString("Disconnected", comment: "Session state")
        }
    }
}

public struct RemoteDisplay: Identifiable, Hashable, Sendable {
    public var id: Int
    public var name: String
    public var width: Int
    public var height: Int
    public var isPrimary: Bool

    public init(id: Int, name: String, width: Int, height: Int, isPrimary: Bool = true) {
        self.id = id
        self.name = name
        self.width = width
        self.height = height
        self.isPrimary = isPrimary
    }

    public var resolutionLabel: String { "\(width) × \(height)" }
}

/// One framebuffer update. `region == nil` means the payload is a full frame.
public struct RemoteFrame: Sendable {
    public var width: Int
    public var height: Int
    public var region: RemoteRegion?
    public var data: Data

    public init(width: Int, height: Int, region: RemoteRegion? = nil, data: Data) {
        self.width = width
        self.height = height
        self.region = region
        self.data = data
    }
}

/// A client-side cursor bitmap received through the Cursor pseudo-encoding.
/// `bgraPixels` is tightly packed BGRA8888 with the cursor mask folded into
/// the alpha channel.
public struct RemoteCursorShape: Sendable, Equatable {
    public var hotspotX: Int
    public var hotspotY: Int
    public var width: Int
    public var height: Int
    public var bgraPixels: Data

    public init(hotspotX: Int, hotspotY: Int, width: Int, height: Int, bgraPixels: Data) {
        self.hotspotX = hotspotX
        self.hotspotY = hotspotY
        self.width = width
        self.height = height
        self.bgraPixels = bgraPixels
    }

    public var isEmpty: Bool { width <= 0 || height <= 0 || bgraPixels.isEmpty }
}

/// One remote item offered by an Apple drag-out (message `0x20`).
public struct RemoteFile: Sendable, Hashable {
    /// Original `file://` URL from the remote pasteboard.
    public var url: String
    /// Absolute POSIX path on the remote computer.
    public var path: String
    /// Last path component, suitable as a local file name.
    public var name: String

    public init(url: String, path: String, name: String) {
        self.url = url
        self.path = path
        self.name = name
    }
}

public enum RemoteTransferError: LocalizedError, Sendable {
    case unsupported
    case notConnected
    case missingDownloadedFile(String)

    public var errorDescription: String? {
        switch self {
        case .unsupported:
            NSLocalizedString("This connection does not support file transfer.", comment: "Transfer error")
        case .notConnected:
            NSLocalizedString("The session is not connected.", comment: "Transfer error")
        case .missingDownloadedFile(let name):
            String(
                format: NSLocalizedString("The downloaded file “%@” is missing.", comment: "Transfer error"),
                name
            )
        }
    }
}

public enum RemoteSessionEvent: Sendable {
    case state(RemoteSessionState)
    case displays([RemoteDisplay])
    case frame(RemoteFrame)
    case cursor(RemoteCursorShape)
    /// Pointer position reported by the server, normalized to 0...1.
    case pointerPosition(x: Double, y: Double)
    case clipboard(String)
    case bell
    /// Upload status for files dropped onto the remote screen. `name` is the
    /// remote file currently being received; `fraction` is 0...1 when known.
    case transferProgress(name: String?, fraction: Double?)
    /// An upload finished or was aborted. `name` is the last known file.
    case transferFinished(name: String?)
    /// Download status for a file requested with `download(remotePath:)`.
    /// `total` is 0 when the server does not report a size.
    case downloadProgress(name: String?, received: Int64, total: Int64)
    /// A download finished. `savedPath` is the local folder the file was
    /// written to; `error` is set when the transfer failed.
    case downloadComplete(savedPath: String?, error: String?)
    case failure(String)
}

// MARK: - Input

public enum PointerAction: Sendable {
    case move
    case down
    case up
}

public enum PointerButton: Int, Sendable {
    case left = 1
    case middle = 2
    case right = 3
}

/// Absolute coordinates are normalized to 0...1 of the remote framebuffer.
/// Relative coordinates carry normalized deltas and are used by trackpad mode.
public struct PointerEvent: Sendable {
    public var action: PointerAction
    public var button: PointerButton
    public var x: Double
    public var y: Double
    public var isRelative: Bool

    public init(action: PointerAction, button: PointerButton = .left, x: Double, y: Double, isRelative: Bool = false) {
        self.action = action
        self.button = button
        self.x = x
        self.y = y
        self.isRelative = isRelative
    }
}

public struct RemoteModifiers: OptionSet, Hashable, Sendable {
    public let rawValue: Int

    public init(rawValue: Int) {
        self.rawValue = rawValue
    }

    public static let control = RemoteModifiers(rawValue: 1 << 0)
    public static let option = RemoteModifiers(rawValue: 1 << 1)
    public static let command = RemoteModifiers(rawValue: 1 << 2)
    public static let shift = RemoteModifiers(rawValue: 1 << 3)

    public static let all: RemoteModifiers = [.control, .option, .command, .shift]

    public var shortLabel: String {
        var value = ""
        if contains(.control) { value += "⌃" }
        if contains(.option) { value += "⌥" }
        if contains(.command) { value += "⌘" }
        if contains(.shift) { value += "⇧" }
        return value
    }
}

public enum RemoteKey: Hashable, Sendable {
    case text(String)
    case escape
    case tab
    case returnKey
    case backspace
    case deleteForward
    case insert
    case arrowUp
    case arrowDown
    case arrowLeft
    case arrowRight
    case home
    case end
    case pageUp
    case pageDown
    case function(Int)
}

public struct RemoteKeyEvent: Sendable {
    public var key: RemoteKey
    public var modifiers: RemoteModifiers

    public init(key: RemoteKey, modifiers: RemoteModifiers = []) {
        self.key = key
        self.modifiers = modifiers
    }
}

// MARK: - Transport contracts (UniFFI integration seam)

/// The transport surface the UI depends on. A UniFFI-backed implementation only
/// needs to conform to this protocol and to `RemoteSessionService`; no shared
/// view or app target changes are required.
public protocol RemoteSessionProtocol: Sendable {
    var events: AsyncStream<RemoteSessionEvent> { get }
    func connect(profile: ConnectionProfile) async throws
    func disconnect() async
    func sendPointer(_ event: PointerEvent) async
    /// Sends wheel clicks at a normalized remote position. Positive Y scrolls
    /// the remote content down; positive X scrolls it right.
    func sendScroll(at point: CGPoint, stepsX: Int32, stepsY: Int32) async
    func sendKey(_ event: RemoteKeyEvent) async
    func sendClipboard(_ text: String) async
    func requestClipboard() async
    func setObserveMode(_ observing: Bool) async
    /// Switches the host to one display, or shows every display when `id` is
    /// `nil`.
    func selectDisplay(_ id: Int?) async
    /// Sends local files to the remote desktop through Apple's drag-and-drop
    /// file transfer protocol. Progress and completion arrive as events.
    func uploadFiles(_ urls: [URL]) async
    /// Downloads a remote POSIX path to the local Downloads folder. Progress
    /// and completion arrive as events.
    func download(remotePath: String) async
    /// Asks the Apple server for its drag pasteboard (message 0x0E) and
    /// returns the remote files it currently offers. Empty when the server has
    /// no file drag in progress or the session is not an Apple session.
    func beginDragOut() async -> [RemoteFile]
    /// Downloads one remote file into `directory` and returns the local URL.
    /// Used by file promises, which write the item only when it is dropped.
    func download(remotePath: String, toDirectory directory: URL) async throws -> URL
}

public extension RemoteSessionProtocol {
    /// Transports without wheel support ignore the request.
    func sendScroll(at point: CGPoint, stepsX: Int32, stepsY: Int32) async {}
    /// Transports without display selection ignore the request.
    func selectDisplay(_ id: Int?) async {}
    /// Transports without file transfer support ignore the request.
    func uploadFiles(_ urls: [URL]) async {}
    /// Transports without file download support ignore the request.
    func download(remotePath: String) async {}
    /// Transports without drag-out support offer no files.
    func beginDragOut() async -> [RemoteFile] { [] }
    /// Transports without drag-out support cannot materialise remote files.
    func download(remotePath: String, toDirectory directory: URL) async throws -> URL {
        throw RemoteTransferError.unsupported
    }
}

public protocol RemoteSessionService: Sendable {
    func makeSession() -> any RemoteSessionProtocol
}
