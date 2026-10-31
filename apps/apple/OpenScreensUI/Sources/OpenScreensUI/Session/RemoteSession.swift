import Foundation
import OpenScreensCanvas

// MARK: - Session state

public enum RemoteSessionState: Equatable, Sendable {
    case idle
    case connecting
    case connected
    case reconnecting(attempt: Int)
    case disconnected(reason: String?)

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
        case .idle: "Idle"
        case .connecting: "Connecting…"
        case .connected: "Connected"
        case .reconnecting(let attempt): "Reconnecting… (\(attempt))"
        case .disconnected: "Disconnected"
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
    func sendKey(_ event: RemoteKeyEvent) async
    func sendClipboard(_ text: String) async
    func requestClipboard() async
    func setObserveMode(_ observing: Bool) async
    /// Sends local files to the remote desktop through Apple's drag-and-drop
    /// file transfer protocol. Progress and completion arrive as events.
    func uploadFiles(_ urls: [URL]) async
}

public extension RemoteSessionProtocol {
    /// Transports without file transfer support ignore the request.
    func uploadFiles(_ urls: [URL]) async {}
}

public protocol RemoteSessionService: Sendable {
    func makeSession() -> any RemoteSessionProtocol
}
