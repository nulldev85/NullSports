#if os(tvOS)
import SwiftUI

/// The Sports tab on the television, laid out as the phone lays it out: a
/// line saying what is on, the sport and My Teams, then every game as a card
/// in sections -- on now, then each day ahead. Select plays a game full
/// screen; hold Select for its channels, reminders, team pages and the rest.
///
/// Nothing moves on this screen but focus. There is no picture behind it, no
/// colour following the remote and no crawl along the bottom: each card
/// carries its own teams' colours, and the screen stays still and quick to
/// move around however many games are on.
struct TVSportsBoard: View {
    @Environment(SportsLibrary.self) private var library
    let events: [SportsGame]
    @Binding var selectedLeague: SportsLeague?
    @Binding var soccerCompetition: String?
    @Binding var onlyFollowed: Bool
    let multiviewPrimaryID: Int?
    let multiviewTitle: String?
    let isScheduleLoading: Bool
    let isScheduleAvailable: Bool
    let scheduleErrorMessage: String?
    let onPlay: (SportsGame) -> Void
    let onStartMultiview: (SportsGame) -> Void
    let onCancelMultiview: () -> Void
    let onShowReplays: () -> Void

    /// The game under the remote, as an index into the cards on screen: Back
    /// goes to the top from anywhere below the first row.
    @State private var focusedCard: Int?
    @State private var topRequest = 0
    @Namespace private var scope
    @Environment(\.resetFocus) private var resetFocus

    static let columns = 3
    static let margin: CGFloat = 80
    static let gap: CGFloat = 36

    /// The games, sorted once per render into what the screen draws.
    struct Slate {
        let all: [SportsGame]
        let live: [SportsGame]
        let days: [(day: Date, games: [SportsGame])]

        init(_ games: [SportsGame]) {
            all = games
            let calendar = Calendar.current
            var byDay: [Date: [SportsGame]] = [:]
            var live: [SportsGame] = []
            for game in games {
                if game.isLive { live.append(game) }
                else if game.isUpcoming { byDay[calendar.startOfDay(for: game.start), default: []].append(game) }
            }
            self.live = live
            days = byDay.keys.sorted().map { ($0, (byDay[$0] ?? []).sorted { $0.start < $1.start }) }
        }

        /// Every card in the order it is drawn, for its place on screen.
        var ordered: [SportsGame] { live + days.flatMap(\.games) }
    }

    var body: some View {
        let slate = Slate(onlyFollowed ? events.filter { library.isFollowing($0) } : events)
        let positions = Dictionary(slate.ordered.enumerated().map { ($1.id, $0) }, uniquingKeysWith: { first, _ in first })
        ScrollViewReader { proxy in
            ScrollView(.vertical) {
                LazyVStack(alignment: .leading, spacing: 44) {
                    masthead(slate).id("top")
                    controls
                        .prefersDefaultFocus(in: scope)
                        .focusSection()
                    if let multiviewTitle { multiviewBanner(multiviewTitle) }
                    if let scheduleErrorMessage, slate.all.isEmpty {
                        Label(scheduleErrorMessage, systemImage: "exclamationmark.arrow.triangle.2.circlepath")
                            .font(.inter(22, .medium)).foregroundStyle(LineupStyle.secondary)
                    }
                    if !slate.live.isEmpty {
                        section("On Now", symbol: "dot.radiowaves.left.and.right",
                                detail: "\(slate.live.count) live", games: slate.live, positions: positions)
                    }
                    ForEach(slate.days, id: \.day) { day, games in
                        let today = Calendar.current.isDateInToday(day)
                        section(today ? "Up Next" : day.formatted(.dateTime.weekday(.wide)),
                                symbol: today ? "clock" : "calendar",
                                detail: day.formatted(.dateTime.month(.abbreviated).day()),
                                games: games, positions: positions, showsDay: false)
                    }
                    if slate.all.isEmpty { emptyState }
                }
                .padding(.horizontal, Self.margin)
                .padding(.top, 20)
                .padding(.bottom, 80)
            }
            .scrollClipDisabled()
            .onChange(of: topRequest) { _, _ in
                withAnimation(.easeOut(duration: 0.25)) { proxy.scrollTo("top", anchor: .top) }
                resetFocus(in: scope)
            }
        }
        .focusScope(scope)
        .onExitCommand(perform: backAction)
    }

    /// Back from a game below the first row goes up to the sport and My
    /// Teams; from there it is the system's, and goes up to the tabs.
    private var backAction: (() -> Void)? {
        guard let focusedCard, focusedCard >= Self.columns else { return nil }
        return { topRequest &+= 1 }
    }

    // MARK: Header

    private func masthead(_ slate: Slate) -> some View {
        HStack(alignment: .lastTextBaseline) {
            VStack(alignment: .leading, spacing: 6) {
                Text(Date(), format: .dateTime.weekday(.wide).month(.wide).day())
                    .font(.inter(24, .medium)).foregroundStyle(LineupStyle.secondary)
                Text(selectedLeague.map(liveLeagueName) ?? "All Sports")
                    .font(.inter(52, .heavy)).tracking(-0.5).foregroundStyle(LineupStyle.text)
            }
            Spacer()
            HStack(spacing: 10) {
                if slate.live.isEmpty {
                    Circle().fill(LineupStyle.secondary.opacity(0.6)).frame(width: 10, height: 10)
                } else {
                    Circle().fill(LineupStyle.liveDot).frame(width: 12, height: 12)
                }
                Text(slate.live.isEmpty
                     ? "\(slate.all.count) \(selectedLeague?.isRacing == true ? "EVENTS" : "GAMES")"
                     : "\(slate.live.count) LIVE NOW")
                    .font(.inter(20, .bold)).tracking(1.2)
            }
            .foregroundStyle(slate.live.isEmpty ? LineupStyle.secondary : LineupStyle.liveStatus)
        }
        .accessibilityElement(children: .combine)
    }

    private var controls: some View {
        HStack(spacing: 20) {
            LiveLeagueFilter(selectedLeague: $selectedLeague)
            if selectedLeague == .soccer { SoccerCompetitionFilter(selected: $soccerCompetition) }
            if !library.followedTeams.isEmpty {
                TVSelectable(scale: LineupStyle.controlLift, drawsFocusChrome: false,
                             action: { onlyFollowed.toggle() }) {
                    LiveChipLabel(symbol: onlyFollowed ? "star.fill" : "star",
                                  title: onlyFollowed ? "My Teams" : "All Teams")
                }
                .accessibilityLabel(onlyFollowed ? "Showing My Teams" : "Showing all teams")
            }
            if MobileGameReplayPolicy.isVisible(myTeams: onlyFollowed, league: selectedLeague) {
                TVSelectable(scale: LineupStyle.controlLift, drawsFocusChrome: false, action: onShowReplays) {
                    LiveChipLabel(symbol: "clock.arrow.circlepath", title: "Game Replays")
                }
            }
            Spacer(minLength: 0)
        }
    }

    private func multiviewBanner(_ title: String) -> some View {
        HStack(spacing: 24) {
            Image(systemName: "rectangle.split.2x1").font(.system(size: 30, weight: .semibold))
                .foregroundStyle(LineupStyle.highlight)
            VStack(alignment: .leading, spacing: 4) {
                Text("Choose a second game").font(.inter(28, .bold)).foregroundStyle(LineupStyle.text)
                Text("Watching \(firstGame?.matchupLine ?? title) first")
                    .font(.inter(20, .medium)).foregroundStyle(LineupStyle.secondary).lineLimit(1)
            }
            Spacer()
            TVSelectable(scale: LineupStyle.controlLift, drawsFocusChrome: false, action: onCancelMultiview) {
                LiveChipLabel(symbol: "xmark", title: "Cancel")
            }
        }
        .padding(24)
        .background(LineupPanelStyle.fill, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
        .focusSection()
    }

    private var firstGame: SportsGame? {
        guard let multiviewPrimaryID else { return nil }
        return events.first { library.stream(for: $0)?.id == multiviewPrimaryID }
    }

    // MARK: Sections

    private func section(_ title: String, symbol: String, detail: String, games: [SportsGame],
                         positions: [String: Int], showsDay: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 22) {
            HStack(alignment: .firstTextBaseline, spacing: 14) {
                Image(systemName: symbol).font(.system(size: 22, weight: .semibold))
                    .foregroundStyle(LineupStyle.highlight)
                Text(title.uppercased()).font(.inter(24, .heavy)).tracking(1.4)
                    .foregroundStyle(LineupStyle.text.opacity(0.86))
                Text(detail).font(.inter(20, .medium)).foregroundStyle(LineupStyle.secondary)
            }
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: Self.gap, alignment: .top),
                                     count: Self.columns),
                      alignment: .leading, spacing: Self.gap) {
                ForEach(games) { game in
                    let position = positions[game.id] ?? 0
                    let isPrimary = multiviewPrimaryID != nil && library.stream(for: game)?.id == multiviewPrimaryID
                    TVSelectable(scale: 1.04, fillRadius: TVGameCard.radius, drawsFocusChrome: false,
                                 action: { onPlay(game) },
                                 onFocusChange: { focused in
                                     if focused { focusedCard = position }
                                     else if focusedCard == position { focusedCard = nil }
                                 }) {
                        TVGameCard(game: game, showsDay: showsDay, isFirstOfMultiview: isPrimary)
                    }
                    .modifier(LiveGameMenu(game: game, isPrimary: isPrimary,
                                           onStartMultiview: { onStartMultiview(game) }))
                }
            }
            .focusSection()
        }
    }

    private var emptyState: some View {
        let title: String
        let detail: String
        if isScheduleLoading {
            title = "Games are loading…"
            detail = "The list fills in as each league answers."
        } else if onlyFollowed {
            title = "Nothing for your teams"
            detail = "None of the teams you follow are playing soon. Choose All Teams to see everything."
        } else if !isScheduleAvailable {
            title = "Schedule unavailable"
            detail = "Your channels are still in TV Guide."
        } else if let selectedLeague {
            title = "No \(liveLeagueName(selectedLeague)) games soon"
            detail = "Choose All Sports to see every league."
        } else {
            title = "No games scheduled"
            detail = "Your channels are still in TV Guide."
        }
        return VStack(alignment: .leading, spacing: 12) {
            Text(title).font(.inter(34, .bold)).foregroundStyle(LineupStyle.text)
            Text(detail).font(.inter(22, .medium)).foregroundStyle(LineupStyle.secondary)
        }
        .padding(.top, 40)
    }
}

/// One game, the phone's card at the television's size: the two sides with
/// their crests, records and the score once it is on; the league, the clock
/// or the start, and who is showing it. The teams' own colours run across it.
struct TVGameCard: View {
    @Environment(\.lineupTVSelectableFocused) private var focused
    let game: SportsGame
    var showsDay = false
    var isFirstOfMultiview = false

    static let radius: CGFloat = 24

    var body: some View {
        let awayColor = MobileTeamColor.readable(game.awayColor) ?? LineupStyle.leagueColor(game.league)
        let homeColor = MobileTeamColor.readable(game.homeColor) ?? awayColor
        let shape = RoundedRectangle(cornerRadius: Self.radius, style: .continuous)
        HStack(alignment: .top, spacing: 20) {
            VStack(alignment: .leading, spacing: 14) {
                if game.isEvent { event } else { matchup }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            status.frame(width: 140, alignment: .leading)
        }
        .foregroundStyle(LineupStyle.text.opacity(0.88))
        .padding(.horizontal, 26).padding(.vertical, 24)
        .frame(maxWidth: .infinity, minHeight: 190, alignment: .topLeading)
        .background(LinearGradient(colors: [awayColor.opacity(focused ? 0.34 : 0.22),
                                            homeColor.opacity(focused ? 0.34 : 0.22)],
                                   startPoint: .leading, endPoint: .trailing), in: shape)
        .background(LineupPanelStyle.fill, in: shape)
        .overlay(shape.strokeBorder(focused ? Color.white.opacity(0.85) : Color.white.opacity(0.06),
                                    lineWidth: focused ? 3 : 1))
        .overlay(alignment: .topTrailing) {
            if isFirstOfMultiview {
                Text("FIRST GAME").font(.inter(14, .heavy)).tracking(1)
                    .padding(.horizontal, 12).padding(.vertical, 6)
                    .background(LineupStyle.highlight, in: Capsule())
                    .foregroundStyle(LineupStyle.onHighlight)
                    .padding(14)
            }
        }
        .contentShape(shape)
        .animation(.easeOut(duration: 0.12), value: focused)
        .accessibilityElement(children: .combine)
        .accessibilityHint(game.isUpcoming ? "Hold for a reminder" : "Watch, or hold for more")
    }

    @ViewBuilder private var matchup: some View {
        if let competition = game.competition {
            Text(competition.name.uppercased()).font(.inter(15, .bold)).tracking(0.6)
                .foregroundStyle(LineupStyle.secondary).lineLimit(1)
        }
        team(game.awayTeam, logo: game.awayLogo, rank: game.awayRank, record: game.awayRecord,
             score: game.awayScore, isAway: true)
        team(game.homeTeam, logo: game.homeLogo, rank: game.homeRank, record: game.homeRecord,
             score: game.homeScore, isAway: false)
        if let place = game.soccer?.detail ?? game.placeLine {
            Text(place).font(.inter(17)).foregroundStyle(LineupStyle.secondary).lineLimit(1)
        }
    }

    @ViewBuilder private var event: some View {
        HStack(spacing: 14) {
            LeagueLogo(league: game.isNFLRedZone ? .nfl : game.league, size: 44)
            Text(game.eventName ?? game.matchupLine).font(.inter(26, .semibold)).lineLimit(2)
        }
        if let session = game.race?.title {
            Text(session).font(.inter(19, .bold)).foregroundStyle(LineupStyle.highlight)
        }
        if let place = game.placeLine {
            Text(place).font(.inter(17)).foregroundStyle(LineupStyle.secondary).lineLimit(1)
        }
    }

    private func team(_ name: String, logo: String, rank: Int?, record: String?, score: String,
                      isAway: Bool) -> some View {
        HStack(spacing: 14) {
            TeamBadge(url: logo, fallback: String(name.prefix(3)).uppercased(), size: 44, tight: true)
            VStack(alignment: .leading, spacing: 2) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    if let rank { Text("\(rank)").font(.interDigits(16, .bold)).foregroundStyle(LineupStyle.secondary) }
                    Text(name).font(.inter(24, .semibold)).lineLimit(1)
                }
                if let record = record?.trimmingCharacters(in: .whitespacesAndNewlines), !record.isEmpty {
                    Text(record).font(.interDigits(16)).foregroundStyle(LineupStyle.secondary)
                }
            }
            Spacer(minLength: 6)
            if game.isLive, let sets = game.tennis {
                TennisSetColumns(score: sets, isAway: isAway, size: 24)
            } else if game.isLive {
                Text(score).font(.interDigits(34, .bold))
            }
        }
    }

    private var status: some View {
        VStack(alignment: .leading, spacing: 10) {
            SportsMark(league: game.league, competition: game.competition, size: 36)
            if game.isLive {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    // Still: a breathing dot is a frame drawn for every live
                    // game on screen, all the time.
                    Circle().fill(LineupStyle.liveDot).frame(width: 10, height: 10)
                    Text(game.status.isEmpty ? "Live" : game.status)
                        .font(.inter(18, .semibold)).lineLimit(2)
                }
                .foregroundStyle(LineupStyle.liveStatus)
            } else {
                Text(showsDay ? game.startLabel : game.start.formatted(.dateTime.hour().minute()))
                    .font(.interDigits(20, .semibold))
            }
            if !game.broadcast.isEmpty {
                Text(game.broadcast.uppercased()).font(.inter(14, .semibold)).tracking(0.5)
                    .foregroundStyle(LineupStyle.secondary).lineLimit(2)
            }
        }
    }
}
#endif
