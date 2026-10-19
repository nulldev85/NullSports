import SwiftUI

/// Live stats for the game being watched, beside or under the picture: the
/// score as far as the picture has got, its chances, and its plays, box
/// score and leaders, every one of them held until the picture shows it.
struct MobileGameStatsPanel: View {
    @ObservedObject var stats: MobileGameStats
    let game: SportsGame
    /// Beside a full-screen picture, rather than under an upright one.
    var sideways = false
    let onSync: () -> Void
    var onClose: (() -> Void)? = nil

    enum StatsSection: String, CaseIterable, Identifiable {
        case plays = "Plays", box = "Box Score", leaders = "Leaders"
        case courts = "Courts", card = "Fight Card", positions = "Positions"
        var id: String { rawValue }
    }
    /// Nil until chosen: the first of the game's own.
    @State private var section: StatsSection?

    /// What a game of this kind has to show, the one to open on first.
    /// Tennis has the scoreboard and the courts and nothing more: ESPN gives
    /// a game at a time and no points, too little for a list of plays. The
    /// games still sync it, from the sync sheet.
    private var sections: [StatsSection] {
        switch game.statsSource {
        case .tennis?: [.courts]
        case .card?: [.card, .plays]
        case .race?: [.positions, .plays]
        default: [.plays, .box, .leaders]
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                LineupIconTile(symbol: "chart.bar.fill", size: 26)
                Text("LIVE STATS").font(.inter(13, .heavy)).tracking(LineupPanelStyle.headerTracking)
                    .foregroundStyle(LineupPanelStyle.caption)
                Spacer(minLength: 8)
                if let onClose {
                    Button(action: onClose) {
                        Image(systemName: "xmark").font(.system(size: 13, weight: .bold, design: .rounded))
                            .foregroundStyle(LineupStyle.text)
                            .frame(width: 30, height: 30)
                            .background(LineupPanelStyle.well, in: Circle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Close stats")
                }
            }
            .padding(.horizontal, 16).padding(.top, 14).padding(.bottom, 10)

            if let reveal = stats.reveal {
                let options = sections
                let shown = section.flatMap { options.contains($0) ? $0 : nil } ?? options[0]
                headline(reveal)
                syncChip(reveal).padding(.horizontal, 16).padding(.top, 10)
                if let home = reveal.homeWinProbability {
                    WinProbabilityBar(reveal: reveal, home: home).padding(.horizontal, 16).padding(.top, 14)
                }
                // One section needs no tabs to choose it.
                if options.count > 1 {
                    HStack(spacing: 8) {
                        ForEach(options) { option in
                            Button { withAnimation(.easeInOut(duration: 0.16)) { section = option } } label: {
                                Text(option.rawValue).lineupChip(shown == option)
                            }
                            .buttonStyle(.plain)
                        }
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, 16).padding(.top, 14).padding(.bottom, 8)
                } else {
                    Color.clear.frame(height: 12)
                }
                Rectangle().fill(LineupPanelStyle.divider).frame(height: 1)
                ScrollView {
                    switch shown {
                    case .plays: plays(reveal)
                    case .box: box(reveal)
                    case .leaders: leaders(reveal)
                    case .courts:
                        // The newest draw, at once: only the match on
                        // screen waits for the picture.
                        if let latest = reveal.latestBoard?.tennis {
                            let onScreen = latest.focus ?? stats.focus
                            // A tournament asks which match is on screen; a
                            // match's own panel already knows.
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
                VStack(spacing: 10) {
                    ProgressView().tint(LineupStyle.text)
                    Text("Loading stats…").font(.inter(14)).foregroundStyle(LineupPanelStyle.quiet)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .foregroundStyle(LineupStyle.text)
        .background(LineupPanelStyle.fill)
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
        return VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.inter(17, .bold)).lineLimit(2)
            Text("Held until your stream gets here").font(.inter(13)).foregroundStyle(LineupPanelStyle.quiet)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 16)
    }

    private func scoreboard(_ reveal: GameStatsReveal) -> some View {
        HStack(spacing: 10) {
            team(logo: game.awayLogo, code: SportsGame.code(reveal.away.abbreviation, game.awayTeam))
            Text("\(reveal.awayScore)").font(.interDigits(sideways ? 28 : 32, .bold))
                .foregroundStyle(reveal.awayScore >= reveal.homeScore ? LineupStyle.text : LineupPanelStyle.quiet)
            VStack(spacing: 2) {
                Text(reveal.status.isEmpty ? "—" : reveal.status)
                    .font(.interDigits(13, .heavy))
                    .foregroundStyle(reveal.state == "in" ? LineupStyle.liveStatus : LineupPanelStyle.quiet)
                    .lineLimit(1).minimumScaleFactor(0.7)
            }
            .frame(maxWidth: .infinity)
            Text("\(reveal.homeScore)").font(.interDigits(sideways ? 28 : 32, .bold))
                .foregroundStyle(reveal.homeScore >= reveal.awayScore ? LineupStyle.text : LineupPanelStyle.quiet)
            team(logo: game.homeLogo, code: SportsGame.code(reveal.home.abbreviation, game.homeTeam))
        }
        .padding(.horizontal, 16)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(reveal.away.name) \(reveal.awayScore), \(reveal.home.name) \(reveal.homeScore), \(reveal.status)")
    }

    private func team(logo: String, code: String) -> some View {
        VStack(spacing: 3) {
            TeamBadge(url: logo, fallback: code, size: sideways ? 30 : 34)
            Text(code).font(.inter(11, .heavy)).foregroundStyle(LineupPanelStyle.quiet)
        }
    }

    /// How the stats are kept with the picture, and the way to set it.
    private func syncChip(_ reveal: GameStatsReveal) -> some View {
        Button(action: onSync) {
            HStack(spacing: 8) {
                Image(systemName: stats.calibrated ? "checkmark.circle.fill" : "timer")
                    .font(.system(size: 13, weight: .bold, design: .rounded))
                    .foregroundStyle(stats.calibrated ? LineupIconTile.green : LineupStyle.highlight)
                Text(syncText(reveal)).font(.inter(12, .semibold)).lineLimit(1).minimumScaleFactor(0.8)
                Spacer(minLength: 4)
                Text(stats.calibrated ? "Adjust" : "Sync").font(.inter(12, .bold)).foregroundStyle(LineupStyle.highlight)
            }
            .padding(.horizontal, 12).frame(height: 34)
            .background(LineupPanelStyle.well, in: Capsule())
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityHint("Matches the stats to your picture")
    }

    private func syncText(_ reveal: GameStatsReveal) -> String {
        let seconds = Int(stats.totalDelay.rounded())
        if reveal.catchingUp { return "Catching up to your stream · \(reveal.catchingUpFor ?? seconds)s" }
        if stats.needsFocus { return "Pick the match on your screen to sync" }
        return stats.calibrated ? "In sync · your stream is \(seconds)s behind live"
                                : "Held \(seconds)s behind live · tap to sync"
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
                    PlayRow(play: play, reveal: reveal, game: game)
                        // Hold a play the moment it shows on screen: the
                        // stats sync to it.
                        .lineupHoldMenu(play.text, symbol: "timer",
                                        message: "Sync the stats to this play.", press: .well,
                                        items: {
                                            guard play.timedMoment != nil else { return [] }
                                            return [MobileMenuItem("It Just Happened on My Screen", symbol: "checkmark.circle") {
                                                stats.sync(to: play)
                                            }]
                                        }) {}
                    Rectangle().fill(LineupPanelStyle.divider).frame(height: 1).padding(.leading, 16)
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
            VStack(spacing: 0) {
                HStack {
                    Text(SportsGame.code(reveal.away.abbreviation, game.awayTeam))
                    Spacer()
                    Text(SportsGame.code(reveal.home.abbreviation, game.homeTeam))
                }
                .font(.inter(12, .heavy)).foregroundStyle(LineupPanelStyle.quiet)
                .padding(.horizontal, 16).padding(.vertical, 10)
                ForEach(Array(reveal.lines.enumerated()), id: \.offset) { _, line in
                    HStack(spacing: 8) {
                        Text(line.away).font(.interDigits(15, .semibold)).frame(width: 74, alignment: .leading)
                        Text(line.label).font(.inter(13)).foregroundStyle(LineupPanelStyle.quiet)
                            .multilineTextAlignment(.center).frame(maxWidth: .infinity)
                        Text(line.home).font(.interDigits(15, .semibold)).frame(width: 74, alignment: .trailing)
                    }
                    .padding(.horizontal, 16).padding(.vertical, 9)
                    Rectangle().fill(LineupPanelStyle.divider).frame(height: 1).padding(.horizontal, 16)
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
            VStack(spacing: 0) {
                ForEach(Array(reveal.leaders.enumerated()), id: \.offset) { _, leader in
                    let home = leader.teamID == reveal.home.id
                    HStack(spacing: 12) {
                        TeamBadge(url: home ? game.homeLogo : game.awayLogo,
                                  fallback: home ? reveal.home.abbreviation : reveal.away.abbreviation, size: 26)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(leader.category.uppercased()).font(.inter(10, .heavy)).tracking(0.6)
                                .foregroundStyle(LineupPanelStyle.quiet)
                            Text(leader.athlete).font(.inter(15, .semibold)).lineLimit(1)
                        }
                        Spacer(minLength: 8)
                        Text(leader.value).font(.interDigits(14, .semibold)).multilineTextAlignment(.trailing)
                            .lineLimit(2)
                    }
                    .padding(.horizontal, 16).padding(.vertical, 10)
                    Rectangle().fill(LineupPanelStyle.divider).frame(height: 1).padding(.leading, 54)
                }
            }
        }
    }

    private func message(_ text: String, symbol: String) -> some View {
        VStack(spacing: 10) {
            LineupIconTile(symbol: symbol, size: 34)
            Text(text).font(.inter(14)).foregroundStyle(LineupPanelStyle.quiet).multilineTextAlignment(.center)
        }
        .padding(.horizontal, 24).padding(.vertical, 28)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// One play: when it happened, what it was, and the score it made.
private struct PlayRow: View {
    let play: GameStatsPlay
    let reveal: GameStatsReveal
    let game: SportsGame

    var body: some View {
        let home = play.teamID == reveal.home.id
        let color = MobileTeamColor.readable(home ? reveal.home.color : (play.teamID == reveal.away.id ? reveal.away.color : nil))
        HStack(alignment: .top, spacing: 12) {
            RoundedRectangle(cornerRadius: 2)
                .fill(color ?? (play.scoring && play.seen != nil ? LineupStyle.highlight : LineupPanelStyle.divider))
                .frame(width: 3)
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text([play.period, play.clock].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · "))
                        .font(.interDigits(11, .heavy)).foregroundStyle(LineupPanelStyle.quiet)
                    if let badge = play.badge {
                        Text(badge)
                            .font(.interDigits(11, .heavy))
                            .foregroundStyle(play.scoring ? LineupStyle.onHighlight : LineupStyle.text)
                            .padding(.horizontal, 7).padding(.vertical, 2)
                            .background(play.scoring ? LineupStyle.highlight : LineupPanelStyle.well, in: Capsule())
                    } else if play.scoring {
                        Text("\(SportsGame.code(reveal.away.abbreviation, game.awayTeam)) \(play.awayScore) – \(play.homeScore) \(SportsGame.code(reveal.home.abbreviation, game.homeTeam))")
                            .font(.interDigits(11, .heavy))
                            .foregroundStyle(LineupStyle.onHighlight)
                            .padding(.horizontal, 7).padding(.vertical, 2)
                            .background(LineupStyle.highlight, in: Capsule())
                    }
                }
                Text(play.text).font(.inter(14, play.scoring ? .semibold : .regular))
                    .foregroundStyle(LineupStyle.text)
                    .fixedSize(horizontal: false, vertical: true)
                // On a board of several matches or fights, which one.
                if play.seen != nil, let context = play.drive {
                    Text(context).font(.inter(12)).foregroundStyle(LineupPanelStyle.quiet).lineLimit(1)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 16).padding(.vertical, 10)
        .accessibilityElement(children: .combine)
    }
}

/// Who is likely to win, as of the last play the picture has shown.
private struct WinProbabilityBar: View {
    let reveal: GameStatsReveal
    let home: Double

    var body: some View {
        let away = 1 - home
        let awayColor = MobileTeamColor.readable(reveal.away.color) ?? LineupPanelStyle.quiet
        let homeColor = MobileTeamColor.readable(reveal.home.color) ?? LineupStyle.highlight
        VStack(spacing: 6) {
            HStack {
                Text("\(reveal.away.abbreviation) \(Int((away * 100).rounded()))%")
                Spacer()
                Text("WIN PROBABILITY").font(.inter(10, .heavy)).tracking(0.8).foregroundStyle(LineupPanelStyle.quiet)
                Spacer()
                Text("\(Int((home * 100).rounded()))% \(reveal.home.abbreviation)")
            }
            .font(.interDigits(12, .heavy))
            GeometryReader { proxy in
                HStack(spacing: 2) {
                    Capsule().fill(awayColor).frame(width: max(4, (proxy.size.width - 2) * away))
                    Capsule().fill(homeColor)
                }
            }
            .frame(height: 8)
            .animation(.easeInOut(duration: 0.4), value: home)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Win probability: \(reveal.away.name) \(Int((away * 100).rounded())) percent, \(reveal.home.name) \(Int((home * 100).rounded())) percent")
    }
}

/// A team's colour from its hex, lifted until it reads on the panels' grey.
enum MobileTeamColor {
    static func readable(_ hex: String?) -> Color? {
        guard var value = hex?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else { return nil }
        value = value.replacingOccurrences(of: "#", with: "")
        guard value.count == 6, let number = UInt64(value, radix: 16) else { return nil }
        var red = Double((number >> 16) & 0xff) / 255
        var green = Double((number >> 8) & 0xff) / 255
        var blue = Double(number & 0xff) / 255
        let luminance = red * 0.2126 + green * 0.7152 + blue * 0.0722
        if luminance < 0.45 {
            let mix = (0.45 - luminance) / max(0.01, 1 - luminance)
            red += (1 - red) * mix; green += (1 - green) * mix; blue += (1 - blue) * mix
        }
        return Color(red: red, green: green, blue: blue)
    }
}

/// Matching the stats to the picture, one play at a time.
///
/// It shows the latest play the stats have shown and asks whether it is on
/// the viewer's screen. "It Just Happened" syncs to that moment exactly.
/// "Not Yet" holds it back and waits for the viewer to say when it plays.
/// "Already Saw It" steps on to the next play and asks again. A few taps
/// at most, and nothing to line up by eye.
struct MobileStatsSyncSheet: View {
    @ObservedObject var stats: MobileGameStats
    let game: SportsGame
    @Environment(\.dismiss) private var dismiss

    private enum Step: Equatable {
        /// Is this play on the viewer's screen?
        case asking(GameStatsPlay)
        /// Held back; tap when it plays.
        case waiting(GameStatsPlay)
        /// Synced to this play.
        case synced(GameStatsPlay)
        /// ESPN has nothing later: the stream is as far on as the feed.
        case caughtUp(GameStatsPlay)
    }
    @State private var step: Step?
    @State private var started = false
    @State private var showsFineTune = false
    @State private var syncs = 0

    var body: some View {
        ScrollView {
            VStack(spacing: 0) {
                HStack(spacing: 12) {
                    LineupIconTile(symbol: "timer", size: 34)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Sync Stats to Your Stream").font(.inter(19, .bold))
                        Text("Every score, play and stat waits until your picture shows it.")
                            .font(.inter(13)).foregroundStyle(LineupPanelStyle.quiet)
                    }
                    Spacer(minLength: 0)
                }
                .padding(.top, 22)

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
                .padding(.top, 18)
                .animation(.easeInOut(duration: 0.2), value: step)

                fineTune.padding(.top, 20)

                HStack {
                    Button("Start Over") { stats.resetDelay(); begin() }.buttonStyle(LineupBarButtonStyle())
                    Spacer()
                    Button("Done") { dismiss() }.buttonStyle(LineupBarButtonStyle(prominent: true))
                }
                .padding(.top, 18).padding(.bottom, 20)
            }
            .padding(.horizontal, 20)
        }
        .scrollIndicators(.hidden)
        .foregroundStyle(LineupStyle.text)
        .background(LineupPanelStyle.fill.ignoresSafeArea())
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
        .presentationBackground(LineupPanelStyle.fill)
        // The picture stays live above the sheet, to be watched against.
        .presentationBackgroundInteraction(.enabled(upThrough: .medium))
        .sensoryFeedback(.success, trigger: syncs)
        .onAppear { if !started { started = true; begin() } }
        // A sheet opened before the first play has one to ask about once
        // ESPN times one.
        .onChange(of: stats.reveal?.plays.first?.id) { _, _ in if step == nil { begin() } }
    }

    private func begin() {
        step = stats.latestShownPlay.map(Step.asking)
    }

    // MARK: Steps

    private func asking(_ play: GameStatsPlay) -> some View {
        VStack(spacing: 12) {
            playCard(play, caption: "LATEST PLAY IN YOUR STATS")
            Text("Is this on your screen yet?").font(.inter(16, .semibold))
            Button {
                stats.sync(to: play)
                syncs += 1
                step = .synced(play)
            } label: {
                Label("It Just Happened", systemImage: "checkmark").frame(maxWidth: .infinity)
            }
            .lineupProminentButton()
            HStack(spacing: 10) {
                choice("Not Yet", symbol: "hourglass") {
                    stats.hold(before: play)
                    step = .waiting(play)
                }
                choice("Already Saw It", symbol: "forward.fill") {
                    if let next = stats.play(after: play) {
                        // Shown now, so it can be asked about.
                        stats.sync(to: next)
                        step = .asking(next)
                    } else {
                        stats.sync(to: play)
                        syncs += 1
                        step = .caughtUp(play)
                    }
                }
            }
        }
    }

    private func waiting(_ play: GameStatsPlay) -> some View {
        VStack(spacing: 12) {
            playCard(play, caption: "WAITING FOR THIS PLAY")
            Text("Tap the moment it happens on your screen. Stats are held back until then.")
                .font(.inter(14)).foregroundStyle(LineupPanelStyle.quiet).multilineTextAlignment(.center)
            Button {
                stats.sync(to: play)
                syncs += 1
                step = .synced(play)
            } label: {
                Label("It's Happening Now", systemImage: "hand.tap.fill").frame(maxWidth: .infinity)
            }
            .lineupProminentButton()
        }
    }

    private func synced(_ play: GameStatsPlay, caughtUp: Bool) -> some View {
        VStack(spacing: 12) {
            HStack(spacing: 12) {
                Image(systemName: "checkmark.circle.fill").font(.system(size: 30, weight: .semibold))
                    .foregroundStyle(LineupIconTile.green)
                VStack(alignment: .leading, spacing: 3) {
                    Text("In sync").font(.inter(18, .bold))
                    Text(caughtUp
                         ? "Your stream is as current as ESPN's feed. Stats show the moment ESPN has them."
                         : "Your stream is \(Self.duration(stats.delay)) behind live. Lineup remembers this for the channel.")
                        .font(.inter(13)).foregroundStyle(LineupPanelStyle.quiet)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
            }
            .padding(16)
            .background(LineupPanelStyle.well, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            Text("Synced to: \(play.text)").font(.inter(12)).foregroundStyle(LineupPanelStyle.quiet)
                .lineLimit(2).multilineTextAlignment(.center)
        }
    }

    /// A tournament with several matches on: which one is on screen.
    private var pickMatch: some View {
        VStack(spacing: 10) {
            Text("Which match is on your screen?").font(.inter(16, .semibold))
            // Every match that could be on screen, each as the picture has
            // it or withheld: the one on screen is among them.
            if let latest = stats.reveal?.latestBoard?.tennis {
                ForEach(GameStatsTennisBoard.courts(latest: latest, shown: stats.reveal?.board?.tennis, onScreen: nil)
                    .map(\.match).filter { $0.state == "in" }) { match in
                    Button {
                        stats.focus = match.id
                        begin()
                    } label: {
                        VStack(alignment: .leading, spacing: 8) {
                            Text([match.round, match.court ?? ""].filter { !$0.isEmpty }.joined(separator: " · "))
                                .font(.inter(11, .semibold)).foregroundStyle(LineupPanelStyle.quiet)
                            MobileTennisMatchBoard(match: match, compact: true)
                        }
                        .padding(14)
                        .background(LineupPanelStyle.well, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                        .contentShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    private var noPlays: some View {
        VStack(spacing: 10) {
            LineupIconTile(symbol: "list.bullet", size: 34)
            Text(stats.reveal?.board == nil ? "Syncing works once the game's plays start."
                 : "Syncing works once something happens: a game, a round, a lap.")
                .font(.inter(15, .semibold)).multilineTextAlignment(.center)
            Text("Until then, stats are held \(Self.duration(stats.delay)) behind live.")
                .font(.inter(13)).foregroundStyle(LineupPanelStyle.quiet).multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 18)
        .background(LineupPanelStyle.well, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
    }

    private func playCard(_ play: GameStatsPlay, caption: String) -> some View {
        VStack(spacing: 6) {
            Text(caption).font(.inter(10, .heavy)).tracking(0.8).foregroundStyle(LineupPanelStyle.quiet)
            Text([play.period, play.clock].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · "))
                .font(.interDigits(15, .heavy)).foregroundStyle(LineupStyle.highlight)
            Text(play.text).font(.inter(17, .semibold)).multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            if play.seen != nil {
                // A board's play: what it made, and which match or fight.
                Text([play.badge, play.drive].compactMap { $0 }.joined(separator: " · "))
                    .font(.interDigits(13, .semibold)).foregroundStyle(LineupPanelStyle.quiet)
                    .multilineTextAlignment(.center)
            } else if let reveal = stats.reveal {
                Text("\(reveal.away.abbreviation) \(play.awayScore) – \(play.homeScore) \(reveal.home.abbreviation)")
                    .font(.interDigits(13, .semibold)).foregroundStyle(LineupPanelStyle.quiet)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 16).padding(.horizontal, 14)
        .background(LineupPanelStyle.well, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
    }

    private func choice(_ title: String, symbol: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: symbol).font(.inter(15, .semibold))
                .frame(maxWidth: .infinity, minHeight: 46)
                .background(LineupPanelStyle.well, in: Capsule())
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
    }

    // MARK: Fine-tune

    private var fineTune: some View {
        VStack(spacing: 10) {
            Button { withAnimation(.easeInOut(duration: 0.2)) { showsFineTune.toggle() } } label: {
                HStack(spacing: 6) {
                    Text("Fine-tune").font(.inter(13, .semibold))
                    Image(systemName: "chevron.down").font(.system(size: 11, weight: .bold))
                        .rotationEffect(.degrees(showsFineTune ? 180 : 0))
                }
                .foregroundStyle(LineupPanelStyle.quiet)
            }
            .buttonStyle(.plain)
            if showsFineTune {
                HStack(spacing: 10) {
                    nudge("−5", by: -5)
                    nudge("−1", by: -1)
                    VStack(spacing: 1) {
                        Text("\(Int(stats.delay.rounded()))s").font(.interDigits(22, .bold)).contentTransition(.numericText())
                        Text("BEHIND LIVE").font(.inter(10, .heavy)).tracking(0.8).foregroundStyle(LineupPanelStyle.quiet)
                    }
                    .frame(minWidth: 96)
                    nudge("+1", by: 1)
                    nudge("+5", by: 5)
                }
                Text("More seconds hold the stats back longer. Fewer show them sooner.")
                    .font(.inter(12)).foregroundStyle(LineupPanelStyle.quiet).multilineTextAlignment(.center)
            }
        }
        .animation(.easeInOut(duration: 0.2), value: stats.delay)
    }

    private func nudge(_ title: String, by seconds: TimeInterval) -> some View {
        Button { stats.nudge(by: seconds) } label: {
            Text(title).font(.interDigits(16, .bold)).frame(width: 48, height: 40)
                .background(LineupPanelStyle.well, in: Capsule())
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(seconds < 0 ? "Show stats \(Int(-seconds)) seconds sooner"
                                        : "Hold stats \(Int(seconds)) seconds longer")
    }

    static func duration(_ seconds: TimeInterval) -> String {
        let whole = Int(seconds.rounded())
        return whole >= 60 ? "\(whole / 60)m \(whole % 60)s" : "\(whole)s"
    }
}
