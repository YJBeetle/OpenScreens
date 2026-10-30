import OpenScreensClient
import OpenScreensUI
import SwiftUI

struct MacSessionWindow: View {
    let route: SessionRoute

    @Environment(ConnectionStore.self) private var store
    @Environment(\.dismissWindow) private var dismissWindow

    @State private var model: SessionViewModel?

    var body: some View {
        Group {
            if let model {
                SessionScreen(model: model, showsCloseButton: false) {
                    dismissWindow()
                }
                .navigationTitle(model.profile.name)
                .navigationSubtitle(model.profile.endpoint)
            } else if store.connection(id: route.profileID) != nil {
                ProgressView("Opening Session…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ContentUnavailableView(
                    "Connection Not Found",
                    systemImage: "questionmark.square.dashed",
                    description: Text("This connection was removed from the library.")
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(minWidth: 820, minHeight: 560)
        .onAppear(perform: createModelIfNeeded)
    }

    private func createModelIfNeeded() {
        guard model == nil, let profile = store.connection(id: route.profileID) else { return }
        model = SessionViewModel(profile: profile, service: UniFfiSessionService())
    }
}
