import SwiftUI

/// One colour per league, so a theme decides the whole set rather than each
/// league carrying a literal that was picked against one background.
fileprivate struct LeagueColors {
    let football: Color
    let college: Color
    let basketball: Color
    let hockey: Color
    let baseball: Color
    let combat: Color
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
    /// active chip, the line down the guide -- anything meant to be the
    /// sharpest thing on screen reads from here.
    let highlight: Color
    /// The same colour, lighter. A fill that covers area cannot be the sharp
    /// one: at the strength a mark wants, a wash across half of every cell in
    /// the guide reads as the ground having changed colour. Lighter and it
    /// reads as fill, which is what it is.
    let highlightSoft: Color
    let selectionBorder: Color
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

#if os(tvOS)
fileprivate extension LineupPalette {
    /// The television's only look: charcoal, light grey and white.
    ///
    /// The four themes are the phone's now. Across a room, colour in the
    /// chrome competes with the picture, so the set gets one neutral room:
    /// a charcoal ground, panels a step or two lighter, light grey for what is
    /// secondary and white for what matters. The games and their teams bring
    /// the colour, and red is kept for the one thing that is live.
    static let television = LineupPalette(
        accent: rgb(0xF5F5F7), background: rgb(0x1A1A1C), surface: rgb(0x242427),
        raised: rgb(0x2E2E32), sidebar: rgb(0x151517), selected: rgb(0x29292C),
        focused: rgb(0x3A3A3E), warning: rgb(0xC7C7CC),
        highlight: rgb(0xFFFFFF), highlightSoft: rgb(0xD1D1D6),
        selectionBorder: rgb(0xFFFFFF),
        positive: rgb(0xF5F5F7), logoPlate: rgb(0xF2F2F7),
        line: rgb(0xFFFFFF).opacity(0.1),
        // One grey for every league: a league is named in words on the
        // television, never told apart by a colour that is not the theme's.
        leagues: LeagueColors(
            football: rgb(0xC7C7CC), college: rgb(0xC7C7CC), basketball: rgb(0xC7C7CC),
            hockey: rgb(0xC7C7CC), baseball: rgb(0xC7C7CC), combat: rgb(0xC7C7CC)
        )
    )
}
#endif

#if !os(tvOS)
fileprivate extension LineupPalette {
    /// The phone's only look. It was one of four themes, Signal, and the one
    /// the app opened in; the others are gone, and with them the setting.
    // Charcoal and broadcast red: a charcoal ground with surfaces that
    // climb clear of it, white type, and one red carrying every live and
    // active state in the app. It is the
    // red of the on-air dot, so the marks that say "active" and the
    // ones that say "live" are one colour rather than two that clash;
    // this was an electric blue, the only blue left in the app.
    //
    // White is the whole light-grey tier as well. Secondary text here
    // is the accent at reduced opacity, which is how the app has
    // always drawn it, and white at two thirds is a light grey -- so
    // the four colours asked for are four, not five.
    static let phone = LineupPalette(
        // Neutral greys, not cool ones. These leaned towards blue by a
        // dozen levels and more, which is invisible in a swatch and
        // reads as navy on a television -- most sets run a cool picture
        // and a dark grey with any blue in it is where that shows. The
        // colour in this theme is the accent's job and nothing else's.
        accent: rgb(0xFFFFFF), background: rgb(0x1C1C1E), surface: rgb(0x252528),
        raised: rgb(0x343438), sidebar: rgb(0x161618), selected: rgb(0x2C2C30),
        // Focus is a step up in the same grey. It used to lean towards
        // the accent, which is a good idea on paper and another source
        // of navy in a room; the accent's border and glow around a
        // focused thing say it far more clearly than its fill ever did.
        focused: rgb(0x3A3A3F), warning: rgb(0xFFB224),
        highlight: rgb(0xFF3347), highlightSoft: rgb(0xFF8A95),
        selectionBorder: rgb(0xFF3347),
        positive: rgb(0x3DDC84), logoPlate: rgb(0xEDF1F6),
        // A charcoal ground is lighter than carbon, so a hairline needs
        // a little more to draw on it than it did on near-black.
        line: rgb(0xFFFFFF).opacity(0.14),
        // A league chip in the accent's own colour reads as the app
        // talking rather than as the league it stands for. Combat's is
        // the deeper red of its own posters, not the accent's.
        leagues: LeagueColors(
            football: rgb(0x8B5CF6), college: rgb(0x00C2A8), basketball: rgb(0xFF6A1F),
            hockey: rgb(0xE14D8A), baseball: rgb(0x3DDC84), combat: rgb(0xD20A0A)
        )
    )
}
#endif

private func rgb(_ value: UInt32) -> Color {
    Color(
        red: Double((value >> 16) & 0xFF) / 255,
        green: Double((value >> 8) & 0xFF) / 255,
        blue: Double(value & 0xFF) / 255
    )
}

enum LineupStyle {
    #if os(tvOS)
    private static var palette: LineupPalette { .television }
    #else
    private static var palette: LineupPalette { .phone }
    #endif
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
    static var highlightSoft: Color { palette.highlightSoft }
    static var liveBorder: Color { palette.highlight.opacity(0.72) }
    static var line: Color { palette.line }
    static var text: Color { palette.accent }
    static var secondary: Color {
        #if os(tvOS)
        // The light grey: a solid colour rather than white at an opacity, so
        // it reads the same over a card, a row or the picture.
        return rgb(0xA1A1A6)
        #else
        return lightPurple.opacity(0.66)
        #endif
    }
    /// Playback chrome stays legible against video.
    static var mediaText: Color { text }
    static var mediaSecondary: Color { secondary }
    static var mediaAccent: Color { text }
    static var field: Color { lightPurple }
    static var live: Color { palette.highlight }
    static var warning: Color { palette.warning }
    /// Broadcast red is identity, not theme decoration. A channel that is on
    /// air uses the exact same red in every appearance and every theme.
    static var liveDot: Color { rgb(0xFF3347) }
    static var liveStatus: Color { liveDot }
    /// Confirmation -- a channel was found, a server answered.
    static var positive: Color { palette.positive }
    static var logoPlate: Color { palette.logoPlate }
    static let compactRadius: CGFloat = 8
    static let panelRadius: CGFloat = 12

    /// How far a focused thing rises, in two steps.
    ///
    /// A lift is proportional, so the same percentage moves a poster a long
    /// way and a chip barely at all. Matching the *feel* across the app
    /// therefore means two numbers, not one: a small control takes the larger
    /// step and a large surface the smaller. These were six numbers picked one
    /// at a time -- 1.02, 1.025, 1.03, 1.04, 1.055, 1.06 -- so crossing the
    /// app with the remote, the amount things jumped changed screen by screen.
    ///
    /// Cards, rows, posters and panels.
    static let cardLift: CGFloat = 1.03
    /// Chips, labels, header buttons, player controls.
    static let controlLift: CGFloat = 1.06

    static func leagueColor(_ league: SportsLeague) -> Color {
        let leagues = palette.leagues
        switch league {
        case .nfl: return leagues.football
        case .ncaaf: return leagues.college
        case .nba: return leagues.basketball
        case .nhl: return leagues.hockey
        case .mlb: return leagues.baseball
        case .ufc: return leagues.combat
        }
    }
}

extension LineupStyle {
    /// What the remote is on wears a light, see-through white layer.
    ///
    /// Focus used to be told five ways -- a fill a shade lighter, a blue rim,
    /// a lilac rim, a glow, a lift -- each screen choosing its own, so moving
    /// between them meant learning again where you were. It is one thing now,
    /// everywhere: the same faint white over the focused card, row, chip or
    /// button, light enough to read through, with one crisp edge.
    static let focusLayer = Color.white.opacity(0.12)
    static let focusEdge = Color.white.opacity(0.6)
}

extension View {
    /// The focus layer, in the shape of what is focused. Drawn over the
    /// content rather than behind it, so it shows on artwork and video as
    /// plainly as on a grey card.
    func lineupFocusLayer<S: InsettableShape>(_ focused: Bool, in shape: S, edge: Bool = true) -> some View {
        overlay {
            if focused {
                ZStack {
                    shape.fill(LineupStyle.focusLayer)
                    if edge { shape.strokeBorder(LineupStyle.focusEdge, lineWidth: 1.5) }
                }
                .allowsHitTesting(false)
            }
        }
    }
}

/// How high something sits, in steps.
///
/// Depth was eight different shadows: radius ten, twelve, eighteen, twenty-four,
/// twenty-eight and thirty-six, dropped five, six, seven, twelve or eighteen
/// points, at five opacities. A shadow's offset and blur are what tell the eye
/// where the light is and how far the thing is off the surface, so eight of
/// them read as eight different rooms.
///
/// Four steps, and a shadow now says how high something is rather than how
/// whoever wrote it felt that afternoon. Coloured glows are a separate matter
/// and keep their own values: a pulsing dot or the line down the guide is not
/// casting a shadow, it is giving off light.
enum LineupDepth {
    /// A card resting on the surface behind it.
    case resting
    /// The same height, for something that repeats many times on one screen.
    /// Ten rows each casting a full shadow is not depth, it is soot.
    case restingQuiet
    /// Raised, because the remote is on it.
    case lifted
    /// A panel over the screen.
    case overlay
    /// A panel that slid in from an edge, so it casts sideways rather than down.
    case overlayFromEdge

    var radius: CGFloat {
        switch self {
        case .resting, .restingQuiet: 12
        case .lifted: 18
        case .overlay, .overlayFromEdge: 28
        }
    }

    var offset: (x: CGFloat, y: CGFloat) {
        switch self {
        case .resting, .restingQuiet: (0, 6)
        case .lifted: (0, 12)
        case .overlay: (0, 16)
        case .overlayFromEdge: (10, 0)
        }
    }

    var opacity: Double {
        switch self {
        case .resting: 0.38
        case .restingQuiet: 0.18
        case .lifted: 0.55
        case .overlay, .overlayFromEdge: 0.42
        }
    }
}

extension View {
    /// A black shadow at one of the four heights. `on` is for the ones that
    /// only cast while focused, so the height is stated in one place and the
    /// call site only decides when.
    func lineupShadow(_ depth: LineupDepth, on: Bool = true) -> some View {
        shadow(color: .black.opacity(on ? depth.opacity : 0),
               radius: depth.radius, x: depth.offset.x, y: depth.offset.y)
    }
}

extension View {
    /// A region the remote can land in as a whole.
    ///
    /// tvOS moves focus geometrically: pressing up looks for something focusable
    /// directly above what is focused now, and if the search comes up empty
    /// nothing happens. In a screen of shelves that is easy to arrange by
    /// accident -- a card scrolled far to the right with only empty margin
    /// above it, a row of controls the next row does not line up with -- and
    /// the press is simply swallowed, which is the "stuck" feeling.
    ///
    /// Marking a region tells the engine it may hand focus to that region
    /// rather than to a particular view inside it, so a direction that finds no
    /// neighbour still arrives somewhere sensible instead of nowhere. And
    /// nowhere is not harmless on this platform: focus with no home falls back
    /// to the tab bar, where the next press changes tab.
    ///
    /// A no-op off tvOS, which has no such engine.
    func lineupFocusRegion() -> some View {
        #if os(tvOS)
        focusSection()
        #else
        self
        #endif
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
            let shape = RoundedRectangle(cornerRadius: 12, style: .continuous)
            configuration.label
                .foregroundStyle(LineupStyle.lightPurple)
                .padding(.horizontal, 20).padding(.vertical, 12)
                .background(LineupStyle.raised, in: shape)
                .lineupFocusLayer(focused, in: shape)
                .scaleEffect(focused ? LineupStyle.controlLift : 1)
                .animation(.easeOut(duration: 0.16), value: focused)
                .opacity(enabled ? (configuration.isPressed ? 0.75 : 1) : 0.45)
        }
    }
}

/// Glass controls that sit together -- a player's row of buttons. Glass
/// cannot sample other glass, so neighbours drawn apart each guess at what
/// is behind them; inside one container they are drawn as one sheet and
/// read as one set. `spacing` is how near two have to come before they run
/// together, kept under the gap between them so they never do.
struct LineupGlassGroup<Content: View>: View {
    var spacing: CGFloat = 8
    @ViewBuilder var content: Content

    var body: some View {
        if #available(iOS 26.0, tvOS 26.0, *) {
            GlassEffectContainer(spacing: spacing) { content }
        } else {
            content
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

    /// Glass for something pressed: it gives under a finger and catches the
    /// light the way the system's own controls do, where `lineupLiquidGlass`
    /// is a surface that only sits there. `prominent` lifts it a shade, for
    /// the one control a screen is about -- play and pause.
    @ViewBuilder
    func lineupGlassControl<S: InsettableShape, F: ShapeStyle>(
        _ shape: S, fallback: F, prominent: Bool = false
    ) -> some View {
        if #available(iOS 26.0, *) {
            self.glassEffect(prominent ? Glass.regular.tint(.white.opacity(0.16)).interactive()
                                       : Glass.regular.interactive(), in: shape)
        } else {
            self.background(fallback, in: shape)
                .overlay(shape.strokeBorder(.white.opacity(0.12), lineWidth: 1))
        }
    }

    func lineupGlassControl<S: InsettableShape>(_ shape: S, prominent: Bool = false) -> some View {
        lineupGlassControl(shape, fallback: Color.black.opacity(0.6), prominent: prominent)
    }

    /// The one action a message is waiting on, such as Retry: the system's
    /// prominent glass button, or its filled button below iOS 26.
    @ViewBuilder
    func lineupProminentButton() -> some View {
        if #available(iOS 26.0, *) {
            self.buttonStyle(.glassProminent)
        } else {
            self.buttonStyle(.borderedProminent)
        }
    }
}

/// The background behind a Form row: the Guide's flat grey. These rows were
/// Liquid Glass, which put a sheen under every setting; the settings now sit
/// on the same quiet ground as the Guide and the Live tab. Passed to
/// `listRowBackground`, which wants a view rather than a modifier.
struct LineupRowBackground: View {
    var body: some View {
        LineupStyle.raised
    }
}

/// A row drawn as the Guide draws a programme: flat grey, squared off at four
/// points, a hairline round it and a gap to the next. `listRowBackground`
/// fills the whole row, so the gap is padding around the cell.
struct LineupCellBackground: View {
    static let shape = RoundedRectangle(cornerRadius: 4, style: .continuous)

    var body: some View {
        Self.shape.fill(LineupStyle.raised)
            .overlay(Self.shape.strokeBorder(LineupStyle.line, lineWidth: 0.5))
            .padding(.horizontal, 12).padding(.vertical, 3)
    }
}

extension View {
    /// List rows as separate Guide cells, the content inside each cell's own
    /// margins.
    func lineupCellRows() -> some View {
        self.listRowBackground(LineupCellBackground())
            .listRowSeparator(.hidden)
            .listRowInsets(EdgeInsets(top: 13, leading: 26, bottom: 13, trailing: 26))
    }
}

extension View {
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
private struct LineupTVSelectableFocusedKey: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    /// Focus owned by `TVSelectable`, exposed to its label so artwork and pill
    /// controls can draw focus on their own exact shapes.
    var lineupTVSelectableFocused: Bool {
        get { self[LineupTVSelectableFocusedKey.self] }
        set { self[LineupTVSelectableFocusedKey.self] = newValue }
    }
}

extension View {
    // Liquid Glass came to the television with tvOS 26, and the shared views
    // that ask for it get it there as on the phone. Before tvOS 26 they keep
    // the theme's own fill and hairline, which is what they always looked
    // like, so nothing shifts in size, shape or spacing on an older system.
    // Focus is not the glass's business on the television: the app's own
    // focus layer and lift sit on top of it, as they sat on the fill.
    @ViewBuilder
    func lineupLiquidGlass<S: InsettableShape, F: ShapeStyle>(
        _ shape: S, clear: Bool = false, fallback: F,
        border: Color = .white.opacity(0.12), prominent: Bool = false
    ) -> some View {
        if #available(tvOS 26.0, *) {
            self.glassEffect(prominent ? Glass.regular.tint(.white.opacity(0.16))
                                       : (clear ? Glass.clear : Glass.regular), in: shape)
        } else {
            self.background(fallback, in: shape)
                .overlay(shape.strokeBorder(border, lineWidth: 1))
        }
    }

    func lineupLiquidGlass<S: InsettableShape>(_ shape: S, clear: Bool = false) -> some View {
        lineupLiquidGlass(shape, clear: clear, fallback: LineupStyle.surface, border: LineupStyle.line)
    }
}

/// A plain view that takes focus and a press, with no Button involved.
///
/// This is exactly what the Live and Guide screens do, and it is why they never
/// showed tvOS's light focus plate: the plate belongs to a button style, so the
/// way past it is not to style a Button but not to use one. Anything that wants
/// to look the same focused as unfocused goes through here.
struct TVSelectable<Content: View>: View {
    @FocusState private var focused: Bool
    /// Defaults to the card step, which is what most of these wrap. A control
    /// passes LineupStyle.controlLift.
    var scale: CGFloat = LineupStyle.cardLift
    /// The corner of the focus layer, which sits a little outside the label so
    /// a borderless row or a word gets a highlight with room around it.
    var fillRadius: CGFloat = 12
    /// Cards whose visible target is only their artwork, and controls that own
    /// a pill surface, turn this off and use `lineupTVSelectableFocused` to
    /// draw focus on that exact shape instead of around the whole label stack.
    var drawsFocusChrome = true
    let action: () -> Void
    var onFocusChange: ((Bool) -> Void)? = nil
    var requestInitialFocus = false
    @ViewBuilder var content: Content

    var body: some View {
        let focusShape = RoundedRectangle(cornerRadius: fillRadius, style: .continuous)
        content
            .environment(\.lineupTVSelectableFocused, focused)
            .contentShape(Rectangle())
            // The app's one focus layer. It sits around the lockup rather than
            // on its first and last pixels, leaving a gutter beside titles and
            // progress copy while keeping the card layout and shelf spacing
            // exactly where they were when focus moves.
            .lineupFocusLayer(focused && drawsFocusChrome, in: focusShape.inset(by: -6))
            .focusable()
            .focused($focused)
            .focusEffectDisabled()
            .onTapGesture(perform: action)
            .onChange(of: focused) { _, value in onFocusChange?(value) }
            .onAppear { if requestInitialFocus { focused = true } }
            // The cue lives here rather than in the content, because content
            // reading @Environment(\.isFocused) cannot be relied on to see the
            // focus this view owns -- and something wrapped in here would then
            // show no feedback at all. A lift and a dark shadow say where you
            // are without painting anything pale over the control.
            .scaleEffect(focused ? scale : 1)
            .lineupShadow(.lifted, on: focused && drawsFocusChrome)
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

    func focusLift(_ focused: Bool, scale: CGFloat = LineupStyle.cardLift) -> some View {
        self
            .scaleEffect(focused ? scale : 1)
            .offset(y: focused ? -3 : 0)
            // A pale shadow on a dark screen does not read as depth; it reads as
            // a light slab sitting behind the control. At this radius it spread
            // around the whole card and washed out the title under the art. A
            // dark shadow lifts the card without painting anything behind it.
            .lineupShadow(.lifted, on: focused)
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
                .font(.inter(.caption, .bold))
                .tracking(1.8)
                .foregroundStyle(LineupStyle.field)
            Text(title).foregroundColor(LineupStyle.lightPurple)
                .font(.inter(50, .semibold))
                .foregroundStyle(LineupStyle.text)
            if let detail {
                Text(detail).foregroundColor(LineupStyle.lightPurple)
                    .font(.inter(.title3))
                    .foregroundStyle(LineupStyle.secondary)
            }
        }
    }
}

struct LeagueMark: View {
    let league: SportsLeague

    var body: some View {
        Text(league.shortName).foregroundColor(LineupStyle.lightPurple)
            .font(.inter(16, .bold))
            .tracking(0.6)
            .foregroundStyle(LineupStyle.text)
            .frame(width: 72, height: 44)
            .background(LineupStyle.raised)
            .overlay(Rectangle().frame(height: 3).foregroundStyle(league.color), alignment: .bottom)
    }
}
