import Combine
import OpenScreensUI
import Sparkle

@MainActor
final class AppUpdater: NSObject, ObservableObject, SPUUpdaterDelegate {
    @Published private(set) var canCheck = false

    private var controller: SPUStandardUpdaterController?
    private var canCheckObservation: AnyCancellable?
    private var channel: UpdateChannel = .release

    func start(channel: UpdateChannel) {
        guard controller == nil,
              let key = Bundle.main.object(forInfoDictionaryKey: "SUPublicEDKey") as? String,
              Data(base64Encoded: key)?.count == 32 else { return }

        self.channel = channel
        let controller = SPUStandardUpdaterController(
            startingUpdater: false,
            updaterDelegate: self,
            userDriverDelegate: nil
        )
        self.controller = controller
        canCheckObservation = controller.updater.publisher(for: \.canCheckForUpdates)
            .sink { [weak self] value in
                Task { @MainActor in self?.canCheck = value }
            }
        controller.startUpdater()
    }

    func check() {
        controller?.checkForUpdates(nil)
    }

    func setChannel(_ channel: UpdateChannel) {
        self.channel = channel
    }

    func allowedChannels(for updater: SPUUpdater) -> Set<String> {
        Self.channels(for: channel)
    }

    private static func channels(for channel: UpdateChannel) -> Set<String> {
        switch channel {
        case .release: []
        case .prerelease: ["prerelease"]
        case .snapshot: ["snapshot"]
        }
    }
}
