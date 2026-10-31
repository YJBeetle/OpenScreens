import SwiftUI

/// Translucent capsule used for floating toolbars, tab bars and session controls.
public struct FloatingBar<Content: View>: View {
    private let content: Content

    public init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    public var body: some View {
        HStack(spacing: 2) {
            content
        }
        .padding(6)
        .glassSurface(in: Capsule(style: .continuous))
        .shadow(color: .black.opacity(0.28), radius: 18, y: 8)
    }
}

/// Square, icon-only control used inside floating bars.
public struct FloatingIconButton: View {
    private let systemImage: String
    private let title: String
    private let isSelected: Bool
    private let action: () -> Void

    public init(
        systemImage: String,
        title: String,
        isSelected: Bool = false,
        action: @escaping () -> Void
    ) {
        self.systemImage = systemImage
        self.title = title
        self.isSelected = isSelected
        self.action = action
    }

    public var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 16, weight: .medium))
                .symbolVariant(isSelected ? .fill : .none)
                .foregroundStyle(isSelected ? Color.white : Color.primary)
                .frame(width: 40, height: 40)
                .background {
                    if isSelected {
                        Circle().fill(Theme.Colors.accent)
                    }
                }
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(NSLocalizedString(title, comment: "Floating control"))
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

/// Small capsule badge used for counts in the sidebar.
public struct CountBadge: View {
    private let count: Int

    public init(count: Int) {
        self.count = count
    }

    public var body: some View {
        Text("\(count)")
            .font(.caption2.weight(.semibold))
            .monospacedDigit()
            .foregroundStyle(.secondary)
            .padding(.horizontal, 7)
            .padding(.vertical, 2)
            .background(.quaternary.opacity(0.7), in: Capsule())
            .accessibilityHidden(true)
    }
}

public struct StatusDot: View {
    private let color: Color
    private let diameter: CGFloat

    public init(color: Color, diameter: CGFloat = 8) {
        self.color = color
        self.diameter = diameter
    }

    public var body: some View {
        Circle()
            .fill(color)
            .frame(width: diameter, height: diameter)
            .overlay {
                Circle().strokeBorder(.white.opacity(0.35), lineWidth: 0.5)
            }
            .accessibilityHidden(true)
    }
}
