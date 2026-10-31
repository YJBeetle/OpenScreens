import Foundation
import OpenScreensCore

@main
struct Probe {
    static func main() async throws {
        let env = ProcessInfo.processInfo.environment
        guard let host = env["OPENSCREENS_HOST"] else {
            print("OPENSCREENS_HOST is required")
            return
        }
        let port = UInt16(env["OPENSCREENS_PORT"] ?? "5900") ?? 5900
        let config = SessionConfig(
            host: host,
            port: port,
            username: env["OPENSCREENS_USERNAME"],
            password: env["OPENSCREENS_PASSWORD"],
            shared: true,
            sshHost: nil,
            sshPort: nil,
            sshUsername: nil,
            sshPassword: nil,
            sshHostKeyFingerprint: nil
        )
        let session = try await RemoteSession.connect(config: config)
        print("connected name=\(session.serverName()) size=\(String(describing: session.size()))")

        var frames = 0
        while frames < 2 {
            guard let event = await session.nextEvent() else {
                print("session ended")
                break
            }
            switch event {
            case .connected(let width, let height, let name):
                print("connected \(width)x\(height) \(name)")
            case .frame(let sequence, let rects):
                frames += 1
                print("frame \(sequence): \(rects.count) rects")
                if frames == 1, let size = session.size() {
                    let rect = Rect(x: 0, y: 0, width: size.width, height: size.height)
                    if let data = session.copyRegion(rect: rect) {
                        let url = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("openscreens-swift-probe.bgra")
                        try data.write(to: url)
                        print("wrote \(data.count) bytes to \(url.path)")
                    }
                }
            case .resized(let width, let height):
                print("resized \(width)x\(height)")
            case .clipboard(let text):
                print("clipboard \(text.count) chars")
            case .bell:
                print("bell")
            case .disconnected(let reason):
                print("disconnected: \(reason)")
                return
            }
        }
    }
}
