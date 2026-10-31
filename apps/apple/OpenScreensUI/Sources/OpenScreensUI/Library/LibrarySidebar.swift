import SwiftUI

/// Source list shared by the macOS split view and iPad navigation.
public struct LibrarySidebar: View {
    @Binding private var selection: LibrarySection?
    @Environment(ConnectionStore.self) private var store

    public init(selection: Binding<LibrarySection?>) {
        _selection = selection
    }

    public var body: some View {
        List(selection: $selection) {
            Section {
                row(.nearby)
                row(.links)
            }
            Section("Services") {
                row(.connect)
            }
            Section("Custom") {
                row(.custom)
            }
        }
        .listStyle(.sidebar)
        .navigationTitle("OpenScreens")
    }

    private func row(_ section: LibrarySection) -> some View {
        HStack(spacing: 8) {
            Image(systemName: section.systemImage)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.secondary)
                .frame(width: 20)

            VStack(alignment: .leading, spacing: 1) {
                Text(section.title)
                if let status = section.serviceStatus {
                    Text(status)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }

            Spacer(minLength: 4)

            let count = store.count(in: section)
            if count > 0 {
                CountBadge(count: count)
            }
        }
        .tag(section)
        .accessibilityElement(children: .combine)
    }
}
