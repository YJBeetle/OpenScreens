import Foundation
import OpenScreensCanvas

extension ConnectionProfile {
    /// Deterministic preview palette derived from the identifier so a connection
    /// keeps the same tile colour across launches.
    public static func suggestedPalette(for id: UUID) -> TilePalette {
        let checksum = id.uuidString.unicodeScalars.reduce(0) { partial, scalar in
            partial &+ Int(scalar.value)
        }
        let all = TilePalette.allCases
        return all[checksum % all.count]
    }
}

/// Groups of connections shown in the library sidebar.
public enum LibrarySection: String, Codable, CaseIterable, Identifiable, Sendable {
    case nearby
    case links
    case connect
    case tailscale
    case custom

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .nearby: "Nearby"
        case .links: "Links"
        case .connect: "Connect"
        case .tailscale: "Tailscale"
        case .custom: "Custom"
        }
    }

    /// Title used for the content pane. The custom library is the app's main
    /// "all connections" list.
    public var screenTitle: String {
        self == .custom ? "All Connections" : title
    }

    public var systemImage: String {
        switch self {
        case .nearby: "dot.radiowaves.left.and.right"
        case .links: "link"
        case .connect: "cloud"
        case .tailscale: "network"
        case .custom: "square.grid.2x2"
        }
    }

    /// Service-backed sections are informational in this build; selecting one
    /// explains how to connect without an account.
    public var isService: Bool {
        self == .connect || self == .tailscale
    }

    public var serviceStatus: String? {
        switch self {
        case .connect: "Not configured"
        case .tailscale: "Optional"
        default: nil
        }
    }

    /// New hand-made connections always land in the custom section.
    public static var defaultDestination: LibrarySection { .custom }
}

/// How the SSH jump host authenticates.
public enum SSHAuthMethod: String, Codable, CaseIterable, Identifiable, Sendable {
    case password
    case privateKey

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .password: "Password"
        case .privateKey: "Private Key"
        }
    }
}

/// Optional SSH jump host used to reach a LAN-only VNC server.
public struct SSHProfile: Codable, Hashable, Sendable {
    public var enabled: Bool
    public var host: String
    public var port: Int
    public var username: String
    public var authMethod: SSHAuthMethod
    public var keyPath: String
    /// Key imported through the app and kept in the Keychain (used on iOS,
    /// where there is no `~/.ssh` to browse).
    public var importedKeyID: UUID?
    public var hostKeyFingerprint: String

    public init(
        enabled: Bool = false,
        host: String = "",
        port: Int = 22,
        username: String = "",
        authMethod: SSHAuthMethod = .password,
        keyPath: String = "",
        importedKeyID: UUID? = nil,
        hostKeyFingerprint: String = ""
    ) {
        self.enabled = enabled
        self.host = host
        self.port = port
        self.username = username
        self.authMethod = authMethod
        self.keyPath = keyPath
        self.importedKeyID = importedKeyID
        self.hostKeyFingerprint = hostKeyFingerprint
    }
}

/// A saved remote computer.
public struct ConnectionProfile: Identifiable, Codable, Hashable, Sendable {
    public var id: UUID
    public var name: String
    public var host: String
    public var port: Int
    public var platform: RemoteOS
    public var section: LibrarySection
    public var palette: TilePalette
    public var authentication: AuthenticationMethod
    public var username: String
    public var isFavorite: Bool
    public var isDiscovered: Bool
    public var controls: ControlPreferences
    public var ssh: SSHProfile?
    /// Full wg-quick configuration text. Mutually exclusive with `ssh`.
    public var wireGuardConfig: String?
    public var createdAt: Date
    public var lastConnectedAt: Date?

    public init(
        id: UUID = UUID(),
        name: String = "",
        host: String = "",
        port: Int = 5900,
        platform: RemoteOS = .macos,
        section: LibrarySection = .custom,
        palette: TilePalette? = nil,
        authentication: AuthenticationMethod = .vncPassword,
        username: String = "",
        isFavorite: Bool = false,
        isDiscovered: Bool = false,
        controls: ControlPreferences = ControlPreferences(),
        ssh: SSHProfile? = nil,
        wireGuardConfig: String? = nil,
        createdAt: Date = .now,
        lastConnectedAt: Date? = nil
    ) {
        self.id = id
        self.name = name
        self.host = host
        self.port = port
        self.platform = platform
        self.section = section
        self.palette = palette ?? ConnectionProfile.suggestedPalette(for: id)
        self.authentication = authentication
        self.username = username
        self.isFavorite = isFavorite
        self.isDiscovered = isDiscovered
        self.controls = controls
        self.ssh = ssh
        self.wireGuardConfig = wireGuardConfig
        self.createdAt = createdAt
        self.lastConnectedAt = lastConnectedAt
    }

    // MARK: - Derived values

    public var trimmedName: String { name.trimmingCharacters(in: .whitespacesAndNewlines) }
    public var trimmedHost: String { host.trimmingCharacters(in: .whitespacesAndNewlines) }

    public var isValid: Bool {
        !trimmedName.isEmpty
            && !trimmedHost.isEmpty
            && (1...65535).contains(port)
            && sshIsValid
    }

    public var sshIsValid: Bool {
        guard let ssh, ssh.enabled else { return true }
        let username = ssh.username.trimmingCharacters(in: .whitespacesAndNewlines)
        let keyPath = ssh.keyPath.trimmingCharacters(in: .whitespacesAndNewlines)
        return !username.isEmpty
            && (1...65535).contains(ssh.port)
            && (ssh.authMethod == .password || !keyPath.isEmpty)
    }

    public var hasWireGuardConfig: Bool {
        guard let wireGuardConfig else { return false }
        return !wireGuardConfig.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// SSH and WireGuard both build the transport tunnel; the core rejects a
    /// session that carries both.
    public var hasTunnelConflict: Bool {
        hasWireGuardConfig && (ssh?.enabled ?? false)
    }

    public var endpoint: String {
        port == 5900 ? host : "\(host):\(port)"
    }

    /// Subtitle under the tile name.
    public var subtitle: String {
        if isDiscovered {
            return host.isEmpty ? "Discovered nearby" : "\(host) · Nearby"
        }
        return endpoint
    }

    public var searchIndex: String {
        "\(name) \(host) \(username) \(section.title)".lowercased()
    }

    /// Returns a trimmed copy with a valid port, ready to persist.
    public func normalized() -> ConnectionProfile {
        var copy = self
        copy.name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        copy.host = host.trimmingCharacters(in: .whitespacesAndNewlines)
        copy.username = username.trimmingCharacters(in: .whitespacesAndNewlines)
        copy.port = min(max(port, 1), 65535)
        if var ssh = copy.ssh {
            ssh.host = ssh.host.trimmingCharacters(in: .whitespacesAndNewlines)
            ssh.username = ssh.username.trimmingCharacters(in: .whitespacesAndNewlines)
            ssh.keyPath = ssh.keyPath.trimmingCharacters(in: .whitespacesAndNewlines)
            ssh.hostKeyFingerprint = ssh.hostKeyFingerprint.trimmingCharacters(in: .whitespacesAndNewlines)
            ssh.port = min(max(ssh.port, 1), 65535)
            copy.ssh = ssh
        }
        if let config = copy.wireGuardConfig {
            let trimmed = config.trimmingCharacters(in: .whitespacesAndNewlines)
            copy.wireGuardConfig = trimmed.isEmpty ? nil : trimmed
        }
        return copy
    }

    public static func draft(
        section: LibrarySection = .defaultDestination,
        platform: RemoteOS = .macos,
        controls: ControlPreferences = ControlPreferences()
    ) -> ConnectionProfile {
        var profile = ConnectionProfile(platform: platform, section: section)
        profile.controls = controls
        return profile
    }
}

/// Default presentation and input preferences for one connection.
public struct ControlPreferences: Codable, Hashable, Sendable {
    public var startInObserveMode: Bool
    public var sharedClipboard: Bool
    public var cursorMode: CursorMode
    public var scaling: RemoteContentMode
    public var autoReconnect: Bool
    public var keepScreenAwake: Bool

    public init(
        startInObserveMode: Bool = false,
        sharedClipboard: Bool = true,
        cursorMode: CursorMode = .touch,
        scaling: RemoteContentMode = .fit,
        autoReconnect: Bool = true,
        keepScreenAwake: Bool = true
    ) {
        self.startInObserveMode = startInObserveMode
        self.sharedClipboard = sharedClipboard
        self.cursorMode = cursorMode
        self.scaling = scaling
        self.autoReconnect = autoReconnect
        self.keepScreenAwake = keepScreenAwake
    }
}

/// The remote operating system, used for the tile glyph and sensible defaults.
public enum RemoteOS: String, Codable, CaseIterable, Identifiable, Sendable {
    case macos
    case windows
    case linux
    case unix
    case generic

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .macos: "macOS"
        case .windows: "Windows"
        case .linux: "Linux"
        case .unix: "Unix"
        case .generic: "Other"
        }
    }

    public var symbolName: String {
        switch self {
        case .macos: "macwindow"
        case .windows: "pc"
        case .linux: "terminal"
        case .unix: "server.rack"
        case .generic: "display"
        }
    }

    public var defaultPort: Int { 5900 }
}

/// Authentication the server will ask for. Credentials are never persisted.
public enum AuthenticationMethod: String, Codable, CaseIterable, Identifiable, Sendable {
    case vncPassword
    case macOSAccount
    case none

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .vncPassword: "VNC Password"
        case .macOSAccount: "macOS Account"
        case .none: "None"
        }
    }

    public var requiresUsername: Bool { self == .macOSAccount }
}

/// How touch input is translated into remote pointer movement.
public enum CursorMode: String, Codable, CaseIterable, Identifiable, Sendable {
    case touch
    case trackpad
    case trackpadAndMouse

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .touch: "Touch"
        case .trackpad: "Trackpad"
        case .trackpadAndMouse: "Trackpad & Mouse"
        }
    }

    public var systemImage: String {
        switch self {
        case .touch: "hand.tap"
        case .trackpad: "rectangle.and.hand.point.up.left"
        case .trackpadAndMouse: "computermouse"
        }
    }

    public var help: String {
        switch self {
        case .touch:
            "Taps jump the pointer to the touched spot. Drag to move the pointer."
        case .trackpad:
            "The screen behaves like a trackpad; the pointer moves relative to your fingers."
        case .trackpadAndMouse:
            "Use relative touch movement and pair a hardware mouse when one is available."
        }
    }
}
