import SwiftUI

extension EnvironmentValues {
    /// Present only when this session's scene can provide an external display.
    @Entry var externalDisplayMirroring: Binding<Bool>? = nil
}

#if os(iOS)
import OpenScreensCanvas

struct SessionExternalDisplay: ViewModifier {
    let model: SessionViewModel

    func body(content: Content) -> some View {
        #if compiler(>=6.4) && !targetEnvironment(macCatalyst)
        if #available(iOS 27, *), UIDevice.current.userInterfaceIdiom == .pad {
            content.modifier(IPadExternalDisplay(model: model))
        } else {
            content
        }
        #else
        content
        #endif
    }
}

#if compiler(>=6.4) && !targetEnvironment(macCatalyst)
@available(iOS 27, *)
private struct IPadExternalDisplay: ViewModifier {
    let model: SessionViewModel
    @Environment(AppLock.self) private var lock: AppLock?
    @State private var available = false
    @State private var enabled = false

    func body(content: Content) -> some View {
        content
            .environment(\.externalDisplayMirroring, available && model.state.isConnected ? $enabled : nil)
            .sceneAccessory {
                if model.state.isConnected {
                    ExternalNonInteractiveAccessory(isEnabled: $enabled) {
                        ZStack {
                            Color.black
                            if model.state.isConnected && lock?.isLocked != true {
                                ProjectedDesktop(model: model)
                            }
                        }
                        .ignoresSafeArea()
                        .allowsHitTesting(false)
                    }
                    .onAvailabilityChange { available = $0 }
                }
            }
            .onChange(of: model.state.isConnected) { _, connected in
                if !connected { available = false }
            }
    }
}

@available(iOS 27, *)
private struct ProjectedDesktop: View {
    let model: SessionViewModel
    @Environment(\.displayScale) private var displayScale

    var body: some View {
        GeometryReader { proxy in
            ZStack {
                if hasFullViewport {
                    RemoteCanvasMirror(renderer: model.renderer)
                    SessionCursorOverlay(model: model) { size in
                        guard let frame = model.framebufferSize, frame.width > 0, frame.height > 0 else { return nil }
                        let scale = min(size.width / frame.width, size.height / frame.height)
                        let width = frame.width * scale
                        let height = frame.height * scale
                        return CGRect(x: (size.width - width) / 2, y: (size.height - height) / 2,
                                      width: width, height: height)
                    }
                }
            }
            .frame(width: proxy.size.width, height: proxy.size.height)
            .onChange(of: Int((proxy.size.width * displayScale).rounded()), initial: true) { _, pixels in
                model.setExternalDisplayPixelWidth(max(1, pixels))
            }
        }
        .onDisappear { model.setExternalDisplayPixelWidth(nil) }
    }

    // During the switch from a zoomed-in subscription the old texture may still
    // represent a crop. Wait for the full viewport before fitting it to the display.
    private var hasFullViewport: Bool {
        guard let viewport = model.viewport else { return true }
        return viewport.x == 0 && viewport.y == 0
            && viewport.width == viewport.framebufferWidth && viewport.height == viewport.framebufferHeight
    }
}
#endif
#endif
