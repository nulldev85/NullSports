import SwiftUI

enum LineupTheme: String, CaseIterable, Identifiable {
    case velvet
    case grandstand
    case pitLane

    static let storageKey = "lineup.appearance.theme"
    var id: String { rawValue }

    var name: String {
        switch self {
        case .velvet: "Velvet"
        case .grandstand: "Grandstand"
        case .pitLane: "Pit Lane"
        }
    }

    var detail: String {
        switch self {
        case .velvet: "Plum & lilac"
        case .grandstand: "Ink & champagne"
        case .pitLane: "Graphite & copper"
        }
    }

    fileprivate var palette: LineupPalette {
        switch self {
        case .velvet:
            LineupPalette(
                accent: rgb(0xD4C7E1), background: rgb(0x221D27), surface: rgb(0x28212D),
                raised: rgb(0x332B3A), sidebar: rgb(0x251F2A), selected: rgb(0x2D2633),
                focused: rgb(0x3D3444), warning: rgb(0xC78259)
            )
        case .grandstand:
            LineupPalette(
                accent: rgb(0xE8D9B5), background: rgb(0x07131D), surface: rgb(0x0D1C28),
                raised: rgb(0x152938), sidebar: rgb(0x0A1823), selected: rgb(0x132633),
                focused: rgb(0x203A4B), warning: rgb(0xD89A56)
            )
        case .pitLane:
            LineupPalette(
                accent: rgb(0xE8A66A), background: rgb(0x101112), surface: rgb(0x181A1C),
                raised: rgb(0x24272A), sidebar: rgb(0x141618), selected: rgb(0x202326),
                focused: rgb(0x32363A), warning: rgb(0xE0B15B)
            )
        }
    }
}

fileprivate struct LineupPalette {
    let accent: Color
    let background: Color
    let surface: Color
    let raised: Color
    let sidebar: Color
    let selected: Color
    let focused: Color
    let warning: Color
}

private func rgb(_ value: UInt32) -> Color {
    Color(
        red: Double((value >> 16) & 0xFF) / 255,
        green: Double((value >> 8) & 0xFF) / 255,
        blue: Double(value & 0xFF) / 255
    )
}

enum LineupStyle {
    static var theme: LineupTheme {
        // The TV app ships Velvet only, so a palette chosen on a phone cannot
        // follow the same account onto a television and restyle it there.
        #if os(tvOS)
        return .velvet
        #else
        return LineupTheme(rawValue: UserDefaults.standard.string(forKey: LineupTheme.storageKey) ?? "") ?? .velvet
        #endif
    }
    private static var palette: LineupPalette { theme.palette }
    static var lightPurple: Color { palette.accent }
    // White is reserved for selected Live card frames.
    static let liveSelectionBorder = Color.white
    static var background: Color { palette.background }
    static var surface: Color { palette.surface }
    static var raised: Color { palette.raised }
    static var sidebarRow: Color { palette.sidebar }
    static var selected: Color { palette.selected }
    static var focused: Color { palette.focused }
    static var liveSurface: Color { palette.selected }
    static var liveBorder: Color { lightPurple.opacity(0.72) }
    static var line: Color { lightPurple.opacity(0.11) }
    static var text: Color { lightPurple }
    static var secondary: Color { lightPurple }
    static var field: Color { lightPurple }
    static var live: Color { lightPurple }
    static var warning: Color { palette.warning }
}

struct LineupThemeSwatch: View {
    let theme: LineupTheme

    var body: some View {
        HStack(spacing: 0) {
            theme.palette.background
            theme.palette.surface
            theme.palette.accent
        }
        .frame(width: 54, height: 24)
        .clipShape(Capsule())
        .overlay(Capsule().stroke(.white.opacity(0.14), lineWidth: 1))
        .accessibilityHidden(true)
    }
}

extension View {
    /// The app's button style, with tvOS's own focus effect switched off.
    ///
    /// `LineupButtonStyle` already draws focus -- a filled background and a
    /// lift. tvOS adds its plate on top of that, sized to the whole button, so
    /// a focused button carried two highlights and the outer one was enormous.
    /// Applying the style is what asks for that plate, so the two travel
    /// together here and a new button cannot pick up one without the other.
    func lineupButtonStyle() -> some View {
        buttonStyle(LineupButtonStyle()).focusEffectDisabled()
    }
}

struct LineupButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        PurpleButtonLabel(configuration: configuration)
    }

    private struct PurpleButtonLabel: View {
        @Environment(\.isFocused) private var focused
        @Environment(\.isEnabled) private var enabled
        let configuration: ButtonStyle.Configuration

        var body: some View {
            configuration.label
                .foregroundStyle(LineupStyle.lightPurple)
                .padding(.horizontal, 20).padding(.vertical, 12)
                .background(focused ? LineupStyle.focused : LineupStyle.raised,
                            in: RoundedRectangle(cornerRadius: 12))
                .opacity(enabled ? (configuration.isPressed ? 0.75 : 1) : 0.45)
        }
    }
}

#if os(iOS)
extension View {
    // Apple's Liquid Glass for the iPhone app's chrome and floating controls.
    // Below iOS 26 the same surfaces keep the theme's own fill and hairline, so
    // nothing shifts in size, shape or spacing on older systems.
    @ViewBuilder
    func lineupLiquidGlass<S: InsettableShape, F: ShapeStyle>(
        _ shape: S, clear: Bool = false, fallback: F,
        border: Color = .white.opacity(0.12)
    ) -> some View {
        if #available(iOS 26.0, *) {
            self.glassEffect(clear ? .clear : .regular, in: shape)
        } else {
            self.background(fallback, in: shape)
                .overlay(shape.strokeBorder(border, lineWidth: 1))
        }
    }

    // The floating-control default: dark scrim and hairline below iOS 26.
    func lineupLiquidGlass<S: InsettableShape>(_ shape: S, clear: Bool = false) -> some View {
        lineupLiquidGlass(shape, clear: clear, fallback: Color.black.opacity(0.6))
    }

    // iOS 26 draws the tab bar in Liquid Glass itself. Forcing an opaque
    // toolbar background paints over that, so the theme colour is applied
    // only below iOS 26, where there is no glass to preserve.
    @ViewBuilder
    func lineupTabBarBackground(_ color: Color) -> some View {
        if #available(iOS 26.0, *) {
            self
        } else {
            self.toolbarBackground(color, for: .tabBar)
                .toolbarBackground(.visible, for: .tabBar)
        }
    }
}
#endif

extension View {
    @ViewBuilder
    func nullGlass(clear: Bool = false, cornerRadius: CGFloat = 18) -> some View {
        self
            .background(LineupStyle.surface.opacity(clear ? 0.72 : 0.94), in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous).stroke(LineupStyle.line, lineWidth: 1))
    }

    func focusLift(_ focused: Bool, scale: CGFloat = 1.035) -> some View {
        self
            .scaleEffect(focused ? scale : 1)
            .offset(y: focused ? -3 : 0)
            // A pale shadow on a dark screen does not read as depth; it reads as
            // a light slab sitting behind the control. At this radius it spread
            // around the whole card and washed out the title under the art. A
            // dark shadow lifts the card without painting anything behind it.
            .shadow(color: focused ? .black.opacity(0.5) : .clear, radius: 18, y: 12)
            .zIndex(focused ? 10 : 0)
            .animation(.spring(response: 0.25, dampingFraction: 0.78), value: focused)
    }
}

struct PageTitle: View {
    let eyebrow: String
    let title: String
    let detail: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(eyebrow.uppercased()).foregroundColor(LineupStyle.lightPurple)
                .font(.caption.weight(.bold))
                .tracking(1.8)
                .foregroundStyle(LineupStyle.field)
            Text(title).foregroundColor(LineupStyle.lightPurple)
                .font(.system(size: 50, weight: .semibold))
                .foregroundStyle(LineupStyle.text)
            if let detail {
                Text(detail).foregroundColor(LineupStyle.lightPurple)
                    .font(.title3)
                    .foregroundStyle(LineupStyle.secondary)
            }
        }
    }
}

struct LeagueMark: View {
    let league: SportsLeague

    var body: some View {
        Text(league.shortName).foregroundColor(LineupStyle.lightPurple)
            .font(.system(size: 16, weight: .bold))
            .tracking(0.6)
            .foregroundStyle(LineupStyle.text)
            .frame(width: 72, height: 44)
            .background(LineupStyle.raised)
            .overlay(Rectangle().frame(height: 3).foregroundStyle(league.color), alignment: .bottom)
    }
}
