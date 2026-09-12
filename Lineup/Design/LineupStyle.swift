import SwiftUI

enum LineupTheme: String, CaseIterable, Identifiable {
    // Declaration order is the order the settings screens list them, and the
    // default belongs at the top.
    case signal
    case velvet

    static let storageKey = "lineup.appearance.theme"
    var id: String { rawValue }

    var name: String {
        switch self {
        case .velvet: "Velvet"
        case .signal: "Signal"
        }
    }

    var detail: String {
        switch self {
        case .velvet: "Plum & lilac"
        case .signal: "Carbon & electric"
        }
    }

    fileprivate var palette: LineupPalette {
        switch self {
        case .velvet:
            LineupPalette(
                accent: rgb(0xD4C7E1), background: rgb(0x221D27), surface: rgb(0x28212D),
                raised: rgb(0x332B3A), sidebar: rgb(0x251F2A), selected: rgb(0x2D2633),
                focused: rgb(0x3D3444), warning: rgb(0xC78259),
                // Velvet has never had a colour of its own apart from its text
                // tint, so its highlight is that tint: nothing about the theme
                // changes by giving the slot a value.
                highlight: rgb(0xD4C7E1), selectionBorder: rgb(0xFFFFFF),
                liveDot: rgb(0xFA4757), positive: rgb(0x6BC77A), logoPlate: rgb(0xFFFFFF),
                line: rgb(0xD4C7E1).opacity(0.11),
                leagues: LeagueColors(
                    football: rgb(0x9C6E4F), college: rgb(0x9E754D), basketball: rgb(0xB36347),
                    hockey: rgb(0x738C96), baseball: rgb(0x6B7DA8)
                )
            )
        case .signal:
            // Carbon and electric. Velvet is warm, soft and low-contrast: plum
            // ground, lilac text, nothing saturated anywhere. This is the
            // opposite on every axis -- a cool near-black ground, crisp cool
            // white type, and one saturated cyan that carries every live and
            // active state in the app.
            LineupPalette(
                accent: rgb(0xE8EDF7), background: rgb(0x06080B), surface: rgb(0x10141C),
                raised: rgb(0x1B212B), sidebar: rgb(0x090C11), selected: rgb(0x151C26),
                // Focus leans towards the theme's own colour rather than just
                // sitting a shade lighter. On a television, where something is
                // always focused, that one step does more than any other.
                focused: rgb(0x1E2C37), warning: rgb(0xFFB224),
                highlight: rgb(0x22D3EE), selectionBorder: rgb(0x22D3EE),
                liveDot: rgb(0xFF2D55), positive: rgb(0x3DDC84), logoPlate: rgb(0xE4EAF4),
                // A hairline at Velvet's weight all but vanishes on a ground
                // this dark, and a card with no edge is a card that floats
                // nowhere. Slightly stronger, and it draws.
                line: rgb(0xE8EDF7).opacity(0.16),
                leagues: LeagueColors(
                    football: rgb(0x3E6BFF), college: rgb(0x00C2A8), basketball: rgb(0xFF6A1F),
                    hockey: rgb(0x8B5CF6), baseball: rgb(0x3DDC84)
                )
            )
        }
    }
}

/// One colour per league, so a theme decides the whole set rather than each
/// league carrying a literal that was picked against one background.
fileprivate struct LeagueColors {
    let football: Color
    let college: Color
    let basketball: Color
    let hockey: Color
    let baseball: Color
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
    /// The theme's own colour, as opposed to its text tint. Live borders, the
    /// active chip, a progress fill -- anything meant to be the sharpest thing
    /// on screen reads from here.
    let highlight: Color
    let selectionBorder: Color
    let liveDot: Color
    let positive: Color
    /// A team badge arrives as artwork drawn for a light background, so a pale
    /// rim is thrown behind its own silhouette to keep a dark crest legible.
    /// Which pale is the theme's call.
    let logoPlate: Color
    /// Dividers and card edges. Derived from the text tint in both themes, but
    /// at its own weight: how far a hairline has to carry depends on how dark
    /// the ground under it is.
    let line: Color
    let leagues: LeagueColors
}

private func rgb(_ value: UInt32) -> Color {
    Color(
        red: Double((value >> 16) & 0xFF) / 255,
        green: Double((value >> 8) & 0xFF) / 255,
        blue: Double(value & 0xFF) / 255
    )
}

enum LineupStyle {
    /// Both platforms read the same stored choice. The television used to be
    /// pinned to Velvet because the themes it could have picked were not
    /// finished for it; the two that remain are, and each has its own settings
    /// entry to choose from.
    /// Signal is what the app looks like out of the box. A device that has
    /// been through the settings screen keeps whatever was chosen there --
    /// changing the default is not a reason to overrule someone's pick.
    static var theme: LineupTheme {
        LineupTheme(rawValue: UserDefaults.standard.string(forKey: LineupTheme.storageKey) ?? "") ?? .signal
    }
    private static var palette: LineupPalette { theme.palette }
    /// The theme's text tint. Named for Velvet's lilac, which is no longer the
    /// only thing it can be.
    static var lightPurple: Color { palette.accent }
    /// The frame on a selected Live card: the one place a theme is allowed its
    /// brightest edge.
    static var liveSelectionBorder: Color { palette.selectionBorder }
    static var background: Color { palette.background }
    static var surface: Color { palette.surface }
    static var raised: Color { palette.raised }
    static var sidebarRow: Color { palette.sidebar }
    static var selected: Color { palette.selected }
    static var focused: Color { palette.focused }
    static var liveSurface: Color { palette.selected }
    static var highlight: Color { palette.highlight }
    static var liveBorder: Color { palette.highlight.opacity(0.72) }
    static var line: Color { palette.line }
    static var text: Color { lightPurple }
    static var secondary: Color { lightPurple }
    static var field: Color { lightPurple }
    static var live: Color { palette.highlight }
    static var warning: Color { palette.warning }
    /// The pulsing dot that marks something as on air.
    static var liveDot: Color { palette.liveDot }
    /// Confirmation -- a channel was found, a server answered.
    static var positive: Color { palette.positive }
    static var logoPlate: Color { palette.logoPlate }

    static func leagueColor(_ league: SportsLeague) -> Color {
        let leagues = palette.leagues
        switch league {
        case .nfl: return leagues.football
        case .ncaaf: return leagues.college
        case .nba: return leagues.basketball
        case .nhl: return leagues.hockey
        case .mlb: return leagues.baseball
        }
    }
}

struct LineupThemeSwatch: View {
    let theme: LineupTheme

    var body: some View {
        HStack(spacing: 0) {
            theme.palette.background
            theme.palette.surface
            theme.palette.accent
            theme.palette.highlight
        }
        .frame(width: 64, height: 24)
        .clipShape(Capsule())
        .overlay(Capsule().stroke(theme.palette.accent.opacity(0.18), lineWidth: 1))
        .accessibilityHidden(true)
    }
}

extension View {
    /// Rebuilds this subtree whenever the theme changes.
    ///
    /// Every colour in the app is read from `LineupStyle`, which answers from
    /// stored state rather than from anything SwiftUI watches. A view is only
    /// asked for its body again when one of its own inputs changes, and a theme
    /// is not an input to any of them -- so on a switch the screens that
    /// happened to re-render took the new palette and the rest kept the old
    /// one, which is the half-repainted screen this fixes.
    ///
    /// Observing the stored value higher up does not help, because the same
    /// rule applies one level down: a panel whose title and rows have not
    /// changed is not rebuilt just because its parent was. Nothing short of
    /// threading the theme through every view's inputs makes the dependency
    /// real, so the subtree is re-identified instead and drawn again from
    /// scratch in the new palette.
    ///
    /// Apply it below whatever holds state worth keeping -- the selected tab
    /// sits above this, so switching a theme does not also move the viewer.
    func lineupThemeScope(_ theme: String) -> some View {
        id(theme)
    }

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

#if os(tvOS)
/// A plain view that takes focus and a press, with no Button involved.
///
/// This is exactly what the Live and Guide screens do, and it is why they never
/// showed tvOS's light focus plate: the plate belongs to a button style, so the
/// way past it is not to style a Button but not to use one. Anything that wants
/// to look the same focused as unfocused goes through here.
struct TVSelectable<Content: View>: View {
    @FocusState private var focused: Bool
    var scale: CGFloat = 1.06
    /// A borderless row draws nothing of its own, so a lift and a shadow have
    /// no shape to lift. Such a row asks for a fill instead, and it is painted
    /// here for the same reason the lift is: this is where focus is known.
    var fill: Color?
    var fillRadius: CGFloat = 12
    let action: () -> Void
    @ViewBuilder var content: Content

    var body: some View {
        content
            .contentShape(Rectangle())
            .background(focused ? (fill ?? .clear) : .clear,
                in: RoundedRectangle(cornerRadius: fillRadius, style: .continuous))
            .focusable()
            .focused($focused)
            .focusEffectDisabled()
            .onTapGesture(perform: action)
            // The cue lives here rather than in the content, because content
            // reading @Environment(\.isFocused) cannot be relied on to see the
            // focus this view owns -- and something wrapped in here would then
            // show no feedback at all. A lift and a dark shadow say where you
            // are without painting anything pale over the control.
            .scaleEffect(focused ? scale : 1)
            .shadow(color: .black.opacity(focused ? 0.55 : 0), radius: 18, y: 12)
            .zIndex(focused ? 10 : 0)
            .animation(.spring(response: 0.24, dampingFraction: 0.8), value: focused)
    }
}
#endif

#if os(tvOS)
/// A button that draws nothing but its label.
///
/// tvOS's own button styles paint a light plate behind a focused button. That
/// plate is what put a white slab behind a focused poster and chip, and it is
/// drawn by the style, not by the focus effect, so focusEffectDisabled() never
/// touched it. Replacing the style replaces that drawing entirely.
struct LineupFlatButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View { configuration.label }
}
#endif

extension View {
    /// A button with no styling of its own, on either platform.
    func lineupFlatButton() -> some View {
        #if os(tvOS)
        return buttonStyle(LineupFlatButtonStyle()).focusEffectDisabled()
        #else
        return buttonStyle(.plain)
        #endif
    }
}

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
