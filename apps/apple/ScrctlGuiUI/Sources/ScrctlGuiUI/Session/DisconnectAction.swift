import Foundation

public enum DisconnectAction: String, Codable, Sendable {
    case none, lockScreen, logOut, ctrlAltDelete
    case topLeft, topRight, bottomLeft, bottomRight

    public init(from decoder: Decoder) throws {
        let value = try decoder.singleValueContainer().decode(String.self)
        self = Self(rawValue: value) ?? .none
    }

    static func options(for platform: RemoteOS) -> [Self] {
        switch platform {
        case .macos: [.none, .lockScreen, .logOut, .topLeft, .topRight, .bottomLeft, .bottomRight]
        case .windows: [.none, .lockScreen, .ctrlAltDelete]
        default: [.none]
        }
    }

    var corner: RemoteHotCorner? {
        switch self {
        case .topLeft: .topLeft
        case .topRight: .topRight
        case .bottomLeft: .bottomLeft
        case .bottomRight: .bottomRight
        default: nil
        }
    }

    var title: String {
        if let corner {
            return String(format: NSLocalizedString("Hot Corner — %@", comment: "Disconnect action"), corner.title)
        }
        switch self {
        case .lockScreen: return NSLocalizedString("Lock Screen", comment: "Disconnect action")
        case .logOut: return NSLocalizedString("Log Out Remote User", comment: "Disconnect action")
        case .ctrlAltDelete: return NSLocalizedString("Ctrl-Alt-Delete", comment: "Disconnect action")
        default: return NSLocalizedString("None", comment: "Disconnect action")
        }
    }
}

extension ConnectionProfile {
    var supportedDisconnectAction: DisconnectAction {
        let action = disconnectAction ?? .none
        return DisconnectAction.options(for: platform).contains(action) ? action : .none
    }
}

struct SessionDisconnectRequest: Identifiable {
    let id = UUID()
    let action: DisconnectAction
    let interruptsTransfers: Bool

    var message: String {
        var lines: [String] = []
        if action != .none {
            lines.append(String(format: NSLocalizedString("Remote action before disconnecting: %@", comment: "Disconnect confirmation"), action.title))
        }
        if interruptsTransfers {
            lines.append(NSLocalizedString("Disconnecting will cancel the current file transfers.", comment: "Disconnect confirmation"))
        }
        if lines.isEmpty {
            return NSLocalizedString("The remote session ends. You can reconnect from the library at any time.", comment: "Disconnect confirmation")
        }
        return lines.joined(separator: "\n")
    }
}
