#if os(tvOS)
import SwiftUI

/// The stats' sizes, as `GameStatsScale` has them on the television.
private func scaled(_ points: CGFloat) -> CGFloat { GameStatsScale.size(points) }

/// Live stats for the game on screen, beside the picture: the score as far as
/// the picture has got, its chances, and its plays, box score and leaders,
/// every one of them held until the picture shows it. The phone's panel, read
/// from across a room and moved through with the remote.
///
/// Syncing happens in the panel rather than on a sheet over the picture, so
/// the picture stays in view beside it to be watched against. Back leaves
/// the sync steps, and from the stats closes the panel.
struct TVGameStatsPanel: View {
    /// The panel's width. The picture keeps the rest: 1280 of the screen's
    /// 1920 points, which is 16:9 exactly.
    static let width: CGFloat = 640

    @ObservedObject var stats: MobileGameStats
    @ObservedObject var autoSync: MobileAutoSync
    let game: SportsGame
    /// Where the remote lands as it comes into the panel: the sync chip.
    let entry: FocusState<Bool>.Binding
    let onClose: () -> Void

    enum StatsSection: String, CaseIterable, Identifiable {
        case plays = "Plays", box = "Box Score", leaders = "Leaders"
        case courts = "Courts", card = "Fight Card", positions = "Positions"
        var id: String { rawValue }
    }
    /// Nil until chosen: the first of the game's own.
    @State private var section: StatsSection?
    /// Showing the sync steps in place of the stats.
    @State private var syncing = false
    /// The play Select was pressed on, asked about.
    @State private var syncingPlay: GameStatsPlay?

    /// What a game of this kind has to show, the one to open on first, as
    /// on the phone.
    private var sections: [StatsSection] {
        switch game.statsSource {
        case .tennis?: [.courts]
        case .card?: [.card, .plays]
        case .race?: [.positions, .plays]
        default: [.plays, .box, .leaders]
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            if syncing {
                TVStatsSyncFlow(stats: stats, game: game,
                                autoSync: stats.autoSyncSport == nil ? nil : autoSync,
                                onDone: leaveSync)
            } else {
                content
            }
        }
        .foregroundStyle(LineupStyle.text)
        .padding(.leading, 20).padding(.trailing, 44).padding(.top, 50).padding(.bottom, 30)
        .frame(width: Self.width)
        .frame(maxHeight: .infinity, alignment: .top)
        .background(LineupPanelStyle.fill)
        .overlay(alignment: .leading) { Rectangle().fill(Color.white.opacity(0.06)).frame(width: 1) }
        .lineupFocusRegion()
        .onExitCommand { if syncing { leaveSync() } else { onClose() } }
        .tvChoices("Sync to This Play", symbol: "timer",
                   isPresented: Binding(get: { syncingPlay != nil }, set: { if !$0 { syncingPlay = nil } }),
                   message: syncingPlay?.text) {
            guard let play = syncingPlay else { return [] }
            return [TVChoice("It Just Happened on My Screen", symbol: "checkmark.circle") { stats.sync(to: play) }]
        }
        .animation(.easeInOut(duration: 0.2), value: syncing)
    }

    private func enterSync() {
        syncing = true
    }

    private func leaveSync() {
        syncing = false
        Task { @MainActor in await Task.yield(); entry.wrappedValue = true }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 14) {
                LineupIconTile(symbol: syncing ? "timer" : "chart.bar.fill", size: 40)
                Text(syncing ? "SYNC STATS TO YOUR STREAM" : "LIVE STATS")
                    .font(.inter(LineupPanelStyle.headerSize, .heavy)).tracking(LineupPanelStyle.headerTracking)
                    .foregroundStyle(LineupPanelStyle.caption).lineLimit(1)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, scaled(16)).padding(.bottom, 16)
            Rectangle().fill(LineupPanelStyle.divider).frame(height: 1)
        }
        .padding(.bottom, 22)
    }

    @ViewBuilder
    private var content: some View {
        if let reveal = stats.reveal {
            let options = sections
            let shown = section.flatMap { options.contains($0) ? $0 : nil } ?? options[0]
            headline(reveal).padding(.horizontal, scaled(16))
            syncChip(reveal).padding(.horizontal, scaled(16)).padding(.top, 22)
            if let home = reveal.homeWinProbability {
                WinProbabilityBar(reveal: reveal, home: home).padding(.horizontal, scaled(16)).padding(.top, 24)
            }
            // One section needs no chips to choose it.
            if options.count > 1 {
                HStack(spacing: 12) {
                    ForEach(options) { option in
                        TVSelectable(scale: LineupStyle.controlLift, drawsFocusChrome: false,
                                     action: { withAnimation(.easeInOut(duration: 0.16)) { section = option } }) {
                            TVStatsChip(title: option.rawValue, selected: shown == option)
                        }
                    }
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, scaled(16)).padding(.top, 24).padding(.bottom, 16)
            } else {
                Color.clear.frame(height: 18)
            }
            Rectangle().fill(LineupPanelStyle.divider).frame(height: 1)
            // Each row takes the remote, so the list scrolls under it.
            ScrollView {
                switch shown {
                case .plays: plays(reveal)
                case .box: box(reveal)
                case .leaders: leaders(reveal)
                case .courts:
                    // The newest draw, at once: only the match on screen
                    // waits for the picture.
                    if let latest = reveal.latestBoard?.tennis {
                        let onScreen = latest.focus ?? stats.focus
                        let pick: ((String) -> Void)? = latest.focus == nil ? { (id: String) in stats.focus = id } : nil
                        MobileTennisCourts(courts: GameStatsTennisBoard.courts(latest: latest, shown: reveal.board?.tennis,
                                                                               onScreen: onScreen),
                                           onScreen: onScreen, onPick: pick)
                    } else {
                        message("No courts yet.", symbol: "sportscourt")
                    }
                case .card:
                    if let card = reveal.board?.card {
                        MobileFightCardList(card: card)
                    } else {
                        message("The card appears once your stream reaches it.", symbol: "list.bullet")
                    }
                case .positions:
                    if let race = reveal.board?.race {
                        MobileRacePositions(race: race, earlier: reveal.earlierBoard?.race)
                    } else {
                        message("The order appears once your stream reaches it.", symbol: "list.bullet")
                    }
                }
            }
            .scrollIndicators(.hidden)
        } else if stats.unavailable {
            message("Stats aren't available for this game.", symbol: "chart.bar")
        } else {
            VStack(spacing: 16) {
                ProgressView().tint(LineupStyle.text)
                Text("Loading stats…").font(.inter(22)).foregroundStyle(LineupPanelStyle.quiet)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    // MARK: Score

    /// The top of the panel: a team game's score, or the board's own.
    @ViewBuilder
    private func headline(_ reveal: GameStatsReveal) -> some View {
        switch reveal.board {
        case .tennis(let draw)?:
            MobileTennisHeader(draw: draw, match: draw.focused ?? stats.focus.flatMap { id in
                draw.matches.first { $0.id == id }
            })
        case .card(let card)?: MobileFightHeader(card: card)
        case .race(let race)?: MobileRaceHeader(race: race)
        case nil:
            if let latest = reveal.latestBoard?.tennis {
                // Not reached yet: who is playing, and nothing of the score.
                let match = latest.focused ?? stats.focus.flatMap { id in latest.matches.first { $0.id == id } }
                MobileTennisHeader(draw: latest, match: match?.withheld, catchingUp: true)
            } else if game.statsSource?.isBoard == true {
                waitingHeader
            } else {
                scoreboard(reveal)
            }
        }
    }

    /// A board not yet reached: what it is, and nothing of how it stands.
    private var waitingHeader: some View {
        let title = game.isEvent ? [game.eventName, game.race?.title].compactMap { $0 }.joined(separator: " · ")
                                 : "\(game.awayTeam) vs \(game.homeTeam)"
        return VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.inter(scaled(17), .bold)).lineLimit(2)
            Text("Held until your stream gets here").font(.inter(scaled(13))).foregroundStyle(LineupPanelStyle.quiet)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func scoreboard(_ reveal: GameStatsReveal) -> some View {
        HStack(spacing: 16) {
            team(logo: game.awayLogo, code: SportsGame.code(reveal.away.abbreviation, game.awayTeam))
            Text("\(reveal.awayScore)").font(.interDigits(scaled(30), .bold))
                .foregroundStyle(reveal.awayScore >= reveal.homeScore ? LineupStyle.text : LineupPanelStyle.quiet)
            Text(reveal.status.isEmpty ? "—" : reveal.status)
                .font(.interDigits(scaled(13), .heavy))
                .foregroundStyle(reveal.state == "in" ? LineupStyle.liveStatus : LineupPanelStyle.quiet)
                .lineLimit(1).minimumScaleFactor(0.7)
                .frame(maxWidth: .infinity)
            Text("\(reveal.homeScore)").font(.interDigits(scaled(30), .bold))
                .foregroundStyle(reveal.homeScore >= reveal.awayScore ? LineupStyle.text : LineupPanelStyle.quiet)
            team(logo: game.homeLogo, code: SportsGame.code(reveal.home.abbreviation, game.homeTeam))
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(reveal.away.name) \(reveal.awayScore), \(reveal.home.name) \(reveal.homeScore), \(reveal.status)")
    }

    private func team(logo: String, code: String) -> some View {
        VStack(spacing: 5) {
            TeamBadge(url: logo, fallback: code, size: scaled(32))
            Text(code).font(.inter(scaled(11), .heavy)).foregroundStyle(LineupPanelStyle.quiet)
        }
    }

    /// How the stats are kept with the picture, and the way in to set it.
    private func syncChip(_ reveal: GameStatsReveal) -> some View {
        TVSelectable(scale: LineupStyle.cardLift, drawsFocusChrome: false, action: enterSync) {
            TVStatsSyncChipLabel(calibrated: stats.calibrated, text: syncText(reveal))
        }
        .focused(entry)
        .accessibilityHint("Matches the stats to your picture")
    }

    private func syncText(_ reveal: GameStatsReveal) -> String {
        let seconds = Int(stats.totalDelay.rounded())
        if reveal.catchingUp { return "Catching up to your stream · \(reveal.catchingUpFor ?? seconds)s" }
        if stats.needsFocus { return "Pick the match on your screen to sync" }
        if autoSync.status == .synced { return "Auto-synced · your stream is \(seconds)s behind live" }
        if !stats.calibrated {
            switch autoSync.status {
            case .reading(.starting): return "Auto Sync is reading the scoreboard…"
            case .reading(.noPicture): return "Auto Sync isn't getting a picture"
            case .reading(.noScoreboard): return "Auto Sync is looking for the scoreboard…"
            case .reading(.matching(let clock?, let agreeing, let needed)):
                return "Auto Sync · \(MobileAutoSync.clock(clock)) · \(agreeing) of \(needed) plays matched"
            case .reading(.matching(nil, let agreeing, let needed)):
                return "Auto Sync · score read · \(agreeing) of \(needed) plays matched"
            case .resting: return "Auto Sync paused: Apple TV is warm"
            case .off, .synced: break
            }
        }
        return stats.calibrated ? "In sync · your stream is \(seconds)s behind live"
                                : "Held \(seconds)s behind live · select to sync"
    }

    // MARK: Sections

    @ViewBuilder
    private func plays(_ reveal: GameStatsReveal) -> some View {
        let shown = reveal.plays
        if shown.isEmpty {
            message(reveal.state == "pre" ? "Plays appear here once it starts."
                    : (reveal.board == nil ? "No plays yet." : "Plays appear here as they happen."),
                    symbol: "list.bullet")
        } else {
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(shown.prefix(120)) { play in
                    // Select a play the moment it shows on screen: the stats
                    // sync to it.
                    GameStatsPlayRow(play: play, reveal: reveal, game: game)
                        .lineupRowFocus { if play.timedMoment != nil { syncingPlay = play } }
                    Rectangle().fill(LineupPanelStyle.divider).frame(height: 1).padding(.leading, scaled(16))
                }
            }
        }
    }

    @ViewBuilder
    private func box(_ reveal: GameStatsReveal) -> some View {
        if reveal.lines.isEmpty {
            message(reveal.catchingUp ? "The box score appears once your stream reaches it."
                                      : "No box score yet.", symbol: "tablecells")
        } else {
            LazyVStack(spacing: 0) {
                HStack {
                    Text(SportsGame.code(reveal.away.abbreviation, game.awayTeam))
                    Spacer()
                    Text(SportsGame.code(reveal.home.abbreviation, game.homeTeam))
                }
                .font(.inter(scaled(12), .heavy)).foregroundStyle(LineupPanelStyle.quiet)
                .padding(.horizontal, scaled(16)).padding(.vertical, scaled(10))
                ForEach(Array(reveal.lines.enumerated()), id: \.offset) { _, line in
                    HStack(spacing: 12) {
                        Text(line.away).font(.interDigits(scaled(15), .semibold)).frame(width: scaled(74), alignment: .leading)
                        Text(line.label).font(.inter(scaled(13))).foregroundStyle(LineupPanelStyle.quiet)
                            .multilineTextAlignment(.center).frame(maxWidth: .infinity)
                        Text(line.home).font(.interDigits(scaled(15), .semibold)).frame(width: scaled(74), alignment: .trailing)
                    }
                    .padding(.horizontal, scaled(16)).padding(.vertical, scaled(9))
                    .lineupRowFocus()
                    Rectangle().fill(LineupPanelStyle.divider).frame(height: 1).padding(.horizontal, scaled(16))
                }
            }
        }
    }

    @ViewBuilder
    private func leaders(_ reveal: GameStatsReveal) -> some View {
        if reveal.leaders.isEmpty {
            message(reveal.catchingUp ? "Leaders appear once your stream reaches them." : "No leaders yet.",
                    symbol: "person.2")
        } else {
            LazyVStack(spacing: 0) {
                ForEach(Array(reveal.leaders.enumerated()), id: \.offset) { _, leader in
                    let home = leader.teamID == reveal.home.id
                    HStack(spacing: 18) {
                        TeamBadge(url: home ? game.homeLogo : game.awayLogo,
                                  fallback: home ? reveal.home.abbreviation : reveal.away.abbreviation, size: scaled(26))
                        VStack(alignment: .leading, spacing: 3) {
                            Text(leader.category.uppercased()).font(.inter(scaled(10), .heavy)).tracking(0.8)
                                .foregroundStyle(LineupPanelStyle.quiet)
                            Text(leader.athlete).font(.inter(scaled(15), .semibold)).lineLimit(1)
                        }
                        Spacer(minLength: 12)
                        Text(leader.value).font(.interDigits(scaled(14), .semibold)).multilineTextAlignment(.trailing)
                            .lineLimit(2)
                    }
                    .padding(.horizontal, scaled(16)).padding(.vertical, scaled(10))
                    .lineupRowFocus()
                    Rectangle().fill(LineupPanelStyle.divider).frame(height: 1).padding(.leading, scaled(54))
                }
            }
        }
    }

    private func message(_ text: String, symbol: String) -> some View {
        VStack(spacing: 16) {
            LineupIconTile(symbol: symbol, size: scaled(34))
            Text(text).font(.inter(scaled(14))).foregroundStyle(LineupPanelStyle.quiet).multilineTextAlignment(.center)
        }
        .padding(.horizontal, 30).padding(.vertical, 40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// The sync chip: how the stats are kept with the picture, as a capsule
/// that wears the focus layer itself.
private struct TVStatsSyncChipLabel: View {
    @Environment(\.lineupTVSelectableFocused) private var focused
    let calibrated: Bool
    let text: String

    var body: some View {
        let shape = Capsule()
        HStack(spacing: 12) {
            Image(systemName: calibrated ? "checkmark.circle.fill" : "timer")
                .font(.system(size: 21, weight: .bold, design: .rounded))
                .foregroundStyle(calibrated ? LineupIconTile.green : LineupStyle.highlight)
            Text(text).font(.inter(19, .semibold)).lineLimit(1).minimumScaleFactor(0.7)
            Spacer(minLength: 6)
            Text(calibrated ? "Adjust" : "Sync").font(.inter(19, .bold)).foregroundStyle(LineupStyle.highlight)
        }
        .padding(.horizontal, 22).frame(height: 58)
        .background(LineupPanelStyle.well, in: shape)
        .lineupFocusLayer(focused, in: shape)
        .animation(.easeOut(duration: 0.16), value: focused)
    }
}

/// A section chip: filled with the accent when chosen, its outline otherwise.
private struct TVStatsChip: View {
    @Environment(\.lineupTVSelectableFocused) private var focused
    let title: String
    let selected: Bool

    var body: some View {
        let shape = Capsule()
        Text(title).font(.inter(21, .bold)).lineLimit(1)
            .foregroundStyle(selected ? LineupStyle.onHighlight : LineupStyle.highlight)
            .padding(.horizontal, 22).frame(height: 48)
            .background(shape.fill(selected ? LineupStyle.highlight : Color.clear))
            .overlay(shape.strokeBorder(selected ? Color.clear : LineupStyle.highlight, lineWidth: 2))
            .lineupFocusLayer(focused, in: shape)
            .animation(.easeOut(duration: 0.16), value: focused)
    }
}

/// A button in the sync steps, on the panel's well grey or, for the one a
/// step is waiting on, the accent.
private struct TVStatsButtonLabel: View {
    @Environment(\.lineupTVSelectableFocused) private var focused
    let title: String
    var symbol: String? = nil
    var prominent = false
    var height: CGFloat = 64

    var body: some View {
        let shape = Capsule()
        HStack(spacing: 12) {
            if let symbol {
                Image(systemName: symbol).font(.system(size: 21, weight: .bold, design: .rounded))
            }
            Text(title).font(.inter(21, .semibold)).lineLimit(1).minimumScaleFactor(0.8)
        }
        .foregroundStyle(prominent ? LineupStyle.onHighlight : LineupStyle.text)
        .padding(.horizontal, 20).frame(maxWidth: .infinity).frame(height: height)
        .background(prominent ? LineupStyle.highlight : LineupPanelStyle.well, in: shape)
        .lineupFocusLayer(focused, in: shape)
        .animation(.easeOut(duration: 0.16), value: focused)
    }
}

/// Matching the stats to the picture, one play at a time, as the phone's
/// sync sheet does it.
///
/// It shows the latest play the stats have shown and asks whether it is on
/// the viewer's screen. "It Just Happened" syncs to that moment exactly.
/// "Not Yet" holds it back and waits for the viewer to say when it plays.
/// "Already Saw It" steps on to the next play and asks again.
private struct TVStatsSyncFlow: View {
    @ObservedObject var stats: MobileGameStats
    let game: SportsGame
    /// Nil where the scoreboard cannot be read: tennis, fights, races.
    var autoSync: MobileAutoSync?
    let onDone: () -> Void

    private enum Step: Equatable {
        /// Is this play on the viewer's screen?
        case asking(GameStatsPlay)
        /// Held back; select when it plays.
        case waiting(GameStatsPlay)
        /// Synced to this play.
        case synced(GameStatsPlay)
        /// ESPN has nothing later: the stream is as far on as the feed.
        case caughtUp(GameStatsPlay)
    }
    private enum Focus: Hashable {
        case primary, done, match(String)
    }
    @State private var step: Step?
    @State private var started = false
    @State private var showsFineTune = false
    @FocusState private var focus: Focus?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                Text("Every score, play and stat waits until your picture shows it.")
                    .font(.inter(19)).foregroundStyle(LineupPanelStyle.quiet)
                    .fixedSize(horizontal: false, vertical: true)

                if let autoSync { TVAutoSyncRow(autoSync: autoSync).padding(.top, 22) }

                Group {
                    if stats.needsFocus {
                        pickMatch
                    } else {
                        switch step {
                        case .asking(let play)?: asking(play)
                        case .waiting(let play)?: waiting(play)
                        case .synced(let play)?: synced(play, caughtUp: false)
                        case .caughtUp(let play)?: synced(play, caughtUp: true)
                        case nil: noPlays
                        }
                    }
                }
                .padding(.top, 22)
                .animation(.easeInOut(duration: 0.2), value: step)

                fineTune.padding(.top, 24)

                HStack(spacing: 14) {
                    TVSelectable(scale: LineupStyle.controlLift, drawsFocusChrome: false,
                                 action: { stats.resetDelay(); begin() }) {
                        TVStatsButtonLabel(title: "Start Over", symbol: "arrow.counterclockwise", height: 58)
                    }
                    TVSelectable(scale: LineupStyle.controlLift, drawsFocusChrome: false, action: onDone) {
                        TVStatsButtonLabel(title: "Done", prominent: true, height: 58)
                    }
                    .focused($focus, equals: .done)
                }
                .padding(.top, 24).padding(.bottom, 12)
            }
            .padding(.horizontal, scaled(16)).padding(.vertical, 8)
        }
        .scrollIndicators(.hidden)
        .onAppear {
            if !started { started = true; begin() }
            settleFocus()
        }
        // Steps opened before the first play have one to ask about once
        // ESPN times one.
        .onChange(of: stats.reveal?.plays.first?.id) { _, _ in if step == nil { begin() } }
        .onChange(of: step) { _, _ in settleFocus() }
    }

    private func begin() {
        step = stats.latestShownPlay.map(Step.asking)
    }

    /// The remote on what the step is waiting on: its answer, or Done.
    private func settleFocus() {
        Task { @MainActor in
            await Task.yield()
            if stats.needsFocus, let first = liveMatches.first {
                focus = .match(first.id)
                return
            }
            switch step {
            case .asking?, .waiting?: focus = .primary
            default: focus = .done
            }
        }
    }

    // MARK: Steps

    private func asking(_ play: GameStatsPlay) -> some View {
        VStack(spacing: 14) {
            playCard(play, caption: "LATEST PLAY IN YOUR STATS")
            Text("Is this on your screen yet?").font(.inter(21, .semibold))
            TVSelectable(scale: LineupStyle.controlLift, drawsFocusChrome: false, action: {
                stats.sync(to: play)
                step = .synced(play)
            }) {
                TVStatsButtonLabel(title: "It Just Happened", symbol: "checkmark", prominent: true)
            }
            .focused($focus, equals: .primary)
            HStack(spacing: 14) {
                TVSelectable(scale: LineupStyle.controlLift, drawsFocusChrome: false, action: {
                    stats.hold(before: play)
                    step = .waiting(play)
                }) {
                    TVStatsButtonLabel(title: "Not Yet", symbol: "hourglass")
                }
                TVSelectable(scale: LineupStyle.controlLift, drawsFocusChrome: false, action: {
                    if let next = stats.play(after: play) {
                        // Shown now, so it can be asked about.
                        stats.sync(to: next)
                        step = .asking(next)
                    } else {
                        stats.caughtUp(past: play)
                        step = .caughtUp(play)
                    }
                }) {
                    TVStatsButtonLabel(title: "Already Saw It", symbol: "forward.fill")
                }
            }
        }
    }

    private func waiting(_ play: GameStatsPlay) -> some View {
        VStack(spacing: 14) {
            playCard(play, caption: "WAITING FOR THIS PLAY")
            Text("Select the moment it happens on your screen. Stats are held back until then.")
                .font(.inter(19)).foregroundStyle(LineupPanelStyle.quiet).multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            TVSelectable(scale: LineupStyle.controlLift, drawsFocusChrome: false, action: {
                stats.sync(to: play)
                step = .synced(play)
            }) {
                TVStatsButtonLabel(title: "It's Happening Now", symbol: "hand.point.up.left.fill", prominent: true)
            }
            .focused($focus, equals: .primary)
        }
    }

    private func synced(_ play: GameStatsPlay, caughtUp: Bool) -> some View {
        VStack(spacing: 14) {
            HStack(spacing: 18) {
                Image(systemName: "checkmark.circle.fill").font(.system(size: 44, weight: .semibold))
                    .foregroundStyle(LineupIconTile.green)
                VStack(alignment: .leading, spacing: 5) {
                    Text("In sync").font(.inter(26, .bold))
                    Text(caughtUp || stats.delay == 0
                         ? "Your stream is as current as ESPN's feed. Stats show the moment ESPN has them."
                         : "Your stream is \(Self.duration(stats.delay)) behind live. Lineup remembers this for the channel.")
                        .font(.inter(19)).foregroundStyle(LineupPanelStyle.quiet)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
            }
            .padding(24)
            .background(LineupPanelStyle.well, in: RoundedRectangle(cornerRadius: 26, style: .continuous))
            Text("Synced to: \(play.text)").font(.inter(18)).foregroundStyle(LineupPanelStyle.quiet)
                .lineLimit(2).multilineTextAlignment(.center)
        }
    }

    /// Every match that could be on screen, on court now.
    private var liveMatches: [GameStatsTennisMatch] {
        guard let latest = stats.reveal?.latestBoard?.tennis else { return [] }
        return GameStatsTennisBoard.courts(latest: latest, shown: stats.reveal?.board?.tennis, onScreen: nil)
            .map(\.match).filter { $0.state == "in" }
    }

    /// A tournament with several matches on: which one is on screen.
    private var pickMatch: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Which match is on your screen?").font(.inter(21, .semibold))
            ForEach(liveMatches) { match in
                TVSelectable(scale: LineupStyle.cardLift, fillRadius: 26, action: {
                    stats.focus = match.id
                    begin()
                    settleFocus()
                }) {
                    VStack(alignment: .leading, spacing: 10) {
                        Text([match.round, match.court ?? ""].filter { !$0.isEmpty }.joined(separator: " · "))
                            .font(.inter(scaled(11), .semibold)).foregroundStyle(LineupPanelStyle.quiet)
                        MobileTennisMatchBoard(match: match, compact: true)
                    }
                    .padding(20)
                    .background(LineupPanelStyle.well, in: RoundedRectangle(cornerRadius: 26, style: .continuous))
                }
                .focused($focus, equals: .match(match.id))
            }
        }
    }

    private var noPlays: some View {
        VStack(spacing: 14) {
            LineupIconTile(symbol: "list.bullet", size: 50)
            Text(stats.reveal?.board == nil ? "Syncing works once the game's plays start."
                 : "Syncing works once something happens: a game, a round, a lap.")
                .font(.inter(21, .semibold)).multilineTextAlignment(.center)
            Text(stats.delay > 0 ? "Until then, stats are held \(Self.duration(stats.delay)) behind live."
                 : "Until then, stats show the moment ESPN has them.")
                .font(.inter(19)).foregroundStyle(LineupPanelStyle.quiet).multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 26).padding(.horizontal, 20)
        .background(LineupPanelStyle.well, in: RoundedRectangle(cornerRadius: 26, style: .continuous))
    }

    private func playCard(_ play: GameStatsPlay, caption: String) -> some View {
        VStack(spacing: 8) {
            Text(caption).font(.inter(16, .heavy)).tracking(1).foregroundStyle(LineupPanelStyle.quiet)
            Text([play.period, play.clock].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · "))
                .font(.interDigits(22, .heavy)).foregroundStyle(LineupStyle.highlight)
            Text(play.text).font(.inter(24, .semibold)).multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            if play.seen != nil {
                // A board's play: what it made, and which match or fight.
                Text([play.badge, play.drive].compactMap { $0 }.joined(separator: " · "))
                    .font(.interDigits(19, .semibold)).foregroundStyle(LineupPanelStyle.quiet)
                    .multilineTextAlignment(.center)
            } else if let reveal = stats.reveal {
                Text("\(reveal.away.abbreviation) \(play.awayScore) – \(play.homeScore) \(reveal.home.abbreviation)")
                    .font(.interDigits(19, .semibold)).foregroundStyle(LineupPanelStyle.quiet)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 22).padding(.horizontal, 20)
        .background(LineupPanelStyle.well, in: RoundedRectangle(cornerRadius: 26, style: .continuous))
    }

    // MARK: Fine-tune

    private var fineTune: some View {
        VStack(spacing: 14) {
            TVSelectable(scale: LineupStyle.controlLift, action: {
                withAnimation(.easeInOut(duration: 0.2)) { showsFineTune.toggle() }
            }) {
                HStack(spacing: 8) {
                    Text("Fine-tune").font(.inter(19, .semibold))
                    Image(systemName: "chevron.down").font(.system(size: 16, weight: .bold))
                        .rotationEffect(.degrees(showsFineTune ? 180 : 0))
                }
                .foregroundStyle(LineupPanelStyle.quiet)
                .padding(.horizontal, 14).padding(.vertical, 8)
            }
            .frame(maxWidth: .infinity)
            if showsFineTune {
                HStack(spacing: 12) {
                    nudge("−5", by: -5)
                    nudge("−1", by: -1)
                    VStack(spacing: 2) {
                        Text("\(Int(stats.delay.rounded()))s").font(.interDigits(32, .bold)).contentTransition(.numericText())
                        Text("BEHIND LIVE").font(.inter(14, .heavy)).tracking(1).foregroundStyle(LineupPanelStyle.quiet)
                    }
                    .frame(minWidth: 130)
                    nudge("+1", by: 1)
                    nudge("+5", by: 5)
                }
                Text("More seconds hold the stats back longer. Fewer show them sooner.")
                    .font(.inter(17)).foregroundStyle(LineupPanelStyle.quiet).multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .animation(.easeInOut(duration: 0.2), value: stats.delay)
    }

    private func nudge(_ title: String, by seconds: TimeInterval) -> some View {
        TVSelectable(scale: LineupStyle.controlLift, drawsFocusChrome: false, action: { stats.nudge(by: seconds) }) {
            TVStatsButtonLabel(title: title, height: 56)
        }
        .frame(width: 84)
        .accessibilityLabel(seconds < 0 ? "Show stats \(Int(-seconds)) seconds sooner"
                                        : "Hold stats \(Int(seconds)) seconds longer")
    }

    static func duration(_ seconds: TimeInterval) -> String {
        let whole = Int(seconds.rounded())
        return whole >= 60 ? "\(whole / 60)m \(whole % 60)s" : "\(whole)s"
    }
}

/// Auto Sync on or off, and what it is doing. Select switches it.
private struct TVAutoSyncRow: View {
    @ObservedObject var autoSync: MobileAutoSync

    var body: some View {
        TVSelectable(scale: LineupStyle.cardLift, drawsFocusChrome: false, action: { autoSync.isEnabled.toggle() }) {
            TVAutoSyncRowLabel(isEnabled: autoSync.isEnabled, detail: detail)
        }
        .accessibilityLabel("Auto Sync")
        .accessibilityValue(autoSync.isEnabled ? "On" : "Off")
    }

    private var detail: String {
        guard autoSync.isEnabled else {
            return "Reads the clock and score on your picture to keep the stats in step, on this Apple TV."
        }
        switch autoSync.status {
        case .synced: return "In step with the scoreboard on your picture. It keeps watching in case your stream moves."
        case .reading(.starting): return "Reading the clock and score on your picture. It takes a minute of play."
        case .reading(.noPicture):
            return "This player isn't handing Auto Sync its picture, so the scoreboard can't be read. Syncing by hand still works."
        case .reading(.noScoreboard):
            return "No game clock on your picture right now. Ads and replays hide the scoreboard; it's picked up again when it's back."
        case .reading(.matching(let clock, let agreeing, let needed)):
            let reading = clock.map { "the clock at \(MobileAutoSync.clock($0))" } ?? "the score"
            return "Reading \(reading) on your picture. It locks on once \(needed) plays agree; \(agreeing) so far."
        case .resting: return "Paused while your Apple TV is warm. It carries on once it cools."
        case .off: return "Starts when the stats are open on a live game."
        }
    }
}

private struct TVAutoSyncRowLabel: View {
    @Environment(\.lineupTVSelectableFocused) private var focused
    let isEnabled: Bool
    let detail: String

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 24, style: .continuous)
        HStack(alignment: .center, spacing: 18) {
            VStack(alignment: .leading, spacing: 5) {
                Text("Auto Sync").font(.inter(22, .semibold))
                Text(detail).font(.inter(18)).foregroundStyle(LineupPanelStyle.quiet)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
            Text(isEnabled ? "On" : "Off").font(.inter(19, .bold))
                .foregroundStyle(isEnabled ? LineupStyle.onHighlight : LineupStyle.text)
                .padding(.horizontal, 18).frame(height: 40)
                .background(isEnabled ? LineupStyle.highlight : LineupPanelStyle.fill, in: Capsule())
        }
        .padding(22)
        .background(LineupPanelStyle.well, in: shape)
        .lineupFocusLayer(focused, in: shape)
        .animation(.easeOut(duration: 0.16), value: focused)
    }
}
#endif
