import SwiftUI

/// Modifier and navigation key row shown above the software keyboard.
struct SessionKeyboardAccessoryRow: View {
    let model: SessionViewModel

    var body: some View {
        HStack(spacing: 6) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    keycap(title: "esc", label: "Escape") {
                        model.sendKey(.escape)
                    }
                    keycap(title: "tab", label: "Tab") {
                        model.sendKey(.tab)
                    }

                    modifierKey("⌃", label: "Control", modifier: .control)
                    modifierKey("⌥", label: "Option", modifier: .option)
                    modifierKey("⌘", label: "Command", modifier: .command)

                    Divider()
                        .frame(height: 22)
                        .padding(.horizontal, 2)

                    keycap(systemImage: "chevron.left", label: "Left Arrow") {
                        model.sendKey(.arrowLeft)
                    }
                    keycap(systemImage: "chevron.up", label: "Up Arrow") {
                        model.sendKey(.arrowUp)
                    }
                    keycap(systemImage: "chevron.down", label: "Down Arrow") {
                        model.sendKey(.arrowDown)
                    }
                    keycap(systemImage: "chevron.right", label: "Right Arrow") {
                        model.sendKey(.arrowRight)
                    }

                    Divider()
                        .frame(height: 22)
                        .padding(.horizontal, 2)

                    keycap(title: "return", label: "Return") {
                        model.sendKey(.returnKey)
                    }
                    keycap(systemImage: "delete.left", label: "Backspace") {
                        model.sendKey(.backspace)
                    }
                }
                .padding(.horizontal, 10)
            }

            Divider()
                .frame(height: 24)

            keycap(systemImage: "keyboard.chevron.compact.down", label: "Hide Keyboard") {
                model.setKeyboardActive(false)
            }
            .padding(.trailing, 10)
        }
        .frame(maxWidth: .infinity)
        .frame(height: 48)
        .background(.bar)
        .overlay(alignment: .top) {
            Divider()
        }
    }

    private func modifierKey(
        _ symbol: String,
        label: String,
        modifier: RemoteModifiers
    ) -> some View {
        let isSelected = model.keyboardModifiers.contains(modifier)
        return Button {
            model.toggleStickyModifier(modifier)
        } label: {
            Text(symbol)
                .font(.system(size: 16, weight: .medium))
                .foregroundStyle(isSelected ? Color.white : Color.primary)
                .frame(width: 38, height: 34)
                .background(
                    isSelected ? AnyShapeStyle(Theme.Colors.accent) : AnyShapeStyle(.quaternary.opacity(0.65)),
                    in: RoundedRectangle(cornerRadius: 8, style: .continuous)
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(NSLocalizedString(label, comment: "Keyboard key"))
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    private func keycap(title: String, label: String, action: @escaping () -> Void) -> some View {
        keycap(label: label, action: action) {
            Text(title)
                .font(.system(size: 13, weight: .medium))
        }
    }

    private func keycap(systemImage: String, label: String, action: @escaping () -> Void) -> some View {
        keycap(label: label, action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 13, weight: .semibold))
        }
    }

    private func keycap<Content: View>(
        label: String,
        action: @escaping () -> Void,
        @ViewBuilder content: () -> Content
    ) -> some View {
        Button(action: action) {
            content()
                .frame(minWidth: 36, minHeight: 34)
                .background(.quaternary.opacity(0.65), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(NSLocalizedString(label, comment: "Keyboard key"))
    }
}
