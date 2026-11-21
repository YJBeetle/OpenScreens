#if SCRCTL_XDB
import OpenScreensXdb
import SwiftUI

struct MacXdbSessionView: View {
    let device: XdbDevice
    @Environment(\.dismiss) private var dismiss
    @State private var session: IosSession?
    @State private var image: CGImage?
    @State private var failure: String?
    @FocusState private var focused: Bool

    var body: some View {
        Group {
            if let failure {
                ContentUnavailableView("Connection Ended", systemImage: "iphone.slash", description: Text(failure))
            } else if let image {
                Image(decorative: image, scale: 1)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .overlay {
                        GeometryReader { geometry in
                            Color.clear
                                .contentShape(Rectangle())
                                .gesture(SpatialTapGesture().onEnded { tap in
                                    focused = true
                                    guard let session, geometry.size.width > 0, geometry.size.height > 0 else { return }
                                    let x = min(max(tap.location.x / geometry.size.width, 0), 1)
                                    let y = min(max(tap.location.y / geometry.size.height, 0), 1)
                                    dispatch { try session.touch(x: x, y: y, down: true)
                                        try session.touch(x: x, y: y, down: false)
                                    }
                                })
                        }
                    }
                    .focusable()
                    .focused($focused)
                    .focusEffectDisabled()
                    .onAppear { focused = true }
                    .onKeyPress(phases: [.down, .repeat]) { press in
                        guard let session, let keys = XdbDevice.hidKeys(press) else { return .ignored }
                        dispatch { try session.keyboard(usages: keys)
                            try session.keyboard(usages: [])
                        }
                        return .handled
                    }
                    .accessibilityLabel("iPhone screen")
            } else {
                ProgressView("Connecting…")
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .navigationTitle(device.name)
        .toolbar { Button("Disconnect", systemImage: "xmark.circle", action: { dismiss() }) }
        .task { await mirror() }
    }

    private func dispatch(_ action: @Sendable @escaping () throws -> Void) {
        Task {
            do { try await XdbDevice.perform(action) }
            catch { if session != nil { failure = error.localizedDescription } }
        }
    }

    private func mirror() async {
        do {
            let udid = device.id
            let opened = try await XdbDevice.perform {
                try IosSession.open(port: XdbDevice.port, udid: udid, transport: .auto, hardwareDecode: true)
            }
            session = opened
            defer {
                session = nil
                XdbDevice.close(opened)
            }
            var serial: UInt64 = 0
            while !Task.isCancelled && failure == nil {
                let since = serial
                if let frame = try await XdbDevice.perform({ try opened.nextFrame(since: since, timeoutMs: 100) }) {
                    serial = frame.serial
                    if !Task.isCancelled { image = XdbDevice.image(frame) }
                }
            }
        } catch {
            if !Task.isCancelled { failure = error.localizedDescription }
        }
    }
}
#endif
