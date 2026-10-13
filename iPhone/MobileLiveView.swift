import SwiftUI

struct MobileLiveView: View {
    @EnvironmentObject private var library: SportsLibrary
    @EnvironmentObject private var reminders: GameReminders
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.verticalSizeClass) private var verticalSizeClass
    @State private var league: SportsLeague?
    @State private var onlyFollowed = false
    @State private var choosingChannel: SportsGame?
    @State private var pendingStream: XtreamStream?
    @State private var pendingGame: SportsGame?
    @State private var upcomingGame: SportsGame?
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
    /// Both teams have a usable preference and they disagree.
    @State private var feedChoice: FeedChoice?
    /// A channel was just chosen for this game; ask how long it should apply.
    @State private var scopingSelection: PendingSelection?
    @StateObject private var playbackSlot = MobilePlaybackSlot()
    /// A new selection gets a new controller; see `MobilePlaybackSlot`.
    private var playback: MobilePlaybackController {
        get { playbackSlot.controller }
        nonmutating set { playbackSlot.controller = newValue }
    }
    @Namespace private var selection
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
        let all = library.games(for: league).filter { !onlyFollowed || library.isFollowing($0) }
        let calendar = Calendar.current
        var byDay: [Date: [SportsGame]] = [:]
        var live: [SportsGame] = []
        var mine: [SportsGame] = []
        // With the tab already narrowed to followed teams, a section for them
        // would be the whole list under a second heading.
        let separatesMine = !onlyFollowed
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
        library.games(for: nil).filter(\.isLive)
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
    private static let inset: CGFloat = 16

    var body: some View {
        // Once, at the top, and passed down. Everything below reads from it.
        let slate = slate()
        // The game in the preview, as the schedule has it now, so its score
        // keeps up while it plays.
        let watching = previewGame.map { game in
            slate.all.first { $0.id == game.id }
                // Narrowed to a league or to followed teams, the list may not
                // hold the game being watched; the schedule still does.
                ?? library.games(for: nil).first { $0.id == game.id }
                ?? game
        }
        return NavigationStack {
            GeometryReader { viewport in
                // The preview sits in the same margins as the cards, under the
                // header, and moves to the top of the screen as it expands.
                let videoHeight = (viewport.size.width - Self.inset * 2) * 9 / 16
                let metadataHeight: CGFloat = watching == nil ? 106 : 0
                let previewTop = Self.headerHeight + 4
                let fullHeight = MobilePlayerLayout.fullscreenHeight(
                    containerHeight: viewport.size.height,
                    safeAreaTop: viewport.safeAreaInsets.top,
                    safeAreaBottom: viewport.safeAreaInsets.bottom)
                ZStack(alignment: .top) {
                    VStack(spacing: 0) {
                        masthead(slate)
                        leagueTabs
                        if previewStream != nil {
                            Color.clear.frame(height: 4 + videoHeight + metadataHeight)
                            if let watching {
                                MobileLiveScoreboard(watching: watching, live: liveEverywhere()) { open($0) }
                                    .padding(.horizontal, Self.inset).padding(.top, 10)
                                    .padding(.bottom, 4)
                            }
                        }
                        slateList(slate)
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
                                onWatchGame: { watchGame($0) }
                            )
                            .frame(height: fillsScreen ? fullHeight : videoHeight + metadataHeight,
                                   alignment: .top)
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
                }
            }
            .background(LineupStyle.background)
            .toolbar(.hidden, for: .navigationBar)
            .toolbar(fillsScreen ? .hidden : .visible, for: .tabBar)
            .statusBarHidden(fillsScreen)
            .persistentSystemOverlays(fillsScreen ? .hidden : .automatic)
            // Turning the phone needs no animation of its own: the rotation
            // already carries everything that follows from it.
            .onChange(of: fillsScreen) { _, value in onFullscreenChange(value) }
            .onChange(of: sideways) { _, value in
                // A preview made full screen by hand, then turned on its side,
                // comes back upright as the preview, not as full screen.
                if value { expanded = false }
            }
            .alert("Game has not started yet", isPresented: Binding(
                get: { upcomingGame != nil },
                set: { if !$0 { upcomingGame = nil } }
            )) {
                if let game = upcomingGame {
                    Button(reminders.reminds(game) ? "Remove reminder" : "Remind me") {
                        reminders.toggleGame(game)
                        upcomingGame = nil
                    }
                }
                Button("OK", role: .cancel) { upcomingGame = nil }
            } message: {
                if let game = upcomingGame {
                    Text("\(game.awayTeam) vs. \(game.homeTeam)\nScheduled for \(game.start.formatted(date: .abbreviated, time: .shortened)).")
                }
            }
            .alert("Streams are still syncing…", isPresented: $showsChannelSyncMessage) {
                Button("OK", role: .cancel) { }
            } message: {
                Text("Lineup is still matching channels to games. The channel list is incomplete until it finishes — try this game again in a moment.")
            }
            .sheet(item: $choosingChannel, onDismiss: {
                // The scope prompt has to wait for the sheet to be gone, or it
                // would try to present over a dismissing sheet.
                if let stream = pendingStream, let game = pendingGame {
                    pendingStream = nil
                    pendingGame = nil
                    applySelection(stream, for: game)
                }
            }) { game in
                MobileChannelPicker(game: game) { stream in
                    pendingStream = stream
                    pendingGame = game
                    choosingChannel = nil
                }
                .environmentObject(library)
            }
            // Both teams have a saved channel and they disagree — the one case
            // where a preference cannot answer on its own.
            .confirmationDialog("Which feed?", isPresented: presenting($feedChoice),
                                titleVisibility: .visible, presenting: feedChoice) { choice in
                Button(choice.home.channelName) {
                    feedChoice = nil
                    if let stream = library.stream(withID: choice.home.streamID) {
                        showPreview(stream, for: choice.game)
                    }
                }
                Button(choice.away.channelName) {
                    feedChoice = nil
                    if let stream = library.stream(withID: choice.away.streamID) {
                        showPreview(stream, for: choice.game)
                    }
                }
                Button("Choose another channel") {
                    let game = choice.game
                    feedChoice = nil
                    choosingChannel = game
                }
                Button("Cancel", role: .cancel) { feedChoice = nil }
            } message: { choice in
                Text("\(choice.home.team) prefers \(choice.home.channelName). \(choice.away.team) prefers \(choice.away.channelName).")
            }
            // After a manual pick: how long should it apply?
            .confirmationDialog("Use this channel for…", isPresented: presenting($scopingSelection),
                                titleVisibility: .visible, presenting: scopingSelection) { selection in
                Button("Just this game") {
                    library.saveGameSelection(selection.stream, for: selection.game)
                    scopingSelection = nil
                }
                ForEach(library.preferenceSides(for: selection.game)) { side in
                    Button("Always use this channel for the \(side.role) (\(side.team))") {
                        // The broader team preference also remembers the
                        // channel for this exact game. That makes all three
                        // scope choices deterministic even when an ad-hoc
                        // sports channel has no guide data to verify it later.
                        library.saveGameSelection(selection.stream, for: selection.game)
                        library.savePreference(selection.stream, for: side.key, teamName: side.team)
                        scopingSelection = nil
                    }
                }
            } message: { selection in
                Text("\(selection.stream.name) is playing now. Lineup can remember it for one of these teams.")
            }
            .onChange(of: isActive) { _, active in
                // Leaving the Live tab still closes the preview, unless it is
                // the stream currently playing in the PiP window.
                if active { playback.resume() }
                else if !playback.pictureInPictureActive { closePreview() }
            }
            .onChange(of: playback.isPlaying) { _, playing in
                // Genuinely playing, not merely selected: a channel that never
                // decodes must not reach the recent list.
                if playing, let stream = previewStream { library.recordRecentChannel(stream) }
            }
            .onChange(of: scenePhase) { _, phase in
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
                    Text("LINEUP").font(.inter(20, .black)).tracking(-0.5).foregroundStyle(LineupStyle.text)
                    Text("LIVE SPORTS").font(.inter(8, .bold)).tracking(2.2).foregroundStyle(LineupStyle.secondary)
                }
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 4) {
                Text(Date(), format: .dateTime.weekday(.abbreviated).month(.abbreviated).day())
                    .font(.inter(.caption2, .medium)).foregroundStyle(LineupStyle.secondary)
                HStack(spacing: 5) {
                    if slate.live.isEmpty && !slate.mine.contains(where: \.isLive) {
                        Circle().fill(LineupStyle.secondary).frame(width: 5, height: 5)
                    } else {
                        MobileLiveDot()
                    }
                    let liveCount = slate.live.count + slate.mine.filter(\.isLive).count
                    Text(liveCount == 0 ? "\(slate.all.count) MATCHUPS" : "\(liveCount) LIVE NOW")
                        .font(.inter(10, .bold)).tracking(1)
                }
                .foregroundStyle(slate.live.isEmpty && !slate.mine.contains(where: \.isLive)
                                 ? LineupStyle.secondary : LineupStyle.liveStatus)
            }
        }
        .padding(.horizontal, 20).padding(.bottom, 17)
        .frame(height: Self.mastheadHeight, alignment: .bottom)
    }

    private var leagueTabs: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 25) {
                if !library.followedTeams.isEmpty { followedTab }
                leagueTab(value: nil)
                ForEach(SportsLeague.allCases) { leagueTab(value: $0) }
            }.padding(.horizontal, 20)
        }
        .frame(height: Self.leagueStripHeight)
        .overlay(alignment: .bottom) { Rectangle().fill(LineupStyle.line).frame(height: 1) }
    }

    /// Only appears once there is somebody to follow. An empty filter is a
    /// control that can only disappoint.
    private var followedTab: some View {
        Button {
            withAnimation(.easeInOut(duration: 0.18)) { onlyFollowed.toggle() }
        } label: {
            Image(systemName: onlyFollowed ? "star.fill" : "star")
                .font(.system(size: 19))
                .foregroundStyle(onlyFollowed ? LineupStyle.highlight : LineupStyle.lightPurple)
                .opacity(onlyFollowed ? 1 : 0.38)
                .frame(minWidth: 44, minHeight: 48)
                .overlay(alignment: .bottom) {
                    if onlyFollowed {
                        Rectangle().fill(LineupStyle.highlight).frame(height: 2)
                    }
                }
        }
        .buttonStyle(.plain)
        .accessibilityLabel("My teams")
        .accessibilityAddTraits(onlyFollowed ? .isSelected : [])
    }

    private func leagueTab(value: SportsLeague?) -> some View {
        Button {
            withAnimation(.easeInOut(duration: 0.18)) { league = value }
        } label: {
            Group {
                if let value {
                    MobileLeagueLogo(league: value, size: 32)
                } else {
                    Image(systemName: "square.grid.2x2.fill").font(.system(size: 21))
                        .foregroundStyle(LineupStyle.lightPurple)
                }
            }
                .opacity(league == value ? 1 : 0.38)
                .frame(minWidth: 44, minHeight: 48)
                .overlay(alignment: .bottom) {
                    if league == value {
                        Rectangle().fill(LineupStyle.highlight).frame(height: 2)
                            .matchedGeometryEffect(id: "leagueUnderline", in: selection)
                    }
                }
        }
        .buttonStyle(.plain)
        .accessibilityLabel(value?.shortName ?? "All sports")
        .accessibilityAddTraits(league == value ? .isSelected : [])
    }

    private func sectionTitle(_ title: String, detail: String) -> some View {
        HStack {
            Text(title).tracking(1.8)
            Spacer()
            Text(detail).tracking(1)
        }
        .font(.inter(9, .bold))
        .foregroundStyle(LineupStyle.secondary)
        .padding(.horizontal, 20).padding(.top, 18).padding(.bottom, 9)
        .background(LineupStyle.background)
    }

    /// The list stays mounted underneath the player while it expands. Only the
    /// player's frame changes, so the controller, decoder, PiP layer and network
    /// connection all remain the same objects throughout the transition.
    private func slateList(_ slate: Slate) -> some View {
        ScrollView {
            // A refresh of the channels is said in the pop-up at the top of the
            // screen, not in a line of its own above the games.
            LazyVStack(spacing: 0, pinnedViews: [.sectionHeaders]) {
                if let error = library.scheduleErrorMessage {
                    Label(error, systemImage: "exclamationmark.arrow.triangle.2.circlepath")
                        .font(.inter(.caption)).foregroundStyle(LineupStyle.lightPurple.opacity(0.65))
                        .padding(16)
                }
                if !slate.mine.isEmpty {
                    Section {
                        ForEach(slate.mine) { matchup($0, showsDay: true) }
                    } header: {
                        let onNow = slate.mine.filter(\.isLive).count
                        sectionTitle("MY TEAMS",
                                     detail: onNow > 0 ? "\(onNow) LIVE" : "\(slate.mine.count) TODAY")
                    }
                }
                if !slate.live.isEmpty {
                    Section {
                        ForEach(slate.live) { matchup($0) }
                    } header: { sectionTitle("ON AIR", detail: "\(slate.live.count) LIVE") }
                }
                ForEach(slate.days, id: \.day) { day, dayGames in
                    Section {
                        ForEach(dayGames) { matchup($0) }
                    } header: {
                        sectionTitle(
                            Calendar.current.isDateInToday(day)
                                ? "UP NEXT"
                                : day.formatted(.dateTime.weekday(.wide)).uppercased(),
                            detail: day.formatted(.dateTime.month(.abbreviated).day()).uppercased())
                    }
                }
                if slate.all.isEmpty && onlyFollowed && !library.isScheduleLoading {
                    ContentUnavailableView("Nothing for your teams",
                        systemImage: "star",
                        description: Text("None of the teams you follow are playing in this range. Tap the star again to see everything."))
                        .padding(.top, 40)
                } else if slate.all.isEmpty && !library.isScheduleLoading {
                    ContentUnavailableView(
                        library.scheduleAvailable(for: league) ? "No games scheduled" : "Schedule unavailable",
                        systemImage: "sportscourt",
                        description: Text("Pull down to refresh, or find your channels in Guide."))
                        .padding(.top, 40)
                }
            }
            .padding(.bottom, 16)
        }
        .refreshable { library.refreshSchedule(showsLoading: true) }
    }

    private func matchup(_ game: SportsGame, showsDay: Bool = false) -> some View {
        Button {
            guard !game.isUpcoming else {
                upcomingGame = game
                return
            }
            open(game)
        } label: {
            MobileMatchupRow(game: game, showsDay: showsDay,
                             isWatching: previewStream != nil && previewGame?.id == game.id)
        }
        .buttonStyle(MobileMatchupButtonStyle())
        .accessibilityElement(children: .combine)
        .accessibilityHint(game.isUpcoming ? "Show scheduled start time" : "Watch game or choose a channel")
        .contextMenu { gameMenu(game) }
    }

    /// Touch and hold on any game: watch it or be reminded, another channel,
    /// or follow either side.
    @ViewBuilder
    private func gameMenu(_ game: SportsGame) -> some View {
        Section {
            if game.isLive {
                let watching = previewGame?.id == game.id && previewStream != nil
                Button(watching ? "Watching" : "Watch", systemImage: "play.fill") { open(game) }
                    .disabled(watching)
            } else {
                let on = reminders.reminds(game)
                Button(on ? "Remove reminder" : "Remind me", systemImage: on ? "bell.slash" : "bell") {
                    reminders.toggleGame(game)
                }
            }
            Button("Choose another channel", systemImage: "list.bullet") { choosingChannel = game }
        }
        // Following happens here rather than on a settings screen: this is
        // where the team is already in front of the viewer.
        Section {
            ForEach(library.followableSides(of: game)) { side in
                let following = library.isFollowing(side.key)
                Button(following ? "Remove \(side.name) from My Teams"
                                 : "Add \(side.name) to My Teams",
                       systemImage: following ? "star.slash" : "star") {
                    library.toggleFollow(side)
                }
            }
        }
    }

    /// One game, one decision. `PreferredChannel` is resolved entirely from
    /// saved preferences plus what the provider currently carries — see
    /// `TeamChannelPreferences.resolve`.
    private func open(_ game: SportsGame) {
        switch library.preferredChannel(for: game) {
        case .syncing:
            showsChannelSyncMessage = true
        case let .play(streamID, _):
            if let stream = library.stream(withID: streamID) { showPreview(stream, for: game) }
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

    private func failoverContext(for game: SportsGame) -> MobilePlaybackController.FailoverContext {
        // Bound once, so the stored closures hold the library directly
        // rather than a copy of this view.
        let library = self.library
        return MobilePlaybackController.FailoverContext(
            plan: { library.failoverPlan(for: game) },
            urls: { id in library.stream(withID: id).map { library.playbackURLs(for: $0) } ?? [] },
            didSwitch: { channel in
                // Keep the on-screen channel in step with what is playing,
                // so metadata and Choose Another Channel stay truthful.
                if let switched = library.stream(withID: channel.streamID) { previewStream = switched }
            },
            didPlay: { id in
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
        HStack(spacing: 14) {
            VStack(alignment: .leading, spacing: 8) {
                if isEvent {
                    VStack(alignment: .leading, spacing: 4) {
                        HStack(spacing: 9) {
                            if game.isNFLRedZone {
                                MobileLeagueLogo(league: .nfl, size: 28)
                            }
                            Text(game.eventName ?? "")
                                .font(.inter(.body, .semibold))
                                .lineLimit(2).multilineTextAlignment(.leading)
                        }
                        if let whereItIs { place(whereItIs) }
                    }
                } else {
                    team(game.awayTeam, logo: game.awayLogo, rank: game.awayRank,
                         record: game.awayRecord, score: game.awayScore, isAway: true)
                    team(game.homeTeam, logo: game.homeLogo, rank: game.homeRank,
                         record: game.homeRecord, score: game.homeScore, isAway: false)
                    if let whereItIs { place(whereItIs) }
                }
            }.frame(maxWidth: .infinity, alignment: .leading)
            Rectangle().fill(LineupStyle.line).frame(width: 1)
            VStack(alignment: .leading, spacing: 6) {
                MobileLeagueLogo(league: game.league, size: 23)
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
                        .foregroundStyle(LineupStyle.secondary)
                }
                Image(systemName: isWatching ? "speaker.wave.2.fill" : "play.fill").font(.system(size: 10))
                    .padding(.top, 2).accessibilityHidden(true)
            }.frame(width: typeSize.isAccessibilitySize ? 100 : 76, alignment: .leading)
        }
        .fixedSize(horizontal: false, vertical: true)
        .padding(.horizontal, 12).padding(.vertical, 12)
        // The Guide's own cells: grey, squared off, a step lighter and edged
        // in a faint red while the game is on.
        .background(game.isLive ? LineupStyle.focused : LineupStyle.raised, in: Self.cell)
        .overlay {
            Self.cell.strokeBorder(game.isLive ? LineupStyle.liveDot.opacity(0.34) : LineupStyle.line,
                                   lineWidth: game.isLive ? 1 : 0.5)
        }
        .padding(.horizontal, 12).padding(.vertical, 3)
        .contentShape(Rectangle())
    }

    static let cell = RoundedRectangle(cornerRadius: 4, style: .continuous)

    /// One line, quiet, and only when there is something to say. The card
    /// earns its look by not filling every gap that could hold a fact.
    private func place(_ text: String) -> some View {
        Text(text)
            .font(.inter(.caption2))
            .foregroundStyle(LineupStyle.secondary)
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
                        .foregroundStyle(LineupStyle.secondary)
                        .accessibilityLabel(game.league == .tennis ? record : "Record: \(record)")
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

private struct MobileMatchupButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .opacity(configuration.isPressed ? 0.7 : 1)
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
        Image("League-\(league.rawValue)")
            .resizable().scaledToFit()
            .frame(width: size, height: size)
            .accessibilityLabel(league.shortName)
    }
}

