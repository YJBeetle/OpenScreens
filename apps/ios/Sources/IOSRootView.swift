import OpenScreensClient
import OpenScreensUI
import SwiftUI

struct IOSRootView: View {
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @Environment(ConnectionStore.self) private var store
    @Environment(\.openWindow) private var openWindow

    @State private var linkProfile: ConnectionProfile?

    var body: some View {
        Group {
            if horizontalSizeClass == .regular {
                IPadLibraryView()
            } else {
                PhoneLibraryView()
            }
        }
        .fullScreenCover(item: $linkProfile) { profile in
            IOSSessionPresenter(profile: profile)
        }
        .onOpenURL(perform: openLink)
    }

    private func openLink(_ url: URL) {
        guard let profile = store.resolveLink(url) else { return }
        store.markConnected(id: profile.id)
        if horizontalSizeClass == .regular {
            openWindow(id: IOSSessionScene.id, value: profile.id)
        } else {
            linkProfile = profile
        }
    }
}

struct IOSSessionPresenter: View {
    @Environment(\.dismiss) private var dismiss

    private let profile: ConnectionProfile
    @State private var model: SessionViewModel

    init(profile: ConnectionProfile) {
        self.profile = profile
        _model = State(initialValue: SessionViewModel(profile: profile, service: UniFfiSessionService()))
    }

    var body: some View {
        SessionScreen(model: model) {
            dismiss()
        }
    }
}

enum IOSSessionScene {
    static let id = "session"
}

/// Session hosted in its own iPad window, dismissed with the window controls.
struct IOSSessionWindow: View {
    @Environment(\.dismissWindow) private var dismissWindow

    @State private var model: SessionViewModel

    init(profile: ConnectionProfile) {
        _model = State(initialValue: SessionViewModel(profile: profile, service: UniFfiSessionService()))
    }

    var body: some View {
        SessionScreen(model: model) {
            dismissWindow()
        }
    }
}

enum IOSLibrarySheet: Identifiable {
    case editor(IOSEditorRoute)
    case settings
    case quickConnect

    var id: String {
        switch self {
        case .editor(let route): "editor-\(route.id.uuidString)"
        case .settings: "settings"
        case .quickConnect: "quick-connect"
        }
    }
}
