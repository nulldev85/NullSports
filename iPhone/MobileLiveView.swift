import SwiftUI

struct MobileLiveView: View {
    @Environment(SportsLibrary.self) private var library
    @EnvironmentObject private var reminders: GameReminders
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.verticalSizeClass) private var verticalSizeClass
    @Environment(\.mobileUsesLineupNavigation) private var usesLineupNavigation
    @State private var league: SportsLeague?
    @State private var soccerCompetition: String?
    @State private var onlyFollowed = false
    @StateObject private var gameReplays = MobileGameReplayStore()
    @State private var selectedGameReplay: MobileGameReplaySelection?
    @State private var catchUpChannel: MobileSportsCatchUpChannel?
    @State private var pendingCatchUp: MobileGameReplaySelection?
    @State private var catchUpLookup: Task<Void, Never>?
    @State private var choosingChannel: SportsGame?
    @State private var showingEventChannels: SportsGame?
    @State private var pendingStream: XtreamStream?
    @State private var pendingGame: SportsGame?
    @State private var upcomingGame: SportsGame?
    @State private var racingDetails: SportsGame?
    @State private var teamPage: MobileTeamPageTarget?
    @State private var showsChannelSyncMessage = false
    @State private var previewStream: XtreamStream?
    @State private var expanded = false
    /// The game the preview belongs to. Needed to offer "Choose another
    /// channel" and to scope a saved preference after the picker returns.
    @State private var previewGame: SportsGame?
    /// The channel before the one in the preview, for Last Channel.
    @State private var previousChannel: XtreamStream?
    /// The channel just moved to, named over the picture for a moment.
    @State private var channelBanner: MobileChannelBannerInfo?
    @State private var bannerTask: Task<Void, Never>?
    @State private var qualityTask: Task<Void, Never>?
    @State private var qualityRequest: UUID?
    /// Both teams have a usable preference and they disagree.
    @State private var feedChoice: FeedChoice?
    /// A channel was just chosen for this game; ask how long it should apply.
    @State private var scopingSelection: PendingSelection?
    @StateObject private var playbackSlot = MobilePlaybackSlot()
    /// The watched game's stats, held behind the picture.
    @StateObject private var gameStats = MobileGameStats()
    @StateObject private var autoSync = MobileAutoSync()
    /// The stats are open: under the picture upright, beside it on its side.
    @State private var showsStats = false
    @State private var syncingStats = false
    /// Two games at once, full screen.
    @State private var multiview: MobileMultiviewSession?
    /// The game on screen, kept while a channel is chosen for the one to
    /// watch beside it.
    @State private var multiviewFirst: MobileMultiviewSession.Tile?
    @State private var multiviewPicking: SportsGame?
    @State private var multiviewSecond: MobileMultiviewSession.Tile?
    /// A new selection gets a new controller; see `MobilePlaybackSlot`.
    private var playback: MobilePlaybackController {
        get { playbackSlot.controller }
        nonmutating set { playbackSlot.controller = newValue }
    }
    /// The sports list, dropped from the pill under the masthead.
    @State private var leagueMenuOpen = false
    var isActive = true
    var onFullscreenChange: (Bool) -> Void = { _ in }
    let onPlay: (XtreamStream) -> Void

    /// Today's games, sorted into what the screen actually draws.
    ///
    /// Computed once per render and passed down. These used to be computed
    /// properties, and a computed property is recomputed at every mention:
    /// one pass over this screen walked every game, checked every clock and
    /// sorted the lot ten times over, which is what a tab switch waited for.
    struct Slate {
        let all: [SportsGame]
        /// The viewer's own games, live first and soonest next. Held out of
        /// the sections below rather than repeated in them.
        let mine: [SportsGame]
        let live: [SportsGame]
        /// Upcoming games already grouped, so the section loop does not filter
        /// the whole list again for each day it draws.
        let days: [(day: Date, games: [SportsGame])]
    }

    private func slate() -> Slate {
        let all = library.games(for: league).map(gameStats.shield).filter {
            (!onlyFollowed || library.isFollowing($0))
                && (league != .soccer || soccerCompetition == nil || $0.competition?.id == soccerCompetition)
        }
        let calendar = Calendar.current
        var byDay: [Date: [SportsGame]] = [:]
        var live: [SportsGame] = []
        var mine: [SportsGame] = []
        // Followed teams' games sit in the list where their time puts them;
        // My Teams narrows the list to them rather than lifting them out.
        let separatesMine = false
        for game in all {
            if separatesMine, library.isFollowing(game) {
                if game.isLive || game.isUpcoming { mine.append(game) }
                continue
            }
            if game.isLive { live.append(game) }
            if game.isUpcoming {
                byDay[calendar.startOfDay(for: game.start), default: []].append(game)
            }
        }
        // On now first, then by kick-off. Whatever a viewer can watch this
        // second outranks whatever they are waiting for.
        mine.sort { left, right in
            if left.isLive != right.isLive { return left.isLive }
            return left.start < right.start
        }
        return Slate(all: all, mine: mine, live: live,
                     days: byDay.keys.sorted().map { ($0, byDay[$0] ?? []) })
    }

    /// Everything on now in every league, for the scoreboard under the
    /// preview, whichever league or teams the list below it is showing.
    private func liveEverywhere() -> [SportsGame] {
        library.games(for: nil).map(gameStats.shield).filter(\.isLive)
            .map { (game: $0, followed: library.isFollowing($0)) }
            .sorted { left, right in
                if left.followed != right.followed { return left.followed }
                return left.game.start < right.game.start
            }
            .map(\.game)
    }

    /// The phone is on its side. Every iPhone has a compact height there and
    /// only there.
    private var sideways: Bool { verticalSizeClass == .compact }

    /// The preview fills the screen when asked to, and whenever the phone is
    /// on its side. Worked out from the orientation rather than set when it
    /// changes, so the preview fills the screen inside the rotation itself
    /// instead of a beat after it, and upright again it is back among the
    /// cards in the same single move.
    ///
    /// Only on this tab: a player kept for Picture in Picture while another
    /// tab is open must not take the screen from it when the phone turns.
    private var fillsScreen: Bool { isActive && previewStream != nil && (expanded || sideways) }

    /// The masthead and the league strip, at fixed heights so the preview
    /// knows where to sit below them.
    private static let mastheadHeight: CGFloat = 62
    private static let leagueStripHeight: CGFloat = 48
    private static var headerHeight: CGFloat { mastheadHeight + leagueStripHeight }
    /// The margin the preview and the score bar under it keep from the edges.
    private static let inset: CGFloat = LineupPanelStyle.margin

    var body: some View {
        // Once, at the top, and passed down. Everything below reads from it.
        let slate = slate()
        // The game in the preview, as the schedule has it now, so its score
        // keeps up while it plays.
        let watching = previewGame.map { game in
            slate.all.first { $0.id == game.id }
                // Narrowed to a league or to followed teams, the list may not
                // hold the game being watched; the schedule still does.
                ?? library.gamesByLeague[game.league]?.first { $0.id == game.id }.map(gameStats.shield)
                ?? gameStats.shield(game)
        }
        // The game the stats panel can follow: on ESPN's play-by-play.
        let statsGame = MobileGameStats.supports(watching) ? watching : nil
        let statsOpen = showsStats && statsGame != nil && previewStream != nil
        let statsBeside = statsOpen && fillsScreen
        return NavigationStack {
            GeometryReader { viewport in
                // The preview sits in the same margins as the cards, under the
                // header, and moves to the top of the screen as it expands.
                let videoHeight = (viewport.size.width - Self.inset * 2) * 9 / 16
                let metadataHeight: CGFloat = watching == nil ? 106 : 0
                let timelineHeight: CGFloat = playback.catchUpSource != nil && playback.error == nil
                    ? MobilePlayerLayout.inlineTimelineHeight : 0
                let previewTop = Self.headerHeight + 4
                let fullHeight = MobilePlayerLayout.fullscreenHeight(
                    containerHeight: viewport.size.height,
                    safeAreaTop: viewport.safeAreaInsets.top,
                    safeAreaBottom: viewport.safeAreaInsets.bottom)
                ZStack(alignment: .top) {
                    VStack(spacing: 0) {
                        masthead(slate)
                        leagueBar
                        if previewStream != nil {
                            Color.clear.frame(height: 4 + videoHeight + metadataHeight + timelineHeight)
                            if statsOpen, let statsGame {
                                // Upright, the stats take the room under the
                                // picture that the games had.
                                MobileGameStatsPanel(stats: gameStats, game: statsGame, autoSync: autoSync.status,
                                                     onSync: { syncingStats = true },
                                                     onClose: { toggleStats() })
                                    .clipShape(RoundedRectangle(cornerRadius: LineupStyle.compactRadius, style: .continuous))
                                    .padding(.horizontal, Self.inset).padding(.top, 10).padding(.bottom, 8)
                                    .transition(.opacity)
                            } else if let watching {
                                MobileLiveScoreboard(watching: watching, live: liveEverywhere()) { open($0) }
                                    .padding(.horizontal, Self.inset).padding(.top, 10)
                                    .padding(.bottom, 4)
                            }
                        }
                        if !statsOpen { slateList(slate) }
                    }
                    .allowsHitTesting(!fillsScreen)
                    .accessibilityHidden(fillsScreen)

                    if let stream = previewStream {
                        TimelineView(.periodic(from: .now, by: 30)) { clock in
                            MobileGuidePlayer(
                                controller: playback,
                                stream: stream,
                                program: library.guidePrograms(for: stream).first {
                                    $0.start <= clock.date && clock.date < $0.end
                                },
                                expanded: fillsScreen,
                                showsMetadata: watching == nil,
                                videoHeight: fillsScreen ? fullHeight : videoHeight,
                                screenInsets: viewport.safeAreaInsets,
                                onClose: closePreview,
                                // On its side the phone itself is the control:
                                // upright again is the way back.
                                onExpand: sideways ? nil : { setExpanded(!expanded) },
                                onRetry: {
                                    playback.start(urls: library.playbackURLs(for: stream),
                                                   channelID: stream.id)
                                },
                                onChooseChannel: chooseAnotherChannelAction,
                                // Up and down the viewer's favourites.
                                onStepChannel: channelStepper(around: stream),
                                lastChannelName: lastChannel?.name,
                                onLastChannel: { if let last = lastChannel { tune(last) } },
                                channelBanner: channelBanner,
                                watchingGameID: previewGame?.id,
                                onWatchGame: { watchGame($0) },
                                onToggleStats: statsGame == nil ? nil : { toggleStats() },
                                statsShown: statsOpen
                            )
                            .frame(height: fillsScreen ? fullHeight : videoHeight + metadataHeight + timelineHeight,
                                   alignment: .top)
                            // On its side, the picture makes room for the
                            // stats beside it rather than going under them.
                            .padding(.trailing, statsBeside ? Self.statsWidth(viewport) + viewport.safeAreaInsets.trailing : 0)
                            .background(LineupStyle.background)
                            // Squared off like the Guide's own cells until it
                            // fills the screen.
                            .clipShape(RoundedRectangle(cornerRadius: fillsScreen ? 0 : LineupStyle.compactRadius,
                                                        style: .continuous))
                            .padding(.horizontal, fillsScreen ? 0 : Self.inset)
                        }
                        .offset(y: fillsScreen ? 0 : previewTop)
                        .ignoresSafeArea(fillsScreen ? .all : [], edges: .all)
                        .id(ObjectIdentifier(playback))
                        .modifier(MobileDismissGesture(
                            enabled: fillsScreen,
                            onBeginExit: { playback.freezePictureForExit() },
                            onDismiss: closePreview))
                        .transition(.move(edge: .top).combined(with: .opacity))
                    }

                    if statsBeside, let statsGame {
                        MobileGameStatsPanel(stats: gameStats, game: statsGame, sideways: true, autoSync: autoSync.status,
                                             onSync: { syncingStats = true },
                                             onClose: { toggleStats() })
                            .padding(.top, viewport.safeAreaInsets.top)
                            // Clear of the home indicator, so the last row can
                            // be scrolled to and read.
                            .padding(.bottom, viewport.safeAreaInsets.bottom)
                            .frame(width: Self.statsWidth(viewport))
                            .padding(.trailing, viewport.safeAreaInsets.trailing)
                            .background(LineupPanelStyle.fill)
                            // The screen's height, as the picture beside it
                            // has. Left to grow, it took the height of the page
                            // behind the picture, taller than the screen, and
                            // the end of a long list sat off the bottom.
                            .frame(maxWidth: .infinity, alignment: .trailing)
                            .frame(height: fullHeight, alignment: .top)
                            .ignoresSafeArea()
                            .transition(.move(edge: .trailing))
                    }

                    if leagueMenuOpen && !fillsScreen {
                        // Everything under the header steps back. The pill
                        // stays in reach: it is how the list closes, too.
                        Color.black.opacity(0.45)
                            .padding(.top, Self.headerHeight)
                            .onTapGesture { setLeagueMenu(false) }
                            .transition(.opacity)
                            .accessibilityHidden(true)
                        MobileLeagueMenu(entries: leagueEntries(), selected: league,
                                         maxHeight: viewport.size.height - Self.headerHeight - 20) { choice in
                            withAnimation(.easeInOut(duration: 0.18)) { league = choice }
                            setLeagueMenu(false)
                        }
                        // A column hung from the pill, down the left side:
                        // it opens where the thumb already is.
                        .frame(width: min(300, viewport.size.width - 32))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.leading, 16)
                        .padding(.top, Self.headerHeight - 4)
                        // Opens with a little growth from the pill; closes as
                        // one flat layer fading out at once, so nothing in it
                        // trails behind the panel.
                        .compositingGroup()
                        .transition(.asymmetric(
                            insertion: reduceMotion ? AnyTransition.opacity
                                : AnyTransition.scale(scale: 0.94, anchor: .topLeading).combined(with: .opacity),
                            removal: AnyTransition.opacity.animation(.easeOut(duration: 0.14))))
                        .accessibilityAction(.escape) { setLeagueMenu(false) }
                    }
                }
            }
            .background(Color.black)
            .toolbar(.hidden, for: .navigationBar)
            .toolbar(fillsScreen || usesLineupNavigation ? .hidden : .visible, for: .tabBar)
            .statusBarHidden(fillsScreen)
            .persistentSystemOverlays(fillsScreen ? .hidden : .automatic)
            // Turning the phone needs no animation of its own: the rotation
            // already carries everything that follows from it.
            .onChange(of: fillsScreen) { _, value in
                onFullscreenChange(value)
                if value { leagueMenuOpen = false }
            }
            .onChange(of: sideways) { _, value in
                // A preview made full screen by hand, then turned on its side,
                // comes back upright as the preview, not as full screen.
                if value { expanded = false }
            }
            .sheet(item: $racingDetails) { RacingSessionDetails(game: $0) }
            .sheet(item: $teamPage) { MobileTeamPage(target: $0) }
            .fullScreenCover(item: $multiview) { session in
                MobileMultiviewView(session: session).environment(library)
            }
            .sheet(item: $multiviewPicking, onDismiss: {
                // Opened once the picker has gone: one full-screen cover
                // can't come up while a sheet is still leaving.
                if let first = multiviewFirst, let second = multiviewSecond { launchMultiview([first, second]) }
                multiviewFirst = nil
                multiviewSecond = nil
            }) { game in
                MobileChannelPicker(library: library, game: game) { stream in
                    multiviewSecond = MobileMultiviewSession.Tile(stream: stream, game: game)
                    multiviewPicking = nil
                }
            }
            .sheet(isPresented: $syncingStats) {
                if let statsGame {
                    MobileStatsSyncSheet(stats: gameStats, game: statsGame,
                                         autoSync: gameStats.autoSyncSport == nil ? nil : autoSync)
                }
            }
            // Auto Sync reads the scoreboard while the stats are open on a
            // live game, from whichever player is showing it.
            .task(id: "\(statsOpen)|\(watching?.isLive == true)|\(previewStream?.id ?? -1)|\(autoSync.isEnabled)") {
                guard statsOpen, autoSync.isEnabled else { autoSync.stop(); return }
                let slot = playbackSlot
                autoSync.run(for: gameStats, channel: previewStream?.id,
                             frames: { [weak slot] in await slot?.controller.captureFrame() },
                             release: { [weak slot] in slot?.controller.releaseFrameOutput() })
            }
            // The stats follow the game on screen from the moment it opens,
            // shown or not, so what the picture needs is there when they are.
            .task(id: "\(previewGame?.id ?? "")|\(previewStream?.id ?? -1)") {
                let slot = playbackSlot
                gameStats.playerLag = { [weak slot] in slot?.controller.secondsBehindLive ?? 0 }
                gameStats.follow(previewStream == nil ? nil : previewGame, channelID: previewStream?.id)
                if previewGame == nil { showsStats = false }
            }
            .fullScreenCover(item: $selectedGameReplay) { selection in
                MobileGameReplayPlayer(selection: selection).environment(library)
            }
            .sheet(item: $catchUpChannel, onDismiss: finishCatchUpSelection) { channel in
                sportsCatchUpSheet(channel)
            }
            .overlay(alignment: .top) {
                if qualityRequest != nil { LiveQualityProgress { cancelQualityCheck() } }
            }
            .onDisappear { cancelQualityCheck(); catchUpLookup?.cancel(); autoSync.stop() }
            .sheet(item: $showingEventChannels, onDismiss: finishChannelSelection) { game in
                MobileEventChannelsSheet(library: library, game: game, playingID: previewStream?.id) { stream in
                    pendingStream = stream
                    pendingGame = game
                    showingEventChannels = nil
                }
            }
            .lineupChoices("Game has not started yet", symbol: "clock",
                           isPresented: Binding(get: { upcomingGame != nil },
                                                set: { if !$0 { upcomingGame = nil } }),
                           message: upcomingGame.map {
                               "\($0.matchupLine)\nScheduled for \($0.start.formatted(date: .abbreviated, time: .shortened))."
                           },
                           cancelTitle: "OK") {
                guard let game = upcomingGame else { return [] }
                let reminded = reminders.reminds(game)
                return [MobileMenuItem(reminded ? "Remove Reminder" : "Remind Me",
                                       symbol: reminded ? "bell.slash" : "bell") {
                    reminders.toggleGame(game)
                    upcomingGame = nil
                }]
            } onCancel: { upcomingGame = nil }
            .lineupChoices("Streams are still syncing…", symbol: "arrow.clockwise",
                           isPresented: $showsChannelSyncMessage,
                           message: "Lineup is still matching channels to games. The channel list is incomplete until it finishes — try this game again in a moment.",
                           cancelTitle: "OK") { [] }
            .sheet(item: $choosingChannel, onDismiss: finishChannelSelection) { game in
                MobileChannelPicker(library: library, game: game) { stream in
                    pendingStream = stream
                    pendingGame = game
                    choosingChannel = nil
                }
            }
            // Both teams have a saved channel and they disagree — the one case
            // where a preference cannot answer on its own.
            .lineupChoices("Which feed?", symbol: "tv", isPresented: presenting($feedChoice),
                           message: feedChoice.map {
                               "\($0.home.team) prefers \($0.home.channelName). \($0.away.team) prefers \($0.away.channelName)."
                           }) {
                guard let choice = feedChoice else { return [] }
                return [
                    MobileMenuItem(choice.home.channelName, id: "home") {
                        feedChoice = nil
                        if let stream = library.stream(withID: choice.home.streamID) {
                            showPreview(stream, for: choice.game)
                        }
                    },
                    MobileMenuItem(choice.away.channelName, id: "away") {
                        feedChoice = nil
                        if let stream = library.stream(withID: choice.away.streamID) {
                            showPreview(stream, for: choice.game)
                        }
                    },
                    MobileMenuItem("Choose Another Channel", symbol: "list.bullet.rectangle", id: "other") {
                        let game = choice.game
                        feedChoice = nil
                        choosingChannel = game
                    }
                ]
            } onCancel: { feedChoice = nil }
            // After a manual pick: how long should it apply?
            .lineupChoices("Use this channel for…", symbol: "star.square.on.square",
                           isPresented: presenting($scopingSelection),
                           message: scopingSelection.map {
                               "\($0.stream.name) is playing now. Lineup can remember it for one of these teams."
                           }) {
                guard let selection = scopingSelection else { return [] }
                let sides = library.preferenceSides(for: selection.game).map { side in
                    MobileMenuItem("Always for the \(side.role) (\(side.team))", symbol: "star",
                                   id: "side-\(side.id)") {
                        // The broader team preference also remembers the
                        // channel for this exact game. That makes all three
                        // scope choices deterministic even when an ad-hoc
                        // sports channel has no guide data to verify it later.
                        library.saveGameSelection(selection.stream, for: selection.game)
                        library.savePreference(selection.stream, for: side.key, teamName: side.team)
                        scopingSelection = nil
                    }
                }
                return [MobileMenuItem("Just This Game", symbol: "sportscourt", id: "game") {
                    library.saveGameSelection(selection.stream, for: selection.game)
                    scopingSelection = nil
                }] + sides
            }
            .onChange(of: isActive) { _, active in
                if !active { cancelQualityCheck(); catchUpLookup?.cancel() }
                // Leaving the Live tab still closes the preview, unless it is
                // the stream currently playing in the PiP window.
                if active { playback.resume() } else { leagueMenuOpen = false }
                if !active && !playback.pictureInPictureActive { closePreview() }
            }
            .onChange(of: library.activeProfile?.id) { _, _ in
                catchUpLookup?.cancel()
                pendingCatchUp = nil
                catchUpChannel = nil
            }
            .onChange(of: playback.isPlaying) { _, playing in
                // Genuinely playing, not merely selected: a channel that never
                // decodes must not reach the recent list.
                if playing, let stream = previewStream { library.recordRecentChannel(stream) }
            }
            .onChange(of: scenePhase) { _, phase in
                if phase == .background { cancelQualityCheck() }
                guard previewStream != nil else { return }
                // Backgrounding no longer stops the stream; MobileBackgroundPolicy
                // decides whether this transition touches playback at all.
                playback.handleScenePhase(active: phase == .active)
            }
        }
    }

    private func masthead(_ slate: Slate) -> some View {
        HStack(alignment: .bottom) {
            HStack(spacing: 10) {
                Rectangle().fill(LineupStyle.highlight).frame(width: 3, height: 31)
                VStack(alignment: .leading, spacing: 1) {
                    Text("LINEUP").font(.inter(20, .black)).tracking(-0.5)
                        .foregroundStyle(LineupStyle.text.opacity(0.84))
                    Text("LIVE SPORTS").font(.inter(8, .bold)).tracking(2.2)
                        .foregroundStyle(LineupStyle.secondary.opacity(0.76))
                }
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 4) {
                Text(Date(), format: .dateTime.weekday(.abbreviated).month(.abbreviated).day())
                    .font(.inter(.caption2, .medium)).foregroundStyle(LineupStyle.secondary.opacity(0.72))
                HStack(spacing: 5) {
                    if slate.live.isEmpty && !slate.mine.contains(where: \.isLive) {
                        Circle().fill(LineupStyle.secondary.opacity(0.76)).frame(width: 5, height: 5)
                    } else {
                        MobileLiveDot()
                    }
                    let liveCount = slate.live.count + slate.mine.filter(\.isLive).count
                    Text(liveCount == 0 ? "\(slate.all.count) \(league?.isRacing == true ? "EVENTS" : "MATCHUPS")" : "\(liveCount) LIVE NOW")
                        .font(.inter(10, .bold)).tracking(1)
                }
                .foregroundStyle(slate.live.isEmpty && !slate.mine.contains(where: \.isLive)
                                 ? LineupStyle.secondary.opacity(0.76) : LineupStyle.liveStatus)
            }
        }
        .padding(.horizontal, 20).padding(.bottom, 17)
        .frame(height: Self.mastheadHeight, alignment: .bottom)
    }

    /// The sport on a pill, and My Teams beside it once there is anyone to
    /// follow.
    private var leagueBar: some View {
        HStack(spacing: 10) {
            MobileLeagueMenuButton(league: league, isOpen: leagueMenuOpen) {
                setLeagueMenu(!leagueMenuOpen)
            }
            if league == .soccer { SoccerCompetitionFilter(selected: $soccerCompetition) }
            Spacer(minLength: 0)
            if !library.followedTeams.isEmpty { followedChip }
        }
        .padding(.horizontal, Self.inset)
        .frame(height: Self.leagueStripHeight)
        .sensoryFeedback(.selection, trigger: league)
        .sensoryFeedback(.selection, trigger: onlyFollowed)
    }

    private func setLeagueMenu(_ open: Bool) {
        guard leagueMenuOpen != open else { return }
        withAnimation(reduceMotion ? .easeInOut(duration: 0.15) : .spring(response: 0.34, dampingFraction: 0.86)) {
            leagueMenuOpen = open
        }
    }

    /// Every league with what it has on, counted once for the open list.
    private func leagueEntries() -> [MobileLeagueMenu.Entry] {
        let all = library.games(for: nil).filter { !onlyFollowed || library.isFollowing($0) }
        var games: [SportsLeague: Int] = [:]
        var live: [SportsLeague: Int] = [:]
        for game in all {
            games[game.league, default: 0] += 1
            if game.isLive { live[game.league, default: 0] += 1 }
        }
        return [MobileLeagueMenu.Entry(league: nil, games: all.count, live: live.values.reduce(0, +))]
            + SportsLeague.allCases.map {
                MobileLeagueMenu.Entry(league: $0, games: games[$0] ?? 0, live: live[$0] ?? 0)
            }
    }

    /// Only appears once there is somebody to follow. An empty filter is a
    /// control that can only disappoint.
    private var followedChip: some View {
        Button {
            withAnimation(.easeInOut(duration: 0.18)) { onlyFollowed.toggle() }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: onlyFollowed ? "star.fill" : "star")
                    .font(.system(size: 13, weight: .bold, design: .rounded))
                if league != .soccer { Text("My Teams") }
            }
            .lineupChip(onlyFollowed)
            .frame(height: 36)
        }
        .buttonStyle(MobileCardButtonStyle())
        .accessibilityLabel("My teams")
        .accessibilityAddTraits(onlyFollowed ? .isSelected : [])
    }

    /// A compact section heading followed by independent list rows. Keeping
    /// each event row separate lets its team colors identify it at a glance.
    private func slateSection(_ title: String, systemImage: String, detail: String,
                              games: [SportsGame], showsDay: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(spacing: 8) {
                Image(systemName: systemImage)
                    .font(.system(size: 13, weight: .heavy, design: .rounded))
                    .foregroundStyle(title == "On Air" ? LineupStyle.liveStatus
                                                        : LineupPanelStyle.quiet.opacity(0.72))
                Text(title.uppercased())
                    .font(.inter(13, .heavy)).tracking(0.65)
                    .foregroundStyle(LineupStyle.text.opacity(0.74))
                Spacer(minLength: 6)
                Text(detail.uppercased())
                    .font(.inter(11, .heavy)).tracking(0.35)
                    .foregroundStyle(title == "On Air" ? LineupStyle.liveStatus
                                                        : LineupPanelStyle.quiet.opacity(0.72))
            }
            LazyVStack(spacing: 9) {
                ForEach(games) { game in matchup(game, showsDay: showsDay) }
            }
        }
        .padding(.horizontal, Self.inset)
        .padding(.bottom, LineupPanelStyle.gap)
    }

    /// The list stays mounted underneath the player while it expands. Only the
    /// player's frame changes, so the controller, decoder, PiP layer and network
    /// connection all remain the same objects throughout the transition.
    private func slateList(_ slate: Slate) -> some View {
        ScrollView {
            // A refresh of the channels is said in the pop-up at the top of the
            // screen, not in a line of its own above the games.
            LazyVStack(spacing: 0) {
                if let error = library.scheduleErrorMessage {
                    Label(error, systemImage: "exclamationmark.arrow.triangle.2.circlepath")
                        .font(.inter(.caption)).foregroundStyle(LineupStyle.lightPurple.opacity(0.65))
                        .padding(16)
                }
                if !slate.mine.isEmpty {
                    let onNow = slate.mine.filter(\.isLive).count
                    slateSection("My Teams", systemImage: "star",
                               detail: onNow > 0 ? "\(onNow) live" : "\(slate.mine.count) today",
                               games: slate.mine, showsDay: true)
                }
                if !slate.live.isEmpty {
                    slateSection("On Air", systemImage: "dot.radiowaves.left.and.right",
                               detail: "\(slate.live.count) live", games: slate.live)
                }
                ForEach(slate.days, id: \.day) { day, dayGames in
                    let today = Calendar.current.isDateInToday(day)
                    slateSection(today ? "Up Next" : day.formatted(.dateTime.weekday(.wide)),
                               systemImage: today ? "clock" : "calendar",
                               detail: day.formatted(.dateTime.month(.abbreviated).day()),
                               games: dayGames)
                }
                if slate.all.isEmpty && onlyFollowed && !library.isScheduleLoading {
                    LineupUnavailableView("Nothing for your teams",
                        systemImage: "star",
                        description: Text("None of the teams you follow are playing in this range. Tap My Teams again to see everything."))
                        .padding(.top, 40)
                } else if slate.all.isEmpty && !library.isScheduleLoading {
                    LineupUnavailableView(
                        library.scheduleAvailable(for: league) ? "No games scheduled" : "Schedule unavailable",
                        systemImage: "sportscourt",
                        description: Text("Pull down to refresh, or find your channels in Guide."))
                        .padding(.top, 40)
                }
                if MobileGameReplayPolicy.isVisible(myTeams: onlyFollowed, league: league) {
                    MobileGameReplaysSection(library: library, store: gameReplays, enabled: isActive) { selection in
                        cancelQualityCheck()
                        closePreview()
                        selectedGameReplay = selection
                    }
                    .padding(.horizontal, Self.inset)
                    .padding(.top, LineupPanelStyle.gap)
                }
            }
            .padding(.bottom, 16)
        }
        .refreshable { library.refreshSchedule(showsLoading: true) }
    }

    private func matchup(_ game: SportsGame, showsDay: Bool = false) -> some View {
        MobileMatchupRow(game: game, showsDay: showsDay,
                         isWatching: previewStream != nil && previewGame?.id == game.id)
            .accessibilityElement(children: .combine)
            .lineupHoldMenu(game.matchupLine, symbol: "sportscourt", press: .well,
                            items: { gameMenuItems(game) },
                            onPresent: { menu in loadCatchUpOption(for: game, menu: menu) }) {
                guard !game.isUpcoming else {
                    upcomingGame = game
                    return
                }
                open(game)
            }
            .accessibilityHint(game.isUpcoming ? "Show scheduled start time" : "Watch game or choose a channel")
    }

    /// Touch and hold on any game: watch it or be reminded, another channel,
    /// or follow either side -- following happens here rather than on a
    /// settings screen, because this is where the team is already in front
    /// of the viewer.
    private func gameMenuItems(_ game: SportsGame) -> [MobileMenuItem] {
        var items: [MobileMenuItem] = []
        if game.league.isRacing {
            items.append(MobileMenuItem("Race Details", symbol: "flag.checkered") { racingDetails = game })
        }
        if game.isLive {
            let watching = previewGame?.id == game.id && previewStream != nil
            items.append(MobileMenuItem(watching ? "Watching" : "Watch", symbol: "play.circle",
                                        isEnabled: !watching) { open(game) })
            items.append(MobileMenuItem("Channels", symbol: "tv") { showingEventChannels = game })
            // Beside the game already playing, rather than instead of it.
            if previewStream != nil && !watching {
                items.append(MobileMenuItem("Watch Side by Side", symbol: "rectangle.split.2x1") {
                    watchSideBySide(game)
                })
            }
        } else {
            let on = reminders.reminds(game)
            items.append(MobileMenuItem(on ? "Remove Reminder" : "Remind Me", symbol: on ? "bell.slash" : "bell") {
                reminders.toggleGame(game)
            })
        }
        items.append(MobileMenuItem("Choose Another Channel", symbol: "list.bullet.rectangle") {
            choosingChannel = game
        })
        // Each side's page: its schedule, standing, roster, injuries, news.
        for side in library.followableSides(of: game) {
            if let target = MobileTeamPageTarget(side: side, competition: game.competition?.id) {
                items.append(MobileMenuItem(side.name, symbol: "person.2", id: "team-\(side.id)") { teamPage = target })
            }
        }
        for side in library.followableSides(of: game) {
            let following = library.isFollowing(side.key)
            items.append(MobileMenuItem(following ? "Remove \(side.name) from My Teams" : "Add \(side.name) to My Teams",
                                        symbol: following ? "star.slash" : "star", id: "follow-\(side.id)") {
                library.toggleFollow(side)
            })
        }
        return items
    }

    private func loadCatchUpOption(for game: SportsGame, menu: MobileHoldMenu) {
        catchUpLookup?.cancel()
        guard game.isLive, let profile = library.activeProfile, !profile.isPlaylist,
              let requestID = menu.request?.id else { return }
        catchUpLookup = Task { @MainActor in
            guard menu.request?.id == requestID else { return }
            let matched = await library.eventChannels(for: game)
            guard !Task.isCancelled, isActive, library.activeProfile?.id == profile.id,
                  menu.request?.id == requestID else { return }
            let current = library.gamesByLeague[game.league]?.first { $0.id == game.id } ?? game
            let channels = MobileSportsCatchUpPolicy.channels(matched, live: current.isLive, playlist: profile.isPlaylist)
            guard !channels.isEmpty else { return }
            var items = gameMenuItems(current)
            let catchUp = MobileMenuItem("Catch Up", symbol: "clock.arrow.circlepath", id: "catch-up") { [weak menu] in
                guard let menu, library.activeProfile?.id == profile.id else { return }
                if channels.count == 1, let stream = channels.first {
                    chooseCatchUpChannel(stream, for: current, profileID: profile.id)
                } else {
                    menu.present("Catch Up Channels", symbol: "clock.arrow.circlepath", message: current.matchupLine,
                        items: channels.map { stream in
                            MobileMenuItem(stream.name, symbol: "tv", id: String(stream.id)) {
                                chooseCatchUpChannel(stream, for: current, profileID: profile.id)
                            }
                        })
                }
            }
            let position = items.firstIndex { $0.title == "Channels" }.map { $0 + 1 } ?? 0
            items.insert(catchUp, at: position)
            menu.updateItems(items, requestID: requestID)
        }
    }

    private func chooseCatchUpChannel(_ selected: XtreamStream, for game: SportsGame, profileID: UUID) {
        guard library.activeProfile?.id == profileID,
              let stream = library.stream(withID: selected.id), stream.hasCatchUp,
              library.isEventChannel(stream, verifiedFor: game) else { return }
        catchUpChannel = MobileSportsCatchUpChannel(profileID: profileID, stream: stream)
    }

    private func sportsCatchUpSheet(_ channel: MobileSportsCatchUpChannel) -> some View {
        MobileCatchUpSheet(stream: channel.stream) { program in
            guard library.activeProfile?.id == channel.profileID else { catchUpChannel = nil; return }
            pendingCatchUp = channel.selection(for: program)
            catchUpChannel = nil
        }
        .environment(library).tint(LineupStyle.highlight).preferredColorScheme(.dark)
    }

    private func finishCatchUpSelection() {
        guard let selection = pendingCatchUp else { return }
        pendingCatchUp = nil
        guard library.activeProfile?.id == selection.profileID,
              let stream = library.stream(withID: selection.recording.stream.id), stream.hasCatchUp else { return }
        cancelQualityCheck()
        closePreview()
        // Present only after the program sheet dismisses. The recording player
        // retains the selected program for retries and never silently goes live.
        selectedGameReplay = selection
    }

    /// One game, one decision. `PreferredChannel` is resolved entirely from
    /// saved preferences plus what the provider currently carries — see
    /// `TeamChannelPreferences.resolve`.
    private func open(_ game: SportsGame) {
        cancelQualityCheck()
        switch library.preferredChannel(for: game) {
        case .syncing:
            showsChannelSyncMessage = true
        case let .play(streamID, source):
            if let stream = library.stream(withID: streamID) {
                if source == .verified {
                    playback.shutdown()
                    previewStream = nil
                    let request = UUID()
                    qualityRequest = request
                    qualityTask = Task { @MainActor in
                        let chosen = await library.bestQualityStream(for: game, fallback: stream)
                        guard !Task.isCancelled, qualityRequest == request, isActive else { return }
                        qualityRequest = nil
                        qualityTask = nil
                        if let chosen { showPreview(chosen, for: game) }
                        else { choosingChannel = game }
                    }
                } else { showPreview(stream, for: game) }
            }
            else { choosingChannel = game }
        case let .chooseFeed(home, away):
            feedChoice = FeedChoice(game: game, home: home, away: away)
        case .pick:
            choosingChannel = game
        }
    }

    /// Offered only while the preview knows which game it belongs to.
    private var chooseAnotherChannelAction: (() -> Void)? {
        guard let game = previewGame else { return nil }
        return { choosingChannel = game }
    }

    /// Drives a dialog from an optional: SwiftUI clears the optional on dismiss,
    /// which a `.constant` binding cannot do — that strands the dialog.
    private func presenting<T>(_ value: Binding<T?>) -> Binding<Bool> {
        Binding(get: { value.wrappedValue != nil },
                set: { if !$0 { value.wrappedValue = nil } })
    }

    private func showPreview(_ stream: XtreamStream, for game: SportsGame?) {
        cancelQualityCheck()
        setExpanded(false)
        playback.shutdown()
        playback = MobilePlaybackController()
        if let current = previewStream, current.id != stream.id { previousChannel = current }
        previewStream = stream
        previewGame = game
        // Failover only exists where there is a game to verify against. Without
        // it the controller retries this channel's own URLs and stops, which is
        // the right behaviour for plain channel playback.
        if let game { playback.failover = failoverContext(for: game) }
        playback.start(urls: library.playbackURLs(for: stream), channelID: stream.id)
        playback.loadCatchUpSource(for: stream, from: library)
    }

    private func cancelQualityCheck() {
        qualityTask?.cancel()
        qualityTask = nil
        qualityRequest = nil
    }

    private func failoverContext(for game: SportsGame) -> MobilePlaybackController.FailoverContext {
        // Bound once, so the stored closures hold the library directly
        // rather than a copy of this view.
        let library = self.library
        let automaticID = library.verifiedStream(for: game)?.id
        return MobilePlaybackController.FailoverContext(
            plan: { library.failoverPlan(for: game) },
            urls: { id in library.stream(withID: id).map { library.playbackURLs(for: $0) } ?? [] },
            didSwitch: { channel in
                // Keep the on-screen channel in step with what is playing,
                // so metadata and Choose Another Channel stay truthful.
                if let switched = library.stream(withID: channel.streamID) { previewStream = switched }
            },
            didPlay: { id in
                // Normal automatic playback must not become a manual pin that
                // overrides a later quality-ranked match. Keep chosen/recovery feeds.
                guard id != automaticID else { return }
                if let working = library.stream(withID: id) {
                    library.saveGameSelection(working, for: game)
                }
            })
    }

    /// The channel Last Channel goes back to: the one played before this,
    /// else the last one watched anywhere.
    private var lastChannel: XtreamStream? {
        guard let current = previewStream else { return nil }
        if let previousChannel, previousChannel.id != current.id { return previousChannel }
        return library.recentStreams.first { $0.id != current.id }
    }

    /// Steps through the viewer's favourites from the channel playing, round
    /// from the end to the start. Nil with nothing else to step to.
    private func channelStepper(around stream: XtreamStream) -> ((Int) -> Void)? {
        let lineup = library.guideStreams(categoryID: nil, favoritesOnly: true, query: "")
        guard lineup.count > 1 || (lineup.count == 1 && lineup[0].id != stream.id) else { return nil }
        return { step in
            let index = lineup.firstIndex { $0.id == stream.id }
            let next = index.map { ($0 + step + lineup.count) % lineup.count } ?? (step > 0 ? 0 : lineup.count - 1)
            tune(lineup[next])
        }
    }

    /// Changes channel on the same player, so full screen stays full screen,
    /// and names the new channel over the picture for a moment. A game comes
    /// with its own failover; a plain channel has none.
    private func tune(_ stream: XtreamStream, for game: SportsGame? = nil) {
        guard let current = previewStream, current.id != stream.id || game != nil else { return }
        if current.id != stream.id { previousChannel = current }
        previewStream = stream
        previewGame = game
        playback.failover = game.map { failoverContext(for: $0) }
        playback.start(urls: library.playbackURLs(for: stream), channelID: stream.id)
        playback.loadCatchUpSource(for: stream, from: library)
        let info = MobileChannelBannerInfo(
            stream: stream,
            program: library.guidePrograms(for: stream).normalizedEPG().first { $0.isLive })
        channelBanner = info
        bannerTask?.cancel()
        bannerTask = Task { @MainActor in
            do { try await Task.sleep(for: .seconds(3)) } catch { return }
            if channelBanner == info { channelBanner = nil }
        }
    }

    /// One of the viewer's teams' games, from an alert: on its channel in
    /// place when it has one, else opened as a tap on the game would.
    private func watchGame(_ game: SportsGame) {
        GameAlertCenter.shared.dismiss()
        if case let .play(streamID, _) = library.preferredChannel(for: game),
           let stream = library.stream(withID: streamID), previewStream != nil {
            tune(stream, for: game)
        } else {
            open(game)
        }
    }

    private func closePreview() {
        setExpanded(false)
        playback.shutdown()
        previewStream = nil
        previewGame = nil
        showsStats = false
        gameStats.stop()
    }

    /// The game playing now and this one, side by side. This one's channel
    /// is the one it would play on its own; without one, it is chosen.
    private func watchSideBySide(_ game: SportsGame) {
        guard let current = previewStream else { return }
        let first = MobileMultiviewSession.Tile(stream: current, game: previewGame)
        switch library.preferredChannel(for: game) {
        case .syncing:
            showsChannelSyncMessage = true
        case let .play(streamID, _):
            if let stream = library.stream(withID: streamID) {
                launchMultiview([first, MobileMultiviewSession.Tile(stream: stream, game: game)])
            } else {
                multiviewFirst = first
                multiviewPicking = game
            }
        case .chooseFeed, .pick:
            multiviewFirst = first
            multiviewPicking = game
        }
    }

    private func launchMultiview(_ tiles: [MobileMultiviewSession.Tile]) {
        cancelQualityCheck()
        // Its connection goes before multiview opens two of its own.
        closePreview()
        multiview = MobileMultiviewSession(tiles: tiles)
    }

    private func toggleStats() {
        withAnimation(reduceMotion ? nil : .smooth(duration: 0.3)) { showsStats.toggle() }
    }

    /// The stats beside a full-screen picture: room for a box score, and
    /// the picture still the larger part.
    private static func statsWidth(_ viewport: GeometryProxy) -> CGFloat {
        min(380, max(300, (viewport.size.width + viewport.safeAreaInsets.leading + viewport.safeAreaInsets.trailing) * 0.38))
    }

    /// Full screen is a layout state of the existing preview, not a new player.
    /// Starting a second controller here was the source of the reconnect, the
    /// doubled background audio, and the disappearing PiP button.
    private func setExpanded(_ value: Bool) {
        guard expanded != value else { return }
        let animation: Animation? = reduceMotion ? nil : .smooth(duration: 0.34)
        withAnimation(animation) {
            expanded = value
            onFullscreenChange(isActive && previewStream != nil && (value || sideways))
        }
    }

    /// A channel came back from the picker. Play it now, and ask whether it
    /// should stick to either team.
    private func finishChannelSelection() {
        // Scope prompts wait until the outgoing channel sheet is gone.
        if let stream = pendingStream, let game = pendingGame {
            pendingStream = nil
            pendingGame = nil
            applySelection(stream, for: game)
        }
    }

    private func applySelection(_ stream: XtreamStream, for game: SportsGame) {
        showPreview(stream, for: game)
        let sides = library.preferenceSides(for: game)
        guard !sides.isEmpty else { return }
        scopingSelection = PendingSelection(game: game, stream: stream)
    }

    struct FeedChoice: Identifiable {
        let game: SportsGame
        let home: TeamFeedOption
        let away: TeamFeedOption
        var id: String { game.id }
    }

    struct PendingSelection: Identifiable {
        let game: SportsGame
        let stream: XtreamStream
        var id: String { game.id + "." + String(stream.id) }
    }
}

/// The score bar pressed in: it gives a little, as the system's own cards do.
struct MobileCardButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .opacity(configuration.isPressed ? 0.9 : 1)
            .animation(.spring(response: 0.25, dampingFraction: 0.8), value: configuration.isPressed)
    }
}

private struct MobileMatchupRow: View {
    @Environment(\.dynamicTypeSize) private var typeSize
    let game: SportsGame
    /// Set where the row is not under a heading that names the day.
    var showsDay = false
    /// The game in the preview above.
    var isWatching = false

    /// Both read from the game itself, so the card and the tests agree on what
    /// an event is and on where it is being held.
    private var isEvent: Bool { game.isEvent }
    private var whereItIs: String? { game.placeLine }

    var body: some View {
        let awayColor = MobileTeamColor.readable(game.awayColor) ?? LineupStyle.leagueColor(game.league)
        let homeColor = MobileTeamColor.readable(game.homeColor) ?? awayColor
        let shape = RoundedRectangle(cornerRadius: 15, style: .continuous)

        HStack(spacing: 14) {
            VStack(alignment: .leading, spacing: 8) {
                if isEvent {
                    VStack(alignment: .leading, spacing: 4) {
                        // An event has no teams to show, so its league's
                        // mark stands where their crests would: the tour on
                        // a tennis tournament, UFC on a fight night.
                        HStack(spacing: 9) {
                            MobileLeagueLogo(league: game.isNFLRedZone ? .nfl : game.league, size: 28)
                            Text(game.eventName ?? "")
                                .font(.inter(.body, .semibold))
                                .foregroundStyle(LineupStyle.text.opacity(0.72))
                                .lineLimit(2).multilineTextAlignment(.leading)
                        }
                        if let session = game.race?.title {
                            Text(session).font(.inter(.caption, .bold))
                                .foregroundStyle(LineupStyle.highlight.opacity(0.78))
                        }
                        if let whereItIs { place(whereItIs) }
                    }
                } else {
                    if let competition = game.competition {
                        Text(competition.name.uppercased()).font(.inter(10, .bold))
                            .foregroundStyle(LineupStyle.secondary.opacity(0.68)).lineLimit(1)
                    }
                    team(game.awayTeam, logo: game.awayLogo, rank: game.awayRank,
                         record: game.awayRecord, score: game.awayScore, isAway: true)
                    team(game.homeTeam, logo: game.homeLogo, rank: game.homeRank,
                         record: game.homeRecord, score: game.homeScore, isAway: false)
                    if let whereItIs { place(whereItIs) }
                    if let detail = game.soccer?.detail { place(detail) }
                }
            }.frame(maxWidth: .infinity, alignment: .leading)
            VStack(alignment: .leading, spacing: 6) {
                SportsMark(league: game.league, competition: game.competition, size: 26)
                if game.isLive {
                    HStack(alignment: .center, spacing: 5) {
                        MobileLiveDot()
                        Text(game.status.isEmpty ? "Live now" : game.status)
                            .font(.inter(.caption, .semibold)).lineLimit(2)
                    }
                    .foregroundStyle(LineupStyle.liveStatus)
                    .accessibilityElement(children: .ignore)
                        .accessibilityLabel("Live. \(game.status)")
                } else {
                    // A bare time only reads correctly under a heading that
                    // names the day. My Teams has no such heading -- it is
                    // sorted by what you can watch, not by date -- so the rows
                    // there carry the day themselves.
                    Text(showsDay ? game.startLabel
                                  : game.start.formatted(.dateTime.hour().minute()))
                        .font(.interDigits(.caption, .semibold))
                }
                if !game.broadcast.isEmpty {
                    Text(game.broadcast.uppercased()).font(.inter(9, .semibold)).tracking(0.5).lineLimit(2)
                        .foregroundStyle(LineupStyle.secondary.opacity(0.68))
                }
                Image(systemName: isWatching ? "speaker.wave.2.fill" : "play.fill").font(.system(size: 10, design: .rounded))
                    .padding(.top, 2).accessibilityHidden(true)
            }.frame(width: typeSize.isAccessibilitySize ? 100 : 76, alignment: .leading)
        }
        .foregroundStyle(LineupStyle.text.opacity(0.72))
        .fixedSize(horizontal: false, vertical: true)
        // Keep a single rounded event tile, like each channel in Guide List,
        // with the visual weight carried by the teams' own colors.
        .padding(.horizontal, 14).padding(.vertical, 12)
        .frame(minHeight: 78)
        .background(LinearGradient(colors: [awayColor.opacity(0.19), homeColor.opacity(0.19)],
                                   startPoint: .leading, endPoint: .trailing), in: shape)
        .overlay(shape.strokeBorder(Color.white.opacity(0.045), lineWidth: 1))
        .contentShape(shape)
    }

    /// One line, quiet, and only when there is something to say. The card
    /// earns its look by not filling every gap that could hold a fact.
    private func place(_ text: String) -> some View {
        Text(text)
            .font(.inter(.caption2))
            .foregroundStyle(LineupStyle.secondary.opacity(0.68))
            .lineLimit(1).truncationMode(.tail)
    }

    private func team(_ name: String, logo: String, rank: Int?, record: String?, score: String,
                      isAway: Bool) -> some View {
        HStack(spacing: 9) {
            // The disc went first and the ring that replaced it goes now: both
            // drew a circle around a mark that is not one. The badge lights
            // its own shape instead.
            TeamBadge(url: logo, fallback: String(name.prefix(3)).uppercased(), size: 28, tight: true)
            VStack(alignment: .leading, spacing: 2) {
                // A college team's Top 25 place, raised after its name.
                mobileRankedName(name, rank: rank, size: 15).font(.inter(.subheadline, .semibold))
                    .lineLimit(typeSize.isAccessibilitySize ? nil : 1)
                    .multilineTextAlignment(.leading)
                if let record = record?.trimmingCharacters(in: .whitespacesAndNewlines), !record.isEmpty {
                    // A tennis player's line holds their country, not a record.
                    Text(record).font(.interDigits(.caption2))
                        .foregroundStyle(LineupStyle.secondary.opacity(0.68))
                        .accessibilityLabel(game.league.isTennis ? record : "Record: \(record)")
                }
            }
            Spacer(minLength: 3)
            if game.isLive, let sets = game.tennis {
                TennisSetColumns(score: sets, isAway: isAway, size: 17)
            } else if game.isLive {
                Text(score).font(.interDigits(.title3, .bold))
            }
        }
    }
}

/// On air, as a small flat red dot that breathes in and out. It had a halo
/// and a glow; nothing in the app glows now but the pale rim that keeps a
/// dark team badge readable.
struct MobileLiveDot: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let dot = Circle().fill(LineupStyle.liveDot).frame(width: 6, height: 6)
        Group {
            if reduceMotion {
                dot
            } else {
                // A phase animator animates only the dot's opacity, so the
                // dot never drifts when the row holding it moves.
                dot.phaseAnimator([false, true]) { dot, dimmed in
                    dot.opacity(dimmed ? 0.45 : 1)
                } animation: { _ in
                    .easeInOut(duration: 1.1)
                }
            }
        }
        .frame(width: 8, height: 8)
        .accessibilityHidden(true)
    }
}

struct MobileLeagueLogo: View {
    let league: SportsLeague
    let size: CGFloat
    var body: some View {
        SportsMark(league: league, size: size)
            .accessibilityLabel(league.shortName)
    }
}

