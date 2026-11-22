import SwiftUI

struct SessionToolbarSettings: View {
    @Environment(SettingsStore.self) private var store
    @Environment(\.dismiss) private var dismiss

    private var availableItems: [SessionToolbarItem] {
        #if os(macOS)
        SessionToolbarItem.allCases.filter { $0 != .keyboard }
        #else
        SessionToolbarItem.allCases
        #endif
    }

    var body: some View {
        let layout = SessionToolbarLayout(pinned: store.settings.toolbarItems, available: availableItems)
        let unpinned = layout.overflow(after: layout.pinned.count)
        Form {
            Section("Preview") {
                GeometryReader { geometry in
                    let count = layout.inlineCount(availableLength: geometry.size.width, buttonSize: 44)
                    FloatingBar {
                        ForEach(layout.pinned.prefix(count)) { item in
                            Image(systemName: item.systemImage)
                                .frame(width: 44, height: 44)
                                .accessibilityLabel(item.title)
                        }
                        if !layout.overflow(after: count).isEmpty {
                            Image(systemName: "ellipsis")
                                .frame(width: 44, height: 44)
                                .accessibilityLabel("More")
                        }
                    }
                    .fixedSize()
                    .frame(maxWidth: .infinity)
                }
                .frame(height: 56)
            }

            Section {
                ForEach(Array(layout.pinned.enumerated()), id: \.element.id) { index, item in
                    HStack {
                        Button {
                            store.settings.toolbarItems.removeAll { $0 == item }
                        } label: {
                            Label("Move to More", systemImage: "minus.circle.fill")
                                .labelStyle(.iconOnly)
                        }
                        .buttonStyle(.borderless)
                        .foregroundStyle(.red)
                        Label(item.title, systemImage: item.systemImage)
                        Spacer(minLength: 0)
                        moveButton(item, offset: -1).disabled(index == 0)
                        moveButton(item, offset: 1).disabled(index == layout.pinned.count - 1)
                    }
                }
            } header: {
                Text("On Toolbar")
            } footer: {
                Text("The order applies to all connections. Each session only shows supported actions.")
            }

            if !unpinned.isEmpty {
                Section("In More") {
                    ForEach(unpinned) { item in
                        Button {
                            store.settings.toolbarItems.append(item)
                        } label: {
                            Label(item.title, systemImage: "plus.circle.fill")
                        }
                        .accessibilityHint("Add to Toolbar")
                    }
                }
            }
        }
        .formStyle(.grouped)
        #if os(macOS)
        .frame(minWidth: 460, minHeight: 460)
        #endif
        .navigationTitle("Session Toolbar")
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("Done") { dismiss() } }
            ToolbarItem(placement: .primaryAction) {
                Button("Reset") { store.settings.toolbarItems = SessionToolbarItem.allCases }
            }
        }
    }

    private func moveButton(_ item: SessionToolbarItem, offset: Int) -> some View {
        Button {
            var items = store.settings.toolbarItems
            let visible = items.filter { availableItems.contains($0) }
            guard let index = visible.firstIndex(of: item),
                  visible.indices.contains(index + offset),
                  let from = items.firstIndex(of: item),
                  let to = items.firstIndex(of: visible[index + offset])
            else { return }
            items.swapAt(from, to)
            store.settings.toolbarItems = items
        } label: {
            Label(LocalizedStringKey(offset < 0 ? "Move Up" : "Move Down"),
                  systemImage: offset < 0 ? "chevron.up" : "chevron.down")
                .labelStyle(.iconOnly)
        }
        .buttonStyle(.borderless)
    }
}
