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
        var host = components.host?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if host.hasPrefix("["), host.hasSuffix("]") {
            host.removeFirst()
            host.removeLast()
        }
        guard !host.isEmpty else { return nil }
        let port = components.port ?? 5900
        guard (1...65535).contains(port) else { return nil }
        return VNCLink(
            host: host,
            port: port,
            username: components.user?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        )
    }

    /// Parses text typed into a Quick Connect field. A bare `host[:port]` is
    /// treated as a `vnc://` address; other schemes are rejected.
    public static func parse(userInput: String) -> VNCLink? {
        let trimmed = userInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let candidate = trimmed.contains("://") ? trimmed : "vnc://\(trimmed)"
        guard let url = URL(string: candidate) else { return nil }
        return parse(url)
    }

    public var url: URL? {
        var components = URLComponents()
        components.scheme = "vnc"
        components.host = host.contains(":") ? "[\(host)]" : host
        if port != 5900 {
            components.port = port
        }
        if !username.isEmpty {
            components.user = username
        }
        return components.url
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
