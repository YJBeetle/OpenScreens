import Foundation

/// A `vnc://host[:port]` link. Only the endpoint and user name travel in the
/// URL; passwords are never read from it and never persisted.
public struct VNCLink: Hashable, Sendable {
    public let host: String
    public let port: Int
    public let username: String

    public init(host: String, port: Int = 5900, username: String = "") {
        self.host = host
        self.port = port
        self.username = username
    }

    public static func parse(_ url: URL) -> VNCLink? {
        guard url.scheme?.lowercased() == "vnc" else { return nil }
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return nil }
        let host = components.host?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !host.isEmpty else { return nil }
        let port = components.port ?? 5900
        guard (1...65535).contains(port) else { return nil }
        return VNCLink(
            host: host,
            port: port,
            username: components.user?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        )
    }
}

extension ConnectionStore {
    /// Resolves a `vnc://` link to a library entry, adding one when the
    /// endpoint is new so the connection is available next time too.
    @discardableResult
    public func resolveLink(_ url: URL) -> ConnectionProfile? {
        guard let link = VNCLink.parse(url) else { return nil }
        if let existing = connections.first(where: {
            $0.host.caseInsensitiveCompare(link.host) == .orderedSame && $0.port == link.port
        }) {
            return existing
        }
        var profile = ConnectionProfile(
            name: link.host,
            host: link.host,
            port: link.port,
            authentication: link.username.isEmpty ? .vncPassword : .macOSAccount,
            username: link.username
        )
        profile = profile.normalized()
        add(profile)
        return profile
    }
}
