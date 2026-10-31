import SwiftUI
import UIKit
import LineupAetherPlayback
import LineupMPVPlayback

/// A band of the theme's colour crossing the dark screen, over and over.
///
/// The app's own mark is a line travelling across a guide, and so is the line
/// down the guide itself. A set looking for its channels is the same idea in
/// motion, and it reads as equipment working rather than as a spinner bolted
/// onto a television.
struct LiveTVSignalSweep: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var sweeping = false

    var body: some View {
        GeometryReader { geometry in
            let band = geometry.size.width * 0.3
            LinearGradient(
                colors: [.clear, LineupStyle.live.opacity(0.05),
                         LineupStyle.live.opacity(0.34), LineupStyle.live.opacity(0.05), .clear],
                startPoint: .leading, endPoint: .trailing)
                .frame(width: band)
                .blur(radius: 10)
                .offset(x: sweeping ? geometry.size.width : -band)
                .animation(.linear(duration: 2.6).repeatForever(autoreverses: false), value: sweeping)
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
        .onAppear { if !reduceMotion { sweeping = true } }
    }
}

// MARK: - Live

/// The Live tab's reading of the theme.
///
/// Every colour here comes from LineupStyle's charcoal, light grey and white.
/// The one colour that is not the theme's is broadcast red, and it only ever
/// means on air; the teams bring their own.
enum LivePalette {
    static var text: Color { LineupStyle.text.opacity(0.78) }
    static var secondary: Color { LineupStyle.secondary.opacity(0.9) }
    static var card: Color { LineupStyle.surface }
    static var rule: Color { LineupStyle.line }
    static var accent: Color { LineupStyle.highlight }
    static var rim: Color { LineupStyle.liveSelectionBorder }
    static var onAir: Color { LineupStyle.liveDot }
}

/// One grid for the whole tab.
enum LiveMetrics {
    /// tvOS's own title-safe inset. The stage, the board and the score crawl
    /// all stop on it, so nothing sits in a television's overscan band and no
    /// edge on the screen stops in two places.
    static let margin: CGFloat = 80
    static let railWidth: CGFloat = 380
    static let gutter: CGFloat = 30
    static let cardHeight: CGFloat = 214
    /// Clear space around anything focusable inside a scroller, which clips:
    /// a focused card's lift and shadow grow into it.
    static let liftRoom: CGFloat = 18
    static let monitorRadius: CGFloat = LineupPanelStyle.radius
}

/// Which game the screen is describing.
///
/// The tab holds this in plain `@State`, which keeps it without watching
/// it, and only the views that describe the game observe it: the monitor, the
/// light behind it and the row counter. An arrow press redraws those three and
/// leaves every card and row where it is.
final class LiveSpotlight: ObservableObject {
    @Published private(set) var gameID: String?
    @Published private(set) var boardRow = 0

    func rest(on game: SportsGame) {
        if gameID != game.id { gameID = game.id }
    }

    func rest(on game: SportsGame, row: Int) {
        rest(on: game)
        if boardRow != row { boardRow = row }
    }

    /// The game under the remote. Before the remote has rested anywhere, the
    /// first game on air, or failing that the first of the night.
    func game(in events: [SportsGame]) -> SportsGame? {
        if let gameID, let game = events.first(where: { $0.id == gameID }) { return game }
        return events.first(where: \.isLive) ?? events.first
    }
}

/// The Live tab: the viewer's teams beside a monitor, every matchup beneath.
///
/// The monitor never sits dark. Resting on a game puts that game's slate on
/// it -- the two crests, the score or the start, the building -- so the night
/// reads like a broadcast while the remote moves. Select cuts the monitor to
/// that game's feed; select again takes it full screen.
struct LiveScreen: View {
    @Environment(SportsLibrary.self) private var library
    let events: [SportsGame]
    let spotlight: LiveSpotlight
    @Binding var selectedLeague: SportsLeague?
    @Binding var soccerCompetition: String?
    let previewStream: XtreamStream?
    let previewGame: SportsGame?
    let previewURLs: [URL]
    let multiviewPrimaryID: Int?
    let multiviewTitle: String?
    let isScheduleLoading: Bool
    let isScheduleAvailable: Bool
    let scheduleErrorMessage: String?
    let onPlay: (SportsGame) -> Void
    let onStartMultiview: (SportsGame) -> Void
    let onCancelMultiview: () -> Void
    let onStopPreview: () -> Void
    /// My Teams beside the monitor, or put away so the monitor runs the full
    /// width of the board and the picture sits centred. Kept between visits.
    @AppStorage("live.myTeamsShown") private var myTeamsShown = true
    /// Where the remote goes after My Teams is put away or brought back: onto
    /// the control that undoes it, rather than wherever focus falls.
    @FocusState private var myTeamsControl: LiveMyTeamsControl?

    var body: some View {
        VStack(spacing: 14) {
            stage
            LiveMatchupBoard(events: events, selectedLeague: $selectedLeague, spotlight: spotlight,
                             soccerCompetition: $soccerCompetition,
                             previewGameID: previewGame?.id, multiviewPrimaryID: multiviewPrimaryID,
                             multiviewTitle: multiviewTitle, isScheduleLoading: isScheduleLoading,
                             isScheduleAvailable: isScheduleAvailable,
                             onPlay: onPlay, onStartMultiview: onStartMultiview,
                             onCancelMultiview: onCancelMultiview)
        }
        .padding(.horizontal, LiveMetrics.margin)
        .padding(.top, 8)
        // The screen and score crawl use the same explicit side margins.
        // Keep vertical layout bounded above the crawl.
        .ignoresSafeArea(.container, edges: .horizontal)
        .onExitCommand { if previewStream != nil { onStopPreview() } }
    }

    /// The viewer's teams and the monitor, sharing the top of the screen. The
    /// matchups run the full width beneath, so Down out of the rail lands in
    /// them.
    ///
    /// The pair is one focus region. The monitor holds nothing to focus, so a
    /// press aimed at it -- Down from the tab bar, Up from the board -- would
    /// otherwise find nothing and be swallowed; as a region it arrives at the
    /// viewer's teams instead.
    private var stage: some View {
        HStack(alignment: .top, spacing: myTeamsShown ? LiveMetrics.gutter : 0) {
            if myTeamsShown {
                LiveMyTeams(events: events, spotlight: spotlight, previewGameID: previewGame?.id,
                            multiviewPrimaryID: multiviewPrimaryID,
                            hideFocus: $myTeamsControl,
                            onHide: { setMyTeams(shown: false) },
                            onPlay: onPlay, onStartMultiview: onStartMultiview)
                    .frame(width: LiveMetrics.railWidth)
                    .transition(.move(edge: .leading).combined(with: .opacity))
            }
            LiveMonitor(spotlight: spotlight, events: events, previewStream: previewStream,
                        previewGame: previewGame, previewURLs: previewURLs,
                        isMultiview: multiviewTitle != nil, isPreparingStreams: isPreparingStreams,
                        isScheduleLoading: isScheduleLoading, isScheduleAvailable: isScheduleAvailable,
                        scheduleErrorMessage: scheduleErrorMessage)
                // Put away, My Teams leaves a tab on the monitor's left edge
                // to bring it back. It sits over the picture rather than
                // beside it, so the monitor keeps the board's full width.
                .overlay(alignment: .leading) {
                    if !myTeamsShown {
                        LiveMyTeamsTab(focus: $myTeamsControl) { setMyTeams(shown: true) }
                            .padding(.leading, 16)
                            .transition(.opacity)
                    }
                }
        }
        .frame(maxHeight: .infinity)
        .lineupFocusRegion()
    }

    private func setMyTeams(shown: Bool) {
        withAnimation(.easeInOut(duration: 0.32)) { myTeamsShown = shown }
        // Onto the control that undoes it, once it is there to take focus.
        DispatchQueue.main.async { myTeamsControl = shown ? .hide : .show }
    }

    /// The same rule the phone uses, from the same file: work in flight is
    /// only a wait when there is nothing behind it.
    private var isPreparingStreams: Bool {
        let banner = LiveSyncBanner.choose(isInitialProviderSync: library.isInitialProviderSync,
                                           hasContent: library.hasRestoredCache,
                                           isScheduleLoading: library.isScheduleLoading,
                                           isLoading: library.isLoading,
                                           channelsAreSyncing: !library.automaticMatchingReady)
        return banner == .initialSync || banner == .refreshing
    }
}

/// One palette for the matchup row and the room behind it. Score and clock
/// updates do not alter the palette or restart a background transition.
struct LiveEventColors: Hashable {
    let away: Color
    let home: Color

    init(game: SportsGame) {
        away = MobileTeamColor.readable(game.awayColor) ?? LineupStyle.leagueColor(game.league)
        home = MobileTeamColor.readable(game.homeColor) ?? away
    }
}

struct LiveEventWash: View {
    let colors: LiveEventColors
    var body: some View {
        ZStack {
            LineupStyle.background
            LinearGradient(colors: [colors.away.opacity(0.19), colors.home.opacity(0.19)],
                           startPoint: .leading, endPoint: .trailing)
                .overlay(LivePalette.card.opacity(0.35))
        }
    }
}

/// The remote's highlighted game colors the Sports tab, independently of
/// whatever stream is playing, without invalidating the tab's lists or player.
struct LiveCanvas: View {
    @ObservedObject var spotlight: LiveSpotlight
    let events: [SportsGame]

    var body: some View {
        let colors = spotlight.game(in: events).map { LiveEventColors(game: $0) }
        LiveCanvasColors(colors: colors)
    }
}

@MainActor final class TVSportsCanvasState: ObservableObject {
    @Published private(set) var colors: LiveEventColors?
    func setColors(_ colors: LiveEventColors?) {
        if self.colors != colors { self.colors = colors }
    }
}

private struct TVSportsCanvasStateKey: EnvironmentKey {
    static let defaultValue: TVSportsCanvasState? = nil
}

extension EnvironmentValues {
    var tvSportsCanvasState: TVSportsCanvasState? {
        get { self[TVSportsCanvasStateKey.self] }
        set { self[TVSportsCanvasStateKey.self] = newValue }
    }
}

struct TVSportsCanvasSource: View {
    @ObservedObject var spotlight: LiveSpotlight
    let events: [SportsGame]
    let canvas: TVSportsCanvasState
    let active: Bool
    var body: some View {
        let colors = spotlight.game(in: events).map { LiveEventColors(game: $0) }
        Color.clear.onChange(of: colors, initial: true) { _, colors in canvas.setColors(colors) }
            .background(TVSportsCanvasSurface(active: active).frame(width: 0, height: 0))
    }
}

/// UIKit may give the tab container/selected host an opaque default ground.
/// Let the outside canvas show through Sports only, restoring other tabs.
private struct TVSportsCanvasSurface: UIViewRepresentable {
    let active: Bool
    func makeUIView(context: Context) -> Probe { Probe() }
    func updateUIView(_ view: Probe, context: Context) { view.active = active; view.apply() }
    static func dismantleUIView(_ view: Probe, coordinator: ()) { view.restore() }

    final class Probe: UIView {
        var active = false
        private struct Entry {
            weak var view: UIView?
            let color: UIColor?
            let opaque: Bool
        }
        private var entries: [Entry] = []
        override func didMoveToWindow() {
            super.didMoveToWindow()
            apply()
            DispatchQueue.main.async { [weak self] in self?.apply() }
        }
        func apply() {
            guard active, window != nil else { restore(); return }
            var responder: UIResponder? = next
            var owner: UIViewController?
            while let current = responder {
                if let controller = current as? UIViewController { owner = controller; break }
                responder = current.next
            }
            guard let tabs = owner?.tabBarController,
                  let tabSurface = tabs.viewIfLoaded,
                  let selected = tabs.selectedViewController?.viewIfLoaded,
                  isDescendant(of: selected) else { return }
            let targets = [tabSurface, selected]
            if entries.count != 2 || entries[0].view !== targets[0] || entries[1].view !== targets[1] {
                restore()
                entries = targets.map { Entry(view: $0, color: $0.backgroundColor, opaque: $0.isOpaque) }
            }
            for target in targets {
                if target.backgroundColor != UIColor.clear { target.backgroundColor = .clear }
                if target.isOpaque { target.isOpaque = false }
            }
        }
        func restore() {
            for entry in entries {
                guard let view = entry.view, view.backgroundColor == UIColor.clear, !view.isOpaque else { continue }
                view.backgroundColor = entry.color
                view.isOpaque = entry.opaque
            }
            entries.removeAll()
        }
    }
}

struct TVSportsTabCanvas: View {
    @ObservedObject var canvas: TVSportsCanvasState
    let active: Bool
    var body: some View {
        LiveCanvasColors(colors: active ? canvas.colors : nil)
    }
}

struct LiveCanvasColors: View {
    let colors: LiveEventColors?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var body: some View {
        ZStack {
            LineupStyle.background
            LiveCanvasTint(colors: colors, animated: !reduceMotion)
                .overlay(LivePalette.card.opacity(colors == nil ? 0 : 0.35))
            LinearGradient(colors: [LineupStyle.raised.opacity(0.26), .clear],
                           startPoint: .top, endPoint: .center)
            RadialGradient(colors: [.clear, .black.opacity(0.3)], center: .center,
                           startRadius: 520, endRadius: 1250)
        }
        .ignoresSafeArea()
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

/// One persistent gradient, including during rapid remote navigation. Retarget
/// the same animation from its visible colors instead of retaining outgoing
/// full-screen SwiftUI transitions for every highlighted event.
struct LiveCanvasTint: UIViewRepresentable {
    let colors: LiveEventColors?
    let animated: Bool

    func makeUIView(context: Context) -> LiveCanvasTintView { LiveCanvasTintView(frame: .zero) }
    func updateUIView(_ view: LiveCanvasTintView, context: Context) {
        view.setColors(colors, animated: animated && !context.transaction.disablesAnimations)
    }
}

final class LiveCanvasTintView: UIView {
    override class var layerClass: AnyClass { CAGradientLayer.self }
    private var palette: LiveEventColors?
    private var initialized = false
    private var gradient: CAGradientLayer { layer as! CAGradientLayer }
    static let animationKey = "event-colors"

    override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = false
        isOpaque = false
        gradient.startPoint = CGPoint(x: 0, y: 0.5)
        gradient.endPoint = CGPoint(x: 1, y: 0.5)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func setColors(_ colors: LiveEventColors?, animated: Bool) {
        guard !initialized || palette != colors else {
            if !animated { gradient.removeAnimation(forKey: Self.animationKey) }
            return
        }
        let wasInitialized = initialized
        initialized = true
        palette = colors
        let clear = UIColor.clear.cgColor
        let target = colors.map {
            [UIColor($0.away).withAlphaComponent(0.19).cgColor,
             UIColor($0.home).withAlphaComponent(0.19).cgColor]
        } ?? [clear, clear]
        let visible = gradient.presentation()?.colors ?? gradient.colors
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        gradient.colors = target
        gradient.removeAnimation(forKey: Self.animationKey)
        CATransaction.commit()
        if animated, wasInitialized, let visible {
            let animation = CABasicAnimation(keyPath: "colors")
            animation.fromValue = visible
            animation.toValue = target
            animation.duration = 0.45
            animation.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            gradient.add(animation, forKey: Self.animationKey)
        }
    }
}

/// The monitor. A slate while nothing is playing, the feed while one is.
struct LiveMonitor: View {
    @Environment(SportsLibrary.self) private var library
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @ObservedObject var spotlight: LiveSpotlight
    let events: [SportsGame]
    let previewStream: XtreamStream?
    let previewGame: SportsGame?
    let previewURLs: [URL]
    let isMultiview: Bool
    let isPreparingStreams: Bool
    let isScheduleLoading: Bool
    let isScheduleAvailable: Bool
    let scheduleErrorMessage: String?

    var body: some View {
        let game = spotlight.game(in: events)
        let shape = RoundedRectangle(cornerRadius: LiveMetrics.monitorRadius, style: .continuous)
        ZStack {
            Color.black
            if let previewStream {
                // The picture is left clear, nothing written over it.
                LiveVideoWall(stream: previewStream, game: previewGame, urls: previewURLs)
            } else if let game {
                LiveSlate(game: game, channel: library.stream(for: game)?.name,
                          hint: isPreparingStreams ? .refreshing : (isMultiview ? .secondGame : .preview))
                    .id(game.id)
                    .transition(.opacity)
            } else {
                LiveEmptySlate(isLoading: isScheduleLoading, isAvailable: isScheduleAvailable,
                               errorMessage: scheduleErrorMessage)
            }
            // Looking for channels is what this screen is for while nothing
            // plays, and the screen is where someone waiting is looking.
            if previewStream == nil && isPreparingStreams {
                LiveTVSignalSweep()
            }
        }
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.3), value: game?.id)
        // A panel like the rest: its fill and corners, no rim of light.
        .clipShape(shape)
        .accessibilityLabel(previewStream == nil ? "Matchup slate" : "TV preview")
    }
}

/// What the monitor says it will do when Select is pressed.
enum LiveHint {
    case preview, secondGame, refreshing
}

/// What the monitor shows for a game while nothing is playing.
///
/// Built like a broadcast's pre-game graphic. The two sides face each other
/// across a centre line, their colours lighting their own halves, and between
/// them is the one fact that matters right now: the score while it is on, the
/// start while it is not.
struct LiveSlate: View {
    let game: SportsGame
    let channel: String?
    let hint: LiveHint

    var body: some View {
        GeometryReader { proxy in
            let crest = min(150, proxy.size.height * 0.27)
            ZStack {
                LiveSlateBackdrop()
                VStack(spacing: 0) {
                    header
                    Spacer(minLength: 10)
                    if game.isEvent {
                        event
                    } else {
                        HStack(alignment: .center, spacing: 0) {
                            LiveCrestColumn(name: game.awayTeam, abbreviation: game.awayAbbreviation,
                                            logo: game.awayLogo,
                                            record: game.awayRecord, crest: crest)
                                .frame(maxWidth: .infinity)
                            center
                                .frame(width: min(450, proxy.size.width * 0.34))
                            LiveCrestColumn(name: game.homeTeam, abbreviation: game.homeAbbreviation,
                                            logo: game.homeLogo,
                                            record: game.homeRecord, crest: crest)
                                .frame(maxWidth: .infinity)
                        }
                    }
                    Spacer(minLength: 10)
                    footer
                }
                .padding(.horizontal, 40).padding(.top, 28).padding(.bottom, 30)
            }
            .frame(width: proxy.size.width, height: proxy.size.height)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(liveAccessibilityLabel(game))
    }

    /// The broadcast bug: the league and its network on the left, and on the
    /// right a red LIVE tag, or when it starts.
    private var header: some View {
        HStack(spacing: 14) {
            if game.competition != nil { SportsMark(league: game.league, competition: game.competition, size: 32) }
            else { LeagueLogo(league: game.isNFLRedZone ? .nfl : game.league, size: 32) }
            Text(game.competition?.shortName ?? game.league.shortName).font(.inter(17, .heavy)).tracking(0.6)
                .foregroundStyle(LivePalette.text)
            if let network = nonempty(game.broadcast) {
                Rectangle().fill(LivePalette.secondary.opacity(0.5)).frame(width: 1, height: 18)
                Text(network.uppercased()).font(.inter(17, .heavy)).tracking(0.6)
                    .foregroundStyle(LivePalette.secondary).lineLimit(1)
            }
            Spacer(minLength: 20)
            if game.isLive {
                LiveOnAirTag()
            } else {
                Text(liveDayLabel(game.start)).font(.inter(15, .heavy)).tracking(0.6)
                    .foregroundStyle(LivePalette.secondary)
            }
        }
    }

    @ViewBuilder private var center: some View {
        if game.isLive && !game.awayScore.isEmpty && !game.homeScore.isEmpty {
            let lead = liveLeader(game)
            VStack(spacing: 22) {
                HStack(alignment: .center, spacing: 22) {
                    Text(game.awayScore)
                        .foregroundStyle(lead == .home ? LivePalette.secondary : LivePalette.text)
                    Capsule().fill(LivePalette.secondary.opacity(0.55)).frame(width: 24, height: 5)
                    Text(game.homeScore)
                        .foregroundStyle(lead == .away ? LivePalette.secondary : LivePalette.text)
                }
                .font(.interDigits(104, .bold))
                .lineLimit(1).minimumScaleFactor(0.5)
                .contentTransition(.numericText())
                LiveStatusCapsule(status: game.status)
                if let detail = game.soccer?.detail {
                    Text(detail).font(.inter(18, .semibold)).foregroundStyle(LivePalette.secondary)
                }
            }
        } else if game.isLive {
            LiveStatusCapsule(status: game.status)
        } else {
            let parts = liveTimeParts(game.start)
            VStack(spacing: 4) {
                Text(liveStartWord(game.league)).font(.inter(15, .heavy)).tracking(0.6)
                    .foregroundStyle(LivePalette.secondary)
                (Text(parts.time).font(.interDigits(84, .semibold)).foregroundStyle(LivePalette.text)
                 + Text(parts.period.map { " " + $0 } ?? "").font(.inter(32, .semibold))
                    .foregroundStyle(LivePalette.secondary))
                    .lineLimit(1).minimumScaleFactor(0.6)
            }
        }
    }

    /// A fight card or RedZone: one event rather than two sides, so its mark
    /// and its name take the middle.
    private var event: some View {
        VStack(spacing: 18) {
            LeagueLogo(league: game.isNFLRedZone ? .nfl : game.league, size: 92)
            Text(game.matchupLine)
                .font(.inter(46, .bold)).foregroundStyle(LivePalette.text)
                .multilineTextAlignment(.center).lineLimit(2).minimumScaleFactor(0.6)
                .frame(maxWidth: 900)
            if game.isLive {
                LiveStatusCapsule(status: game.status)
            } else {
                Text("\(game.race?.title.uppercased() ?? liveStartWord(game.league))  ·  \(game.startLabel.uppercased())")
                    .font(.interDigits(20, .bold)).tracking(2)
                    .foregroundStyle(LivePalette.secondary)
            }
        }
    }

    /// Where it is played, what Select will do, and the channel it will open.
    /// The two sides are containers even when empty, so a game with no venue
    /// or no matched channel still keeps the hint in the middle.
    private var footer: some View {
        HStack(alignment: .center, spacing: 20) {
            HStack(spacing: 8) {
                if let place = game.placeLine {
                    Image(systemName: "mappin").font(.system(size: 15, weight: .semibold, design: .rounded))
                    Text(place).lineLimit(1)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            LiveActionHint(hint: hint)
            HStack(spacing: 8) {
                if let channel {
                    Image(systemName: "dot.radiowaves.left.and.right").font(.system(size: 15, weight: .semibold, design: .rounded))
                    Text(channel).lineLimit(1)
                }
            }
            .frame(maxWidth: .infinity, alignment: .trailing)
        }
        .font(.inter(17, .medium))
        .foregroundStyle(LivePalette.secondary)
    }
}

/// The slate's ground: black, each side's colour lifting its own half, and a
/// centre line and circle drawn faintly through the middle, the way every
/// field and floor and rink is marked.
/// The slate's ground: dark, with the court's lines. No team colour is cast
/// across it or around the crests; the only light is the pale rim each crest
/// carries to keep a dark badge readable.
struct LiveSlateBackdrop: View {
    var body: some View {
        GeometryReader { proxy in
            let size = proxy.size
            ZStack {
                // The panels' flat fill: no gradient or vignette, as on the
                // phone. The court lines stay, faint, as the slate's mark.
                LineupPanelStyle.fill
                LiveCourtLines()
            }
            .frame(width: size.width, height: size.height)
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

/// A centre line and circle. The line fades out through the middle third so
/// it never runs through the score.
struct LiveCourtLines: View {
    var body: some View {
        GeometryReader { proxy in
            let ring = proxy.size.height * 0.66
            ZStack {
                Rectangle()
                    .fill(LinearGradient(stops: [
                        .init(color: .white.opacity(0.06), location: 0),
                        .init(color: .clear, location: 0.3),
                        .init(color: .clear, location: 0.7),
                        .init(color: .white.opacity(0.06), location: 1)
                    ], startPoint: .top, endPoint: .bottom))
                    .frame(width: 2)
                Circle().strokeBorder(.white.opacity(0.05), lineWidth: 2)
                    .frame(width: ring, height: ring)
            }
            .frame(width: proxy.size.width, height: proxy.size.height)
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

/// One side of a matchup on the slate.
struct LiveCrestColumn: View {
    let name: String
    let abbreviation: String
    let logo: String
    let record: String?
    let crest: CGFloat

    var body: some View {
        VStack(spacing: 16) {
            LiveCrest(url: logo, fallback: abbreviation.isEmpty ? String(name.prefix(3)).uppercased() : abbreviation,
                      size: crest)
            VStack(spacing: 5) {
                Text(name).font(.inter(30, .semibold)).foregroundStyle(LivePalette.text)
                    .lineLimit(1).minimumScaleFactor(0.6)
                if let record = nonempty(record) {
                    Text(record).font(.interDigits(19, .medium)).foregroundStyle(LivePalette.secondary)
                }
            }
        }
        .padding(.horizontal, 10)
    }
}

/// A crest at slate size, lit by its own silhouette the way TeamBadge lights a
/// small one, with the room around it that the glow needs. Flattened inside
/// its own frame, a blur this wide is cut square at the edges, and a square of
/// light behind a crest reads as a sticker.
struct LiveCrest: View {
    let url: String
    let fallback: String
    let size: CGFloat

    var body: some View {
        let rim = max(3, size * 0.06)
        LineupArtView(url: URL(string: url), width: size) { loaded in
            if let image = loaded {
                let art = image.resizable().scaledToFit().frame(width: size, height: size)
                ZStack {
                    LineupStyle.logoPlate.mask { art.blur(radius: rim) }.opacity(0.6)
                    art
                }
                .frame(width: size + rim * 6, height: size + rim * 6)
                .drawingGroup()
                .frame(width: size, height: size)
            } else {
                Text(fallback)
                    .font(.inter(max(12, size * 0.28), .black))
                    .foregroundStyle(LivePalette.secondary)
                    .lineLimit(1).minimumScaleFactor(0.6)
            }
        }
        .frame(width: size, height: size)
        .transaction { $0.animation = nil }
        .accessibilityHidden(true)
    }
}

/// A broadcast's LIVE bug.
struct LiveOnAirTag: View {
    var body: some View {
        HStack(spacing: 7) {
            Circle().fill(LineupStyle.onLive).frame(width: 7, height: 7)
            Text("LIVE").font(.inter(14, .heavy)).tracking(0.6)
        }
        .foregroundStyle(LineupStyle.onLive)
        .padding(.horizontal, 12).frame(height: 30)
        .background(LivePalette.onAir, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
        .accessibilityHidden(true)
    }
}

/// Where a game on air stands -- the clock, the inning -- behind its red dot.
struct LiveStatusCapsule: View {
    let status: String

    var body: some View {
        HStack(spacing: 11) {
            PulsingLiveDot(size: 9)
            Text(status.isEmpty ? "LIVE" : status.uppercased())
                .font(.inter(18, .heavy)).tracking(0.6)
                .lineLimit(1).minimumScaleFactor(0.7)
        }
        .foregroundStyle(LivePalette.text)
        .padding(.horizontal, 20).frame(height: 42)
        .background(Color.black.opacity(0.35), in: Capsule())
        .overlay(Capsule().strokeBorder(LivePalette.onAir.opacity(0.65), lineWidth: 1.5))
    }
}

/// What Select will do, said once, at the foot of the slate.
struct LiveActionHint: View {
    let hint: LiveHint

    var body: some View {
        // While channels refresh, the pop-up at the top of the screen says so.
        if hint != .refreshing {
            HStack(spacing: 10) {
                Image(systemName: hint == .secondGame ? "rectangle.split.2x1.fill" : "play.fill")
                    .font(.system(size: 14, weight: .bold, design: .rounded))
                Text(hint == .secondGame ? "SELECT TO WATCH SIDE BY SIDE" : "SELECT TO PREVIEW")
                    .font(.inter(15, .heavy)).tracking(0.6)
            }
            .foregroundStyle(LivePalette.text)
            .padding(.horizontal, 22).frame(height: 44)
            .background(.white.opacity(0.08), in: Capsule())
            .overlay(Capsule().strokeBorder(.white.opacity(0.18), lineWidth: 1))
            .fixedSize()
        }
    }
}

/// The slate with nothing to show: still dressed, never a black rectangle.
struct LiveEmptySlate: View {
    let isLoading: Bool
    let isAvailable: Bool
    let errorMessage: String?

    var body: some View {
        ZStack {
            LiveSlateBackdrop()
            VStack(spacing: 18) {
                Image(systemName: isLoading ? "antenna.radiowaves.left.and.right" : "sportscourt")
                    .font(.system(size: 52, weight: .ultraLight, design: .rounded))
                    .foregroundStyle(LivePalette.secondary)
                Text(isLoading ? "Setting the board." :
                     (isAvailable ? "A moment between games." : "The schedule is unavailable."))
                    .font(.inter(46, .bold)).foregroundStyle(LivePalette.text)
                    .multilineTextAlignment(.center)
                Text(isLoading ? "Tonight's games will be here in a moment." :
                     (isAvailable ? "Come back for the next matchup." :
                        (errorMessage ?? "We’ll try again shortly.")))
                    .font(.inter(21)).foregroundStyle(LivePalette.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 680)
            }
            .padding(48)
        }
    }
}

/// The feed, at sixteen by nine, with the score either side of it.
///
/// The monitor is wider than a picture, so a playing feed always left two
/// black bars beside it. They carry each side's crest and score now, the way
/// a stadium hangs its scoreboards either side of the big screen.
struct LiveVideoWall: View {
    let stream: XtreamStream
    let game: SportsGame?
    let urls: [URL]

    var body: some View {
        GeometryReader { proxy in
            let picture = min(proxy.size.width, proxy.size.height * 16 / 9)
            let flank = max(0, (proxy.size.width - picture) / 2)
            HStack(spacing: 0) {
                LiveFlank(game: game, isHome: false).frame(width: flank)
                LiveSelectedPreview(stream: stream, game: game, urls: urls)
                    .id(stream.id)
                    .frame(width: picture)
                    .overlay(alignment: .topLeading) { LiveTallyChip().padding(20) }
                LiveFlank(game: game, isHome: true).frame(width: flank)
            }
            .frame(width: proxy.size.width, height: proxy.size.height)
        }
    }
}

/// One side's scoreboard beside a playing feed: its crest and score on the
/// monitor's plain black.
struct LiveFlank: View {
    let game: SportsGame?
    let isHome: Bool

    var body: some View {
        GeometryReader { proxy in
            if let game, !game.isEvent, proxy.size.width >= 140 {
                let score = isHome ? game.homeScore : game.awayScore
                let abbreviation = isHome ? game.homeAbbreviation : game.awayAbbreviation
                VStack(spacing: 12) {
                    LiveCrest(url: isHome ? game.homeLogo : game.awayLogo, fallback: abbreviation,
                              size: min(92, proxy.size.width * 0.5))
                    Text(abbreviation).font(.inter(20, .heavy)).tracking(0.6)
                        .foregroundStyle(LivePalette.secondary)
                    if game.isLive, !score.isEmpty {
                        Text(score).font(.interDigits(56, .bold))
                            .foregroundStyle(LivePalette.text)
                            .contentTransition(.numericText())
                    } else if let record = nonempty(isHome ? game.homeRecord : game.awayRecord) {
                        Text(record).font(.interDigits(17, .medium)).foregroundStyle(LivePalette.secondary)
                    }
                }
                .frame(width: proxy.size.width, height: proxy.size.height)
            }
        }
        .accessibilityHidden(true)
    }
}

/// A small tally on the playing feed, so a preview reads as live television.
struct LiveTallyChip: View {
    var body: some View {
        HStack(spacing: 8) {
            Circle().fill(LivePalette.onAir).frame(width: 8, height: 8)
            Text("PREVIEW").font(.inter(13, .heavy)).tracking(0.6)
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 12).frame(height: 30)
        .background(.black.opacity(0.55), in: Capsule())
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

/// The viewer's teams, beside the monitor.
///
/// Followed teams' games only; everything else is on the board beneath. With
/// nobody followed, or nobody of theirs playing, it says which -- and where
/// following happens, because a hold-Select menu is not something anyone finds
/// by accident.
struct LiveMyTeams: View {
    @Environment(SportsLibrary.self) private var library
    @Environment(\.liveGameActions) private var actions
    let events: [SportsGame]
    let spotlight: LiveSpotlight
    let previewGameID: String?
    let multiviewPrimaryID: Int?
    let hideFocus: FocusState<LiveMyTeamsControl?>.Binding
    let onHide: () -> Void
    let onPlay: (SportsGame) -> Void
    let onStartMultiview: (SportsGame) -> Void

    var body: some View {
        let mine = events.filter { library.isFollowing($0) }
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 14) {
                LiveEyebrow(title: "MY TEAMS", live: mine.filter(\.isLive).count,
                            detail: mine.isEmpty ? nil : "\(mine.count) \(mine.count == 1 ? "GAME" : "GAMES")")
                LiveMyTeamsHideButton(focus: hideFocus, action: onHide)
            }
            if mine.isEmpty {
                LiveMyTeamsEmpty(teams: library.followedTeams.teams, hasGames: !events.isEmpty)
            } else {
                ScrollView(.vertical) {
                    VStack(spacing: 12) {
                        ForEach(mine) { game in
                            LiveTeamRow(game: game, isOnScreen: game.id == previewGameID,
                                        isPrimary: multiviewPrimaryID != nil
                                            && multiviewPrimaryID == library.stream(for: game)?.id,
                                        onFocus: { spotlight.rest(on: game) },
                                        onPlay: { onPlay(game) },
                                        onStartMultiview: { onStartMultiview(game) })
                                .id(game.id)
                        }
                    }
                    .padding(LiveMetrics.liftRoom)
                }
                .scrollIndicators(.hidden)
                .padding(-LiveMetrics.liftRoom)
            }
            // The NFL teams followed, recorded: as on the phone, with a
            // provider that keeps recordings.
            if let actions, library.followedTeams.teams.contains(where: { $0.league == "NFL" }),
               let profile = library.activeProfile, !profile.isPlaylist {
                TVGameReplaysEntry(action: actions.replays)
            }
        }
    }
}

/// The two controls that put My Teams away and bring it back.
enum LiveMyTeamsControl: Hashable {
    case hide, show
}

/// In My Teams' heading: puts the rail away so the monitor can run the
/// full width of the board, the picture centred.
struct LiveMyTeamsHideButton: View {
    let focus: FocusState<LiveMyTeamsControl?>.Binding
    let action: () -> Void

    var body: some View {
        let focused = focus.wrappedValue == .hide
        let shape = Capsule()
        HStack(spacing: 7) {
            Image(systemName: "chevron.left").font(.system(size: 13, weight: .bold, design: .rounded))
            Text("Hide").font(.inter(15, .semibold))
        }
        .foregroundStyle(LivePalette.text)
        .padding(.horizontal, 14).frame(height: 36)
        .background(LineupStyle.raised, in: shape)
        .overlay(shape.strokeBorder(LivePalette.rule, lineWidth: 1))
        .lineupFocusLayer(focused, in: shape)
        .scaleEffect(focused ? LineupStyle.controlLift : 1)
        .animation(.spring(response: 0.24, dampingFraction: 0.8), value: focused)
        .contentShape(shape)
        .focusable()
        .focused(focus, equals: .hide)
        .focusEffectDisabled()
        .tvSelectAction(action)
        .accessibilityLabel("Hide My Teams")
        .accessibilityAddTraits(.isButton)
    }
}

/// With My Teams put away: a tab on the monitor's left edge that brings it
/// back.
struct LiveMyTeamsTab: View {
    let focus: FocusState<LiveMyTeamsControl?>.Binding
    let action: () -> Void

    var body: some View {
        let focused = focus.wrappedValue == .show
        let shape = RoundedRectangle(cornerRadius: 14, style: .continuous)
        VStack(spacing: 10) {
            Image(systemName: "star.fill").font(.system(size: 16, weight: .semibold, design: .rounded))
            Image(systemName: "chevron.right").font(.system(size: 14, weight: .bold, design: .rounded))
        }
        .foregroundStyle(LivePalette.text)
        .frame(width: 48, height: 116)
        .background(Color.black.opacity(0.6), in: shape)
        .overlay(shape.strokeBorder(Color.white.opacity(0.2), lineWidth: 1))
        .lineupFocusLayer(focused, in: shape)
        .scaleEffect(focused ? LineupStyle.controlLift : 1)
        .animation(.spring(response: 0.24, dampingFraction: 0.8), value: focused)
        .contentShape(shape)
        .focusable()
        .focused(focus, equals: .show)
        .focusEffectDisabled()
        .tvSelectAction(action)
        .accessibilityLabel("Show My Teams")
        .accessibilityAddTraits(.isButton)
    }
}

/// A section's small-caps title, with a red count when anything is on air.
struct LiveEyebrow: View {
    let title: String
    var live = 0
    var detail: String?

    var body: some View {
        HStack(spacing: 9) {
            Text(title.uppercased()).font(.inter(20, .heavy)).tracking(LineupPanelStyle.headerTracking)
                .foregroundStyle(LineupPanelStyle.caption)
            Spacer(minLength: 10)
            if live > 0 {
                Circle().fill(LivePalette.onAir).frame(width: 7, height: 7)
                Text("\(live) LIVE").font(.inter(14, .heavy)).tracking(0.6)
                    .foregroundStyle(LineupStyle.liveStatus)
            } else if let detail {
                Text(detail).font(.inter(14, .heavy)).tracking(0.6).foregroundStyle(LivePalette.secondary)
            }
        }
        .frame(height: 30)
    }
}

/// My Teams with nothing to list: says which empty it is.
struct LiveMyTeamsEmpty: View {
    let teams: [FollowedTeam]
    let hasGames: Bool

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 20, style: .continuous)
        VStack(alignment: .leading, spacing: 14) {
            ZStack {
                Circle().fill(LivePalette.accent.opacity(0.16))
                Image(systemName: teams.isEmpty ? "star" : "moon.zzz")
                    .font(.system(size: 24, weight: .semibold, design: .rounded))
                    .foregroundStyle(LivePalette.accent)
            }
            .frame(width: 58, height: 58)
            Text(teams.isEmpty ? "Follow your teams" : "Your teams are off")
                .font(.inter(26, .bold)).foregroundStyle(LivePalette.text)
            Text(teams.isEmpty
                 ? "Choose your teams in Settings > My Teams, or hold Select on a game to add one."
                 : "None of your teams play in this range.")
                .font(.inter(18)).foregroundStyle(LivePalette.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if !teams.isEmpty {
                VStack(spacing: 0) {
                    ForEach(Array(teams.prefix(5))) { team in
                        HStack(spacing: 12) {
                            if let league = SportsLeague(rawValue: team.league.lowercased()), league.isRacing {
                                SportsMark(league: league, size: 30)
                            } else {
                                TeamBadge(url: team.logo, fallback: team.abbreviation, size: 30)
                            }
                            Text(team.name).font(.inter(17, .semibold))
                                .foregroundStyle(LivePalette.text).lineLimit(1)
                            Spacer(minLength: 8)
                            Text("NO GAME").font(.inter(12, .heavy)).tracking(0.6)
                                .foregroundStyle(LivePalette.secondary)
                        }
                        .padding(.vertical, 10)
                        .overlay(alignment: .top) { Rectangle().fill(LivePalette.rule).frame(height: 1) }
                    }
                }
                .padding(.top, 4)
            }
        }
        .padding(26)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .background(LivePalette.card.opacity(0.55), in: shape)
        .overlay(shape.strokeBorder(LivePalette.rule, lineWidth: 1))
    }
}

/// One of the viewer's games: both sides, the score, and where it stands.
struct LiveTeamRow: View {
    @FocusState private var focused: Bool
    let game: SportsGame
    let isOnScreen: Bool
    let isPrimary: Bool
    let onFocus: () -> Void
    let onPlay: () -> Void
    let onStartMultiview: () -> Void

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 16, style: .continuous)
        let lead = liveLeader(game)
        VStack(alignment: .leading, spacing: 9) {
            if game.isEvent {
                HStack(spacing: 12) {
                    LeagueLogo(league: game.isNFLRedZone ? .nfl : game.league, size: 30)
                    Text(game.matchupLine).font(.inter(19, .semibold))
                        .foregroundStyle(LivePalette.text).lineLimit(2).minimumScaleFactor(0.8)
                }
            } else {
                side(game.awayTeam, game.awayAbbreviation, game.awayLogo, game.awayScore, dim: lead == .home, isAway: true)
                side(game.homeTeam, game.homeAbbreviation, game.homeLogo, game.homeScore, dim: lead == .away, isAway: false)
            }
            HStack(spacing: 8) {
                if game.isLive {
                    PulsingLiveDot(size: 6)
                    Text(game.status.isEmpty ? "LIVE" : game.status.uppercased())
                        .foregroundStyle(LineupStyle.liveStatus).lineLimit(1)
                } else {
                    Text(game.startLabel.uppercased()).foregroundStyle(LivePalette.text).lineLimit(1)
                }
                Text(game.league.shortName).foregroundStyle(LivePalette.secondary)
                Spacer(minLength: 6)
                if isPrimary {
                    LiveTag(symbol: "rectangle.split.2x1.fill", title: "FIRST GAME")
                } else if isOnScreen {
                    LiveTag(symbol: "tv.fill", title: "ON SCREEN")
                }
            }
            .font(.inter(13, .bold)).tracking(1.3)
        }
        .padding(.leading, 20).padding(.trailing, 18).padding(.vertical, 15)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background { LiveCardSurface(shape: shape, isLive: game.isLive, tally: .leading) }
        .overlay {
            shape.strokeBorder(isPrimary ? LivePalette.rim : LivePalette.rule, lineWidth: isPrimary ? 2 : 1)
        }
        .lineupFocusLayer(focused, in: shape)
        .contentShape(shape)
        .focusable().focused($focused).focusEffectDisabled()
        .tvSelectAction(onPlay)
        .onChange(of: focused) { _, value in if value { onFocus() } }
        .modifier(LiveGameMenu(game: game, isPrimary: isPrimary, onStartMultiview: onStartMultiview))
        .scaleEffect(focused ? LineupStyle.cardLift : 1)
        .lineupShadow(.lifted, on: focused)
        .zIndex(focused ? 1 : 0)
        .animation(.spring(response: 0.26, dampingFraction: 0.82), value: focused)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(liveAccessibilityLabel(game))
        .accessibilityAddTraits(.isButton)
    }

    private func side(_ name: String, _ abbreviation: String, _ logo: String, _ score: String,
                      dim: Bool, isAway: Bool) -> some View {
        HStack(spacing: 12) {
            TeamBadge(url: logo, fallback: abbreviation.isEmpty ? String(name.prefix(3)).uppercased() : abbreviation,
                      size: 30)
            Text(name).font(.inter(18, .semibold))
                .foregroundStyle(dim ? LivePalette.secondary : LivePalette.text)
                .lineLimit(1).minimumScaleFactor(0.75)
            Spacer(minLength: 8)
            if game.isLive, let sets = game.tennis {
                TennisSetColumns(score: sets, isAway: isAway, size: 22,
                                 primary: LivePalette.text, secondary: LivePalette.secondary)
            } else if game.isLive, !score.isEmpty {
                Text(score).font(.interDigits(24, .bold))
                    .foregroundStyle(dim ? LivePalette.secondary : LivePalette.text)
                    .contentTransition(.numericText())
            }
        }
    }
}

/// The surface a game sits on: the theme's card, a little light along its top
/// edge, and -- while the game is on air -- a tally strip in broadcast red.
struct LiveCardSurface: View {
    enum Tally { case top, leading }
    let shape: RoundedRectangle
    let isLive: Bool
    var tally: Tally = .top

    // The panels' flat fill. A game that is on says so in its status line,
    // in red, as on the phone; a stripe across the top said it twice.
    var body: some View {
        LivePalette.card.clipShape(shape)
    }
}

/// A small filled tag: this game is on the monitor, or is multiview's first.
struct LiveTag: View {
    let symbol: String
    let title: String
    /// The symbol alone, where the row needs the room.
    var compact = false

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: symbol).font(.system(size: 11, weight: .bold, design: .rounded))
            if !compact {
                Text(title).font(.inter(12, .heavy)).tracking(0.6)
            }
        }
        .foregroundStyle(LineupStyle.onHighlight)
        .padding(.horizontal, 9).frame(height: 24)
        .background(LivePalette.accent, in: Capsule())
        .fixedSize()
    }
}

/// Hold Select on any game: a reminder, either side into My Teams, or
/// multiview. The same on the board and in the rail, so following is offered
/// wherever a game is -- the rail is empty until somebody is followed, so a
/// follow that lived only there could never be reached on a fresh install.
struct LiveGameMenu: ViewModifier {
    @Environment(SportsLibrary.self) private var library
    @EnvironmentObject private var reminders: GameReminders
    @Environment(\.liveChooseChannel) private var chooseChannel
    @Environment(\.liveGameActions) private var actions
    @State private var showingRaceDetails = false
    let game: SportsGame
    let isPrimary: Bool
    let onStartMultiview: () -> Void

    func body(content: Content) -> some View {
        content.tvHoldMenu(game.matchupLine, symbol: "sportscourt", tint: LineupStyle.leagueColor(game.league)) {
            var items: [TVChoice] = []
            if game.league.isRacing {
                items.append(TVChoice("Race Details", symbol: "flag.checkered") { showingRaceDetails = true })
            }
            items += actions?.liveItems(for: game, library: library) ?? []
            if game.isUpcoming {
                let on = reminders.reminds(game)
                items.append(TVChoice(on ? "Remove Reminder" : "Remind Me", symbol: on ? "bell.slash" : "bell") {
                    reminders.toggleGame(game)
                })
            }
            // A channel of the viewer's own for this game, and whether to
            // keep it for either team, as on iPhone.
            if let chooseChannel {
                items.append(TVChoice("Choose Another Channel", symbol: "list.bullet.rectangle") { chooseChannel(game) })
            }
            items += actions?.teamItems(for: game, library: library) ?? []
            for team in library.followableSides(of: game) {
                let following = library.isFollowing(team.key)
                items.append(TVChoice(following ? "Remove \(team.name) from My Teams" : "Add \(team.name) to My Teams",
                                      symbol: following ? "star.slash" : "star", id: "follow-\(team.id)") {
                    library.toggleFollow(team)
                })
            }
            if library.stream(for: game) != nil {
                items.append(TVChoice("Start Multiview", symbol: "rectangle.split.2x1", isEnabled: !isPrimary,
                                      action: onStartMultiview))
            }
            return items
        }
        .lineupFullScreenCover(isPresented: $showingRaceDetails) { RacingSessionDetails(game: game) }
    }
}

/// Every matchup, four across, beneath the monitor.
///
/// One row shows at a time and Down brings the next four. Every row stays in
/// the focus tree rather than being built on demand, because a row that does
/// not exist yet is a row Up cannot find.
struct LiveMatchupBoard: View {
    @Environment(SportsLibrary.self) private var library
    let events: [SportsGame]
    @Binding var selectedLeague: SportsLeague?
    let spotlight: LiveSpotlight
    @Binding var soccerCompetition: String?
    let previewGameID: String?
    let multiviewPrimaryID: Int?
    let multiviewTitle: String?
    let isScheduleLoading: Bool
    let isScheduleAvailable: Bool
    let onPlay: (SportsGame) -> Void
    let onStartMultiview: (SportsGame) -> Void
    let onCancelMultiview: () -> Void

    private var rows: Int { events.count }

    /// Multiview's first game, named by its matchup rather than by whatever
    /// the provider calls the channel carrying it.
    private var firstGame: SportsGame? {
        guard let multiviewPrimaryID else { return nil }
        return events.first { library.stream(for: $0)?.id == multiviewPrimaryID }
    }

    /// The board's word on an empty night. The monitor above carries the
    /// mood and any error, so this says what to do next.
    private var emptyLane: LiveEmptyLane {
        if isScheduleLoading {
            return LiveEmptyLane(title: "Games are loading…", detail: "The board fills in as each league answers.")
        }
        guard isScheduleAvailable else {
            return LiveEmptyLane(title: "No matchups to show.", detail: "Your channels are still in Guide.")
        }
        guard let selectedLeague else {
            return LiveEmptyLane(title: "No games in this range.", detail: "Your channels are still in Guide.")
        }
        return LiveEmptyLane(title: "No \(liveLeagueName(selectedLeague)) games in this range.",
                             detail: "Switch to All sports to see every league.")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            // The panels' hairline under the header.
            Rectangle().fill(LineupStyle.line).frame(height: 1)
            if events.isEmpty {
                emptyLane
            } else {
                LiveMatchupList(events: events, spotlight: spotlight, previewGameID: previewGameID,
                                multiviewPrimaryID: multiviewPrimaryID,
                                onPlay: onPlay, onStartMultiview: onStartMultiview)
            }
        }
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 18) {
            if let multiviewTitle {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Choose a second game").font(.inter(26, .bold)).foregroundStyle(LivePalette.text)
                    Text("MULTIVIEW  ·  FIRST GAME  \((firstGame.map(liveHeadline) ?? multiviewTitle).uppercased())")
                        .font(.inter(13, .heavy)).tracking(0.6)
                        .foregroundStyle(LivePalette.secondary).lineLimit(1)
                }
            } else {
                // The panels' header: icon and heavy caption in light grey.
                HStack(alignment: .firstTextBaseline, spacing: 16) {
                    HStack(spacing: 12) {
                        LineupIconTile(symbol: "sportscourt", size: LineupPanelStyle.headerSize * 1.6)
                        Text(selectedLeague?.isRacing == true ? "EVENTS" : "MATCHUPS")
                            .font(.inter(LineupPanelStyle.headerSize + 2, .heavy))
                            .tracking(LineupPanelStyle.headerTracking)
                    }
                    .foregroundStyle(LineupPanelStyle.caption)
                    LiveBoardCount(total: events.count, live: events.filter(\.isLive).count,
                                   noun: selectedLeague?.isRacing == true ? "EVENT" : "GAME")
                }
            }
            Spacer(minLength: 20)
            LiveRowPager(spotlight: spotlight, rows: rows)
            if multiviewTitle != nil {
                TVSelectable(scale: LineupStyle.controlLift, drawsFocusChrome: false, action: onCancelMultiview) {
                    LiveChipLabel(symbol: "xmark", title: "Cancel multiview")
                }
            } else {
                if selectedLeague == .soccer { SoccerCompetitionFilter(selected: $soccerCompetition) }
                LiveLeagueFilter(selectedLeague: $selectedLeague)
            }
        }
        .frame(height: 56)
    }
}

/// The board with nothing on it: a dashed lane where the cards go, so the
/// screen keeps its shape and says why it is empty.
struct LiveEmptyLane: View {
    let title: String
    let detail: String

    var body: some View {
        HStack(spacing: 18) {
            Image(systemName: "calendar").font(.system(size: 28, weight: .light, design: .rounded))
                .foregroundStyle(LivePalette.secondary)
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.inter(22, .semibold)).foregroundStyle(LivePalette.text)
                Text(detail).font(.inter(17)).foregroundStyle(LivePalette.secondary).lineLimit(2)
            }
        }
        .frame(maxWidth: .infinity)
        .frame(height: LiveMetrics.cardHeight)
        .background {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .strokeBorder(LivePalette.rule, style: StrokeStyle(lineWidth: 1.5, dash: [7, 7]))
        }
        .padding(.vertical, LiveMetrics.liftRoom)
    }
}

/// "24 GAMES · 6 LIVE", beside the board's title.
struct LiveBoardCount: View {
    let total: Int
    let live: Int
    var noun = "GAME"

    var body: some View {
        HStack(spacing: 10) {
            Text("\(total) \(noun)\(total == 1 ? "" : "S")")
            if live > 0 {
                Circle().fill(LivePalette.onAir).frame(width: 7, height: 7)
                Text("\(live) LIVE").foregroundStyle(LineupStyle.liveStatus)
            }
        }
        .font(.inter(14, .heavy)).tracking(0.6)
        .foregroundStyle(LivePalette.secondary)
    }
}

/// Which row of the board is showing, and that there are more beneath it.
struct LiveRowPager: View {
    @ObservedObject var spotlight: LiveSpotlight
    let rows: Int

    private var current: Int { min(max(spotlight.boardRow, 0), max(rows - 1, 0)) }

    var body: some View {
        if rows > 1 {
            HStack(spacing: 7) {
                if rows <= 10 {
                    ForEach(0..<rows, id: \.self) { row in
                        Capsule()
                            .fill(row == current ? LivePalette.text : LivePalette.secondary.opacity(0.35))
                            .frame(width: row == current ? 22 : 7, height: 7)
                    }
                } else {
                    Text("\(current + 1) / \(rows)").font(.interDigits(15, .bold))
                        .foregroundStyle(LivePalette.secondary)
                }
            }
            .animation(.spring(response: 0.3, dampingFraction: 0.82), value: current)
            .accessibilityHidden(true)
        }
    }
}

/// The sport filter: one chip, at the head of the board it filters.
struct LiveLeagueFilter: View {
    @Binding var selectedLeague: SportsLeague?
    @State private var choosing = false

    private var title: String {
        selectedLeague.map(liveLeagueName) ?? "All sports"
    }

    var body: some View {
        // TVSelectable over a confirmation dialog, the shape the rest of the
        // app uses: a menu would draw the television's own focus plate over a
        // chip that already draws its own.
        TVSelectable(scale: LineupStyle.controlLift, drawsFocusChrome: false, action: { choosing = true }) {
            LiveChipLabel(symbol: "line.3.horizontal.decrease", title: title,
                          league: selectedLeague, trailing: "chevron.down")
        }
        .tvChoices("Show which sport?", symbol: "sportscourt", isPresented: $choosing) {
            [TVChoice("All Sports", id: "all", isSelected: selectedLeague == nil) { selectedLeague = nil }]
                + SportsLeague.allCases.map { league in
                    TVChoice(liveLeagueName(league), id: league.rawValue, isSelected: selectedLeague == league) {
                        selectedLeague = league
                    }
                }
        }
        .accessibilityLabel("Filter by sport")
    }
}

/// A chip's face. Focus fills it, the way the app's other action pills mark
/// focus, rather than drawing a second frame around it.
struct LiveChipLabel: View {
    @Environment(\.lineupTVSelectableFocused) private var focused
    let symbol: String
    let title: String
    var league: SportsLeague?
    var trailing: String?

    var body: some View {
        HStack(spacing: 10) {
            if let league {
                LeagueLogo(league: league, size: 24)
            } else {
                LineupIconTile(symbol: symbol, size: 30)
            }
            Text(title).font(.inter(17, .semibold)).lineLimit(1)
            if let trailing {
                Image(systemName: trailing).font(.system(size: 13, weight: .bold, design: .rounded)).opacity(0.7)
            }
        }
        .foregroundStyle(LivePalette.text)
        .padding(.leading, league == nil ? 8 : 20).padding(.trailing, 20).frame(height: 46)
        // The phone's pill: the panels' fill, no outline.
        .background(LivePalette.card, in: Capsule())
        .lineupFocusLayer(focused, in: Capsule())
        .lineupShadow(.lifted, on: focused)
        .animation(.spring(response: 0.22, dampingFraction: 0.8), value: focused)
    }
}

/// A full-width, remote-focusable matchup list. Each event keeps its existing
/// selection and hold-menu actions; focusing a row still drives the unchanged
/// Live preview stage above it.
struct LiveMatchupList: View {
    let events: [SportsGame]
    let spotlight: LiveSpotlight
    let previewGameID: String?
    let multiviewPrimaryID: Int?
    let onPlay: (SportsGame) -> Void
    let onStartMultiview: (SportsGame) -> Void

    /// Room for a crest as tall as a team's name and record together, with
    /// the arena under it, all large enough to read across a room.
    private let rowHeight: CGFloat = 144
    private let viewportHeight: CGFloat = 360

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView(.vertical) {
                LazyVStack(spacing: 9) {
                    ForEach(Array(events.enumerated()), id: \.element.id) { index, game in
                        LiveMatchupListRow(game: game, isOnScreen: game.id == previewGameID,
                                           multiviewPrimaryID: multiviewPrimaryID,
                                           rowHeight: rowHeight,
                                           onFocus: {
                                               spotlight.rest(on: game, row: index)
                                               proxy.scrollTo(game.id, anchor: .center)
                                           },
                                           onPlay: { onPlay(game) },
                                           onStartMultiview: { onStartMultiview(game) })
                            .id(game.id)
                    }
                }
                .padding(.horizontal, LiveMetrics.liftRoom)
                .padding(.vertical, LiveMetrics.liftRoom)
            }
            .scrollIndicators(.hidden)
            .focusSection()
        }
        .frame(height: viewportHeight)
        .clipped()
    }
}

/// The channel-list look adapted for a television: muted team-color wash,
/// prominent crests and score lines, and the same quiet status column.
///
/// A game reads across the card as a broadcast's score line does: each
/// team's crest, name and record at its end of the card, the score between
/// them either side of VS, and the arena and its city under it all. An event
/// -- a tournament, a fight card, a race -- keeps its mark and its name.
struct LiveMatchupListRow: View {
    @Environment(SportsLibrary.self) private var library
    @FocusState private var focused: Bool
    let game: SportsGame
    let isOnScreen: Bool
    let multiviewPrimaryID: Int?
    let rowHeight: CGFloat
    let onFocus: () -> Void
    let onPlay: () -> Void
    let onStartMultiview: () -> Void

    private var isPrimary: Bool {
        multiviewPrimaryID != nil && multiviewPrimaryID == library.stream(for: game)?.id
    }

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 17, style: .continuous)
        HStack(spacing: 22) {
            if game.isEvent {
                eventContent
            } else {
                matchupContent
            }
            // The home team ends where the status begins; a hairline keeps
            // its name from reading into the clock.
            Rectangle().fill(Color.white.opacity(0.08)).frame(width: 1, height: 88)
                .padding(.leading, 6)

            VStack(alignment: .leading, spacing: 8) {
                if game.isLive {
                    HStack(spacing: 8) {
                        PulsingLiveDot(size: 8)
                        Text(game.status.isEmpty ? "LIVE NOW" : game.status.uppercased())
                            .font(.inter(17, .heavy)).tracking(0.6)
                            .foregroundStyle(LineupStyle.liveStatus).lineLimit(1)
                    }
                } else {
                    Text(game.startLabel).font(.interDigits(20, .semibold))
                        .foregroundStyle(LivePalette.text).lineLimit(1)
                }
                // A game's row has no league column, so its mark rides
                // with the network; an event's stands at its start.
                HStack(spacing: 8) {
                    if !game.isEvent {
                        SportsMark(league: game.league, competition: game.competition, size: 22)
                    }
                    if let network = nonempty(game.broadcast) {
                        Text(network.uppercased()).font(.inter(13, .heavy)).tracking(0.5)
                            .foregroundStyle(LivePalette.secondary.opacity(0.78)).lineLimit(1)
                    }
                }
                HStack(spacing: 8) {
                    Image(systemName: isPrimary ? "rectangle.split.2x1.fill" :
                            (isOnScreen ? "tv.fill" : "play.fill"))
                        .font(.system(size: 14, weight: .bold, design: .rounded))
                    Text(isPrimary ? "FIRST GAME" : (isOnScreen ? "ON SCREEN" : "SELECT TO WATCH"))
                        .font(.inter(12, .heavy)).tracking(0.5).lineLimit(1)
                }
                .foregroundStyle(LivePalette.secondary.opacity(0.82))
            }
            .frame(width: 280, alignment: .leading)
        }
        .padding(.horizontal, 26).padding(.vertical, 10)
        .frame(maxWidth: .infinity).frame(height: rowHeight)
        .background {
            LiveEventWash(colors: LiveEventColors(game: game))
                .clipShape(shape)
        }
        .overlay(shape.strokeBorder(Color.white.opacity(0.045), lineWidth: 1))
        .lineupFocusLayer(focused, in: shape)
        .contentShape(shape)
        .focusable().focused($focused).focusEffectDisabled()
        .tvSelectAction(onPlay)
        .onChange(of: focused) { _, value in if value { onFocus() } }
        .modifier(LiveGameMenu(game: game, isPrimary: isPrimary, onStartMultiview: onStartMultiview))
        .scaleEffect(focused ? 1.012 : 1)
        .lineupShadow(.lifted, on: focused)
        .zIndex(focused ? 1 : 0)
        .animation(.spring(response: 0.26, dampingFraction: 0.82), value: focused)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(liveAccessibilityLabel(game))
        .accessibilityAddTraits(.isButton)
    }

    /// A tournament, a fight card or a race: its mark, then its name.
    private var eventContent: some View {
        HStack(spacing: 22) {
            SportsMark(league: game.league, competition: game.competition, size: 48)
                .frame(width: 74)
            VStack(alignment: .leading, spacing: 5) {
                Text(game.competition?.name.uppercased() ?? game.league.shortName.uppercased())
                    .font(.inter(13, .heavy)).tracking(0.6)
                    .foregroundStyle(LivePalette.secondary.opacity(0.82)).lineLimit(1)
                Text(game.eventName ?? game.league.shortName)
                    .font(.inter(24, .semibold)).foregroundStyle(LivePalette.text)
                    .lineLimit(1).minimumScaleFactor(0.78)
                if let session = game.race?.title {
                    Text(session).font(.inter(16, .semibold))
                        .foregroundStyle(LineupStyle.highlight.opacity(0.8)).lineLimit(1)
                }
                if let place = game.placeLine, !place.isEmpty {
                    Text(place).font(.inter(14, .medium)).foregroundStyle(LivePalette.secondary.opacity(0.78))
                        .lineLimit(1)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        }
    }

    /// Crest, name and record at each end, the score either side of VS in
    /// the middle, and where it is under the score.
    private var matchupContent: some View {
        let lead = liveLeader(game)
        return VStack(spacing: 6) {
            HStack(spacing: 0) {
                teamSide(game.awayTeam, abbreviation: game.awayAbbreviation, logo: game.awayLogo,
                         record: game.awayRecord, dim: lead == .home)
                    .frame(maxWidth: .infinity, alignment: .leading)
                scoreLine(lead: lead)
                    .padding(.horizontal, 24)
                    .layoutPriority(1)
                teamSide(game.homeTeam, abbreviation: game.homeAbbreviation, logo: game.homeLogo,
                         record: game.homeRecord, dim: lead == .away)
                    .frame(maxWidth: .infinity, alignment: .trailing)
            }
            if let place = matchupPlace {
                Text(place).font(.inter(21, .medium)).foregroundStyle(LivePalette.secondary.opacity(0.82))
                    .lineLimit(1).minimumScaleFactor(0.8).truncationMode(.tail)
                    .frame(maxWidth: .infinity, alignment: .center)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// The arena and its city and state, and a soccer match's own note
    /// after them.
    private var matchupPlace: String? {
        let parts = [game.fullPlaceLine, game.soccer?.detail].compactMap(nonempty)
        return parts.isEmpty ? nil : parts.joined(separator: " \u{00B7} ")
    }

    /// One team: its crest large, its name, and its record under the name.
    private func teamSide(_ name: String, abbreviation: String, logo: String, record: String?,
                          dim: Bool) -> some View {
        HStack(spacing: 20) {
            TeamBadge(url: logo,
                      fallback: abbreviation.isEmpty ? String(name.prefix(3)).uppercased() : abbreviation,
                      size: 88, tight: true)
            VStack(alignment: .leading, spacing: 4) {
                Text(name).font(.inter(36, .semibold))
                    .foregroundStyle(dim ? LivePalette.secondary : LivePalette.text)
                    .lineLimit(1).minimumScaleFactor(0.7)
                if let record = nonempty(record) {
                    Text(record).font(.interDigits(22, .medium))
                        .foregroundStyle(LivePalette.secondary.opacity(0.82)).lineLimit(1)
                }
            }
        }
    }

    /// "3  VS  0": the away score, VS, the home score. Before the start, or
    /// with no score to give, VS alone; a tennis match, its sets either side.
    private func scoreLine(lead: LiveLead) -> some View {
        HStack(spacing: 20) {
            score(game.awayScore, isAway: true, dim: lead == .home)
            Text("VS").font(.inter(21, .heavy)).tracking(1.4)
                .foregroundStyle(LivePalette.secondary.opacity(0.8))
            score(game.homeScore, isAway: false, dim: lead == .away)
        }
    }

    @ViewBuilder
    private func score(_ value: String, isAway: Bool, dim: Bool) -> some View {
        if game.isLive, let sets = game.tennis {
            TennisSetColumns(score: sets, isAway: isAway, size: 30,
                             primary: LivePalette.text, secondary: LivePalette.secondary)
        } else if !game.isUpcoming, !value.isEmpty {
            Text(value).font(.interDigits(52, .bold))
                .foregroundStyle(dim ? LivePalette.secondary : LivePalette.text)
                .contentTransition(.numericText())
                .lineLimit(1).fixedSize()
        }
    }
}

/// Which side is ahead, for dimming the other.
enum LiveLead { case away, home, level }

func liveLeader(_ game: SportsGame) -> LiveLead {
    guard game.isLive, let away = Int(game.awayScore), let home = Int(game.homeScore),
          away != home else { return .level }
    return away > home ? .away : .home
}

/// A team's colour, lifted until it can glow on a dark screen; the theme's own
/// colour stands in for a side the schedule has no colour for.
/// "8:20 PM" as "8:20" and "PM", so the period can be set smaller than the
/// time. A clock with no period, in a 24-hour locale, comes back whole.
func liveTimeParts(_ date: Date) -> (time: String, period: String?) {
    let text = date.formatted(.dateTime.hour().minute())
    guard let letter = text.firstIndex(where: \.isLetter), letter != text.startIndex else { return (text, nil) }
    let time = text[..<letter].trimmingCharacters(in: .whitespaces)
    let period = text[letter...].trimmingCharacters(in: .whitespaces)
    return time.isEmpty ? (text, nil) : (time, period.isEmpty ? nil : period)
}

func liveDayLabel(_ date: Date) -> String {
    let calendar = Calendar.current
    if calendar.isDateInToday(date) { return calendar.component(.hour, from: date) >= 17 ? "TONIGHT" : "TODAY" }
    if calendar.isDateInTomorrow(date) { return "TOMORROW" }
    return date.formatted(.dateTime.weekday(.wide)).uppercased()
}

/// What each sport calls its start.
func liveStartWord(_ league: SportsLeague) -> String {
    switch league {
    case .nfl, .ncaaf: "KICKOFF"
    case .nba: "TIP-OFF"
    case .nhl: "PUCK DROP"
    case .mlb: "FIRST PITCH"
    case .ufc: "MAIN CARD"
    case .atp, .wta: "FIRST SERVE"
    case .soccer: "KICKOFF"
    case .f1: "LIGHTS OUT"
    case .nascar: "GREEN FLAG"
    }
}

/// A league as the sport filter names it.
func liveLeagueName(_ league: SportsLeague) -> String {
    league == .ncaaf ? "College" : league.shortName
}

/// The matchup in a line: "BOS 3 – NYY 5", "BOS @ MIL", or an event's name.
func liveHeadline(_ game: SportsGame) -> String {
    if game.isEvent { return game.matchupLine }
    if game.isLive && !game.awayScore.isEmpty && !game.homeScore.isEmpty {
        return "\(game.awayAbbreviation) \(game.awayScore)  –  \(game.homeAbbreviation) \(game.homeScore)"
    }
    return "\(game.awayAbbreviation) \(game.sidesSymbol) \(game.homeAbbreviation)"
}

func liveAccessibilityLabel(_ game: SportsGame) -> String {
    let matchup = game.matchupLine
    guard game.isLive else { return "\(matchup), \(game.start.formatted(date: .abbreviated, time: .shortened))" }
    let score = game.awayScore.isEmpty || game.homeScore.isEmpty ? "" : ", \(game.awayScore) to \(game.homeScore)"
    return "\(matchup)\(score), \(game.status.isEmpty ? "live" : game.status)"
}

struct LiveSelectedPreview: View {
    @Environment(SportsLibrary.self) private var library
    @StateObject private var controller = TVPlaybackController(place: .sports)
    @State private var choosingGame: SportsGame?
    @State private var pickedChannel: TVPickedChannel?
    @State private var scopingChannel: TVPickedChannel?
    let stream: XtreamStream
    let game: SportsGame?
    let urls: [URL]

    var body: some View {
        TVHostedSurface(controller: controller)
            .overlay(alignment: .bottomLeading) { TVPreviewFormatBadges(controller: controller) }
            .overlay { TVPlaybackStatus(controller: controller) }.background(Color.black)
        .onAppear {
            // Back from full screen, where it played on: nothing to open.
            guard !controller.isOpen else { return }
            if let game {
                configureGameFailover(controller, game: game, library: library) { choosingGame = game }
            }
            controller.start(urls: urls, muted: false, channelID: stream.id)
            TVPreviewHandoff.previewing(stream.id, in: controller)
        }
        .lineupFullScreenCover(item: $choosingGame, onDismiss: {
            scopingChannel = library.asksScope(for: pickedChannel)
            pickedChannel = nil
        }) { game in
            ManualGameChannelPicker(game: game) { chosen in
                library.saveGameSelection(chosen, for: game)
                pickedChannel = TVPickedChannel(game: game, stream: chosen, startsMultiview: false)
                choosingGame = nil
                controller.start(urls: library.playbackURLs(for: chosen), channelID: chosen.id)
            }
        }
        .channelScopePrompt($scopingChannel)
        .onDisappear { if !controller.lentToFullScreen { controller.stop() } }
    }
}
/// A steady broadcast-red core with a slow halo around it. The core never
/// blinks or changes size, so it remains a crisp status mark; only the light
/// it casts breathes. That reads as an illuminated indicator rather than a
/// generic animated circle.
/// On air, as a small red dot.
///
/// It was a glossy bead -- a gradient, a rim, a glow and a halo -- which at
/// these sizes read as a smudge of red rather than a mark. Flat and smaller,
/// its edge stays crisp from across a room, and a slow breath is what says
/// *now*: a still dot is a bullet point.
struct PulsingLiveDot: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let size: CGFloat

    /// Three quarters of what each caller asked for: every live dot in the
    /// app gets smaller at once, without reworking the rows that hold them.
    private var diameter: CGFloat { (size * 0.72).rounded() }

    var body: some View {
        Group {
            if reduceMotion {
                dot(opacity: 1)
            } else {
                // Breathing from phase to phase, which the animation system
                // runs. A clock redrew every dot on screen twenty times a
                // second for as long as a game was on, and that was work the
                // main thread had in hand when the viewer changed tabs. A
                // repeating animation is no answer either: it takes hold of
                // any move the dot makes while it runs, which left the dot
                // drifting after the panel holding it slid in. A phase
                // animator animates only what its phases change.
                dot(opacity: 1)
                    .phaseAnimator([false, true]) { dot, dimmed in
                        dot.opacity(dimmed ? 0.45 : 1)
                    } animation: { _ in
                        .easeInOut(duration: 1.1)
                    }
            }
        }
        .accessibilityHidden(true)
    }

    private func dot(opacity: Double) -> some View {
        Circle()
            .fill(LineupStyle.liveDot)
            .frame(width: diameter, height: diameter)
            .opacity(opacity)
    }
}

struct LiveTicker: View {
    /// The strip keeps its height; its words fill more of it, to be read
    /// from the couch.
    static let height: CGFloat = 38

    let events: [SportsGame]
    var isActive = true
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private let cardWidth = CGFloat(TVTickerWindow.cardWidth)
    /// As tall as the strip has room for with the scores beside it; a wide
    /// mark has more room across.
    private let logoSize: CGFloat = 34
    private let logoWidth: CGFloat = 58
    private let emptyWidth: CGFloat = 520

    var body: some View {
        HStack(alignment: .bottom, spacing: 24) {
            // The crawl's bug, in the theme's own colour, the way a broadcast
            // brands the corner its scores come in from.
            Text("SCORES")
                .font(.inter(17, .heavy)).tracking(0.7)
                .foregroundStyle(LineupStyle.onHighlight)
                .padding(.horizontal, 14).frame(height: 31)
                .background(LineupStyle.highlight, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                .padding(.bottom, 3)
            TVScoreTicker(events: events, active: isActive && !reduceMotion) { entries in
                AnyView(tickerContent(entries).fixedSize(horizontal: true, vertical: false)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading).ignoresSafeArea())
            }
            // Scores fade in and out at the ends rather than being cut off.
            .mask {
                LinearGradient(stops: [
                    .init(color: .clear, location: 0), .init(color: .black, location: 0.06),
                    .init(color: .black, location: 0.94), .init(color: .clear, location: 1)
                ], startPoint: .leading, endPoint: .trailing)
            }
        }
        .padding(.horizontal, LiveMetrics.margin).padding(.bottom, 2)
        .overlay(alignment: .top) { Rectangle().fill(LineupStyle.line).frame(height: 1) }
        .transaction { $0.animation = nil }
        .allowsHitTesting(false)
    }

    private func tickerContent(_ entries: [TVTickerEntry]) -> some View {
        HStack(spacing: 0) {
            if entries.isEmpty {
                Text("NO LIVE OR FINAL SCORES YET")
                    .font(.inter(21, .heavy)).tracking(0.7)
                    .foregroundStyle(LineupStyle.secondary).lineLimit(1)
                    .frame(width: emptyWidth, alignment: .leading)
            } else {
                // Every column keeps its fixed width: the scroll arithmetic
                // above counts in whole items of `cardWidth`.
                ForEach(entries.indices, id: \.self) { slot in
                    let game = entries[slot].game
                    HStack(alignment: .firstTextBaseline, spacing: 12) {
                        // The league's own mark, as the board shows it,
                        // centred on the team codes' capitals.
                        LeagueLogo(league: game.isNFLRedZone ? .nfl : game.league,
                                   size: logoSize, width: logoWidth)
                            .frame(width: logoWidth + 8, alignment: .leading)
                            .alignmentGuide(.firstTextBaseline) { $0.height / 2 + 10 }
                            .accessibilityLabel(game.league.shortName)
                        Text(game.awayAbbreviation)
                            .font(.inter(28, .bold))
                            .foregroundStyle(sportsReadableTeamColor(game.awayColor) ?? LineupStyle.text)
                            .frame(width: 92, alignment: .leading)
                        Text(game.awayScore)
                            .font(.interDigits(30, .bold)).foregroundStyle(LineupStyle.text)
                            .frame(width: 62, alignment: .trailing)
                        Text("–").font(.inter(24, .medium)).foregroundStyle(LineupStyle.secondary)
                        Text(game.homeAbbreviation)
                            .font(.inter(28, .bold))
                            .foregroundStyle(sportsReadableTeamColor(game.homeColor) ?? LineupStyle.text)
                            .frame(width: 92, alignment: .leading)
                        Text(game.homeScore)
                            .font(.interDigits(30, .bold)).foregroundStyle(LineupStyle.text)
                            .frame(width: 62, alignment: .trailing)
                        Text(game.isLive ? game.status.uppercased() : "FINAL")
                            .font(.inter(18, .heavy)).tracking(0.7)
                            .foregroundStyle(game.isLive ? LineupStyle.liveStatus : LineupStyle.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .lineLimit(1)
                    .frame(width: cardWidth, alignment: .leading)
                    .padding(.trailing, CGFloat(entries[slot].spacing))
                }
            }
        }
    }
}

func sportsReadableTeamColor(_ value: String?) -> Color? {
    guard var value = nonempty(value) else { return nil }
    value = value.replacingOccurrences(of: "#", with: "")
    guard value.count == 6, let hex = UInt64(value, radix: 16) else { return nil }
    var red = Double((hex >> 16) & 0xff) / 255
    var green = Double((hex >> 8) & 0xff) / 255
    var blue = Double(hex & 0xff) / 255
    // Provider colors can contain white too; keep those ticker labels on theme.
    if min(red, green, blue) > 0.75 && max(red, green, blue) - min(red, green, blue) < 0.12 {
        return LineupStyle.lightPurple
    }
    let luminance = (red * 0.2126) + (green * 0.7152) + (blue * 0.0722)
    if luminance < 0.50 {
        let whiteMix = (0.50 - luminance) / max(0.01, 1 - luminance)
        red += (1 - red) * whiteMix
        green += (1 - green) * whiteMix
        blue += (1 - blue) * whiteMix
    }
    return Color(red: red, green: green, blue: blue)
}

func nonempty(_ value: String?) -> String? {
    guard let value, !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
    return value
}

func sportsSymbol(_ league: SportsLeague) -> String {
    switch league {
    case .nfl, .ncaaf: "football.fill"
    case .nba: "basketball.fill"
    case .nhl: "hockey.puck.fill"
    case .mlb: "baseball.fill"
    case .ufc: "figure.martial.arts"
    case .atp, .wta: "tennisball.fill"
    case .soccer: "soccerball"
    case .f1, .nascar: "flag.checkered"
    }
}

struct LeagueLogo: View {
    let league: SportsLeague
    let size: CGFloat
    /// Room across for a mark wider than it is tall -- UFC's, the tennis
    /// tours' -- which a square would shrink. Square by default.
    var width: CGFloat?

    private var logoURL: URL? {
        guard league != .ncaaf && league != .ufc && !league.isTennis else { return nil }
        return URL(string: "https://a.espncdn.com/i/teamlogos/leagues/500/\(league.rawValue).png")
    }

    var body: some View {
        Group {
            // ESPN has no league mark for these: UFC, the NCAA's and the
            // tennis tours' come with the app.
            if league == .soccer || league.isRacing {
                SportsMark(league: league, size: size)
            } else if league == .ufc || league == .ncaaf || league.isTennis {
                Image("League-\(league.rawValue)").resizable().scaledToFit()
            } else {
                LineupArtView(url: logoURL, width: size) { loaded in
                    if let image = loaded {
                        image.resizable().scaledToFit().colorMultiply(LineupStyle.lightPurple)
                    } else {
                        Image(systemName: sportsSymbol(league))
                            .resizable().scaledToFit()
                            .padding(size * 0.18)
                            .foregroundStyle(LineupStyle.secondary)
                    }
                }
            }
        }
        .transaction { $0.animation = nil }
        .frame(width: width ?? size, height: size)
        .clipped()
    }
}

struct ScreenHeading: View {
    let title: String
    let detail: String
    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            Rectangle().fill(LineupStyle.highlight).frame(width: 42, height: 4)
            Text(title).font(.inter(44, .bold)).tracking(-1).foregroundStyle(LineupStyle.text)
            Text(detail).font(.inter(.callout, .medium)).foregroundStyle(LineupStyle.secondary)
        }
    }
}

struct ChannelLogo: View {
    let url: String?
    var width: CGFloat = 74
    var height: CGFloat = 54
    var body: some View {
        LineupArtView(url: URL(string: url ?? ""), width: width) { loaded in
            if let image = loaded { image.resizable().scaledToFit().colorMultiply(LineupStyle.lightPurple) }
            else { Image(systemName: "tv").font(.inter(.caption)).foregroundStyle(LineupStyle.secondary) }
        }
        .transaction { $0.animation = nil }
        .padding(4).frame(width: width, height: height).background(LineupStyle.raised)
    }
}
