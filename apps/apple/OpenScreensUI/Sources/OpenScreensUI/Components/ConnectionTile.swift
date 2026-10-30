import SwiftUI

/// Screen-shaped preview tile for one saved computer.
public struct ConnectionTile: View {
    private let profile: ConnectionProfile

    public init(profile: ConnectionProfile) {
        self.profile = profile
    }

    public var body: some View {
        ZStack(alignment: .bottomLeading) {
            profile.palette.gradient

            motif

            LinearGradient(
                colors: [.clear, .black.opacity(0.10), .black.opacity(0.62)],
                startPoint: .top,
                endPoint: .bottom
            )

            VStack(alignment: .leading, spacing: 2) {
                HStack(alignment: .top) {
                    Image(systemName: profile.platform.symbolName)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.92))
                        .frame(width: 26, height: 26)
                        .background(.black.opacity(0.18), in: RoundedRectangle(cornerRadius: 7, style: .continuous))

                    Spacer(minLength: 8)

                    if profile.isFavorite {
                        Image(systemName: "star.fill")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(.white.opacity(0.9))
                            .accessibilityHidden(true)
                    }

                    if profile.section == .nearby {
                        StatusDot(color: Theme.Colors.success, diameter: 7)
                            .padding(.top, 4)
                    }
                }

                Spacer(minLength: 12)

                Text(profile.name)
                    .font(Theme.Typography.tileName)
                    .foregroundStyle(.white)
                    .lineLimit(1)
                    .shadow(color: .black.opacity(0.25), radius: 4, y: 1)

                Text(profile.subtitle)
                    .font(Theme.Typography.tileDetail)
                    .foregroundStyle(.white.opacity(0.74))
                    .lineLimit(1)
            }
            .padding(12)
        }
        .aspectRatio(1.55, contentMode: .fit)
        .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.tile, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: Theme.Radius.tile, style: .continuous)
                .strokeBorder(Theme.Colors.tileStroke, lineWidth: 1)
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
