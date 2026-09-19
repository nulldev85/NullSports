import SwiftUI

struct MobileLiveView: View {
    @EnvironmentObject private var library: SportsLibrary
    @EnvironmentObject private var reminders: GameReminders
    @Environment(\.scenePhase) private var scenePhase
    @State private var league: SportsLeague?
    @State private var choosingChannel: SportsGame?
    @State private var pendingStream: XtreamStream?
    @State private var pendingGame: SportsGame?
    @State private var upcomingGame: SportsGame?
    @State private var showsChannelSyncMessage = false
    @State private var previewStream: XtreamStream?
    /// The game the preview belongs to. Needed to offer "Choose another
    /// channel" and to scope a saved preference after the picker returns.
    @State private var previewGame: SportsGame?
    /// Both teams have a usable preference and they disagree.
    @State private var feedChoice: FeedChoice?
    /// A channel was just chosen for this game; ask how long it should apply.
    @State private var scopingSelection: PendingSelection?
    @State private var playback = MobilePlaybackController()
    @Namespace private var selection
    var isActive = true
    let onPlay: (XtreamStream) -> Void

    /// Today's games, sorted into what the screen actually draws.
    ///
    /// These used to be computed properties, and a computed property is
    /// recomputed at every mention. A single pass over this screen mentioned
    /// them about ten times -- the masthead twice, the live section three
    /// times, and once per upcoming day inside a loop -- so one render walked
    /// every game, checked every clock and sorted the lot ten times over.
    /// That is what a tab switch was waiting for.
    struct Slate {
        let all: [SportsGame]
        let live: [SportsGame]
        /// Upcoming games already grouped, so the section loop does not filter
        /// the whole list again for each day it draws.
        let days: [(day: Date, games: [SportsGame])]
    }

    private func slate() -> Slate {
        let all = library.games(for: league)
        let calendar = Calendar.current
        var byDay: [Date: [SportsGame]] = [:]
        var live: [SportsGame] = []
        for game in all {
            if game.isLive { live.append(game) }
            if game.isUpcoming {
                byDay[calendar.startOfDay(for: game.start), default: []].append(game)
            }
        }
        return Slate(all: all, live: live,
                     days: byDay.keys.sorted().map { ($0, byDay[$0] ?? []) })
    }

    var body: some View {
        // Once, at the top, and passed down. Everything below reads from it.
        let slate = slate()
        return NavigationStack {
            VStack(spacing: 0) {
                masthead(slate)
                leagueTabs
                if let stream = previewStream {
                    TimelineView(.periodic(from: .now, by: 30)) { clock in
                        MobileGuidePlayer(
                            controller: playback,
                            stream: stream,
                            program: library.guidePrograms(for: stream).first {
                                $0.start <= clock.date && clock.date < $0.end
                            },
                            expanded: false,
                            showsMetadata: true,
                            videoHeight: UIScreen.main.bounds.width * 9 / 16,
                            onClose: closePreview,
                            onExpand: { onPlay(stream) },
                            onRetry: { playback.start(urls: library.playbackURLs(for: stream), channelID: stream.id) },
                            onChooseChannel: chooseAnotherChannelAction
                        )
                        .id(ObjectIdentifier(playback))
                    }
                    .transition(.move(edge: .top).combined(with: .opacity))
                }
                ScrollView {
                    LazyVStack(spacing: 0, pinnedViews: [.sectionHeaders]) {
                        // Three different waits, said three different ways. The
                        // first sync of a new provider is the only one with an
                        // empty screen behind it, so it explains itself at
                        // length; a refresh running behind restored cache is a
                        // quiet line, because everything below it already works.
                        switch LiveSyncBanner.choose(
                            isInitialProviderSync: library.isInitialProviderSync,
                            hasContent: library.hasRestoredCache,
                            isScheduleLoading: library.isScheduleLoading,
                            isLoading: library.isLoading,
                            channelsAreSyncing: library.channelsAreSyncing) {
                        case .initialSync: InitialSyncBanner()
                        case .background: BackgroundRefreshBanner()
                        case .refreshing: RefreshingStreamsBanner()
                        case .none: EmptyView()
                        }
                        if let error = library.scheduleErrorMessage {
                            Label(error, systemImage: "exclamationmark.arrow.triangle.2.circlepath")
                                .font(.inter(.caption)).foregroundStyle(LineupStyle.lightPurple.opacity(0.65))
                                .padding(16)
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
                                sectionTitle(Calendar.current.isDateInToday(day) ? "UP NEXT" : day.formatted(.dateTime.weekday(.wide)).uppercased(),
                                             detail: day.formatted(.dateTime.month(.abbreviated).day()).uppercased())
                            }
                        }
                        if slate.all.isEmpty && !library.isScheduleLoading {
                            ContentUnavailableView(library.scheduleAvailable(for: league) ? "No games scheduled" : "Schedule unavailable",
                                systemImage: "sportscourt",
                                description: Text("Pull down to refresh, or find your channels in Guide."))
                                .padding(.top, 40)
                        }
                    }
                    .padding(.bottom, 16)
                }
                .refreshable { library.refreshSchedule(showsLoading: true) }
            }
            .background(LineupStyle.background)
            .toolbar(.hidden, for: .navigationBar)
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
                Button("Just this game") { scopingSelection = nil }
                ForEach(library.preferenceSides(for: selection.game)) { side in
                    Button("Always use this channel for the \(side.role) (\(side.team))") {
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
                    Circle().fill(slate.live.isEmpty ? LineupStyle.secondary : LineupStyle.liveDot).frame(width: 5, height: 5)
                    Text(slate.live.isEmpty ? "\(slate.all.count) MATCHUPS" : "\(slate.live.count) LIVE NOW")
                        .font(.inter(10, .bold)).tracking(1)
                }
            }
        }.padding(.horizontal, 20).padding(.top, 14).padding(.bottom, 17)
    }

    private var leagueTabs: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 25) {
                leagueTab(value: nil)
                ForEach(SportsLeague.allCases) { leagueTab(value: $0) }
            }.padding(.horizontal, 20)
        }
        .overlay(alignment: .bottom) { Rectangle().fill(LineupStyle.line).frame(height: 1) }
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

    private func matchup(_ game: SportsGame) -> some View {
        Button {
            guard !game.isUpcoming else {
                upcomingGame = game
                return
            }
            open(game)
        } label: { MobileMatchupRow(game: game) }
        .buttonStyle(MobileMatchupButtonStyle())
        .accessibilityElement(children: .combine)
        .accessibilityHint(game.isUpcoming ? "Show scheduled start time" : "Watch game or choose a channel")
        .contextMenu {
            Button("Choose another channel", systemImage: "list.bullet") { choosingChannel = game }
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
                })
        }
        playback.start(urls: library.playbackURLs(for: stream), channelID: stream.id)
    }

    private func closePreview() {
        playback.shutdown()
        previewStream = nil
        previewGame = nil
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

private struct MobileMatchupRow: View {
    @Environment(\.dynamicTypeSize) private var typeSize
    let game: SportsGame

    /// Both read from the game itself, so the card and the tests agree on what
    /// an event is and on where it is being held.
    private var isEvent: Bool { game.isEvent }
    private var whereItIs: String? { game.placeLine }

    var body: some View {
        HStack(spacing: 14) {
            VStack(alignment: .leading, spacing: 8) {
                if isEvent {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(game.eventName ?? "")
                            .font(.inter(.body, .semibold))
                            .lineLimit(2).multilineTextAlignment(.leading)
                        if let whereItIs { place(whereItIs) }
                    }
                } else {
                    team(game.awayTeam, logo: game.awayLogo, record: game.awayRecord, score: game.awayScore)
                    team(game.homeTeam, logo: game.homeLogo, record: game.homeRecord, score: game.homeScore)
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
                    }.accessibilityElement(children: .ignore)
                        .accessibilityLabel("Live. \(game.status)")
                } else {
                    Text(game.start, format: .dateTime.hour().minute())
                        .font(.interDigits(.caption, .semibold))
                }
                if !game.broadcast.isEmpty {
                    Text(game.broadcast.uppercased()).font(.inter(9, .semibold)).tracking(0.5).lineLimit(2)
                        .foregroundStyle(LineupStyle.secondary)
                }
                Image(systemName: "play.fill").font(.system(size: 10))
                    .padding(.top, 2).accessibilityHidden(true)
            }.frame(width: typeSize.isAccessibilitySize ? 100 : 76, alignment: .leading)
        }
        .fixedSize(horizontal: false, vertical: true)
        .padding(.horizontal, 20).padding(.vertical, 13)
        .background(game.isLive ? LineupStyle.surface : .clear)
        .overlay(alignment: .leading) {
            if game.isLive { Rectangle().fill(LineupStyle.liveDot).frame(width: 3) }
        }
        .overlay(alignment: .bottom) { Rectangle().fill(LineupStyle.line).frame(height: 1).padding(.horizontal, 20) }
        .contentShape(Rectangle())
    }

    /// One line, quiet, and only when there is something to say. The card
    /// earns its look by not filling every gap that could hold a fact.
    private func place(_ text: String) -> some View {
        Text(text)
            .font(.inter(.caption2))
            .foregroundStyle(LineupStyle.secondary)
            .lineLimit(1).truncationMode(.tail)
    }

    private func team(_ name: String, logo: String, record: String?, score: String) -> some View {
        HStack(spacing: 9) {
            // The disc went first and the ring that replaced it goes now: both
            // drew a circle around a mark that is not one. The badge lights
            // its own shape instead.
            TeamBadge(url: logo, fallback: String(name.prefix(3)).uppercased(), size: 28)
            VStack(alignment: .leading, spacing: 2) {
                Text(name).font(.inter(.subheadline, .semibold))
                    .lineLimit(typeSize.isAccessibilitySize ? nil : 1)
                    .multilineTextAlignment(.leading)
                if let record = record?.trimmingCharacters(in: .whitespacesAndNewlines), !record.isEmpty {
                    Text(record).font(.interDigits(.caption2))
                        .foregroundStyle(LineupStyle.secondary)
                        .accessibilityLabel("Record: \(record)")
                }
            }
            Spacer(minLength: 3)
            if game.isLive {
                Text(score).font(.interDigits(.title3, .bold))
            }
        }
    }
}

private struct MobileMatchupButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(configuration.isPressed ? LineupStyle.raised : .clear)
    }
}

/// Small pulsing red dot used to mark something as live. Shared across the
/// schedule list and the player controls (MobilePlayerView/MobileGuidePlayer).
struct MobileLiveDot: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var pulsing = false
    private var red: Color { LineupStyle.liveDot }

    var body: some View {
        ZStack {
            Circle().fill(red.opacity(0.4))
                .scaleEffect(pulsing && !reduceMotion ? 1.8 : 1)
                .opacity(pulsing && !reduceMotion ? 0 : 1)
                .animation(reduceMotion ? nil : .easeOut(duration: 1.6).repeatForever(autoreverses: false), value: pulsing)
            Circle().fill(red).frame(width: 5, height: 5)
        }
        .frame(width: 8, height: 8)
        .accessibilityHidden(true)
        .onAppear { pulsing = !reduceMotion }
        .onDisappear { pulsing = false }
        .onChange(of: reduceMotion) { _, reduced in pulsing = !reduced }
    }
}

private struct MobileLeagueLogo: View {
    let league: SportsLeague
    let size: CGFloat
    var body: some View {
        Image("League-\(league.rawValue)")
            .resizable().scaledToFit()
            .frame(width: size, height: size)
            .accessibilityLabel(league.shortName)
    }
}

/// Shown while channels, guide or matching are still in flight. Matching is what
/// decides a game's channel, so it stays up until that settles — otherwise a game
/// with no channel yet is indistinguishable from one with no channel at all.
/// The one wait a viewer genuinely has to sit through: a provider with nothing
/// cached. Names the stage and keeps moving, so it never reads as a freeze.
private struct InitialSyncBanner: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(spacing: 10) {
            ProgressView().controlSize(.regular)
            Text("SETTING UP YOUR PROVIDER").font(.inter(10, .bold)).tracking(1.6)
                .foregroundStyle(LineupStyle.lightPurple.opacity(0.75))
            Text("Lineup is downloading your channel list and guide, then matching channels to today's games. This happens once — later launches open straight from the last sync.")
                .font(.inter(.caption))
                .multilineTextAlignment(.center)
                .foregroundStyle(LineupStyle.secondary)
                .padding(.horizontal, 28)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 26)
        .accessibilityElement(children: .combine)
    }
}

/// Cache is already on screen and usable; this is only a footnote.
private struct BackgroundRefreshBanner: View {
    var body: some View {
        HStack(spacing: 8) {
            ProgressView().controlSize(.mini)
            Text("UPDATING IN BACKGROUND").font(.inter(10, .bold)).tracking(1.6)
        }
        .foregroundStyle(LineupStyle.lightPurple.opacity(0.55))
        .frame(maxWidth: .infinity)
        .padding(.vertical, 10)
        .accessibilityLabel("Updating in the background. Everything on screen is usable.")
    }
}

private struct RefreshingStreamsBanner: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var dimmed = false

    var body: some View {
        HStack(spacing: 8) {
            Circle().fill(LineupStyle.live).frame(width: 6, height: 6)
            Text("REFRESHING STREAMS").font(.inter(10, .bold)).tracking(1.6)
        }
        .foregroundStyle(LineupStyle.lightPurple.opacity(0.75))
        .opacity(reduceMotion || !dimmed ? 1 : 0.32)
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.9).repeatForever(autoreverses: true), value: dimmed)
        .onAppear { dimmed = true }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 14)
        .accessibilityLabel("Refreshing streams")
    }
}
