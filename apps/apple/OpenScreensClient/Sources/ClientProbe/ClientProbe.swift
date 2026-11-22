import Foundation
import OpenScreensClient
import OpenScreensUI

@main
struct ClientProbe {
    static func main() async {
        let env = ProcessInfo.processInfo.environment
        guard let host = env["OPENSCREENS_HOST"] else {
            print("OPENSCREENS_HOST is required")
            return
        }
        var profile = ConnectionProfile(
            name: "Probe",
            host: host,
            port: Int(env["OPENSCREENS_PORT"] ?? "5900") ?? 5900
        )
        profile.username = env["OPENSCREENS_USERNAME"] ?? ""
        profile.authentication = profile.username.isEmpty ? .vncPassword : .macOSAccount

        let session = UniFfiRemoteSession()
        let consumer = Task {
            var frames = 0
            for await event in session.events {
                switch event {
                case .state(let state):
                    print("state: \(state.label)")
                case .curtainModeSupport(let supported):
                    print("curtain mode support: \(supported)")
                case .serverFeatures(let appleRemote, let fileUpload, let fileDownload):
                    print("apple remote: \(appleRemote), upload: \(fileUpload), download: \(fileDownload)")
                case .framebufferSize(let width, let height):
                    print("desktop: \(width)x\(height)")
                case .displays(let displays):
                    print("displays: \(displays.map { "\($0.name) \($0.width)x\($0.height)" })")
                case .frame(let frame):
                    frames += 1
                    print("frame \(frames): \(frame.width)x\(frame.height) region=\(String(describing: frame.region)) bytes=\(frame.data.count)")
                    if frames >= 2 { exit(0) }
                case .clipboardRequest:
                    print("clipboard requested")
                case .clipboard(let text):
                    print("clipboard: \(text.count) chars")
                case .cursor(let shape):
                    print("cursor: \(shape.width)x\(shape.height)")
                case .pointerPosition(let x, let y):
                    print("pointer: \(x), \(y)")
                case .bell:
                    print("bell")
                case .transferProgress(let name, let fraction):
                    print("transfer: \(name ?? "-") \(fraction.map { String(format: "%.0f%%", $0 * 100) } ?? "")")
                case .transferFinished(let names, let destination):
                    print("transfer finished: \(names.joined(separator: ", ")) \(destination)")
                case .downloadProgress(let name, let received, let total):
                    print("download: \(name ?? "-") \(received)/\(total)")
                case .downloadComplete(let items, let error):
                    print("download complete: \(items.map(\.path).joined(separator: ", ")) \(error ?? "")")
                case .failure(let reason):
                    print("failure: \(reason)")
                }
            }
        }

        do {
            try await session.connect(profile: profile)
        } catch {
            print("connect failed: \(error)")
            exit(1)
        }
        try? await Task.sleep(for: .seconds(20))
        consumer.cancel()
    }
}
