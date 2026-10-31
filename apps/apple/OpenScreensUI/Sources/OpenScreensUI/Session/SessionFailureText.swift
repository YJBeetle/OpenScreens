import Foundation

/// Localized text for the core's machine-readable failure codes. `.unknown`
/// keeps the core's diagnostic reason, which is also what a server-provided
/// close reason looks like.
enum SessionFailureText {
    static func localized(_ kind: RemoteFailureKind, reason: String) -> String {
        switch kind {
        case .unknown:
            return reason
        case .network:
            return NSLocalizedString(
                "A network error interrupted the connection.",
                comment: "Connection failure: socket error"
            )
        case .connectionRefused:
            return NSLocalizedString(
                "The server refused the connection.",
                comment: "Connection failure: refused"
            )
        case .missingUsername:
            return NSLocalizedString(
                "The server requires Apple authentication, but no username is configured.",
                comment: "Connection failure: Apple account username missing"
            )
        case .missingPassword:
            return NSLocalizedString(
                "The server requires authentication, but no password is configured.",
                comment: "Connection failure: password missing"
            )
        case .authenticationFailed:
            return NSLocalizedString(
                "Authentication failed. Check the username and password.",
                comment: "Connection failure: rejected credentials"
            )
        case .unsupportedVersion:
            return NSLocalizedString(
                "The server's RFB version is not supported.",
                comment: "Connection failure: protocol version"
            )
        case .unsupportedSecurityType:
            return NSLocalizedString(
                "The server requires an authentication method this app does not support.",
                comment: "Connection failure: security type"
            )
        case .protocolViolation:
            return NSLocalizedString(
                "The server sent data this app could not understand.",
                comment: "Connection failure: protocol error"
            )
        case .decode:
            return NSLocalizedString(
                "The remote screen data could not be decoded.",
                comment: "Connection failure: decoder error"
            )
        case .tunnel:
            return NSLocalizedString(
                "The tunnel connection failed.",
                comment: "Connection failure: SSH, WireGuard or OpenVPN tunnel"
            )
        case .sshTunnel:
            return NSLocalizedString(
                "The SSH tunnel failed.",
                comment: "Connection failure: SSH tunnel"
            )
        case .closed:
            return NSLocalizedString(
                "The connection was closed.",
                comment: "Connection failure: transport closed"
            )
        case .invalidInput:
            return NSLocalizedString(
                "The connection settings are invalid.",
                comment: "Connection failure: invalid input"
            )
        }
    }
}
