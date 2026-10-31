import OpenScreensClient
import OpenScreensUI
import SwiftUI

struct IOSRootView: View {
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass

    var body: some View {
        if horizontalSizeClass == .regular {
            IPadLibraryView()
        } else {
            PhoneLibraryView()
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

    var id: String {
        switch self {
        case .editor(let route): "editor-\(route.id.uuidString)"
        case .settings: "settings"
        }
    }
}
