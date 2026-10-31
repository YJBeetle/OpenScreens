import AppIntents
import Foundation

/// Opens a remote session from Shortcuts or Siri. The session travels through
/// the same `vnc://` handler as links opened from other apps.
public struct ConnectIntent: AppIntent {
    public static let title: LocalizedStringResource = "Connect to VNC Server"
    public static let description = IntentDescription("Open a remote screen in OpenScreens.")
    public static let openAppWhenRun = true

    @Parameter(title: "Hostname")
    public var host: String

    @Parameter(title: "Port")
    public var port: Int?

    @Parameter(title: "User Name")
    public var username: String?

    public init() {}

    public static var parameterSummary: some ParameterSummary {
        Summary("Connect to \(\.$host)") {
            \.$port
            \.$username
        }
    }

    public func perform() async throws -> some IntentResult & OpensIntent {
        let host = host.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !host.isEmpty else { throw VNCIntentError.invalidHost }
        let port = port ?? 5900
        guard (1...65535).contains(port) else { throw VNCIntentError.invalidPort }
        let username = (username ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let link = VNCLink(host: host, port: port, username: username)
        guard let url = link.url else { throw VNCIntentError.invalidHost }
        return .result(opensIntent: OpenURLIntent(url))
    }
}

enum VNCIntentError: Error, CustomLocalizedStringResourceConvertible {
    case invalidHost
    case invalidPort

    var localizedStringResource: LocalizedStringResource {
        switch self {
        case .invalidHost: "Enter a hostname or IP address."
        case .invalidPort: "The port must be between 1 and 65535."
        }
    }
}
