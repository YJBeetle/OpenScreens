#if SCRCTL_XDB
import OpenScreensXdb
import SwiftUI

struct XdbDeviceList: Decodable, Sendable {
    let devices: [XdbDevice]
}

struct XdbDevice: Identifiable, Codable, Hashable, Sendable {
    var id: String { udid }
    let udid: String
    private let deviceName: String?
    let pairing: String?
    let state: String?

    var isReady: Bool { pairing == "record_present" || state == "paired" || state == "connected" }

    var name: String {
        guard let name = deviceName?.trimmingCharacters(in: .whitespacesAndNewlines),
              !name.isEmpty, name.caseInsensitiveCompare(udid) != .orderedSame else {
            return String(localized: "iPhone")
        }
        return name
    }

    private enum CodingKeys: String, CodingKey { case udid, deviceName = "name", pairing, state }

    // A discovery refresh can change metadata without changing the session target.
    static func == (lhs: Self, rhs: Self) -> Bool { lhs.udid == rhs.udid }

    func hash(into hasher: inout Hasher) { hasher.combine(udid) }

    static var port: UInt16 {
        ProcessInfo.processInfo.environment["XDB_PORT"].flatMap(UInt16.init) ?? 0
    }

    // Use a serial worker so a HID press and release cannot interleave with another input.
    private static let worker = DispatchQueue(label: "org.scrctl.xdb-session", qos: .userInitiated)
    private static let discoveryWorker = DispatchQueue(label: "org.scrctl.xdb-discovery", qos: .utility)

    static func perform<T: Sendable>(_ body: @Sendable @escaping () throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { continuation in
            worker.async { continuation.resume(with: Result(catching: body)) }
        }
    }

    static func discover() async throws -> [Self] {
        try await withCheckedThrowingContinuation { continuation in
            discoveryWorker.async {
                continuation.resume(with: Result {
                    let json = try iosListDevices(port: port, transport: .auto, timeoutMs: 3000)
                    return try JSONDecoder().decode(XdbDeviceList.self, from: Data(json.utf8)).devices
                        .filter { !$0.id.isEmpty && $0.isReady }
                })
            }
        }
    }

    static func close(_ session: IosSession) {
        worker.async {
            try? session.keyboard(usages: [])
            try? session.shutdown()
        }
    }

    static func image(_ frame: IosFrame) -> CGImage? {
        guard let provider = CGDataProvider(data: frame.pixels as CFData) else { return nil }
        return CGImage(
            width: Int(frame.width), height: Int(frame.height),
            bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: Int(frame.rowPitch),
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: [.byteOrder32Little, CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipFirst.rawValue)],
            provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent
        )
    }

    static func hidKeys(_ press: KeyPress) -> [UInt16]? {
        // Preserve local window shortcuts such as Command-W.
        if press.modifiers.contains(.command) { return nil }
        let usage: UInt16
        if press.key == .delete {
            usage = 42
        } else if press.key == .return {
            usage = 40
        } else if press.key == .tab {
            usage = 43
        } else if press.key == .space {
            usage = 44
        } else if press.key == .escape {
            usage = 41
        } else {
            let key = press.characters.lowercased()
            guard key.unicodeScalars.count == 1, let scalar = key.unicodeScalars.first else { return nil }
            switch scalar.value {
            case 97...122: usage = UInt16(scalar.value - 97 + 4)
            case 49...57: usage = UInt16(scalar.value - 49 + 30)
            case 48: usage = 39
            default: return nil
            }
        }
        var keys: [UInt16] = []
        if press.modifiers.contains(.shift) { keys.append(0xe1) }
        if press.modifiers.contains(.control) { keys.append(0xe0) }
        if press.modifiers.contains(.option) { keys.append(0xe2) }
        keys.append(usage)
        return keys
    }
}
#endif
