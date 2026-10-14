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
    let tennis: Color
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
        // The reference app's Settings, measured: a dark grey ground, cards a
        // step lighter, and a step lighter again for what is chosen, pressed
        // or in focus. Nothing in the app sits on black but a picture.
        accent: rgb(0xFFFFFF), background: rgb(0x1C1C1E), surface: rgb(0x2C2C2E),
        raised: rgb(0x2C2C2E), sidebar: rgb(0x232325), selected: rgb(0x3A3A3C),
        // Focus is a step up in the same grey. It used to lean towards
        // the accent, which is a good idea on paper and another source
        // of navy in a room; the accent's border and glow around a
        // focused thing say it far more clearly than its fill ever did.
        focused: rgb(0x3A3A3C), warning: rgb(0xFFB224),
        highlight: rgb(0xFF3347), highlightSoft: rgb(0xFF8A95),
        selectionBorder: rgb(0xFF3347),
        positive: rgb(0x3DDC84), logoPlate: rgb(0xEDF1F6),
        // On a card this lands on the panel's own divider grey, #404043.
        line: rgb(0xFFFFFF).opacity(0.09),
        // A league chip in the accent's own colour reads as the app
        // talking rather than as the league it stands for. Combat's is
        // the deeper red of its own posters, not the accent's.
        leagues: LeagueColors(
            football: rgb(0x8B5CF6), college: rgb(0x00C2A8), basketball: rgb(0xFF6A1F),
            hockey: rgb(0xE14D8A), baseball: rgb(0x3DDC84), combat: rgb(0xD20A0A),
            tennis: rgb(0xC9DC3A)
        )
    )
}

private func rgb(_ value: UInt32) -> Color {
    Color(
        red: Double((value >> 16) & 0xFF) / 255,
        green: Double((value >> 8) & 0xFF) / 255,
        blue: Double(value & 0xFF) / 255
    )
}

/// The panels: a dark grey ground with cards a step lighter, big soft corners,
/// and a header inside each card -- an icon and a heavy rounded caption in
/// light grey, over a hairline. Measured off a reference screen, not picked
/// by eye, so every screen that uses them agrees to the point. The television
/// takes the same look at the size it is read at, across a room.
enum LineupPanelStyle {
    #if os(tvOS)
    static let radius: CGFloat = 32
    static let margin: CGFloat = 80
    static let inset: CGFloat = 30
    static let gap: CGFloat = 28
    /// The header's caption and icon.
    static let headerSize: CGFloat = 22
    static let headerTracking: CGFloat = 0.6
    #else
    static let radius: CGFloat = 24
    /// Card edge to screen edge.
    static let margin: CGFloat = 20
    /// Card edge to what is in it, the header and its hairline included.
    static let inset: CGFloat = 20
    /// Card to card.
    static let gap: CGFloat = 14
    static let headerSize: CGFloat = 15
    static let headerTracking: CGFloat = 0.4
    #endif
    static let fill = rgb(0x2C2C2E)
    /// Inside a card: a bar's empty track, a pressed row, a chosen one.
    static let well = rgb(0x3A3A3C)
    static let divider = rgb(0x404043)
    /// Headers and body copy. White is kept for the numbers and names a card
    /// is about, so they stand out from the words around them.
    static let caption = rgb(0xCCCCCC)
    static let quiet = rgb(0x9E9EA5)
    static var shape: RoundedRectangle { RoundedRectangle(cornerRadius: radius, style: .continuous) }

    // Settings and the lists under it, as the reference app draws its own:
    // a dark grey ground with its rows a step lighter, hairlines between
    // them, and values in a quiet grey.
    static let listGround = rgb(0x1C1C1E)
    static let listCard = rgb(0x2C2C2E)
    static let listSeparator = rgb(0x404043)
    static let listValue = rgb(0x9E9EA5)
    static let listChevron = rgb(0x656569)
    /// Under a server's own mark, as an app icon's dark ground.
    static let listLogoTile = rgb(0x1F1F1F)
}

/// A symbol on a small square of colour, the way Settings draws its rows --
/// and, so the app reads as one, every panel's header too. Each symbol
/// keeps one colour wherever it appears.
struct LineupIconTile: View {
    let symbol: String
    var size: CGFloat = 30
    var tint: Color? = nil

    var body: some View {
        let style = Self.style(for: symbol)
        Image(systemName: style.symbol)
            .font(.system(size: size * 0.5, weight: .semibold, design: .rounded))
            .foregroundStyle(.white)
            .frame(width: size, height: size)
            .background(tint ?? style.color, in: RoundedRectangle(cornerRadius: size * 0.26, style: .continuous))
            .accessibilityHidden(true)
    }

    // The system's own colours, as its Settings uses them.
    static let blue = rgb(0x0A84FF)
    static let green = rgb(0x30D158)
    static let red = rgb(0xFF453A)
    static let orange = rgb(0xFF9F0A)
    static let yellow = rgb(0xFFCC00)
    static let pink = rgb(0xFF375F)
    static let purple = rgb(0xBF5AF2)
    static let indigo = rgb(0x5E5CE6)
    static let teal = rgb(0x30B0C7)
    static let gray = rgb(0x8E8E93)

    /// The symbol drawn, filled where it has a filled form, and its colour.
    static func style(for symbol: String) -> (symbol: String, color: Color) {
        switch symbol {
        case "flame": ("flame.fill", orange)
        case "play.circle": ("play.circle.fill", blue)
        case "heart", "heart.fill": ("heart.fill", pink)
        case "eye.fill": ("eye.fill", blue)
        case "shuffle": ("shuffle", purple)
        case "play.fill": ("play.fill", green)
        case "list.bullet": ("list.bullet", teal)
        case "square.grid.2x2": ("square.grid.2x2.fill", indigo)
        case "link": ("link", blue)
        case "point.3.connected.trianglepath.dotted": ("point.3.connected.trianglepath.dotted", teal)
        case "speedometer": ("speedometer", orange)
        case "list.bullet.rectangle.portrait": ("list.bullet.rectangle.portrait.fill", green)
        case "captions.bubble.fill": ("captions.bubble.fill", blue)
        case "gearshape.fill": ("gearshape.fill", gray)
        case "sportscourt.fill": ("sportscourt.fill", green)
        case "rectangle.on.rectangle": ("rectangle.on.rectangle", purple)
        case "arrow.left.arrow.right": ("arrow.left.arrow.right", blue)
        case "line.3.horizontal.decrease": ("line.3.horizontal.decrease", teal)
        case "heart.text.square": ("heart.text.square.fill", pink)
        case "tv": ("tv.fill", purple)
        case "list.star": ("list.star", teal)
        case "rectangle.stack": ("rectangle.stack.fill", indigo)
        case "dot.radiowaves.left.and.right": ("dot.radiowaves.left.and.right", red)
        case "clock": ("clock.fill", blue)
        case "calendar": ("calendar", red)
        case "star": ("star.fill", yellow)
        case "sportscourt": ("sportscourt.fill", green)
        case "film": ("film.fill", indigo)
        case "play.rectangle": ("play.rectangle.fill", red)
        case "play.rectangle.on.rectangle": ("play.rectangle.on.rectangle.fill", purple)
        case "person.2": ("person.2.fill", blue)
        case "square.stack": ("square.stack.fill", indigo)
        case "list.number": ("list.number", teal)
        case "paintpalette": ("paintpalette.fill", pink)
        case "slider.horizontal.3": ("slider.horizontal.3", gray)
        case "bookmark": ("bookmark.fill", orange)
        case "antenna.radiowaves.left.and.right": ("antenna.radiowaves.left.and.right", blue)
        case "play.square.stack", "play.square.stack.fill": ("play.square.stack.fill", purple)
        case "waveform.path.ecg": ("waveform.path.ecg", teal)
        case "info.circle": ("info.circle.fill", gray)
        case "forward.end.fill": ("forward.end.fill", blue)
        case "magnifyingglass": ("magnifyingglass", gray)
        case "sparkles.rectangle.stack": ("sparkles.rectangle.stack.fill", purple)
        case "star.square.on.square": ("star.square.on.square.fill", yellow)
        case "plus": ("plus", green)
        case "icloud": ("icloud.fill", blue)
        case "number": ("number", gray)
        case "trash": ("trash.fill", red)
        case "rectangle.stack.badge.play": ("rectangle.stack.badge.play.fill", teal)
        case "plus.rectangle.on.rectangle": ("plus.rectangle.on.rectangle", green)
        case "minus.rectangle": ("minus.rectangle.fill", red)
        case "arrow.up.arrow.down": ("arrow.up.arrow.down", orange)
        case "arrow.clockwise": ("arrow.clockwise", teal)
        case "externaldrive.badge.plus": ("externaldrive.fill.badge.plus", indigo)
        case "bell": ("bell.fill", red)
        case "rectangle.stack.badge.plus": ("rectangle.stack.fill.badge.plus", indigo)
        case "chart.line.uptrend.xyaxis": ("chart.line.uptrend.xyaxis", green)
        case "film.stack": ("film.stack.fill", indigo)
        case "play.slash": ("play.slash.fill", gray)
        case "wifi.exclamationmark": ("wifi.exclamationmark", orange)
        case "pencil": ("pencil", orange)
        case "sparkles.tv": ("sparkles.tv.fill", purple)
        case "rectangle.split.2x1": ("rectangle.split.2x1.fill", purple)
        case "waveform": ("waveform", blue)
        case "gearshape": ("gearshape.fill", gray)
        case "checkmark": ("checkmark", green)
        case "arrow.uturn.backward": ("arrow.uturn.backward", blue)
        case "rectangle.stack.badge.minus": ("rectangle.stack.fill.badge.minus", red)
        case "eye": ("eye.fill", blue)
        case "eye.slash": ("eye.slash.fill", gray)
        case "heart.slash": ("heart.slash.fill", gray)
        case "star.slash": ("star.slash.fill", gray)
        case "arrow.up": ("arrow.up", blue)
        case "arrow.down": ("arrow.down", blue)
        case "backward.end": ("backward.end.fill", indigo)
        case "bell.slash": ("bell.slash.fill", gray)
        case "captions.bubble": ("captions.bubble.fill", blue)
        case "exclamationmark.triangle": ("exclamationmark.triangle.fill", orange)
        case "doc.text": ("doc.text.fill", orange)
        case "timer": ("timer", blue)
        case "list.bullet.rectangle": ("list.bullet.rectangle.fill", green)
        case "clock.arrow.circlepath": ("clock.arrow.circlepath", orange)
        default: (symbol, gray)
        }
    }
}

/// The progress bar every player draws, the way the reference app draws its
/// own: a thick, fully rounded track in a quiet grey, filled from the left in
/// the viewer's accent. No knob and no gloss -- and a new accent repaints it
/// with everything else.
struct LineupProgressBar: View {
    /// How far along, from 0 to 1.
    let value: Double
    /// Further along than `value`, in a softer accent: how far a broadcast
    /// has got, which is the part of it that can be played.
    var reach: Double? = nil
    var height: CGFloat = Self.standardHeight
    /// A touch brighter over artwork, which is lighter than a panel.
    var track: Color = Self.track

    #if os(tvOS)
    static let standardHeight: CGFloat = 12
    #else
    static let standardHeight: CGFloat = 8
    #endif
    /// Reads as the same grey track over a dark panel and over a picture.
    static let track = Color.white.opacity(0.16)

    var body: some View {
        GeometryReader { proxy in
            let width = proxy.size.width
            ZStack(alignment: .leading) {
                Capsule().fill(track)
                if let reach {
                    Capsule().fill(LineupStyle.highlight.opacity(0.38))
                        .frame(width: fill(reach, of: width))
                }
                Capsule().fill(LineupStyle.highlight)
                    .frame(width: fill(value, of: width))
            }
        }
        .frame(height: height)
        .accessibilityHidden(true)
    }

    /// Never narrower than the bar is tall once it has started, so its end
    /// stays round instead of pinching into a sliver.
    private func fill(_ fraction: Double, of width: CGFloat) -> CGFloat {
        let clamped = min(max(fraction.isFinite ? fraction : 0, 0), 1)
        guard clamped > 0 else { return 0 }
        return min(width, max(height, width * clamped))
    }
}

/// A screen with nothing to show yet, in the reference app's manner rather
/// than the system's: the subject's tile, large; what it is, in white; what
/// to do about it, quietly; and the action that fixes it, if there is one.
struct LineupUnavailableView<Actions: View>: View {
    let title: String
    let symbol: String
    var description: Text?
    @ViewBuilder var actions: Actions

    #if os(tvOS)
    private static var tile: CGFloat { 96 }
    private static var titleSize: CGFloat { 34 }
    private static var bodySize: CGFloat { 22 }
    private static var width: CGFloat { 900 }
    #else
    private static var tile: CGFloat { 64 }
    private static var titleSize: CGFloat { 20 }
    private static var bodySize: CGFloat { 15 }
    private static var width: CGFloat { 420 }
    #endif

    var body: some View {
        VStack(spacing: 14) {
            LineupIconTile(symbol: symbol, size: Self.tile)
                .padding(.bottom, 4)
            Text(title)
                .font(.inter(Self.titleSize, .bold))
                .foregroundStyle(LineupStyle.text)
                .multilineTextAlignment(.center)
            if let description {
                description
                    .font(.inter(Self.bodySize))
                    .foregroundStyle(LineupPanelStyle.quiet)
                    .multilineTextAlignment(.center)
            }
            actions.padding(.top, 6)
        }
        .padding(.horizontal, 32)
        .frame(maxWidth: Self.width)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

extension LineupUnavailableView where Actions == EmptyView {
    init(_ title: String, systemImage: String, description: Text? = nil) {
        self.init(title: title, symbol: systemImage, description: description) { EmptyView() }
    }
}

/// An icon and its words the way the reference app sets them: the icon on its
/// coloured tile, the words beside it. Every labelled control uses it, so a
/// button and a Settings row read as one family.
struct LineupTileLabel: View {
    let title: String
    let symbol: String
    var tileSize: CGFloat = 26
    var tint: Color? = nil

    var body: some View {
        HStack(spacing: tileSize * 0.42) {
            LineupIconTile(symbol: symbol, size: tileSize, tint: tint)
            Text(title).lineLimit(1)
        }
    }
}

/// The one action a message is waiting on, such as Retry: the accent, filled,
/// in a capsule, its words in the colour that reads on it.
struct LineupProminentButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.inter(17, .bold))
            .foregroundStyle(LineupStyle.onHighlight)
            .padding(.horizontal, 22).frame(minHeight: 46)
            .background(LineupStyle.highlight, in: Capsule())
            .opacity(configuration.isPressed ? 0.8 : 1)
    }
}

/// A panel's own header: icon, upper-case title, and whatever the panel puts
/// on the right, such as See All.
struct LineupPanelHeader<Accessory: View>: View {
    let title: String
    var systemImage: String?
    @ViewBuilder var accessory: () -> Accessory

    var body: some View {
        HStack(spacing: 8) {
            if let systemImage {
                LineupIconTile(symbol: systemImage, size: LineupPanelStyle.headerSize * 1.6)
            }
            Text(title.uppercased())
                .font(.inter(LineupPanelStyle.headerSize, .heavy)).tracking(LineupPanelStyle.headerTracking)
                .lineLimit(1)
                .accessibilityAddTraits(.isHeader)
            Spacer(minLength: 8)
            accessory()
        }
        .foregroundStyle(LineupPanelStyle.caption)
    }
}

extension LineupPanelHeader where Accessory == EmptyView {
    init(_ title: String, systemImage: String? = nil) {
        self.init(title: title, systemImage: systemImage) { EmptyView() }
    }
}

enum LineupStyle {
    /// One palette for the phone and the television, so the two apps are
    /// the same colours: the same ground, panels and greys, the viewer's
    /// accent for what is chosen and live, the same colour for each league.
    private static var palette: LineupPalette { .phone }
    /// The theme's text tint. Named for Velvet's lilac, which is no longer the
    /// only thing it can be.
    static var lightPurple: Color { palette.accent }
    /// The frame on a selected Live card: the one place a theme is allowed its
    /// brightest edge.
    static var liveSelectionBorder: Color {
        return LineupAccent.current.color
    }
    static var background: Color { palette.background }
    static var surface: Color { palette.surface }
    static var raised: Color { palette.raised }
    static var sidebarRow: Color { palette.sidebar }
    static var selected: Color { palette.selected }
    static var focused: Color { palette.focused }
    static var liveSurface: Color { palette.selected }
    /// The accent the viewer chose, on the phone and the television alike.
    static var highlight: Color {
        return LineupAccent.current.color
    }
    static var highlightSoft: Color {
        return LineupAccent.current.soft
    }
    /// Type set on the highlight, legible whatever accent was chosen.
    static var onHighlight: Color {
        return LineupAccent.current.onAccent
    }
    static var liveBorder: Color { highlight.opacity(0.72) }
    static var line: Color { palette.line }
    static var text: Color { palette.accent }
    static var secondary: Color {
        return lightPurple.opacity(0.66)
    }
    /// Playback chrome stays legible against video.
    static var mediaText: Color { text }
    static var mediaSecondary: Color { secondary }
    static var mediaAccent: Color { text }
    static var field: Color { lightPurple }
    /// An error is red whatever the accent.
    static var live: Color {
        return broadcastRed
    }
    static var warning: Color { palette.warning }
    /// What is on air: the accent, on the phone and the television alike, so
    /// the live marks and the active ones are one colour whatever the viewer
    /// chose -- Red by default, which is the broadcast red it always was.
    static var liveDot: Color {
        return LineupAccent.current.color
    }
    static var liveStatus: Color { liveDot }
    /// Type set on a live mark, legible whatever the accent is.
    static var onLive: Color {
        return LineupAccent.current.onAccent
    }
    /// The red of failure, which is not a matter of taste.
    static var broadcastRed: Color { rgb(0xFF3347) }
    /// Confirmation -- a channel was found, a server answered.
    static var positive: Color { palette.positive }
    static var logoPlate: Color { palette.logoPlate }
    #if os(tvOS)
    static let compactRadius: CGFloat = 8
    static let panelRadius: CGFloat = 12
    #else
    static let compactRadius: CGFloat = 14
    static let panelRadius: CGFloat = 24
    #endif

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
        case .atp, .wta: return leagues.tennis
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
    /// Rebuilds this subtree when the accent changes.
    ///
    /// Every colour is read from `LineupStyle`, which answers from stored
    /// state rather than from anything SwiftUI watches, so a view is not
    /// drawn again just because the accent moved. Re-identifying the subtree
    /// draws all of it again in the new colour. Apply it below whatever holds
    /// state worth keeping, such as the selected tab.
    @ViewBuilder
    func lineupAccentScope(_ accent: String) -> some View {
        id(accent)
    }

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

    // No glass to merge: the app's surfaces are solid, as the reference
    // app's are. Kept so the groups that used it need not change.
    var body: some View { content }
}

#if os(iOS)
extension View {
    // Apple's Liquid Glass for the iPhone app's chrome and floating controls.
    // Below iOS 26 the same surfaces keep the theme's own fill and hairline, so
    // nothing shifts in size, shape or spacing on older systems.
    //
    // Glass no longer: every floating surface is the reference app's card --
    // its grey, solid, with a hairline of light round it -- so a panel over
    // a picture and a panel on a page are the same thing.
    func lineupLiquidGlass<S: InsettableShape, F: ShapeStyle>(
        _ shape: S, clear: Bool = false, fallback: F,
        border: Color = .white.opacity(0.12)
    ) -> some View {
        self.background(LineupPanelStyle.fill.opacity(clear ? 0.86 : 0.97), in: shape)
            .overlay(shape.strokeBorder(Color.white.opacity(0.08), lineWidth: 1))
    }

    // The floating-control default: dark scrim and hairline below iOS 26.
    func lineupLiquidGlass<S: InsettableShape>(_ shape: S, clear: Bool = false) -> some View {
        lineupLiquidGlass(shape, clear: clear, fallback: Color.black.opacity(0.6))
    }

    /// Glass for something pressed: it gives under a finger and catches the
    /// light the way the system's own controls do, where `lineupLiquidGlass`
    /// is a surface that only sits there. `prominent` lifts it a shade, for
    /// the one control a screen is about -- play and pause.
    // The reference app's round button, as its close button is drawn: the
    // card grey with a white glyph and a hairline of light. The one a screen
    // is about -- play and pause -- a step lighter.
    func lineupGlassControl<S: InsettableShape, F: ShapeStyle>(
        _ shape: S, fallback: F, prominent: Bool = false
    ) -> some View {
        self.background(prominent ? LineupPanelStyle.well : LineupPanelStyle.fill, in: shape)
            .overlay(shape.strokeBorder(Color.white.opacity(0.08), lineWidth: 1))
    }

    func lineupGlassControl<S: InsettableShape>(_ shape: S, prominent: Bool = false) -> some View {
        lineupGlassControl(shape, fallback: Color.black.opacity(0.6), prominent: prominent)
    }

    /// The one action a message is waiting on, such as Retry: the system's
    /// prominent glass button, or its filled button below iOS 26.
    func lineupProminentButton() -> some View {
        self.buttonStyle(LineupProminentButtonStyle())
    }
}

/// A card with a header, a hairline, and its content under them. `padded`
/// gives the content the card's insets. Rows that carry their own -- a list
/// of games divided by hairlines, a row of posters that scrolls beneath the
/// card's edges -- take the card's full width instead.
struct LineupPanel<Content: View, Accessory: View>: View {
    let title: String
    var systemImage: String?
    var padded = true
    @ViewBuilder var accessory: () -> Accessory
    @ViewBuilder var content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            LineupPanelHeader(title: title, systemImage: systemImage, accessory: accessory)
                .padding(.top, 15).padding(.bottom, 11)
                .padding(.horizontal, LineupPanelStyle.inset)
            Rectangle().fill(LineupPanelStyle.divider).frame(height: 1)
                .padding(.horizontal, LineupPanelStyle.inset)
            content()
                .padding(.horizontal, padded ? LineupPanelStyle.inset : 0)
                .padding(.top, padded ? 16 : 0).padding(.bottom, padded ? 18 : 4)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(LineupPanelStyle.fill, in: LineupPanelStyle.shape)
        .clipShape(LineupPanelStyle.shape)
    }
}

extension LineupPanel where Accessory == EmptyView {
    init(_ title: String, systemImage: String? = nil, padded: Bool = true,
         @ViewBuilder content: @escaping () -> Content) {
        self.init(title: title, systemImage: systemImage, padded: padded,
                  accessory: { EmptyView() }, content: content)
    }
}

extension View {
    /// A card with no header: the panel's fill and corners alone.
    func lineupPanelCard(padding: CGFloat = LineupPanelStyle.inset) -> some View {
        self.padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(LineupPanelStyle.fill, in: LineupPanelStyle.shape)
    }

    /// A filter or choice as a capsule: filled with the accent when chosen,
    /// drawn in its outline otherwise.
    func lineupChip(_ selected: Bool) -> some View {
        self.font(.inter(15, .bold))
            .lineLimit(1)
            .foregroundStyle(selected ? LineupStyle.onHighlight : LineupStyle.highlight)
            .padding(.horizontal, 14).frame(minHeight: 32)
            .background(Capsule().fill(selected ? LineupStyle.highlight : Color.clear))
            .overlay(Capsule().strokeBorder(selected ? Color.clear : LineupStyle.highlight, lineWidth: 1.5))
            .contentShape(Capsule())
    }
}

/// The background behind a Form row: the Guide's flat grey. These rows were
/// Liquid Glass, which put a sheen under every setting; the settings now sit
/// on the same quiet ground as the Guide and the Live tab. Passed to
/// `listRowBackground`, which wants a view rather than a modifier.
struct LineupRowBackground: View {
    var body: some View {
        LineupPanelStyle.fill
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
    /// A section of an inset-grouped list drawn as one panel: the panel's
    /// fill, its hairline between rows, and its side insets.
    func lineupPanelRows() -> some View {
        self.listRowBackground(LineupPanelStyle.fill)
            .listRowSeparatorTint(LineupPanelStyle.divider)
            .listRowInsets(EdgeInsets(top: 12, leading: LineupPanelStyle.inset,
                                      bottom: 12, trailing: LineupPanelStyle.inset))
    }

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
    //
    // Glass no longer, as on the phone: the reference app's card grey,
    // solid, with a hairline of light; a step lighter for the prominent one.
    func lineupLiquidGlass<S: InsettableShape, F: ShapeStyle>(
        _ shape: S, clear: Bool = false, fallback: F,
        border: Color = .white.opacity(0.12), prominent: Bool = false
    ) -> some View {
        self.background(prominent ? LineupPanelStyle.well : LineupPanelStyle.fill.opacity(clear ? 0.86 : 0.97),
                        in: shape)
            .overlay(shape.strokeBorder(Color.white.opacity(0.08), lineWidth: 1))
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
                .font(.inter(50, .heavy))
                .foregroundStyle(LineupStyle.text)
            if let detail {
                Text(detail).foregroundColor(LineupStyle.lightPurple)
                    .font(.inter(.title3))
                    .foregroundStyle(LineupStyle.secondary)
            }
        }
    }
}

/// A group's caption over a list of choices, in the panels' header type:
/// light grey and heavy, at each platform's size.
struct LineupGroupHeading: ViewModifier {
    func body(content: Content) -> some View {
        #if os(tvOS)
        content.font(.inter(18, .heavy)).tracking(LineupPanelStyle.headerTracking)
            .textCase(.uppercase)
            .foregroundStyle(LineupPanelStyle.caption)
        #else
        content.font(.inter(15, .heavy)).tracking(0.4)
            .textCase(.uppercase)
            .foregroundStyle(LineupPanelStyle.caption)
        #endif
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
