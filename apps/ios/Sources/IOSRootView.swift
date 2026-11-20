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
            IOSSessionPresenter(profile: profile, store: store)
        }
        .onOpenURL(perform: openLink)
    }

    private func openLink(_ url: URL) {
        guard let profile = store.resolveLink(url) else { return }
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

    init(profile: ConnectionProfile, store: ConnectionStore) {
        self.profile = profile
        _model = State(initialValue: SessionViewModel(
            profile: profile,
            service: UniFfiSessionService(),
            connectionStore: store
        ))
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

    @Environment(ConnectionStore.self) private var store
    let profile: ConnectionProfile?
    @State private var model: SessionViewModel?

    var body: some View {
        Group {
            if let model {
                SessionScreen(model: model) { dismissWindow() }
            } else if profile == nil {
                ContentUnavailableView {
                    Label("Connection Not Found", systemImage: "questionmark.folder")
                } description: {
                    Text("This connection was removed from the library.")
                }
            } else {
                ProgressView()
            }
        }
        .onChange(of: profile?.id, initial: true) {
            // A Bonjour advertisement can disappear without ending the session.
            if let profile, model?.profile.id != profile.id {
                model = SessionViewModel(profile: profile, service: UniFfiSessionService(), connectionStore: store)
            }
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
