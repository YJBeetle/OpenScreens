import SwiftUI

/// Screen-shaped preview tile for one saved computer.
public struct ConnectionTile: View {
    private let profile: ConnectionProfile

    private let preview: CGImage?

    public init(profile: ConnectionProfile, preview: CGImage? = nil) {
        self.preview = preview
        self.profile = profile
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Rectangle()
                .fill(.black)
                .aspectRatio(2.1, contentMode: .fit)
                .overlay {
                    if let preview {
                        Image(decorative: preview, scale: 1)
                            .resizable()
                            .scaledToFill()
                    } else {
                        profile.palette.gradient.overlay { motif }
                    }
                }
                .clipped()

            HStack(spacing: 8) {
                Image(systemName: profile.platform.symbolName)
                    .foregroundStyle(.secondary)
                VStack(alignment: .leading, spacing: 2) {
                    Text(profile.name)
                        .font(Theme.Typography.tileName)
                        .foregroundStyle(.primary)
                    Text(profile.subtitle)
                        .font(Theme.Typography.tileDetail)
                        .foregroundStyle(.secondary)
                }
                .lineLimit(1)
                Spacer(minLength: 0)
                if profile.isFavorite {
                    Image(systemName: "star.fill").font(.caption).foregroundStyle(.secondary)
                }
                if profile.section == .nearby {
                    StatusDot(color: Theme.Colors.success, diameter: 7)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
        }
        .background(.background)
        .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.tile, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: Theme.Radius.tile, style: .continuous)
                .strokeBorder(.primary.opacity(0.12), lineWidth: 1)
        }
        .shadow(color: .black.opacity(0.18), radius: 12, y: 5)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(profile.name), \(profile.platform.title), \(profile.subtitle)")
        .accessibilityHint("Connects to this remote screen")
        .accessibilityAddTraits(.isButton)
    }

    /// Faint screen outline and glare, drawn procedurally so no artwork ships.
    private var motif: some View {
        Canvas { context, size in
            let screen = CGRect(
                x: size.width * 0.52,
                y: size.height * 0.12,
                width: size.width * 0.58,
                height: size.height * 0.72
            )
            let rounded = Path(roundedRect: screen, cornerRadius: 9, style: .continuous)
            context.stroke(rounded, with: .color(.white.opacity(0.12)), lineWidth: 1)
            context.stroke(
                Path(roundedRect: screen.insetBy(dx: 7, dy: 7), cornerRadius: 5, style: .continuous),
                with: .color(.white.opacity(0.055)),
                lineWidth: 1
            )

            let glare = CGRect(
                x: -size.width * 0.2,
                y: size.height * 0.15,
                width: size.width * 0.8,
                height: size.width * 0.8
            )
            context.fill(
                Path(ellipseIn: glare),
                with: .radialGradient(
                    Gradient(colors: [.white.opacity(0.13), .white.opacity(0)]),
                    center: CGPoint(x: glare.midX, y: glare.midY),
                    startRadius: 0,
                    endRadius: glare.width / 2
                )
            )
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

struct TilePressStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.985 : 1)
            .brightness(configuration.isPressed ? -0.03 : 0)
            .animation(.snappy(duration: 0.16), value: configuration.isPressed)
    }
}

/// Colour chooser used by the connection editor.
public struct TilePalettePicker: View {
    @Binding private var selection: TilePalette

    public init(selection: Binding<TilePalette>) {
        _selection = selection
    }

    public var body: some View {
        HStack(spacing: 8) {
            ForEach(TilePalette.allCases) { palette in
                Button {
                    selection = palette
                } label: {
                    Circle()
                        .fill(palette.gradient)
                        .frame(width: 23, height: 23)
                        .overlay {
                            Circle()
                                .strokeBorder(.white.opacity(selection == palette ? 0.95 : 0.0), lineWidth: 2)
                                .padding(2)
                        }
                        .overlay {
                            Circle().strokeBorder(Theme.Colors.hairline, lineWidth: 1)
                        }
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(palette.title)
                .accessibilityAddTraits(selection == palette ? .isSelected : [])
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Tile colour")
    }
}
