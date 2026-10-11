import SwiftUI

struct MobileLiveView: View {
    @EnvironmentObject private var library: SportsLibrary
    @EnvironmentObject private var reminders: GameReminders
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.verticalSizeClass) private var verticalSizeClass
    @State private var league: SportsLeague?
    /// The part of the slate on screen, once the viewer has picked one. Until
    /// then the tab opens on what is live, or on what is next when nothing is.
    @State private var segment: MobileLiveSegment?
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
        /// On now. The viewer's own teams first, then by start.
        let live: [SportsGame]
        /// Still to come, already grouped by day.
        let days: [(day: Date, games: [SportsGame])]
        /// The viewer's teams, live and to come: live first, soonest next.
        let mine: [SportsGame]
        var upcomingCount: Int { days.reduce(0) { $0 + $1.games.count } }
    }

    private func slate() -> Slate {
        let all = library.games(for: league)
        var live: [(game: SportsGame, followed: Bool)] = []
        var upcoming: [SportsGame] = []
        var mine: [SportsGame] = []
        for game in all {
            let followed = library.isFollowing(game)
            if game.isLive { live.append((game, followed)) }
            if game.isUpcoming { upcoming.append(game) }
            if followed && (game.isLive || game.isUpcoming) { mine.append(game) }
        }
        live.sort { left, right in
            if left.followed != right.followed { return left.followed }
            return left.game.start < right.game.start
        }
        // On now first, then by kick-off. Whatever a viewer can watch this
        // second outranks whatever they are waiting for.
        mine.sort { left, right in
            if left.isLive != right.isLive { return left.isLive }
            return left.start < right.start
        }
        return Slate(all: all, live: live.map(\.game), days: Self.byDay(upcoming), mine: mine)
    }

    private static func byDay(_ games: [SportsGame]) -> [(day: Date, games: [SportsGame])] {
        let calendar = Calendar.current
        var byDay: [Date: [SportsGame]] = [:]
        for game in games { byDay[calendar.startOfDay(for: game.start), default: []].append(game) }
        return byDay.keys.sorted().map { day in
            (day, (byDay[day] ?? []).sorted { $0.start < $1.start })
        }
    }

    /// Everything on now in every league, for the scoreboard under the
    /// preview, whichever league the cards below it are showing.
    private func liveEverywhere(_ slate: Slate) -> [SportsGame] {
        guard league != nil else { return slate.live }
        return library.games(for: nil).filter(\.isLive)
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

    private var showsMyTeams: Bool { !library.followedTeams.isEmpty }

    private func shownSegment(_ slate: Slate) -> MobileLiveSegment {
        if let segment, segment != .mine || showsMyTeams { return segment }
        return slate.live.isEmpty && !slate.days.isEmpty ? .upNext : .live
    }

    /// The header's height, fixed so the preview knows where to sit below it.
    private static let headerHeight: CGFloat = 62
    /// The margin the cards, and the preview above them, keep from the edges.
    private static let inset: CGFloat = 16

    var body: some View {
        // Once, at the top, and passed down. Everything below reads from it.
        let slate = slate()
        let shown = shownSegment(slate)
        // The game in the preview, as the schedule has it now, so its score
        // keeps up while it plays.
        let watching = previewGame.map { game in slate.all.first { $0.id == game.id } ?? game }
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
                        header
                        if previewStream != nil {
                            Color.clear.frame(height: 4 + videoHeight + metadataHeight)
                            if let watching {
                                MobileLiveScoreboard(watching: watching, live: liveEverywhere(slate)) { open($0) }
                                    .padding(.horizontal, Self.inset).padding(.top, 10)
                            }
                        }
                        segmentBar(slate, selected: shown)
                            .padding(.horizontal, Self.inset).padding(.top, 12)
                        content(slate, shown: shown)
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
                                onChooseChannel: chooseAnotherChannelAction
                            )
                            .frame(height: fillsScreen ? fullHeight : videoHeight + metadataHeight,
                                   alignment: .top)
                            .background(LineupStyle.background)
                            // A card among the cards until it fills the screen.
                            .clipShape(RoundedRectangle(cornerRadius: fillsScreen ? 0 : MobileCard.radius, style: .continuous))
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

    /// The day, the tab's name, and the league it shows.
    private var header: some View {
        HStack(alignment: .bottom, spacing: 8) {
            VStack(alignment: .leading, spacing: 0) {
                Text(Date(), format: .dateTime.weekday(.wide).month(.abbreviated).day())
                    .font(.inter(12, .semibold)).foregroundStyle(LineupStyle.secondary)
                Text("Live").font(.inter(30, .heavy)).tracking(-0.7).foregroundStyle(LineupStyle.text)
                    .accessibilityAddTraits(.isHeader)
            }
            Spacer(minLength: 8)
            leagueMenu
        }
        .padding(.horizontal, Self.inset).padding(.bottom, 2)
        .frame(height: Self.headerHeight, alignment: .bottom)
    }

    /// The leagues, one button rather than a strip of them: a row of logos
    /// took a line of the screen to say which one was picked.
    private var leagueMenu: some View {
        Menu {
            Picker("League", selection: Binding(
                get: { league },
                set: { value in withAnimation(.easeInOut(duration: 0.18)) { league = value } })) {
                Text("All Sports").tag(nil as SportsLeague?)
                ForEach(SportsLeague.allCases) { Text($0 == .ncaaf ? "College Football" : $0.shortName).tag(Optional($0)) }
            }
        } label: {
            HStack(spacing: 6) {
                if let league { MobileLeagueLogo(league: league, size: 18) }
                Text(league.map { $0 == .ncaaf ? "College" : $0.shortName } ?? "All Sports")
                    .font(.inter(13, .bold))
                Image(systemName: "chevron.down").font(.system(size: 10, weight: .bold))
            }
            .foregroundStyle(LineupStyle.text)
            .padding(.leading, 14).padding(.trailing, 12)
            .frame(height: 36)
            .lineupGlassControl(Capsule(), fallback: LineupStyle.raised)
        }
        .accessibilityLabel("League, \(league?.fullName ?? "all sports")")
    }

    /// Live, Up Next and My Teams: switched between, each a screen of its
    /// own, rather than stacked into one long list to scroll down.
    private func segmentBar(_ slate: Slate, selected: MobileLiveSegment) -> some View {
        HStack(spacing: 3) {
            segmentButton(.live, title: "Live", count: slate.live.count,
                          dot: !slate.live.isEmpty, selected: selected)
            segmentButton(.upNext, title: "Up Next", count: slate.upcomingCount,
                          dot: false, selected: selected)
            if showsMyTeams {
                segmentButton(.mine, title: "My Teams", count: slate.mine.count,
                              dot: slate.mine.contains(where: \.isLive), selected: selected)
            }
        }
        .padding(3)
        .frame(height: 42)
        .lineupLiquidGlass(Capsule(), fallback: LineupStyle.surface)
    }

    private func segmentButton(_ value: MobileLiveSegment, title: String, count: Int,
                               dot: Bool, selected: MobileLiveSegment) -> some View {
        let on = value == selected
        return Button {
            withAnimation(reduceMotion ? nil : .snappy(duration: 0.28)) { segment = value }
        } label: {
            HStack(spacing: 5) {
                if dot { Circle().fill(LineupStyle.liveDot).frame(width: 7, height: 7) }
                Text(title).font(.inter(13, on ? .heavy : .bold))
                Text("\(count)").font(.interDigits(13, .semibold)).opacity(0.65)
            }
            .lineLimit(1).minimumScaleFactor(0.8)
            .foregroundStyle(on ? LineupStyle.background : LineupStyle.text.opacity(0.82))
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background {
                if on {
                    Capsule().fill(LineupStyle.text)
                        .matchedGeometryEffect(id: "liveSegment", in: selection)
                }
            }
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(title), \(count)")
        .accessibilityAddTraits(on ? .isSelected : [])
    }

    /// The list stays mounted underneath the player while it expands. Only the
    /// player's frame changes, so the controller, decoder, PiP layer and network
    /// connection all remain the same objects throughout the transition.
    private func content(_ slate: Slate, shown: MobileLiveSegment) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                if let error = library.scheduleErrorMessage {
                    Label(error, systemImage: "exclamationmark.arrow.triangle.2.circlepath")
                        .font(.inter(.caption)).foregroundStyle(LineupStyle.lightPurple.opacity(0.65))
                }
                switch shown {
                case .live:
                    if slate.live.isEmpty {
                        nothingLive(slate)
                    } else {
                        tileGrid(slate.live)
                    }
                case .upNext:
                    if slate.days.isEmpty {
                        nothingScheduled
                    } else {
                        upcomingSections(slate.days)
                    }
                case .mine:
                    let live = slate.mine.filter(\.isLive)
                    let later = slate.mine.filter(\.isUpcoming)
                    if slate.mine.isEmpty {
                        ContentUnavailableView("Your teams aren't playing", systemImage: "star",
                            description: Text("None of the teams you follow have a game in this range. Touch and hold a game to follow its teams."))
                            .padding(.top, 24)
                    } else {
                        if !live.isEmpty { tileGrid(live) }
                        if !later.isEmpty { upcomingSections(Self.byDay(later)) }
                    }
                }
            }
            .padding(.horizontal, Self.inset).padding(.top, 14).padding(.bottom, 24)
        }
        .scrollIndicators(.hidden)
        .refreshable { library.refreshSchedule(showsLoading: true) }
    }

    /// Games on now, two to a row: a whole slate on one screen.
    private func tileGrid(_ games: [SportsGame]) -> some View {
        LazyVGrid(columns: [GridItem(.flexible(), spacing: 10), GridItem(.flexible(), spacing: 10)],
                  spacing: 10) {
            ForEach(games) { game in
                Button { open(game) } label: {
                    MobileScoreTile(game: game, isWatching: previewGame?.id == game.id,
                                    isFollowed: library.isFollowing(game))
                }
                .buttonStyle(MobileCardButtonStyle())
                .accessibilityHint("Watch game. Touch and hold for more, such as adding a team to My Teams.")
                .contentShape(.contextMenuPreview, MobileCard.shape)
                .contextMenu { gameMenu(game) }
            }
        }
    }

    /// Games still to come, a card for each day.
    private func upcomingSections(_ days: [(day: Date, games: [SportsGame])]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(days, id: \.day) { day, games in
                Text(Self.dayTitle(day))
                    .font(.inter(12, .heavy)).tracking(1.2)
                    .foregroundStyle(LineupStyle.secondary)
                    .padding(.leading, 4).padding(.top, day == days.first?.day ? 0 : 8)
                    .accessibilityAddTraits(.isHeader)
                VStack(spacing: 0) {
                    ForEach(Array(games.enumerated()), id: \.element.id) { index, game in
                        if index > 0 {
                            Rectangle().fill(LineupStyle.line).frame(height: 1).padding(.leading, 14)
                        }
                        Button { upcomingGame = game } label: { MobileUpcomingRow(game: game) }
                            .buttonStyle(MobileRowButtonStyle())
                            .accessibilityHint("Show scheduled start time")
                            .contextMenu { gameMenu(game) }
                    }
                }
                .background(LineupStyle.surface, in: MobileCard.shape)
                .clipShape(MobileCard.shape)
                .overlay(MobileCard.shape.strokeBorder(LineupStyle.line, lineWidth: 1))
            }
        }
    }

    private static func dayTitle(_ day: Date) -> String {
        let calendar = Calendar.current
        if calendar.isDateInToday(day) { return "TODAY" }
        if calendar.isDateInTomorrow(day) { return "TOMORROW" }
        return day.formatted(.dateTime.weekday(.wide)).uppercased()
            + " · " + day.formatted(.dateTime.month(.abbreviated).day()).uppercased()
    }

    @ViewBuilder
    private func nothingLive(_ slate: Slate) -> some View {
        VStack(spacing: 14) {
            ContentUnavailableView {
                Label("Nothing live right now", systemImage: "dot.radiowaves.left.and.right")
            } description: {
                if let next = slate.days.first?.games.first {
                    Text("Next up: \(next.shortMatchup), \(next.startLabel).")
                } else {
                    Text("Pull down to refresh, or find your channels in Guide.")
                }
            }
            if !slate.days.isEmpty {
                Button("See Up Next") {
                    withAnimation(reduceMotion ? nil : .snappy(duration: 0.28)) { segment = .upNext }
                }
                .lineupProminentButton()
            }
        }
        .padding(.top, 24)
        .frame(maxWidth: .infinity)
    }

    @ViewBuilder
    private var nothingScheduled: some View {
        if library.isScheduleLoading {
            ProgressView().frame(maxWidth: .infinity).padding(.top, 40)
        } else {
            ContentUnavailableView(
                library.scheduleAvailable(for: league) ? "No games scheduled" : "Schedule unavailable",
                systemImage: "sportscourt",
                description: Text("Pull down to refresh, or find your channels in Guide."))
                .padding(.top, 24)
        }
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
        previewStream = stream
        previewGame = game
        // Failover only exists where there is a game to verify against. Without
        // it the controller retries this channel's own URLs and stops, which is
        // the right behaviour for plain channel playback.
        if let game {
            // Bound once, so the stored closures hold the library directly
            // rather than a copy of this view.
            let library = self.library
            playback.failover = MobilePlaybackController.FailoverContext(
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
        playback.start(urls: library.playbackURLs(for: stream), channelID: stream.id)
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

/// A card pressed in: it gives a little, as the system's own cards do.
struct MobileCardButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .opacity(configuration.isPressed ? 0.9 : 1)
            .animation(.spring(response: 0.25, dampingFraction: 0.8), value: configuration.isPressed)
    }
}

/// A row inside a card, lit while pressed.
private struct MobileRowButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(configuration.isPressed ? LineupStyle.raised : .clear)
    }
}

/// A crisp red LED with a breathing halo. The red core stays steady so the
/// status never blinks; only the light around it moves.
struct MobileLiveDot: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private var red: Color { LineupStyle.liveDot }

    var body: some View {
        ZStack {
            halo
            Circle()
                .fill(RadialGradient(stops: [
                    .init(color: Color(red: 1, green: 0.58, blue: 0.62), location: 0),
                    .init(color: red, location: 0.28),
                    .init(color: Color(red: 0.58, green: 0.025, blue: 0.09), location: 1)
                ], center: .topLeading, startRadius: 0, endRadius: 5))
                .frame(width: 5, height: 5)
                .overlay(Circle().stroke(Color.white.opacity(0.2), lineWidth: 0.4))
                .shadow(color: red.opacity(0.48), radius: 2.5)
        }
        .frame(width: 8, height: 8)
        .accessibilityHidden(true)
    }

    /// The halo keeps its own time: it grows and fades, then starts again.
    ///
    /// It was a repeating animation started as the dot appeared, and that
    /// takes hold of anything else that changes at the same moment -- the
    /// dot's place in its row included. Opening the Guide lays out and
    /// reorders its rows just as their dots appear, so the dots slid to and
    /// fro without end, in and out of the program cells that clip them, and
    /// read as blinking until the rows were redrawn. A keyframe animator
    /// animates only the halo's size and fade, and nothing it holds can move.
    @ViewBuilder
    private var halo: some View {
        let ring = Circle().fill(red.opacity(0.3)).frame(width: 10, height: 10)
        if reduceMotion {
            ring.scaleEffect(0.75).opacity(0.34)
        } else {
            ring.keyframeAnimator(initialValue: 0.0, repeating: true) { ring, progress in
                ring.scaleEffect(0.68 + 0.37 * progress).opacity(0.5 * (1 - progress))
            } keyframes: { _ in
                LinearKeyframe(1.0, duration: 1.8, timingCurve: .easeOut)
            }
        }
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

