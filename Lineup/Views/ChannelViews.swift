import SwiftUI
import UIKit
import LineupAetherPlayback
import LineupMPVPlayback

struct LiveView: View {
    @Environment(SportsLibrary.self) private var library
    @Environment(\.scenePhase) private var scenePhase
    let isActive: Bool
    @State private var selectedLeague: SportsLeague?
    @State private var soccerCompetition: String?
    /// What is full screen. One value carries the channel, the game and the
    /// preview's player together: read from state of their own inside the
    /// cover, the game and the player could come through as they were a
    /// moment before -- no player, so full screen opened a second stream
    /// while the preview's, lent to it, kept playing underneath.
    @State private var fullScreen: TVFullScreenItem?
    @State private var multiviewPrimary: XtreamStream?
    @State private var multiviewPrimaryGame: SportsGame?
    @State private var multiviewSession: MultiviewSession?
    @State private var previewStream: XtreamStream?
    @State private var previewGameID: String?
    @State private var previewWasManuallySelected = false
    @State private var playbackTransitionID: UUID?
    @State private var qualityTask: Task<Void, Never>?
    @State private var qualityRequest: UUID?
    @State private var manualChannelGame: SportsGame?
    @State private var showsChannelSyncMessage = false
    @State private var manualSelectionStartsMultiview = false
    /// Both teams have a saved channel and they disagree: which feed.
    @State private var feedChoice: TVFeedChoice?
    /// A channel picked for a game, held until the picker has gone.
    @State private var pickedChannel: TVPickedChannel?
    /// After a pick: just this game, or always for one of its teams.
    @State private var scopingChannel: TVPickedChannel?
    /// From a game's hold menu: the channels verified to carry it, a side's
    /// page, the game from its start, and My Teams' recorded games.
    @State private var eventChannelsGame: SportsGame?
    @State private var teamPage: MobileTeamPageTarget?
    @State private var catchUpStream: XtreamStream?
    @State private var catchUpChoice: TVCatchUpChoice?
    @State private var catchUpMissing: SportsGame?
    @State private var catchUpLookup: Task<Void, Never>?
    @State private var showingReplays = false

    private var dayStart: Date { Calendar.current.startOfDay(for: Date()) }
    private var horizon: Date { Calendar.current.date(byAdding: .day, value: 2, to: dayStart) ?? dayStart }
    private var events: [SportsGame] {
        library.games(for: selectedLeague).filter {
            let end = $0.league.isRacing ? (Calendar.current.date(byAdding: .day, value: 14, to: dayStart) ?? horizon) : horizon
            return ($0.isLive || ($0.start >= dayStart && $0.start < end))
                && (selectedLeague != .soccer || soccerCompetition == nil || $0.competition?.id == soccerCompetition)
        }
    }
    private var tickerEvents: [SportsGame] { library.scoreTickerGames() }
    private var liveEvents: [SportsGame] { events.filter { $0.isLive } }
    private var upcomingEvents: [SportsGame] { events.filter { $0.isUpcoming } }

    var body: some View {
        GeometryReader { container in
            VStack(spacing: 0) {
                NavigationStack {
                    LiveScreen(
                        events: events,
                        selectedLeague: $selectedLeague,
                        soccerCompetition: $soccerCompetition,
                        previewStream: previewStream,
                        previewGame: library.gamesByLeague.values.lazy.flatMap { $0 }.first { $0.id == previewGameID },
                        previewURLs: previewStream.map { library.playbackURLs(for: $0) } ?? [],
                        multiviewPrimaryID: multiviewPrimary?.id,
                        multiviewTitle: multiviewPrimary?.name,
                        isScheduleLoading: library.isLoading || library.isScheduleLoading,
                        isScheduleAvailable: library.scheduleAvailable(for: selectedLeague),
                        scheduleErrorMessage: library.scheduleErrorMessage,
                        onPlay: select,
                        onStartMultiview: startMultiview,
                        onCancelMultiview: {
                            multiviewPrimary = nil
                            multiviewPrimaryGame = nil
                        },
                        onStopPreview: stopPreview
                    )
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    // Hold Select on any game for its channel, wherever the
                    // game's card is.
                    .environment(\.liveChooseChannel, { chooseChannel(for: $0) })
                    .environment(\.liveGameActions, gameActions)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .clipped()
                // The ticker belongs to the full-height Live layout, outside
                // NavigationStack's independently inset content area.
                LiveTicker(events: tickerEvents)
                    .frame(height: LiveTicker.height)
            }
            .frame(width: container.size.width, height: container.size.height, alignment: .top)
            .background(LiveCanvas())
            .lineupFullScreenCover(item: $fullScreen) { item in
                PlayerView(
                    urls: library.playbackURLs(for: item.stream),
                    title: item.stream.name,
                    program: library.guidePrograms(for: item.stream).normalizedEPG().first { $0.isLive },
                    game: item.game,
                    channelID: item.stream.id,
                    channel: item.stream,
                    // Up and Down go through the viewer's favourites; a
                    // replay is the game alone.
                    lineup: item.recordingOnly ? [] : library.guideStreams(categoryID: nil, favoritesOnly: true, query: ""),
                    recording: item.recording,
                    recordingOnly: item.recordingOnly,
                    continuing: item.preview
                )
            }
            .lineupFullScreenCover(item: $eventChannelsGame, onDismiss: applyPickedChannel) { game in
                TVEventChannelsScreen(game: game, playingID: previewGameID == game.id ? previewStream?.id : nil) { stream in
                    pickedChannel = TVPickedChannel(game: game, stream: stream, startsMultiview: false)
                    eventChannelsGame = nil
                }
            }
            .lineupFullScreenCover(item: $teamPage) { TVTeamPage(target: $0) }
            .lineupFullScreenCover(item: $catchUpStream) { stream in
                TVCatchUpScreen(stream: stream) { programme in
                    catchUpStream = nil
                    watchRecording(of: stream, programme: programme)
                }
            }
            .lineupFullScreenCover(isPresented: $showingReplays) {
                TVGameReplaysScreen { recording in
                    showingReplays = false
                    watchRecording(of: recording.stream, programme: recording.program, recordingOnly: true)
                }
            }
            .tvChoices("Catch Up", symbol: "clock.arrow.circlepath", isPresented: presenting($catchUpChoice),
                       message: catchUpChoice.map { "\($0.game.matchupLine): which channel's recording?" }) {
                guard let choice = catchUpChoice else { return [] }
                return choice.channels.map { stream in
                    TVChoice(stream.name, symbol: "tv", id: String(stream.id)) { openCatchUp(stream, for: choice.game) }
                }
            } onCancel: { catchUpChoice = nil }
            .tvChoices("No recording for this game", symbol: "clock.arrow.circlepath",
                       isPresented: presenting($catchUpMissing),
                       message: "None of the channels Lineup found for this game keeps a recording with your provider. TV Guide's Catch Up lists every channel that does.",
                       cancelTitle: "OK") { [] }
            .lineupFullScreenCover(item: $manualChannelGame, onDismiss: applyPickedChannel) { game in
                ManualGameChannelPicker(game: game) { stream in
                    pickedChannel = TVPickedChannel(game: game, stream: stream,
                                                    startsMultiview: manualSelectionStartsMultiview)
                    manualChannelGame = nil
                }
            }
            // Both teams have a saved channel and they disagree -- the one
            // case where a preference cannot answer on its own.
            .tvChoices("Which feed?", symbol: "tv", isPresented: presenting($feedChoice),
                       message: feedChoice.map {
                           "\($0.home.team) prefers \($0.home.channelName). \($0.away.team) prefers \($0.away.channelName)."
                       }) {
                guard let choice = feedChoice else { return [] }
                return [
                    TVChoice(choice.home.channelName, id: "home") { startFeed(choice.home, of: choice) },
                    TVChoice(choice.away.channelName, id: "away") { startFeed(choice.away, of: choice) },
                    // Run once the sheet has gone, so the picker can come up.
                    TVChoice("Choose Another Channel", symbol: "list.bullet.rectangle", id: "other") {
                        let game = choice.game
                        let multiview = choice.startsMultiview
                        feedChoice = nil
                        chooseChannel(for: game, startsMultiview: multiview)
                    }
                ]
            } onCancel: { feedChoice = nil }
            .channelScopePrompt($scopingChannel)
            .tvChoices("Channels are still syncing", symbol: "arrow.clockwise", isPresented: $showsChannelSyncMessage,
                       message: "Please wait for channel syncing to finish, then select the game again.",
                       cancelTitle: "OK") { [] }
            .lineupFullScreenCover(item: $multiviewSession) { session in
                MultiviewView(
                    primary: session.primary,
                    secondary: session.secondary,
                    primaryURLs: library.playbackURLs(for: session.primary),
                    secondaryURLs: library.playbackURLs(for: session.secondary),
                    primaryGame: session.primaryGame,
                    secondaryGame: session.secondaryGame
                )
            }
            .task(id: isActive) {
                guard isActive else { return }
                while !Task.isCancelled {
                    do { try await Task.sleep(for: .seconds(30)) }
                    catch { return }
                    // Live scores need refreshing every 30s; tomorrow's slate does not.
                    library.refreshSchedule(showsLoading: false, includeTomorrow: false)
                }
            }
            .onChange(of: isActive) { _, active in
                if !active { stopPreview() }
            }
            .overlay(alignment: .top) {
                if qualityRequest != nil { LiveQualityProgress { cancelQualityCheck() } }
            }
            .onDisappear { cancelQualityCheck(); catchUpLookup?.cancel() }
            .onChange(of: scenePhase) { _, phase in if phase == .background { cancelQualityCheck() } }
        }
        .ignoresSafeArea(.container, edges: [.horizontal, .bottom])
        .background(LineupStyle.background.ignoresSafeArea())
    }

    private func select(_ game: SportsGame) {
        // On the monitor already: a second press takes that same picture
        // full screen, on the channel it is showing.
        if previewGameID == game.id, let previewStream {
            play(game, on: previewStream)
            return
        }
        // Another card whose channel is the one already on the monitor --
        // two tournaments carried by one tennis channel, say. Opening it
        // again would change nothing on screen, and a press that changes
        // nothing reads as a press that did not register, so it is taken
        // full screen, as a second press would be.
        if let previewStream, case let .play(streamID, _) = library.preferredChannel(for: game),
           streamID == previewStream.id {
            previewGameID = game.id
            play(game, on: previewStream)
            return
        }
        stopPreview()
        open(game, startsMultiview: false)
    }

    /// One game, one decision, made as the iPhone makes it: a channel chosen
    /// for this game, then a team's saved channel where the guide says it is
    /// carrying the game, then Lineup's own match -- and the picker when none
    /// of those answers. `TeamChannelPreferences.resolve` decides.
    private func open(_ game: SportsGame, startsMultiview: Bool) {
        cancelQualityCheck()
        switch library.preferredChannel(for: game) {
        case .syncing:
            showsChannelSyncMessage = true
        case let .play(streamID, source):
            if let stream = library.stream(withID: streamID) {
                TVPreviewHandoff.stopPreviews()
                let request = UUID()
                if source == .verified {
                    qualityRequest = request
                    qualityTask = Task { @MainActor in
                        let chosen = await library.bestQualityStream(for: game, fallback: stream)
                        guard !Task.isCancelled, qualityRequest == request, isActive else { return }
                        qualityRequest = nil
                        qualityTask = nil
                        if let chosen { start(game, on: chosen, startsMultiview: startsMultiview) }
                        else { chooseChannel(for: game, startsMultiview: startsMultiview) }
                    }
                } else { start(game, on: stream, startsMultiview: startsMultiview) }
            } else {
                chooseChannel(for: game, startsMultiview: startsMultiview)
            }
        case let .chooseFeed(home, away):
            feedChoice = TVFeedChoice(game: game, home: home, away: away, startsMultiview: startsMultiview)
        case .pick:
            chooseChannel(for: game, startsMultiview: startsMultiview)
        }
    }

    private func start(_ game: SportsGame, on stream: XtreamStream, startsMultiview: Bool,
                       manuallySelected: Bool = false) {
        cancelQualityCheck()
        if startsMultiview {
            stopPreview()
            multiviewPrimary = stream
            multiviewPrimaryGame = game
        } else {
            play(game, on: stream, manuallySelected: manuallySelected)
        }
    }

    private func startFeed(_ option: TeamFeedOption, of choice: TVFeedChoice) {
        feedChoice = nil
        guard let stream = library.stream(withID: option.streamID) else { return }
        start(choice.game, on: stream, startsMultiview: choice.startsMultiview)
    }

    private func chooseChannel(for game: SportsGame, startsMultiview: Bool = false) {
        manualSelectionStartsMultiview = startsMultiview
        manualChannelGame = game
    }

    /// A channel came back from the picker: play it, remember it for this
    /// game, and ask whether it should stick to either team.
    private func applyPickedChannel() {
        guard let picked = pickedChannel else { return }
        pickedChannel = nil
        library.saveGameSelection(picked.stream, for: picked.game)
        // Fresh on the monitor, rather than taken full screen as a second
        // press on a game already there would be.
        if !picked.startsMultiview, previewGameID == picked.game.id { stopPreview() }
        start(picked.game, on: picked.stream, startsMultiview: picked.startsMultiview, manuallySelected: true)
        scopingChannel = library.asksScope(for: picked)
    }

    /// Drives a dialog from an optional: SwiftUI clears the optional on
    /// dismiss, which a constant binding cannot do.
    private func presenting<T>(_ value: Binding<T?>) -> Binding<Bool> {
        Binding(get: { value.wrappedValue != nil },
                set: { if !$0 { value.wrappedValue = nil } })
    }

    private func play(_ game: SportsGame, on stream: XtreamStream, manuallySelected: Bool = false) {
        guard let primary = multiviewPrimary else {
            if previewGameID == game.id, let preview = TVPreviewHandoff.lend(playing: stream.id) {
                // The preview's own player goes full screen, still playing,
                // and the preview stays behind it to come back to.
                playbackTransitionID = nil
                presentWithoutAnimation {
                    fullScreen = TVFullScreenItem(stream: stream, game: game, preview: preview)
                }
            } else if previewGameID == game.id {
                let transitionID = UUID()
                playbackTransitionID = transitionID
                previewStream = nil
                previewGameID = nil
                Task { @MainActor in
                    try? await Task.sleep(for: .milliseconds(180))
                    guard isActive, playbackTransitionID == transitionID else { return }
                    playbackTransitionID = nil
                    fullScreen = TVFullScreenItem(stream: stream, game: game)
                }
            } else {
                playbackTransitionID = nil
                previewStream = stream
                previewGameID = game.id
                previewWasManuallySelected = manuallySelected
            }
            return
        }
        guard primary.id != stream.id else { return }
        multiviewPrimary = nil
        multiviewSession = MultiviewSession(primary: primary, secondary: stream,
                                           primaryGame: multiviewPrimaryGame, secondaryGame: game)
        multiviewPrimaryGame = nil
    }

    private func startMultiview(_ game: SportsGame) {
        open(game, startsMultiview: true)
    }

    private var gameActions: LiveGameActions {
        LiveGameActions(channels: { eventChannelsGame = $0 }, catchUp: findCatchUp,
                        teamPage: { teamPage = $0 }, replays: { showingReplays = true })
    }

    /// Catch Up from a game's menu: of the channels verified to carry it,
    /// the ones that keep a recording. One opens its programmes; several
    /// ask which; none says so.
    private func findCatchUp(_ game: SportsGame) {
        catchUpLookup?.cancel()
        guard let profile = library.activeProfile, !profile.isPlaylist else { return }
        catchUpLookup = Task { @MainActor in
            let matched = await library.eventChannels(for: game)
            guard !Task.isCancelled, isActive, library.activeProfile?.id == profile.id else { return }
            let current = library.gamesByLeague[game.league]?.first { $0.id == game.id } ?? game
            let channels = MobileSportsCatchUpPolicy.channels(matched, live: current.isLive, playlist: profile.isPlaylist)
            switch channels.count {
            case 0: catchUpMissing = current
            case 1: openCatchUp(channels[0], for: current)
            default: catchUpChoice = TVCatchUpChoice(game: current, channels: channels)
            }
        }
    }

    /// Checked again as it is chosen: still the provider's, still keeping
    /// recordings, still carrying the game.
    private func openCatchUp(_ selected: XtreamStream, for game: SportsGame) {
        catchUpChoice = nil
        guard let stream = library.stream(withID: selected.id), stream.hasCatchUp,
              library.isEventChannel(stream, verifiedFor: game) else { return }
        catchUpStream = stream
    }

    /// A recording full screen, once the screen it was chosen on has gone.
    /// A replay is the recording or nothing: it never goes live instead.
    private func watchRecording(of stream: XtreamStream, programme: CatchUpProgramme, recordingOnly: Bool = false) {
        stopPreview()
        TVPreviewHandoff.stopPreviews()
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(180))
            guard isActive else { return }
            fullScreen = TVFullScreenItem(stream: stream, recording: programme, recordingOnly: recordingOnly)
        }
    }

    private func stopPreview() {
        cancelQualityCheck()
        playbackTransitionID = nil
        previewStream = nil
        previewGameID = nil
        previewWasManuallySelected = false
    }

    private func cancelQualityCheck() {
        qualityTask?.cancel()
        qualityTask = nil
        qualityRequest = nil
    }
}

/// Catch Up from a game's menu, with more than one channel recording it.
private struct TVCatchUpChoice {
    let game: SportsGame
    let channels: [XtreamStream]
}

/// Both teams have a saved channel for a game, and they are not the same.
private struct TVFeedChoice: Identifiable {
    let game: SportsGame
    let home: TeamFeedOption
    let away: TeamFeedOption
    let startsMultiview: Bool
    var id: String { game.id }
}

/// A channel the viewer picked for a game.
private struct TVPickedChannel: Identifiable {
    let game: SportsGame
    let stream: XtreamStream
    let startsMultiview: Bool
    var id: String { game.id + "." + String(stream.id) }
}

/// After a channel is picked for a game: keep it for just this game, or
/// always for either team -- the iPhone's question, asked wherever a channel
/// is chosen on the television.
private struct TVChannelScopePrompt: ViewModifier {
    @Environment(SportsLibrary.self) private var library
    @Binding var picked: TVPickedChannel?

    func body(content: Content) -> some View {
        content.tvChoices("Use this channel for…", symbol: "star.square.on.square",
                          isPresented: Binding(get: { picked != nil }, set: { if !$0 { picked = nil } }),
                          message: picked.map {
                              "\($0.stream.name) is on now. Lineup can remember it for either team's games."
                          }) {
            guard let choice = picked else { return [] }
            let sides = library.preferenceSides(for: choice.game).map { side in
                TVChoice("Always for the \(side.role) (\(side.team))", symbol: "star", id: "side-\(side.id)") {
                    library.savePreference(choice.stream, for: side.key, teamName: side.team)
                    picked = nil
                }
            }
            return [TVChoice("Just This Game", symbol: "sportscourt", id: "game") { picked = nil }] + sides
        }
    }
}

extension View {
    fileprivate func channelScopePrompt(_ picked: Binding<TVPickedChannel?>) -> some View {
        modifier(TVChannelScopePrompt(picked: picked))
    }
}

extension SportsLibrary {
    /// Whether a pick for this game has a team to be kept for.
    fileprivate func asksScope(for picked: TVPickedChannel?) -> TVPickedChannel? {
        guard let picked, !preferenceSides(for: picked.game).isEmpty else { return nil }
        return picked
    }
}

/// Opens the channel picker for a game, from wherever the game's card is.
private struct LiveChooseChannelKey: EnvironmentKey {
    static let defaultValue: ((SportsGame) -> Void)? = nil
}

extension EnvironmentValues {
    fileprivate var liveChooseChannel: ((SportsGame) -> Void)? {
        get { self[LiveChooseChannelKey.self] }
        set { self[LiveChooseChannelKey.self] = newValue }
    }
}

/// Choosing the channel to watch a game on: the whole screen, browsed the
/// way the TV Guide is. The provider's categories down the left, as the
/// Guide's sidebar has them, with Lineup's own suggestions first -- its
/// match and the channels saved for either team -- and the chosen list
/// across the rest, each channel with what it is showing now.
private struct ManualGameChannelPicker: View {
    @Environment(SportsLibrary.self) private var library
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    /// Nil until one is chosen: Suggested when there is anything to
    /// suggest, every channel when there is not.
    @State private var source: Source?
    @FocusState private var sidebarFocus: String?
    let game: SportsGame
    let onSelect: (XtreamStream) -> Void

    private enum Source: Hashable {
        case suggested, favorites, all, category(String)
    }

    var body: some View {
        let notes = suggestionNotes()
        let suggested = suggestions()
        let current = source ?? (suggested.isEmpty ? .all : .suggested)
        let searching = !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let streams = searching
            ? library.guideStreams(categoryID: nil, favoritesOnly: false, query: query)
            : channels(in: current, suggested: suggested)
        VStack(alignment: .leading, spacing: 30) {
            header
            HStack(alignment: .top, spacing: 36) {
                sidebar(current: current, hasSuggestions: !suggested.isEmpty)
                    .frame(width: 400)
                    .frame(maxHeight: .infinity, alignment: .top)
                    .background(GuidePalette.rail, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
                    .focusSection()
                list(streams, title: searching ? "Results" : title(of: current), notes: notes, searching: searching)
                    // A new list for each source, so the first channel in
                    // it is where the remote lands.
                    .id(searching ? "search" : String(describing: current))
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                    .focusSection()
            }
        }
        .padding(.horizontal, 80)
        .padding(.top, 56)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(LineupPresentationStyle.ground.ignoresSafeArea())
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 28) {
            VStack(alignment: .leading, spacing: 8) {
                Text("CHOOSE A CHANNEL")
                    .font(.inter(16, .heavy)).tracking(0.6).foregroundStyle(LineupPresentationStyle.secondary)
                Text("\(game.awayTeam) vs. \(game.homeTeam)")
                    .font(.inter(40, .semibold)).foregroundStyle(LineupPresentationStyle.text)
                    .lineLimit(1).minimumScaleFactor(0.7)
                Text(game.broadcast.isEmpty ? "No network listed" : "Listed on \(game.broadcast)")
                    .font(.inter(20)).foregroundStyle(LineupPresentationStyle.secondary)
            }
            Spacer(minLength: 24)
            TextField("Search channels", text: $query)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .frame(width: 560)
            Button("Cancel", role: .cancel) { dismiss() }
                .lineupButtonStyle()
        }
        .focusSection()
    }

    private func sidebar(current: Source, hasSuggestions: Bool) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            GuideSidebarHeading(title: "BROWSE")
            if hasSuggestions {
                GuideSidebarButton(title: "Suggested", symbol: "sparkles", selected: current == .suggested,
                                   focus: $sidebarFocus, focusID: "suggested") { choose(.suggested) }
            }
            GuideSidebarButton(title: "Favorites", symbol: "star", selected: current == .favorites,
                               focus: $sidebarFocus, focusID: "favorites") { choose(.favorites) }
            GuideSidebarButton(title: "All channels", symbol: "square.grid.2x2", selected: current == .all,
                               focus: $sidebarFocus, focusID: "all") { choose(.all) }
            GuideSidebarHeading(title: "CATEGORIES").padding(.top, 10)
            ScrollView {
                LazyVStack(spacing: 4) {
                    ForEach(library.categories) { category in
                        GuideSidebarButton(title: category.categoryName, symbol: "rectangle.grid.1x2",
                                           selected: current == .category(category.id),
                                           focus: $sidebarFocus, focusID: "category-" + category.id) {
                            choose(.category(category.id))
                        }
                    }
                }
                .padding(.vertical, 4)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
    }

    @ViewBuilder
    private func list(_ streams: [XtreamStream], title: String, notes: [Int: String],
                      searching: Bool) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                Text(title.uppercased())
                    .font(.inter(16, .heavy)).tracking(0.6).foregroundStyle(LineupPresentationStyle.secondary)
                    .lineLimit(1)
                Spacer(minLength: 16)
                Text(streams.count == 1 ? "1 channel" : "\(streams.count.formatted()) channels")
                    .font(.inter(16)).foregroundStyle(LineupPresentationStyle.secondary)
            }
            .padding(.horizontal, 14)
            if streams.isEmpty {
                VStack(spacing: 14) {
                    Image(systemName: searching ? "magnifyingglass" : "tv")
                        .font(.system(size: 44, design: .rounded)).foregroundStyle(LineupPresentationStyle.secondary)
                    Text(searching ? "Nothing matched \u{201C}\(query)\u{201D}" : "No channels here")
                        .font(.inter(26, .semibold)).foregroundStyle(LineupPresentationStyle.text)
                    Text(searching ? "Try another name, or browse a category on the left."
                                   : "Choose another category on the left.")
                        .font(.inter(20)).foregroundStyle(LineupPresentationStyle.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 10) {
                        ForEach(streams) { stream in
                            // Typing is left alone: focus is only sent into a
                            // list chosen from the sidebar or the one first shown.
                            row(stream, note: notes[stream.id],
                                first: !searching && stream.id == streams.first?.id)
                        }
                    }
                    // Room for a focused row's lift at both ends.
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                    .padding(.bottom, 80)
                }
            }
        }
    }

    private func row(_ stream: XtreamStream, note: String?, first: Bool) -> some View {
        let now = library.guidePrograms(for: stream).normalizedEPG().first { $0.isLive }
        let shape = RoundedRectangle(cornerRadius: 14, style: .continuous)
        return TVSelectable(scale: 1.012, fillRadius: 14, action: { onSelect(stream) }, requestInitialFocus: first) {
            HStack(spacing: 22) {
                ChannelLogo(url: stream.streamIcon, width: 96, height: 58)
                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                VStack(alignment: .leading, spacing: 4) {
                    Text(stream.name)
                        .font(.inter(24, .semibold)).foregroundStyle(LineupPresentationStyle.text).lineLimit(1)
                    Text(now?.title ?? "No guide information")
                        .font(.inter(19)).foregroundStyle(LineupPresentationStyle.secondary).lineLimit(1)
                }
                Spacer(minLength: 16)
                if let note {
                    Text(note.uppercased())
                        .font(.inter(14, .bold)).tracking(1).foregroundStyle(LineupPresentationStyle.text)
                        .lineLimit(1).fixedSize()
                        .padding(.horizontal, 12).frame(height: 28)
                        .background(LineupPresentationStyle.row, in: Capsule())
                }
                if library.isFavorite(stream) {
                    Image(systemName: "star.fill")
                        .font(.system(size: 18, design: .rounded)).foregroundStyle(LineupPresentationStyle.secondary)
                }
            }
            .padding(.horizontal, 20)
            .frame(height: 88)
            .background(LineupPresentationStyle.card, in: shape)
        }
        .accessibilityLabel("Watch \(game.awayTeam) versus \(game.homeTeam) on \(stream.name)")
    }

    private func choose(_ next: Source) {
        query = ""
        source = next
    }

    private func title(of source: Source) -> String {
        switch source {
        case .suggested: return "Suggested"
        case .favorites: return "Favorites"
        case .all: return "All Channels"
        case .category(let id): return library.categories.first { $0.id == id }?.categoryName ?? "Category"
        }
    }

    private func channels(in source: Source, suggested: [XtreamStream]) -> [XtreamStream] {
        switch source {
        case .suggested: return suggested
        case .favorites: return library.guideStreams(categoryID: nil, favoritesOnly: true, query: "")
        case .all: return library.guideStreams(categoryID: nil, favoritesOnly: false, query: "")
        case .category(let id): return library.guideStreams(categoryID: id, favoritesOnly: false, query: "")
        }
    }

    /// Why a suggested channel is suggested, by its id.
    private func suggestionNotes() -> [Int: String] {
        var notes: [Int: String] = [:]
        for side in library.preferenceSides(for: game) {
            if let saved = library.teamPreferences.preference(for: side.key) {
                notes[saved.streamID] = side.team
            }
        }
        if let matched = library.verifiedStream(for: game) { notes[matched.id] = "Lineup's match" }
        return notes
    }

    /// Lineup's match and the teams' saved channels, then a few favorites.
    private func suggestions() -> [XtreamStream] {
        var seen: Set<Int> = []
        var out: [XtreamStream] = []
        func add(_ stream: XtreamStream?) {
            if let stream, seen.insert(stream.id).inserted { out.append(stream) }
        }
        add(library.verifiedStream(for: game))
        for side in library.preferenceSides(for: game) {
            add(library.teamPreferences.preference(for: side.key).flatMap { library.stream(withID: $0.streamID) })
        }
        for showing in library.tennisCoverage(for: game) { add(showing) }
        for favorite in library.guideStreams(categoryID: nil, favoritesOnly: true, query: "") { add(favorite) }
        return Array(out.prefix(8))
    }
}

/// A channel's past programmes that the provider kept, to play from the
/// start: the whole screen, the list on the right by day, newest first, and
/// what the focused programme is on the left.
///
/// Focus only ever moves up and down the list. The days are headings in it
/// rather than a rail of their own, so there is nothing for a sideways press
/// to land on by accident and change what is listed.
private struct TVCatchUpScreen: View {
    @Environment(SportsLibrary.self) private var library
    let stream: XtreamStream
    let onSelect: (CatchUpProgramme) -> Void
    @State private var programmes: [CatchUpProgramme] = []
    @State private var loading = true
    @State private var failed = false
    @State private var focused: CatchUpProgramme?

    private struct Day: Identifiable {
        let day: Date
        let programmes: [CatchUpProgramme]
        var id: Date { day }
    }

    /// The programmes by the day they started, the latest day first.
    private var days: [Day] {
        let calendar = Calendar.current
        let grouped = Dictionary(grouping: programmes) { calendar.startOfDay(for: $0.start) }
        return grouped.keys.sorted(by: >).map { day in
            Day(day: day, programmes: (grouped[day] ?? []).sorted { $0.start > $1.start })
        }
    }

    var body: some View {
        HStack(alignment: .top, spacing: 64) {
            TVCatchUpDetail(stream: stream, programme: focused ?? programmes.first,
                            dayCount: days.count, programmeCount: programmes.count)
                .frame(width: 600)
                .frame(maxHeight: .infinity, alignment: .top)
            list
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        }
        .padding(.horizontal, 90)
        .padding(.top, 70)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(LineupPresentationStyle.ground.ignoresSafeArea())
        .task {
            do {
                programmes = try await library.catchUpProgrammes(for: stream)
            } catch {
                failed = true
            }
            loading = false
        }
    }

    @ViewBuilder
    private var list: some View {
        if loading {
            ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if programmes.isEmpty {
            VStack(spacing: 14) {
                Image(systemName: failed ? "wifi.exclamationmark" : "clock.arrow.circlepath")
                    .font(.system(size: 44, weight: .regular, design: .rounded))
                    .foregroundStyle(LineupPresentationStyle.secondary)
                Text(failed ? "The provider didn't answer" : "Nothing kept yet")
                    .font(.inter(26, .semibold)).foregroundStyle(LineupPresentationStyle.text)
                Text(failed ? "Try again in a moment."
                            : "Programs from this channel will show here once the provider has kept them.")
                    .font(.inter(18)).foregroundStyle(LineupPresentationStyle.secondary)
                    .multilineTextAlignment(.center).frame(maxWidth: 520)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 10, pinnedViews: [.sectionHeaders]) {
                    ForEach(days) { group in
                        Section {
                            ForEach(group.programmes) { programme in
                                TVSelectable(scale: 1.015, fillRadius: 14,
                                             action: { onSelect(programme) },
                                             onFocusChange: { if $0 { focused = programme } },
                                             requestInitialFocus: programme.id == programmes.first?.id) {
                                    TVCatchUpRow(programme: programme)
                                }
                            }
                        } header: {
                            TVCatchUpDayHeader(day: group.day, count: group.programmes.count)
                        }
                    }
                }
                // Room for a focused row's lift at both ends of the list.
                .padding(.horizontal, 14)
                .padding(.bottom, 80)
            }
        }
    }
}

/// The left of the catch-up screen: the channel, then everything about the
/// programme in focus. Nothing here takes focus.
private struct TVCatchUpDetail: View {
    let stream: XtreamStream
    let programme: CatchUpProgramme?
    let dayCount: Int
    let programmeCount: Int

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 18) {
                ChannelLogo(url: stream.streamIcon, width: 96, height: 64)
                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                VStack(alignment: .leading, spacing: 4) {
                    Text("CATCH UP").font(.inter(13, .heavy)).tracking(0.6)
                        .foregroundStyle(LineupPresentationStyle.secondary)
                    Text(stream.name).font(.inter(30, .bold)).foregroundStyle(LineupPresentationStyle.text)
                        .lineLimit(2).minimumScaleFactor(0.8)
                }
            }
            if programmeCount > 0 {
                Text("\(programmeCount) programs over \(dayCount == 1 ? "1 day" : "\(dayCount) days")")
                    .font(.inter(16, .medium)).foregroundStyle(LineupPresentationStyle.secondary)
                    .padding(.top, 14)
            }

            Rectangle().fill(LineupStyle.line).frame(height: 1).padding(.vertical, 34)

            if let programme {
                VStack(alignment: .leading, spacing: 16) {
                    Text(TVCatchUpFormat.when(programme))
                        .font(.inter(15, .heavy)).tracking(0.6)
                        .foregroundStyle(LineupPresentationStyle.secondary)
                    Text(programme.title)
                        .font(.inter(40, .bold)).foregroundStyle(LineupPresentationStyle.text)
                        .lineLimit(3).minimumScaleFactor(0.75)
                        .fixedSize(horizontal: false, vertical: true)
                    HStack(spacing: 12) {
                        TVCatchUpChip(text: TVCatchUpFormat.length(programme.duration))
                        if programme.isOnNow { TVCatchUpOnNow() }
                    }
                    if programme.isOnNow {
                        TVCatchUpProgress(fraction: TVCatchUpFormat.elapsedFraction(programme), height: 10)
                            .frame(maxWidth: 420)
                    }
                    if !programme.detail.isEmpty {
                        Text(programme.detail)
                            .font(.inter(20)).foregroundStyle(LineupPresentationStyle.secondary)
                            .lineSpacing(4)
                            .lineLimit(8)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                // A new programme's words replace the last one's at once: an
                // animated swap would trail behind the remote.
                .transaction { $0.animation = nil }
            }

            Spacer(minLength: 24)

            HStack(spacing: 10) {
                Image(systemName: "play.circle")
                Text(programme?.isOnNow == true ? "Select to watch from the start, then catch up to live"
                                                : "Select to watch from the start")
            }
            .font(.inter(17, .medium))
            .foregroundStyle(LineupPresentationStyle.secondary)
            .padding(.bottom, 60)
        }
    }
}

/// A day's heading in the list, pinned while its programmes scroll under it.
private struct TVCatchUpDayHeader: View {
    let day: Date
    let count: Int

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(TVCatchUpFormat.dayTitle(day))
                .font(.inter(16, .heavy)).tracking(0.6)
                .foregroundStyle(LineupPresentationStyle.text)
            Text(day.formatted(.dateTime.month(.abbreviated).day()).uppercased())
                .font(.inter(14, .heavy)).tracking(0.6)
                .foregroundStyle(LineupPresentationStyle.secondary)
            Spacer(minLength: 0)
            Text(count == 1 ? "1 program" : "\(count) programs")
                .font(.inter(14, .medium))
                .foregroundStyle(LineupPresentationStyle.secondary)
        }
        .padding(.horizontal, 24)
        .padding(.top, 22).padding(.bottom, 12)
        // Opaque, so rows scrolling up under a pinned heading do not show
        // through it.
        .background(LineupPresentationStyle.ground)
    }
}

/// One programme in the catch-up list.
private struct TVCatchUpRow: View {
    let programme: CatchUpProgramme

    var body: some View {
        HStack(alignment: .center, spacing: 26) {
            VStack(alignment: .leading, spacing: 4) {
                Text(programme.start.formatted(date: .omitted, time: .shortened))
                    .font(.interDigits(22, .semibold))
                    .foregroundStyle(LineupPresentationStyle.text)
                Text(TVCatchUpFormat.length(programme.duration))
                    .font(.inter(15, .medium))
                    .foregroundStyle(LineupPresentationStyle.secondary)
            }
            .frame(width: 128, alignment: .leading)

            Rectangle().fill(LineupStyle.line).frame(width: 1, height: 46)

            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 12) {
                    if programme.isOnNow { TVCatchUpOnNow() }
                    Text(programme.title)
                        .font(.inter(23, .semibold))
                        .foregroundStyle(LineupPresentationStyle.text)
                        .lineLimit(1)
                }
                if !programme.detail.isEmpty {
                    Text(programme.detail)
                        .font(.inter(16))
                        .foregroundStyle(LineupPresentationStyle.secondary)
                        .lineLimit(1)
                }
                if programme.isOnNow {
                    TVCatchUpProgress(fraction: TVCatchUpFormat.elapsedFraction(programme), height: 6)
                        .padding(.top, 4)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 24).padding(.vertical, 18)
        .frame(minHeight: 96)
        .background(programme.isOnNow ? LineupStyle.focused : LineupPresentationStyle.row,
                    in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .accessibilityElement(children: .combine)
    }
}

/// "ON NOW", red: catch-up's one status.
private struct TVCatchUpOnNow: View {
    var body: some View {
        HStack(spacing: 6) {
            Circle().fill(LineupStyle.liveDot).frame(width: 8, height: 8)
            Text("ON NOW").font(.inter(13, .heavy)).tracking(0.6)
                .foregroundStyle(LineupStyle.liveStatus)
        }
    }
}

private struct TVCatchUpChip: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.inter(15, .semibold))
            .foregroundStyle(LineupPresentationStyle.text)
            .padding(.horizontal, 12).padding(.vertical, 6)
            .background(LineupPresentationStyle.row, in: Capsule())
    }
}

/// How far a programme still on has got: the app's progress bar.
private struct TVCatchUpProgress: View {
    let fraction: Double
    let height: CGFloat

    var body: some View {
        LineupProgressBar(value: fraction, height: height)
    }
}

/// The catch-up screen's words for times and lengths.
private enum TVCatchUpFormat {
    static func dayTitle(_ day: Date) -> String {
        let calendar = Calendar.current
        if calendar.isDateInToday(day) { return "TODAY" }
        if calendar.isDateInYesterday(day) { return "YESTERDAY" }
        return day.formatted(.dateTime.weekday(.wide)).uppercased()
    }

    /// "TODAY · 9:00 – 11:00 AM"
    static func when(_ programme: CatchUpProgramme) -> String {
        let day = dayTitle(Calendar.current.startOfDay(for: programme.start))
        let start = programme.start.formatted(date: .omitted, time: .shortened)
        let end = programme.end.formatted(date: .omitted, time: .shortened)
        return "\(day)  ·  \(start) – \(end)"
    }

    /// "2 hr", "1 hr 30 min", "45 min"
    static func length(_ duration: TimeInterval) -> String {
        let minutes = max(1, Int((duration / 60).rounded()))
        let hours = minutes / 60, rest = minutes % 60
        if hours == 0 { return "\(rest) min" }
        return rest == 0 ? "\(hours) hr" : "\(hours) hr \(rest) min"
    }

    static func elapsedFraction(_ programme: CatchUpProgramme, now: Date = Date()) -> Double {
        guard programme.duration > 0 else { return 0 }
        return min(1, max(0, now.timeIntervalSince(programme.start) / programme.duration))
    }
}

private enum LiveBoardStyle {
    static var accent: Color { LineupStyle.lightPurple }
    static var leagueFocus: Color { LineupStyle.focused }
    static var canvas: Color { LineupPresentationStyle.ground }
    static var panel: Color { LineupPresentationStyle.card }
    static var muted: Color { LineupStyle.lightPurple }
}

private struct LiveBoardRail: View {
    @Binding var selectedLeague: SportsLeague?
    let onChoose: () -> Void
    let onEnterGames: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("EXPLORE").font(.inter(16, .heavy)).tracking(LineupPanelStyle.headerTracking)
                .foregroundStyle(LineupPanelStyle.caption).padding(.bottom, 8)
            LiveBoardLeagueButton(title: "All sports", league: nil, selected: selectedLeague == nil,
                onEnterGames: onEnterGames) { selectedLeague = nil; onChoose() }
            ForEach(SportsLeague.allCases) { league in
                LiveBoardLeagueButton(title: league == .ncaaf ? "College" : league.shortName,
                    league: league, selected: selectedLeague == league, onEnterGames: onEnterGames) {
                    selectedLeague = league
                    onChoose()
                }
            }
            Spacer(minLength: 12)
        }
        .frame(width: 156, alignment: .leading)
        .padding(.trailing, 24)
        .overlay(alignment: .trailing) { Rectangle().fill(LineupStyle.lightPurple.opacity(0.08)).frame(width: 1) }
        .focusSection()
    }
}

private struct LiveBoardLeagueButton: View {
    @FocusState private var focused: Bool
    let title: String
    let league: SportsLeague?
    let selected: Bool
    let onEnterGames: () -> Void
    let action: () -> Void

    var body: some View {
        Group {
            HStack(spacing: 12) {
                if let league {
                    LeagueLogo(league: league, size: 26)
                } else {
                    Image(systemName: "square.grid.2x2.fill").frame(width: 26)
                }
                Text(title).foregroundColor(LineupStyle.lightPurple).font(.inter(17, .semibold)).lineLimit(1)
                Spacer(minLength: 0)
            }
            .foregroundStyle(selected || focused ? LineupStyle.text : LineupStyle.secondary)
            .padding(.horizontal, 12).frame(height: 49)
            .background(focused ? LiveBoardStyle.leagueFocus : (selected ? LineupStyle.lightPurple.opacity(0.07) : .clear))
            .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
            .overlay(alignment: .leading) {
                if selected && !focused { Rectangle().fill(LiveBoardStyle.accent).frame(width: 3, height: 22) }
            }
        }
        .contentShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        .focusable().focused($focused).focusEffectDisabled()
        .tvSelectAction(action)
        .accessibilityAddTraits(.isButton)
        .onMoveCommand { if $0 == .right { onEnterGames() } }
        .accessibilityLabel(title)
        .accessibilityAddTraits(selected ? [.isSelected] : [])
    }
}

/// The date, and nothing else. Refreshing used to sit out at the right of it,
/// which is the far corner of a television from where anyone is looking.
private struct LiveBoardHeading: View {
    var body: some View {
        HStack(alignment: .center) {
            Text(Date().formatted(.dateTime.weekday(.wide).month(.abbreviated).day()))
                .font(.inter(16, .medium))
                .foregroundStyle(LiveBoardStyle.muted)
            Spacer()
        }
        .foregroundStyle(LineupStyle.lightPurple)
        .frame(height: 28)
    }
}

/// A band of the theme's colour crossing the dark screen, over and over.
///
/// The app's own mark is a line travelling across a guide, and so is the line
/// down the guide itself. A set looking for its channels is the same idea in
/// motion, and it reads as equipment working rather than as a spinner bolted
/// onto a television.
private struct LiveTVSignalSweep: View {
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

private struct LiveEmptySlateDashboard: View {
    @Binding var selectedLeague: SportsLeague?
    @Binding var focusedGame: SportsGame?
    let isLoading: Bool
    let isAvailable: Bool
    let errorMessage: String?

    var body: some View {
        VStack(spacing: 20) {
            LiveBoardHeading()
            HStack(spacing: 30) {
                LiveBoardRail(selectedLeague: $selectedLeague, onChoose: { focusedGame = nil }, onEnterGames: {})
                VStack(alignment: .leading, spacing: 22) {
                    Image(systemName: isLoading ? "antenna.radiowaves.left.and.right" : "sportscourt")
                        .font(.inter(56, .ultraLight)).foregroundStyle(LiveBoardStyle.muted)
                    Text(isLoading ? "Setting the board." : (isAvailable ? "A moment between games." : "The schedule is unavailable.")).foregroundColor(LineupStyle.lightPurple)
                        .font(.inter(38, .bold))
                    Text(isLoading ? "Your games will appear here shortly." :
                        (isAvailable ? "Explore another sport, or come back for the next matchup." :
                            (errorMessage ?? "We’ll try again shortly. Your saved channels are still available in Guide."))).foregroundColor(LineupStyle.lightPurple)
                        .font(.inter(20)).foregroundStyle(LiveBoardStyle.muted)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
                .padding(44)
                .background(LiveBoardStyle.panel, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
            }
            .frame(maxHeight: .infinity)
        }
        .padding(.horizontal, 38).padding(.bottom, 26)
        .background(LiveBoardStyle.canvas)
    }
}

// MARK: - Live

/// The Live tab's reading of the theme.
///
/// Every colour here comes from LineupStyle's charcoal, light grey and white.
/// The one colour that is not the theme's is broadcast red, and it only ever
/// means on air; the teams bring their own.
private enum LivePalette {
    static var text: Color { LineupStyle.text.opacity(0.78) }
    static var secondary: Color { LineupStyle.secondary.opacity(0.9) }
    static var card: Color { LineupStyle.surface }
    static var rule: Color { LineupStyle.line }
    static var accent: Color { LineupStyle.highlight }
    static var rim: Color { LineupStyle.liveSelectionBorder }
    static var onAir: Color { LineupStyle.liveDot }
}

/// One grid for the whole tab.
private enum LiveMetrics {
    /// tvOS's own title-safe inset. The stage, the board and the score crawl
    /// all stop on it, so nothing sits in a television's overscan band and no
    /// edge on the screen stops in two places.
    static let margin: CGFloat = 80
    static let railWidth: CGFloat = 380
    static let gutter: CGFloat = 30
    static let columns = 4
    static let cardSpacing: CGFloat = 22
    static let cardHeight: CGFloat = 214
    /// Clear space around anything focusable inside a scroller, which clips:
    /// a focused card's lift and shadow grow into it.
    static let liftRoom: CGFloat = 18
    static let monitorRadius: CGFloat = LineupPanelStyle.radius
}

/// Which game the screen is describing.
///
/// The screen holds this in plain `@State`, which keeps it without watching
/// it, and only the views that describe the game observe it: the monitor, the
/// light behind it and the row counter. An arrow press redraws those three and
/// leaves every card and row where it is.
private final class LiveSpotlight: ObservableObject {
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
private struct LiveScreen: View {
    @Environment(SportsLibrary.self) private var library
    let events: [SportsGame]
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
    @State private var spotlight = LiveSpotlight()
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
        // The navigation stack insets its content by the safe area again,
        // which pushed the stage and the board in from the crawl's edge. The
        // screen keeps its own margins instead. Only the sides: below, the
        // inset is what keeps the board above the crawl.
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

/// The room the monitor stands in: the theme's ground, lifted a little
/// overhead and falling away towards the corners.
private struct LiveCanvas: View {
    var body: some View {
        ZStack {
            LineupStyle.background
            LinearGradient(colors: [LineupStyle.raised.opacity(0.26), .clear],
                           startPoint: .top, endPoint: .center)
            RadialGradient(colors: [.clear, .black.opacity(0.3)], center: .center,
                           startRadius: 520, endRadius: 1250)
        }
        .ignoresSafeArea()
        .allowsHitTesting(false)
    }
}

/// The monitor. A slate while nothing is playing, the feed while one is.
private struct LiveMonitor: View {
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
private enum LiveHint {
    case preview, secondGame, refreshing
}

/// What the monitor shows for a game while nothing is playing.
///
/// Built like a broadcast's pre-game graphic. The two sides face each other
/// across a centre line, their colours lighting their own halves, and between
/// them is the one fact that matters right now: the score while it is on, the
/// start while it is not.
private struct LiveSlate: View {
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
                (Text(parts.time).font(.interDigits(84, .semibold)).foregroundColor(LivePalette.text)
                 + Text(parts.period.map { " " + $0 } ?? "").font(.inter(32, .semibold))
                    .foregroundColor(LivePalette.secondary))
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
private struct LiveSlateBackdrop: View {
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
private struct LiveCourtLines: View {
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
private struct LiveCrestColumn: View {
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
private struct LiveCrest: View {
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
private struct LiveOnAirTag: View {
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
private struct LiveStatusCapsule: View {
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
private struct LiveActionHint: View {
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
private struct LiveEmptySlate: View {
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
private struct LiveVideoWall: View {
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
private struct LiveFlank: View {
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
private struct LiveTallyChip: View {
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
private struct LiveMyTeams: View {
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
private enum LiveMyTeamsControl: Hashable {
    case hide, show
}

/// In My Teams' heading: puts the rail away so the monitor can run the
/// full width of the board, the picture centred.
private struct LiveMyTeamsHideButton: View {
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
private struct LiveMyTeamsTab: View {
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
private struct LiveEyebrow: View {
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
private struct LiveMyTeamsEmpty: View {
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
private struct LiveTeamRow: View {
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
private struct LiveCardSurface: View {
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
private struct LiveTag: View {
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
private struct LiveGameMenu: ViewModifier {
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
private struct LiveMatchupBoard: View {
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
private struct LiveEmptyLane: View {
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
private struct LiveBoardCount: View {
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
private struct LiveRowPager: View {
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
private struct LiveLeagueFilter: View {
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
private struct LiveChipLabel: View {
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

/// The board itself: rows of four, one row tall, scrolled a whole row at a
/// time so the focused card is never cut off at either edge.
private struct LiveMatchupGrid: View {
    let events: [SportsGame]
    let spotlight: LiveSpotlight
    let previewGameID: String?
    let multiviewPrimaryID: Int?
    let onPlay: (SportsGame) -> Void
    let onStartMultiview: (SportsGame) -> Void

    private var rowStarts: [Int] {
        Array(stride(from: 0, to: events.count, by: LiveMetrics.columns))
    }

    var body: some View {
        GeometryReader { shelf in
            let columns = LiveMetrics.columns
            let room = LiveMetrics.liftRoom
            let cardWidth = max(1, (shelf.size.width - room * 2
                                    - LiveMetrics.cardSpacing * CGFloat(columns - 1)) / CGFloat(columns))
            ScrollViewReader { proxy in
                ScrollView(.vertical) {
                    VStack(spacing: 0) {
                        ForEach(rowStarts, id: \.self) { rowStart in
                            HStack(spacing: LiveMetrics.cardSpacing) {
                                ForEach(0..<columns, id: \.self) { column in
                                    let index = rowStart + column
                                    if events.indices.contains(index) {
                                        let game = events[index]
                                        LiveMatchupCard(game: game, isOnScreen: game.id == previewGameID,
                                                        multiviewPrimaryID: multiviewPrimaryID,
                                                        onFocus: {
                                                            spotlight.rest(on: game, row: rowStart / columns)
                                                            proxy.scrollTo(rowStart, anchor: .top)
                                                        },
                                                        onPlay: { onPlay(game) },
                                                        onStartMultiview: { onStartMultiview(game) })
                                            .frame(width: cardWidth, height: LiveMetrics.cardHeight)
                                            .id(game.id)
                                    } else {
                                        Color.clear
                                            .frame(width: cardWidth, height: LiveMetrics.cardHeight)
                                            .accessibilityHidden(true)
                                    }
                                }
                            }
                            .padding(.horizontal, room)
                            .padding(.vertical, room)
                            .frame(height: LiveMetrics.cardHeight + room * 2)
                            .id(rowStart)
                        }
                    }
                }
                .scrollIndicators(.hidden)
                .focusSection()
            }
        }
        .frame(height: LiveMetrics.cardHeight + LiveMetrics.liftRoom * 2)
        // A television's scroll view does not clip, so the next row would show
        // beneath this one. The mask stops just past the row's own lift room:
        // a focused card's shadow fits inside it, the next row's edge does not.
        .mask(alignment: .top) {
            Rectangle()
                .frame(height: LiveMetrics.cardHeight + LiveMetrics.liftRoom * 2 + 14)
                .padding(.horizontal, -60)
        }
        .padding(.horizontal, -LiveMetrics.liftRoom)
    }
}

/// A full-width, remote-focusable matchup list. Each event keeps its existing
/// selection and hold-menu actions; focusing a row still drives the unchanged
/// Live preview stage above it.
private struct LiveMatchupList: View {
    let events: [SportsGame]
    let spotlight: LiveSpotlight
    let previewGameID: String?
    let multiviewPrimaryID: Int?
    let onPlay: (SportsGame) -> Void
    let onStartMultiview: (SportsGame) -> Void

    private let rowHeight: CGFloat = 116
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
private struct LiveMatchupListRow: View {
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

    private var awayColor: Color {
        MobileTeamColor.readable(game.awayColor) ?? LineupStyle.leagueColor(game.league)
    }

    private var homeColor: Color {
        MobileTeamColor.readable(game.homeColor) ?? awayColor
    }

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 17, style: .continuous)
        HStack(spacing: 22) {
            SportsMark(league: game.league, competition: game.competition, size: 48)
                .frame(width: 74)

            VStack(alignment: .leading, spacing: 5) {
                Text(game.competition?.name.uppercased() ?? game.league.shortName.uppercased())
                    .font(.inter(13, .heavy)).tracking(0.6)
                    .foregroundStyle(LivePalette.secondary.opacity(0.82)).lineLimit(1)
                if game.isEvent {
                    Text(game.eventName ?? game.league.shortName)
                        .font(.inter(24, .semibold)).foregroundStyle(LivePalette.text)
                        .lineLimit(1).minimumScaleFactor(0.78)
                    if let session = game.race?.title {
                        Text(session).font(.inter(16, .semibold))
                            .foregroundStyle(LineupStyle.highlight.opacity(0.8)).lineLimit(1)
                    }
                } else {
                    matchupTeam(game.awayTeam, abbreviation: game.awayAbbreviation,
                                logo: game.awayLogo, record: game.awayRecord,
                                score: game.awayScore, dim: liveLeader(game) == .home, isAway: true)
                    matchupTeam(game.homeTeam, abbreviation: game.homeAbbreviation,
                                logo: game.homeLogo, record: game.homeRecord,
                                score: game.homeScore, dim: liveLeader(game) == .away, isAway: false)
                }
                if let place = game.placeLine, !place.isEmpty {
                    Text(place).font(.inter(14, .medium)).foregroundStyle(LivePalette.secondary.opacity(0.78))
                        .lineLimit(1)
                }
                if let detail = game.soccer?.detail {
                    Text(detail).font(.inter(13, .medium)).foregroundStyle(LivePalette.secondary.opacity(0.78))
                        .lineLimit(1)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)

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
                if let network = nonempty(game.broadcast) {
                    Text(network.uppercased()).font(.inter(13, .heavy)).tracking(0.5)
                        .foregroundStyle(LivePalette.secondary.opacity(0.78)).lineLimit(1)
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
            .frame(width: 310, alignment: .leading)
        }
        .padding(.horizontal, 22).padding(.vertical, 10)
        .frame(maxWidth: .infinity).frame(height: rowHeight)
        .background {
            LinearGradient(colors: [awayColor.opacity(0.19), homeColor.opacity(0.19)],
                           startPoint: .leading, endPoint: .trailing)
                .overlay(LivePalette.card.opacity(0.35))
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

    private func matchupTeam(_ name: String, abbreviation: String, logo: String, record: String?,
                             score: String, dim: Bool, isAway: Bool) -> some View {
        HStack(spacing: 10) {
            TeamBadge(url: logo,
                      fallback: abbreviation.isEmpty ? String(name.prefix(3)).uppercased() : abbreviation,
                      size: 31, tight: true)
            Text(name).font(.inter(19, .semibold))
                .foregroundStyle(dim ? LivePalette.secondary : LivePalette.text)
                .lineLimit(1).minimumScaleFactor(0.75)
            if let record = nonempty(record) {
                Text(record).font(.interDigits(13, .medium)).foregroundStyle(LivePalette.secondary.opacity(0.78))
                    .lineLimit(1)
            }
            Spacer(minLength: 8)
            if game.isLive, let sets = game.tennis {
                TennisSetColumns(score: sets, isAway: isAway, size: 22,
                                 primary: LivePalette.text, secondary: LivePalette.secondary)
            } else if !game.isUpcoming, !score.isEmpty {
                Text(score).font(.interDigits(25, .bold))
                    .foregroundStyle(dim ? LivePalette.secondary : LivePalette.text)
                    .contentTransition(.numericText())
            }
        }
    }
}

/// One matchup on the board.
private struct LiveMatchupCard: View {
    @Environment(SportsLibrary.self) private var library
    @FocusState private var focused: Bool
    let game: SportsGame
    let isOnScreen: Bool
    let multiviewPrimaryID: Int?
    let onFocus: () -> Void
    let onPlay: () -> Void
    let onStartMultiview: () -> Void

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 26, style: .continuous)
        let isPrimary = multiviewPrimaryID != nil && multiviewPrimaryID == library.stream(for: game)?.id
        VStack(alignment: .leading, spacing: 0) {
            topLine
            Spacer(minLength: 8)
            if game.isEvent {
                HStack(spacing: 16) {
                    LeagueLogo(league: game.isNFLRedZone ? .nfl : game.league, size: 56)
                    VStack(alignment: .leading, spacing: 6) {
                        Text(game.eventName ?? game.league.shortName)
                            .font(.inter(22, .semibold)).foregroundStyle(LivePalette.text)
                            .lineLimit(2).minimumScaleFactor(0.75)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        if let session = game.race?.title {
                            Text(session).font(.inter(16, .bold)).foregroundStyle(LineupStyle.highlight).lineLimit(1)
                        }
                    }
                }
            } else {
                let lead = liveLeader(game)
                VStack(spacing: 10) {
                    team(game.awayTeam, game.awayAbbreviation, game.awayLogo, game.awayRecord, game.awayScore,
                         dim: lead == .home, isAway: true)
                    team(game.homeTeam, game.homeAbbreviation, game.homeLogo, game.homeRecord, game.homeScore,
                         dim: lead == .away, isAway: false)
                }
                if let detail = game.soccer?.detail {
                    Text(detail).font(.inter(13, .semibold)).foregroundStyle(LivePalette.secondary)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 8)
            footer(isPrimary: isPrimary)
        }
        .padding(.horizontal, 22).padding(.top, 16).padding(.bottom, 14)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background { LiveCardSurface(shape: shape, isLive: game.isLive) }
        // Only multiview's first game is edged; the rest are plain panels.
        .overlay {
            if isPrimary { shape.strokeBorder(LivePalette.rim, lineWidth: 2) }
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

    private var topLine: some View {
        HStack(spacing: 10) {
            if game.competition != nil || game.league.isRacing {
                SportsMark(league: game.league, competition: game.competition, size: 26)
            } else {
                LeagueLogo(league: game.isNFLRedZone ? .nfl : game.league, size: 26)
            }
            Text(game.competition?.shortName ?? game.league.shortName).font(.inter(15, .heavy)).tracking(0.6)
                .foregroundStyle(LivePalette.secondary)
            Spacer(minLength: 0)
        }
        .frame(height: 26)
    }

    /// The game clock, or the start, in the bottom corner where a scoreboard
    /// keeps it.
    @ViewBuilder private var clock: some View {
        if game.isLive {
            HStack(spacing: 8) {
                PulsingLiveDot(size: 7)
                Text(game.status.isEmpty ? "LIVE" : game.status.uppercased())
                    .font(.inter(15, .bold)).tracking(1.2)
                    .foregroundStyle(LineupStyle.liveStatus)
                    .lineLimit(1).minimumScaleFactor(0.7)
            }
        } else {
            Text(game.startLabel).font(.interDigits(17, .semibold)).tracking(0)
                .foregroundStyle(LivePalette.text).lineLimit(1)
        }
    }

    private func team(_ name: String, _ abbreviation: String, _ logo: String, _ record: String?,
                      _ score: String, dim: Bool, isAway: Bool) -> some View {
        HStack(spacing: 14) {
            TeamBadge(url: logo, fallback: abbreviation.isEmpty ? String(name.prefix(3)).uppercased() : abbreviation,
                      size: 40)
            VStack(alignment: .leading, spacing: 1) {
                Text(name).font(.inter(22, .semibold))
                    .foregroundStyle(dim ? LivePalette.secondary : LivePalette.text)
                    .lineLimit(1).minimumScaleFactor(0.72)
                if let record = nonempty(record) {
                    Text(record).font(.interDigits(16, .medium)).foregroundStyle(LivePalette.secondary)
                }
            }
            Spacer(minLength: 8)
            if game.isLive, let sets = game.tennis {
                TennisSetColumns(score: sets, isAway: isAway, size: 28,
                                 primary: LivePalette.text, secondary: LivePalette.secondary)
            } else if game.isLive, !score.isEmpty {
                Text(score).font(.interDigits(34, .bold))
                    .foregroundStyle(dim ? LivePalette.secondary : LivePalette.text)
                    .contentTransition(.numericText())
            }
        }
    }

    /// What Select will do here, said only while the card has focus. Nothing
    /// for multiview's first game: choosing it again as the second does not
    /// start anything.
    private func actionHint(isPrimary: Bool) -> (symbol: String, title: String)? {
        guard focused else { return nil }
        if multiviewPrimaryID != nil {
            return isPrimary ? nil : ("rectangle.split.2x1.fill", "SIDE BY SIDE")
        }
        return isOnScreen ? ("arrow.up.left.and.arrow.down.right", "FULL SCREEN") : ("play.fill", "PREVIEW")
    }

    /// Where to watch and what Select will do on the left, the clock on the
    /// right. When room runs short the network gives way first; the clock
    /// never does.
    private func footer(isPrimary: Bool) -> some View {
        let hint = actionHint(isPrimary: isPrimary)
        return HStack(spacing: 14) {
            if isPrimary {
                LiveTag(symbol: "rectangle.split.2x1.fill", title: "FIRST GAME")
            } else if isOnScreen {
                // Focused, the tag keeps its colour and gives its words to the
                // hint beside it.
                LiveTag(symbol: "tv.fill", title: "ON SCREEN", compact: hint != nil)
            } else if let network = nonempty(game.broadcast) {
                Text(network.uppercased()).foregroundStyle(LivePalette.secondary).lineLimit(1)
            } else if hint == nil {
                Text("NO LISTED NETWORK").foregroundStyle(LivePalette.secondary).lineLimit(1)
            }
            if let hint {
                HStack(spacing: 7) {
                    Image(systemName: hint.symbol).font(.system(size: 12, weight: .bold, design: .rounded))
                    Text(hint.title).lineLimit(1)
                }
                .layoutPriority(1)
            }
            Spacer(minLength: 8)
            clock.layoutPriority(2)
        }
        .font(.inter(13, .heavy)).tracking(0.6)
        .foregroundStyle(LivePalette.text)
        .frame(height: 24)
    }
}

/// Which side is ahead, for dimming the other.
private enum LiveLead { case away, home, level }

private func liveLeader(_ game: SportsGame) -> LiveLead {
    guard game.isLive, let away = Int(game.awayScore), let home = Int(game.homeScore),
          away != home else { return .level }
    return away > home ? .away : .home
}

/// A team's colour, lifted until it can glow on a dark screen; the theme's own
/// colour stands in for a side the schedule has no colour for.
/// "8:20 PM" as "8:20" and "PM", so the period can be set smaller than the
/// time. A clock with no period, in a 24-hour locale, comes back whole.
private func liveTimeParts(_ date: Date) -> (time: String, period: String?) {
    let text = date.formatted(.dateTime.hour().minute())
    guard let letter = text.firstIndex(where: \.isLetter), letter != text.startIndex else { return (text, nil) }
    let time = text[..<letter].trimmingCharacters(in: .whitespaces)
    let period = text[letter...].trimmingCharacters(in: .whitespaces)
    return time.isEmpty ? (text, nil) : (time, period.isEmpty ? nil : period)
}

private func liveDayLabel(_ date: Date) -> String {
    let calendar = Calendar.current
    if calendar.isDateInToday(date) { return calendar.component(.hour, from: date) >= 17 ? "TONIGHT" : "TODAY" }
    if calendar.isDateInTomorrow(date) { return "TOMORROW" }
    return date.formatted(.dateTime.weekday(.wide)).uppercased()
}

/// What each sport calls its start.
private func liveStartWord(_ league: SportsLeague) -> String {
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
private func liveLeagueName(_ league: SportsLeague) -> String {
    league == .ncaaf ? "College" : league.shortName
}

/// The matchup in a line: "BOS 3 – NYY 5", "BOS @ MIL", or an event's name.
private func liveHeadline(_ game: SportsGame) -> String {
    if game.isEvent { return game.matchupLine }
    if game.isLive && !game.awayScore.isEmpty && !game.homeScore.isEmpty {
        return "\(game.awayAbbreviation) \(game.awayScore)  –  \(game.homeAbbreviation) \(game.homeScore)"
    }
    return "\(game.awayAbbreviation) \(game.sidesSymbol) \(game.homeAbbreviation)"
}

private func liveAccessibilityLabel(_ game: SportsGame) -> String {
    let matchup = game.matchupLine
    guard game.isLive else { return "\(matchup), \(game.start.formatted(date: .abbreviated, time: .shortened))" }
    let score = game.awayScore.isEmpty || game.homeScore.isEmpty ? "" : ", \(game.awayScore) to \(game.homeScore)"
    return "\(matchup)\(score), \(game.status.isEmpty ? "live" : game.status)"
}

private struct LiveSelectedPreview: View {
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
private struct PulsingLiveDot: View {
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

private struct LiveTicker: View {
    /// The strip keeps its height; its words fill more of it, to be read
    /// from the couch.
    static let height: CGFloat = 38

    let events: [SportsGame]
    @State private var displayedEvents: [SportsGame] = []
    /// Points a second: with each score's column wider for its larger
    /// words, a score stays in view as long as it did before.
    private let speed: Double = 67
    private let cardWidth: CGFloat = 766
    /// As tall as the strip has room for with the scores beside it; a wide
    /// mark has more room across.
    private let logoSize: CGFloat = 34
    private let logoWidth: CGFloat = 58
    private let cardSpacing: CGFloat = 38
    private let loopSpacing: CGFloat = 72
    private let emptyWidth: CGFloat = 520

    private func cycleWidth(for count: Int) -> CGFloat {
        count == 0 ? emptyWidth + loopSpacing : CGFloat(count) * (cardWidth + cardSpacing) - cardSpacing + loopSpacing
    }

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
            GeometryReader { viewport in
                let cycle = cycleWidth(for: displayedEvents.count)
                let copies = max(2, Int(ceil(viewport.size.width / cycle)) + 1)
                HStack(spacing: loopSpacing) {
                    ForEach(0..<copies, id: \.self) { _ in tickerContent }
                }
                .fixedSize(horizontal: true, vertical: false)
                // The strip is built once and slid by the animation system.
                // A clock used to rebuild every score in it sixty times a
                // second for as long as a game was on, and the main thread
                // was still busy with that when the viewer changed tabs. A
                // new score changes the strip in place; only a game joining
                // or leaving it starts the crawl again.
                .keyframeAnimator(initialValue: 0.0, repeating: true) { strip, distance in
                    strip.offset(x: -CGFloat(distance))
                } keyframes: { _ in
                    LinearKeyframe(Double(cycle), duration: Double(cycle) / speed)
                }
                .id(cycle)
                .frame(width: viewport.size.width, height: viewport.size.height, alignment: .bottomLeading)
                .clipped()
                // Scores fade in and out at the ends rather than being cut
                // off by the edge of the strip.
                .mask {
                    LinearGradient(stops: [
                        .init(color: .clear, location: 0), .init(color: .black, location: 0.06),
                        .init(color: .black, location: 0.94), .init(color: .clear, location: 1)
                    ], startPoint: .leading, endPoint: .trailing)
                }
            }
        }
        .padding(.horizontal, LiveMetrics.margin).padding(.bottom, 2)
        .background(LineupStyle.surface.ignoresSafeArea(edges: .bottom))
        .overlay(alignment: .top) { Rectangle().fill(LineupStyle.line).frame(height: 1) }
        .transaction { $0.animation = nil }
        .allowsHitTesting(false)
        .onAppear { updateScores(events) }
        .onChange(of: events) { _, updated in updateScores(updated) }
    }

    private func updateScores(_ updated: [SportsGame]) {
        guard updated != displayedEvents else { return }
        // Score and status changes update in place without restarting the crawl.
        displayedEvents = updated
    }

    private var tickerContent: some View {
        HStack(spacing: cardSpacing) {
            if displayedEvents.isEmpty {
                Text("NO LIVE OR FINAL SCORES YET")
                    .font(.inter(21, .heavy)).tracking(0.7)
                    .foregroundStyle(LineupStyle.secondary).lineLimit(1)
                    .frame(width: emptyWidth, alignment: .leading)
            } else {
                // Every column keeps its fixed width: the scroll arithmetic
                // above counts in whole items of `cardWidth`.
                ForEach(displayedEvents) { game in
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
                }
            }
        }
    }
}

private func sportsTeamColor(_ value: String?) -> Color? {
    guard var value = nonempty(value) else { return nil }
    value = value.replacingOccurrences(of: "#", with: "")
    guard value.count == 6, let hex = UInt64(value, radix: 16) else { return nil }
    return Color(red: Double((hex >> 16) & 0xff) / 255, green: Double((hex >> 8) & 0xff) / 255, blue: Double(hex & 0xff) / 255)
}

private func sportsReadableTeamColor(_ value: String?) -> Color? {
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

private func nonempty(_ value: String?) -> String? {
    guard let value, !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
    return value
}

private func sportsSymbol(_ league: SportsLeague) -> String {
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

private struct LeagueLogo: View {
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

private struct LiveFilterButton: View {
    @FocusState private var isFocused: Bool
    let title: String
    let selected: Bool
    let action: () -> Void
    var body: some View {
        Text(title).foregroundColor(LineupStyle.lightPurple).font(.inter(.callout, .semibold)).padding(.horizontal, 20).frame(height: 42)
            .foregroundStyle(selected || isFocused ? LineupStyle.text : LineupStyle.secondary)
            .background(selected ? LineupStyle.lightPurple.opacity(0.10) : Color.clear)
            .clipShape(Capsule()).nullGlass(cornerRadius: 22)
            .overlay(alignment: .bottom) { if selected { Capsule().fill(LineupStyle.field).frame(width: 28, height: 3).offset(y: -4) } }
            .contentShape(Capsule()).focusable().focused($isFocused).focusEffectDisabled().tvSelectAction(action)
            .focusLift(isFocused, scale: LineupStyle.controlLift)
    }
}

private struct ScheduleSection: View {
    let title: String
    let events: [SportsGame]
    let multiviewPrimaryID: Int?
    let onPlay: (SportsGame) -> Void
    let onStartMultiview: (SportsGame) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                if title == "Live now" { Circle().fill(LineupStyle.text).frame(width: 9, height: 9) }
                Text(title.uppercased()).foregroundColor(LineupStyle.lightPurple).font(.inter(.caption, .heavy)).tracking(0.6)
                    .foregroundStyle(title == "Live now" ? LineupStyle.text : LineupStyle.secondary)
                Text("(\(events.count))").foregroundColor(LineupStyle.lightPurple).font(.inter(.caption)).foregroundStyle(LineupStyle.secondary)
                Rectangle().fill(LineupStyle.line).frame(height: 1)
            }
            LazyVGrid(columns: [GridItem(.flexible(), spacing: 18), GridItem(.flexible(), spacing: 18)], spacing: 18) {
                ForEach(events) { event in
                    GameEventCard(
                        event: event,
                        multiviewPrimaryID: multiviewPrimaryID,
                        onPlay: { onPlay(event) },
                        onStartMultiview: { onStartMultiview(event) }
                    )
                }
            }
        }
    }
}

private struct ScreenHeading: View {
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

private struct EmptySchedule: View {
    let isLoading: Bool
    let isAvailable: Bool
    let errorMessage: String?
    var body: some View {
        HStack(spacing: 16) {
            if isLoading { ProgressView() } else { Image(systemName: isAvailable ? "calendar" : "wifi.exclamationmark") }
            Text(isLoading ? "Checking official schedules…" : (isAvailable ? "No games scheduled today or tomorrow" : (errorMessage ?? "Schedule unavailable — try Refresh"))).foregroundColor(LineupStyle.lightPurple)
        }
        .font(.inter(.title3)).foregroundStyle(LineupStyle.secondary)
        .padding(.vertical, 46)
    }
}

private struct GameEventCard: View {
    @Environment(SportsLibrary.self) private var library
    @EnvironmentObject private var reminders: GameReminders
    @Environment(\.liveChooseChannel) private var chooseChannel
    @FocusState private var isFocused: Bool
    let event: SportsGame
    let multiviewPrimaryID: Int?
    let onPlay: () -> Void
    let onStartMultiview: () -> Void
    private var stream: XtreamStream? { library.stream(for: event) }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 18) {
                MatchupArtwork(event: event)
                VStack(alignment: .leading, spacing: 8) {
                    if event.isEvent {
                        Text(event.matchupLine)
                            .font(.inter(20, .semibold)).foregroundStyle(LineupStyle.text)
                            .lineLimit(2).minimumScaleFactor(0.75)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    } else {
                        GameTeamLine(logo: event.awayLogo, name: event.awayTeam, score: event.isLive ? event.awayScore : nil)
                        Text("@").foregroundColor(LineupStyle.lightPurple).font(.inter(.caption, .bold)).foregroundStyle(LineupStyle.secondary).padding(.leading, 20)
                        GameTeamLine(logo: event.homeLogo, name: event.homeTeam, score: event.isLive ? event.homeScore : nil)
                    }
                    if let place = event.placeLine {
                        Text(place).font(.inter(.caption))
                            .foregroundStyle(LineupStyle.secondary)
                            .lineLimit(1).truncationMode(.tail)
                    }
                    HStack(spacing: 12) {
                        Text(event.league.shortName).foregroundColor(LineupStyle.lightPurple)
                            .font(.inter(.caption, .bold)).padding(.horizontal, 10).frame(height: 28)
                            .background(LineupStyle.selected).clipShape(Capsule())
                        Text(event.start.formatted(date: .abbreviated, time: .shortened)).foregroundColor(LineupStyle.lightPurple)
                            .font(.interDigits(.caption)).foregroundStyle(LineupStyle.secondary).lineLimit(1)
                        Spacer(minLength: 118)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.horizontal, 18).padding(.vertical, 16)
            .overlay(alignment: .bottomTrailing) {
                GameStatusBadge(event: event)
                    .padding(.trailing, 18).padding(.bottom, 16)
            }
                Rectangle().fill(LineupStyle.line).frame(height: 1)
                HStack(spacing: 12) {
                    Image(systemName: stream == nil ? "tv.slash" : "checkmark.circle.fill")
                        .foregroundStyle(stream == nil ? LineupStyle.warning : LineupStyle.positive)
                    Text(stream?.name ?? (event.broadcast.isEmpty ? "No matching channel" : event.broadcast)).foregroundColor(LineupStyle.lightPurple)
                        .font(.inter(.callout, .medium)).foregroundStyle(LineupStyle.lightPurple).lineLimit(1)
                    Spacer()
                    if isFocused, stream != nil {
                        Label("Watch", systemImage: "play.fill")
                            .font(.inter(.caption, .bold)).foregroundStyle(LineupStyle.text)
                            .transition(.opacity.combined(with: .move(edge: .trailing)))
                    }
                    if stream == nil {
                        Label("No channel", systemImage: "display").font(.inter(.caption, .semibold)).foregroundStyle(LineupStyle.secondary)
                    }
                }
                .padding(.horizontal, 18).frame(height: 46)
                .nullGlass(clear: event.isLive, cornerRadius: 0)
        }
        .background(isFocused ? LineupStyle.focused : (event.isLive ? LineupStyle.selected : LineupStyle.surface))
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).inset(by: 1).stroke(event.isLive ? LineupStyle.text.opacity(0.28) : LineupStyle.line, lineWidth: 1))
        .overlay {
            if multiviewPrimaryID == stream?.id {
                RoundedRectangle(cornerRadius: 14, style: .continuous).inset(by: 2).stroke(LineupStyle.liveSelectionBorder.opacity(0.8), lineWidth: 3)
            }
        }
        .contentShape(Rectangle()).focusable().focused($isFocused).focusEffectDisabled().tvSelectAction(onPlay)
        .tvHoldMenu(event.matchupLine, symbol: "sportscourt") {
            var items: [TVChoice] = []
            if event.isUpcoming {
                let on = reminders.reminds(event)
                items.append(TVChoice(on ? "Remove Reminder" : "Remind Me", symbol: on ? "bell.slash" : "bell") {
                    reminders.toggleGame(event)
                })
            }
            if let chooseChannel {
                items.append(TVChoice("Choose Another Channel", symbol: "list.bullet.rectangle") { chooseChannel(event) })
            }
            // Following is offered wherever a game is, not only in the rail.
            // The rail is empty until somebody is followed, so a follow action
            // that lived only there could never be reached from a fresh install.
            for team in library.followableSides(of: event) {
                let following = library.isFollowing(team.key)
                items.append(TVChoice(following ? "Remove \(team.name) from My Teams" : "Add \(team.name) to My Teams",
                                      symbol: following ? "star.slash" : "star", id: "follow-\(team.id)") {
                    library.toggleFollow(team)
                })
            }
            if stream != nil {
                let first = multiviewPrimaryID == stream?.id
                items.append(TVChoice(first ? "First Multiview Game" : "Start Multiview", symbol: "rectangle.split.2x1",
                                      isEnabled: !first) { onStartMultiview() })
            }
            return items
        }
        .focusLift(isFocused)
        .animation(.easeOut(duration: 0.18), value: isFocused)
    }
}

private struct GameStatusBadge: View {
    let event: SportsGame

    private var title: String {
        if event.isLive { return "LIVE" }
        return Calendar.current.isDateInToday(event.start) ? "TODAY" : "TOMORROW"
    }

    var body: some View {
        HStack(spacing: 7) {
            if event.isLive { PulsingLiveDot(size: 7) }
            Text(title).font(.inter(.caption, .bold)).tracking(1.1)
        }
        .foregroundStyle(event.isLive ? LineupStyle.liveStatus : LineupStyle.text)
        .padding(.horizontal, 13).frame(height: 34)
        .background(event.isLive ? LineupStyle.liveDot.opacity(0.12) : LineupStyle.lightPurple.opacity(0.06))
        .clipShape(Capsule())
        .nullGlass(clear: event.isLive, cornerRadius: 17)
    }
}

private struct MatchupArtwork: View {
    let event: SportsGame
    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 10, style: .continuous).fill(LineupStyle.raised)
            // An event is one card, not two sides. Two crests either side of a
            // "VS" is a promise the fixture does not make, so it gets the
            // league's own mark instead.
            if event.isEvent {
                LeagueLogo(league: event.league, size: 76)
            } else {
                HStack(spacing: 16) {
                    TeamBadge(url: event.awayLogo, fallback: event.awayAbbreviation, size: 58)
                    Text("VS").foregroundColor(LineupStyle.lightPurple).font(.inter(.caption2, .bold)).foregroundStyle(LineupStyle.secondary)
                        .frame(width: 32, height: 32).background(LineupStyle.background).clipShape(Circle())
                    TeamBadge(url: event.homeLogo, fallback: event.homeAbbreviation, size: 58)
                }
            }
        }.frame(width: 190, height: 126)
    }
}

private struct GameTeamLine: View {
    let logo: String
    let name: String
    let score: String?
    var body: some View {
        HStack(spacing: 12) {
            TeamBadge(url: logo, fallback: String(name.prefix(3)).uppercased(), size: 34)
            Text(name).foregroundColor(LineupStyle.lightPurple)
                .font(.inter(18, .semibold))
                .foregroundStyle(LineupStyle.text)
                .lineLimit(1)
                .allowsTightening(true)
                .minimumScaleFactor(0.68)
                .layoutPriority(1)
            Spacer(minLength: 12)
            if let score, !score.isEmpty {
                Text(score).foregroundColor(LineupStyle.lightPurple).font(.interDigits(.title2, .bold)).foregroundStyle(LineupStyle.text)
            }
        }
    }
}

private struct ChannelLogo: View {
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

/// The guide's colours: charcoal, light grey and white, and red for now.
private enum GuidePalette {
    static var background: Color { LineupStyle.background }
    /// The channel column and the sidebar, a step darker than the grid so the
    /// names read as a margin rather than as more programmes.
    static var rail: Color { LineupStyle.sidebarRow }
    static var surface: Color { LineupStyle.surface }
    static var raised: Color { LineupStyle.raised }
    static var line: Color { LineupStyle.line }
    static var text: Color { LineupStyle.text }
    static var secondary: Color { LineupStyle.secondary }
    /// The channel's artwork supplies the row background. Programme cells
    /// reveal that same colour, with only elapsed progress filled over it.
    static var rowText: Color { LineupStyle.text.opacity(0.72) }
    static var channelText: Color { LineupStyle.secondary.opacity(0.82) }
}

private enum TVGuideViewMode: String, CaseIterable {
    case tvGuide
    case list

    static let storageKey = "Lineup.tv.guideViewMode.v1"
    static let defaultMode: Self = .tvGuide

    var title: String {
        switch self {
        case .tvGuide: "TV Guide"
        case .list: "List"
        }
    }

    var symbol: String {
        switch self {
        case .tvGuide: "rectangle.grid.1x2"
        case .list: "list.bullet"
        }
    }

    static func restored(_ rawValue: String?) -> Self {
        rawValue.flatMap(Self.init(rawValue:)) ?? defaultMode
    }
}

struct GuideView: View {
    @Environment(SportsLibrary.self) private var library
    var isActive = true
    @FocusState private var gridFocus: GuideGridFocus?
    @FocusState private var sidebarFocus: String?
    @State private var returnGridFocus: GuideGridFocus?
    @State private var selectedCategoryID: String?
    @State private var favoritesOnly = true
    @AppStorage(TVGuideViewMode.storageKey) private var guideViewModeValue = TVGuideViewMode.defaultMode.rawValue
    @State private var searchActive = false
    @State private var query = ""
    /// What is full screen, with the preview's player when it carries on;
    /// see the Live tab's.
    @State private var fullScreen: TVFullScreenItem?
    @State private var multiviewPrimary: XtreamStream?
    @State private var multiviewSession: MultiviewSession?
    @State private var guideNow = Date()
    @State private var focusedGuideItem: GuideFocusItem?
    /// The channel playing in the preview. Resting on a channel plays it
    /// there without sound; Select turns its sound on, and Select again
    /// takes it full screen.
    @State private var previewPlaybackStream: XtreamStream?
    @State private var pinnedPreviewItem: GuideFocusItem?
    /// Whether the preview's sound is on: only once its channel is chosen.
    @State private var previewAudible = false
    /// Waits for the remote to rest on a channel before playing it, so
    /// passing through rows doesn't open a stream for each.
    @State private var hoverTask: Task<Void, Never>?
    @State private var playbackTransitionID: UUID?
    /// What the preview goes back to playing when full screen closes.
    ///
    /// Going full screen tears the preview's player down first -- two players
    /// on one channel is two connections to the provider for one picture --
    /// so on the way back there is nothing left running to return to. This is
    /// what was pinned when it left, kept so it can be put back.
    @State private var resumeAfterFullscreen: GuideFocusItem?
    /// The channel full screen moved to, if the viewer changed channel
    /// there: the preview picks it up when full screen closes.
    @State private var fullScreenChannel: XtreamStream?
    /// A channel whose past programmes are being chosen from.
    @State private var catchUpChannel: XtreamStream?
    /// The preview's one player, kept for as long as the Guide is. Resting
    /// on a channel opens it there and moving on stops it; nothing is built
    /// or torn down as the remote moves (see `GuidePreviewVideo`).
    @StateObject private var previewPlayer = TVPlaybackController(place: .guide)
    @State private var previewHidden = false
    @State private var sidebarVisible = false
    @State private var reorderingFavorites = false
    /// Where the remote is taking focus, and which rows exist to take it.
    @State private var navigation = GuideNavigation()
    private var filtered: [XtreamStream] {
        library.guideStreams(categoryID: searchActive ? nil : selectedCategoryID, favoritesOnly: searchActive ? false : favoritesOnly, query: query)
    }
    private var selectedTitle: String {
        if favoritesOnly { return "Favorites" }
        return library.categories.first { $0.id == selectedCategoryID }?.categoryName ?? "All channels"
    }
    private var guideViewMode: TVGuideViewMode { TVGuideViewMode.restored(guideViewModeValue) }
    private var previewItem: GuideFocusItem? {
        if let focusedGuideItem, filtered.contains(where: { $0.id == focusedGuideItem.stream.id }) {
            return focusedGuideItem
        }
        for stream in filtered {
            if let program = library.guidePrograms(for: stream).first(where: { $0.start <= guideNow && guideNow < $0.end }) {
                return GuideFocusItem(stream: stream, program: program)
            }
        }
        return nil
    }
    private var displayedPreviewItem: GuideFocusItem? {
        previewPlaybackStream == nil ? previewItem : pinnedPreviewItem
    }

    private var controlBar: GuideControlBar {
        GuideControlBar(
            title: selectedTitle,
            channelCount: filtered.count,
            searchActive: $searchActive,
            query: $query,
            multiviewTitle: multiviewPrimary?.name,
            now: guideNow,
            guideViewModeValue: $guideViewModeValue,
            selectedCategoryID: $selectedCategoryID,
            favoritesOnly: $favoritesOnly,
            onCancelMultiview: { multiviewPrimary = nil }
        )
    }

    var body: some View {
        GeometryReader { container in
            let layout = GuideLayout(width: container.size.width - 2 * GuideLayout.margin)
            NavigationStack {
                VStack(alignment: .leading, spacing: 18) {
                    if !previewHidden, let previewItem = displayedPreviewItem {
                        GuidePreviewPanel(
                            player: previewPlayer,
                            controls: controlBar,
                            item: previewItem,
                            categoryName: library.categories.first(where: { $0.id == previewItem.stream.categoryID })?.categoryName ?? "Live TV",
                            quality: guideQuality(previewItem.stream),
                            previewURLs: previewPlaybackStream?.id == previewItem.stream.id ? library.playbackURLs(for: previewItem.stream) : nil,
                            audible: previewAudible,
                            now: guideNow
                        )
                        .frame(height: GuidePreviewPanel.height)
                        // The video reaches the screen's left edge; the info
                        // pane keeps the Guide's readable inset on the right.
                        .padding(.leading, -GuideLayout.margin)
                        .padding(.trailing, GuideLayout.inset)
                        .transition(.opacity.combined(with: .move(edge: .top)))
                    } else {
                        controlBar.padding(.horizontal, GuideLayout.inset)
                    }

                    ZStack(alignment: .topLeading) {
                        VStack(alignment: .leading, spacing: 0) {
                            if guideViewMode == .tvGuide {
                                GuideTimelineHeader(now: guideNow)
                            } else {
                                GuideListHeader(now: guideNow, channelWidth: layout.listChannelWidth)
                            }
                            if filtered.isEmpty {
                                Label(favoritesOnly ? "Your favorite channels will appear here." : "No channels in this category.",
                                      systemImage: favoritesOnly ? "star" : "rectangle.stack")
                                    .font(.inter(22, .medium)).foregroundStyle(GuidePalette.secondary)
                                    .padding(.top, 28).padding(.leading, 14)
                                    .focusable()
                                    .focused($gridFocus, equals: GuideGridFocus(streamID: -1, programStart: nil))
                                    .modifier(GuideLeftBoundary(enabled: !sidebarVisible && !searchActive, onOpen: openSidebar))
                            } else {
                                ScrollViewReader { proxy in
                                ScrollView {
                                    LazyVStack(alignment: .leading, spacing: 0) {
                                        ForEach(filtered) { stream in
                                            let programs = visibleGuidePrograms(for: stream)
                                            let currentProgram = programs.first { $0.start <= guideNow && guideNow < $0.end }
                                            Group {
                                                if guideViewMode == .tvGuide {
                                                    GuideChannelRow(
                                                        stream: stream,
                                                        favoritesMode: favoritesOnly && !searchActive,
                                                        now: guideNow,
                                                        gridFocus: $gridFocus,
                                                        multiviewPrimaryID: multiviewPrimary?.id,
                                                        onPlay: { select(stream) },
                                                        onStartMultiview: { multiviewPrimary = stream },
                                                        onReorderFavorites: { reorderingFavorites = true },
                                                        onStartOver: { watchRecording(of: stream, programme: nil) },
                                                        onCatchUp: { catchUpChannel = stream },
                                                        onMoveFocus: { direction, focus in
                                                            moveGuideFocus(direction, from: focus, proxy: proxy)
                                                        },
                                                        onFocusProgram: { program in
                                                            focusedGuideItem = GuideFocusItem(stream: stream, program: program)
                                                            previewHidden = false
                                                        }
                                                    )
                                                } else {
                                                    GuideChannelListRow(
                                                        stream: stream,
                                                        program: currentProgram,
                                                        now: guideNow,
                                                        quality: guideQuality(stream),
                                                        favoritesMode: favoritesOnly && !searchActive,
                                                        gridFocus: $gridFocus,
                                                        multiviewPrimaryID: multiviewPrimary?.id,
                                                        onPlay: { select(stream) },
                                                        onStartMultiview: { multiviewPrimary = stream },
                                                        onReorderFavorites: { reorderingFavorites = true },
                                                        onStartOver: { watchRecording(of: stream, programme: nil) },
                                                        onCatchUp: { catchUpChannel = stream },
                                                        onMoveFocus: { direction, focus in
                                                            moveGuideListFocus(direction, from: focus, proxy: proxy)
                                                        },
                                                        onFocus: {
                                                            focusedGuideItem = currentProgram.map { GuideFocusItem(stream: stream, program: $0) }
                                                            previewHidden = false
                                                        }
                                                    )
                                                }
                                            }
                                            .id(stream.id)
                                            .onAppear { rowBuilt(stream.id) }
                                            .onDisappear { navigation.builtRows.remove(stream.id) }
                                        }
                                    }.padding(.top, 2)
                                }
                                .onChange(of: sidebarVisible) { _, visible in
                                    guard !visible, let target = gridFocus else { return }
                                    proxy.scrollTo(target.streamID, anchor: .center)
                                    Task { @MainActor in
                                        await Task.yield()
                                        guard !sidebarVisible else { return }
                                        gridFocus = target
                                    }
                                }
                                }
                            }
                        }
                        .disabled(sidebarVisible && !searchActive)
                        .overlay(alignment: .topLeading) {
                            if guideViewMode == .tvGuide {
                                GuideEPGLeadingFade(
                                    startX: GuideLayout.inset + layout.channelWidth,
                                    width: min(248, max(168, layout.slotWidth * 0.92))
                                )
                            }
                        }

                        if sidebarVisible && !searchActive {
                            GuideSidebar(
                                selectedCategoryID: $selectedCategoryID,
                                favoritesOnly: $favoritesOnly,
                                focus: $sidebarFocus,
                                onCollapse: closeSidebar
                            )
                            .frame(width: layout.channelWidth)
                            .frame(maxHeight: .infinity)
                            .background(GuidePalette.rail)
                            .overlay(alignment: .trailing) {
                                Rectangle().fill(GuidePalette.line).frame(width: 1)
                            }
                            .lineupShadow(.overlayFromEdge)
                            .transition(.move(edge: .leading).combined(with: .opacity))
                            .focusSection()
                        }
                    }
                    // The grid sits straight on the ground, clipped square so
                    // rows leave cleanly under the time bar rather than
                    // drawing past it.
                    .clipShape(Rectangle())
                }
                .padding(.horizontal, GuideLayout.margin).padding(.top, 8)
                // Only the preview coming and going is animated. Focus moving
                // through the grid never is.
                .animation(.easeOut(duration: 0.18), value: previewHidden)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .ignoresSafeArea(.container, edges: .bottom)
                .background(GuidePalette.background.ignoresSafeArea())
                .lineupFullScreenCover(item: $fullScreen, onDismiss: resumePreview) { item in
                    PlayerView(
                        urls: library.playbackURLs(for: item.stream),
                        title: item.stream.name,
                        program: library.guidePrograms(for: item.stream).normalizedEPG().first { $0.isLive },
                        channelID: item.stream.id,
                        channel: item.stream,
                        // Up and Down go through the Guide's own list, as
                        // it stands: the category or favourites on screen.
                        lineup: filtered,
                        recording: item.recording,
                        startsOver: item.startsOver,
                        onChannelChange: { fullScreenChannel = $0 },
                        continuing: item.preview
                    )
                }
                .lineupFullScreenCover(item: $catchUpChannel) { stream in
                    TVCatchUpScreen(stream: stream) { programme in
                        catchUpChannel = nil
                        watchRecording(of: stream, programme: programme)
                    }
                }
                .lineupFullScreenCover(item: $multiviewSession) { session in
                    MultiviewView(
                        primary: session.primary,
                        secondary: session.secondary,
                        primaryURLs: library.playbackURLs(for: session.primary),
                        secondaryURLs: library.playbackURLs(for: session.secondary),
                        primaryGame: session.primaryGame,
                        secondaryGame: session.secondaryGame
                    )
                }
                .lineupFullScreenCover(isPresented: $reorderingFavorites) {
                    TVFavoritesOrderView()
                }
                .task(id: isActive) {
                    guard isActive else { return }
                    while !Task.isCancelled {
                        guideNow = Date()
                        do { try await Task.sleep(for: .seconds(5)) }
                        catch { return }
                    }
                }
                .onChange(of: gridFocus?.streamID) { _, streamID in rest(on: streamID) }
                .onChange(of: guideViewModeValue) { _, value in restoreGuideFocus(for: value) }
                .onChange(of: selectedCategoryID) { _, _ in restoreFilteredGuideFocus() }
                .onChange(of: favoritesOnly) { _, _ in restoreFilteredGuideFocus() }
                .onChange(of: searchActive) { _, _ in restoreFilteredGuideFocus() }
                .onChange(of: query) { _, _ in restoreFilteredGuideFocus() }
                // Away from the Guide nothing plays, and coming back to it
                // plays nothing until the remote rests on a channel.
                .onChange(of: isActive) { _, active in
                    guard !active else { return }
                    hoverTask?.cancel()
                    stopPreview()
                }
                .onExitCommand {
                    if playbackTransitionID != nil {
                        // Menu during the handover: full screen never opens, so
                        // there is nothing to come back from and nothing to
                        // keep. Left set, this would hold a channel that was
                        // never handed anywhere.
                        playbackTransitionID = nil
                        resumeAfterFullscreen = nil
                    } else if previewPlaybackStream != nil {
                        hoverTask?.cancel()
                        stopPreview()
                    } else if !previewHidden {
                        previewHidden = true
                    }
                }
            }
            .environment(\.guideLayout, layout)
            .ignoresSafeArea(.container, edges: [.horizontal, .bottom])
        }
        .ignoresSafeArea(.container, edges: [.horizontal, .bottom])
    }

    private func openSidebar() {
        guard !sidebarVisible, !searchActive else { return }
        returnGridFocus = gridFocus
        gridFocus = nil
        withAnimation(.easeInOut(duration: 0.2)) { sidebarVisible = true }
    }

    private func closeSidebar() {
        sidebarFocus = nil
        withAnimation(.easeInOut(duration: 0.2)) { sidebarVisible = false }
        let channels = filtered
        let stream = returnGridFocus.flatMap { previous in channels.first { $0.id == previous.streamID } } ?? channels.first
        guard let stream else {
            gridFocus = GuideGridFocus(streamID: -1, programStart: nil)
            return
        }
        let anchor = guideTimelineAnchor(guideNow)
        let end = anchor.addingTimeInterval(Double(guideVisibleSlotCount) * 1800)
        let programs = library.guidePrograms(for: stream).filter { $0.end > anchor && $0.start < end }
        if guideViewMode == .list {
            gridFocus = GuideGridFocus(streamID: stream.id, programStart: nil)
        } else {
            let restored = programs.first { $0.start == returnGridFocus?.programStart } ?? programs.first
            gridFocus = GuideGridFocus(streamID: stream.id, programStart: restored?.start)
        }
    }

    private func restoreGuideFocus(for rawValue: String) {
        guard let stream = filtered.first(where: { $0.id == gridFocus?.streamID }) ?? filtered.first else { return }
        guard TVGuideViewMode.restored(rawValue) == .tvGuide else {
            gridFocus = GuideGridFocus(streamID: stream.id, programStart: nil)
            return
        }
        let programs = visibleGuidePrograms(for: stream)
        let current = programs.first { $0.start <= guideNow && guideNow < $0.end } ?? programs.first
        gridFocus = GuideGridFocus(streamID: stream.id, programStart: current?.start)
    }

    private func restoreFilteredGuideFocus() {
        guard !filtered.contains(where: { $0.id == gridFocus?.streamID }), let first = filtered.first else { return }
        if guideViewMode == .list {
            gridFocus = GuideGridFocus(streamID: first.id, programStart: nil)
        } else {
            let programs = visibleGuidePrograms(for: first)
            let program = programs.first { $0.start <= guideNow && guideNow < $0.end } ?? programs.first
            gridFocus = GuideGridFocus(streamID: first.id, programStart: program?.start)
        }
    }

    /// Keep vertical remote movement on what is airing now.
    ///
    /// Program blocks have different widths from channel to channel. Native
    /// geometric focus therefore sometimes treats a future block as the
    /// nearest target when moving up or down. Vertical movement is channel
    /// browsing, so it always lands on the adjacent channel's on-air block.
    /// Horizontal movement remains schedule browsing and walks every visible
    /// listing in the current row.
    ///
    /// A press is taken from where the last one was going, while that one is
    /// still on its way. Presses come faster than focus settles when a
    /// direction is held or swiped, and one taken from the cell that
    /// happened to have focus -- a row or more behind -- sent focus back up
    /// the guide it had just come down. A row not yet built is scrolled in
    /// first and focused once it is there; asked for before, focus had
    /// nowhere to go and fell back to a row on screen.
    private func moveGuideFocus(_ direction: MoveCommandDirection, from cell: GuideGridFocus,
                                proxy: ScrollViewProxy) {
        let source = navigation.headingTo() ?? cell
        guard let row = filtered.firstIndex(where: { $0.id == source.streamID }) else { return }

        switch direction {
        case .up, .down:
            let targetRow = direction == .up ? row - 1 : row + 1
            guard filtered.indices.contains(targetRow) else { return }
            let stream = filtered[targetRow]
            let programs = visibleGuidePrograms(for: stream)
            let onAir = programs.first { $0.start <= guideNow && guideNow < $0.end }
            send(GuideGridFocus(streamID: stream.id, programStart: (onAir ?? programs.first)?.start), proxy: proxy)

        case .left, .right:
            let stream = filtered[row]
            let programs = visibleGuidePrograms(for: stream)
            guard !programs.isEmpty else {
                if direction == .left { openSidebar() }
                return
            }
            let current = source.programStart.flatMap { start in
                programs.firstIndex(where: { $0.start == start })
            } ?? 0
            let target = direction == .left ? current - 1 : current + 1
            guard programs.indices.contains(target) else {
                if direction == .left { openSidebar() }
                return
            }
            send(GuideGridFocus(streamID: stream.id, programStart: programs[target].start), proxy: proxy)

        default:
            return
        }
    }

    /// In List mode the remote moves between channels only. Horizontal
    /// movement opens the existing category/favorites sidebar, just as it
    /// does at the left edge of the TV Guide grid.
    private func moveGuideListFocus(_ direction: MoveCommandDirection, from cell: GuideGridFocus,
                                    proxy: ScrollViewProxy) {
        let source = navigation.headingTo() ?? cell
        guard let row = filtered.firstIndex(where: { $0.id == source.streamID }) else { return }
        switch direction {
        case .left:
            openSidebar()
        case .up, .down:
            let targetRow = direction == .up ? row - 1 : row + 1
            guard filtered.indices.contains(targetRow) else { return }
            send(GuideGridFocus(streamID: filtered[targetRow].id, programStart: nil), proxy: proxy)
        default:
            break
        }
    }

    private func send(_ target: GuideGridFocus, proxy: ScrollViewProxy) {
        navigation.heading(to: target)
        if navigation.builtRows.contains(target.streamID) {
            gridFocus = target
        } else {
            // Focused as it is built; see `rowBuilt`.
            proxy.scrollTo(target.streamID)
        }
    }

    /// A row has been built. If focus was on its way to it, it goes there now.
    private func rowBuilt(_ streamID: Int) {
        navigation.builtRows.insert(streamID)
        guard let target = navigation.headingTo(), target.streamID == streamID,
              !sidebarVisible, gridFocus != target else { return }
        gridFocus = target
    }

    private func visibleGuidePrograms(for stream: XtreamStream) -> [CurrentProgram] {
        let start = guideTimelineAnchor(guideNow)
        let end = start.addingTimeInterval(Double(guideVisibleSlotCount) * 1800)
        return library.guidePrograms(for: stream)
            .filter { $0.end > start && $0.start < end }
            .sorted { $0.start < $1.start }
    }

    /// Put the preview back on the channel that was just full screen.
    ///
    /// It keeps playing there until a different channel is chosen, which is
    /// the branch below that pins a new one. Choosing the same channel again
    /// goes back to full screen, as it did before.
    ///
    /// Only for a preview that could not be lent to full screen. One that
    /// was carries on playing behind it and needs nothing put back.
    private func resumePreview() {
        previewHidden = false
        // Moved to another channel in full screen: that channel carries on
        // here, with its sound, as the one being watched.
        if let changed = fullScreenChannel {
            fullScreenChannel = nil
            resumeAfterFullscreen = nil
            hoverTask?.cancel()
            startPreview(changed, audible: true)
            return
        }
        guard let resume = resumeAfterFullscreen else { return }
        resumeAfterFullscreen = nil
        pinnedPreviewItem = resume
        // It was being watched full screen, so it comes back with its sound.
        previewAudible = true
        previewPlaybackStream = resume.stream
    }

    /// The remote resting on a channel: once it has stayed a moment, the
    /// channel plays in the preview without sound. Moving to another channel
    /// stops the one playing at once, so the preview never shows a channel
    /// the remote has left.
    private func rest(on streamID: Int?) {
        hoverTask?.cancel()
        guard let streamID, streamID != -1, isActive, multiviewPrimary == nil,
              previewPlaybackStream?.id != streamID else { return }
        if previewPlaybackStream != nil { stopPreview() }
        hoverTask = Task { @MainActor in
            do { try await Task.sleep(for: .milliseconds(600)) } catch { return }
            guard gridFocus?.streamID == streamID, previewPlaybackStream == nil,
                  let stream = filtered.first(where: { $0.id == streamID }) else { return }
            startPreview(stream, audible: false)
        }
    }

    private func startPreview(_ stream: XtreamStream, audible: Bool) {
        let program = focusedGuideItem.flatMap { $0.stream.id == stream.id ? $0.program : nil }
            ?? library.guidePrograms(for: stream).normalizedEPG().first(where: { $0.start <= guideNow && guideNow < $0.end })
            ?? library.guidePrograms(for: stream).normalizedEPG().first
            ?? CurrentProgram(
                channelID: stream.epgChannelID ?? String(stream.id),
                title: stream.name,
                detail: "Live channel preview",
                start: guideNow,
                end: guideNow.addingTimeInterval(3600)
            )
        pinnedPreviewItem = GuideFocusItem(stream: stream, program: program)
        previewAudible = audible
        previewPlaybackStream = stream
        previewHidden = false
    }

    private func stopPreview() {
        previewPlaybackStream = nil
        pinnedPreviewItem = nil
        previewAudible = false
    }

    /// A channel's recording full screen: a programme from the past, or with
    /// none, the programme on now from its start. The preview's stream is
    /// let go first -- two streams of one channel is two connections.
    private func watchRecording(of stream: XtreamStream, programme: CatchUpProgramme?) {
        hoverTask?.cancel()
        stopPreview()
        fullScreenChannel = nil
        playbackTransitionID = nil
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(180))
            fullScreen = TVFullScreenItem(stream: stream, recording: programme, startsOver: programme == nil)
        }
    }

    /// Select on a channel: playing without sound, its sound comes on;
    /// with its sound on, it goes full screen; not playing yet, it starts
    /// with its sound.
    private func select(_ stream: XtreamStream) {
        guard let primary = multiviewPrimary else {
            hoverTask?.cancel()
            if previewPlaybackStream?.id == stream.id, !previewAudible {
                previewAudible = true
            } else if previewPlaybackStream?.id == stream.id, let preview = TVPreviewHandoff.lend(playing: stream.id) {
                // The preview's own player goes full screen, still playing,
                // and the preview stays pinned behind it to come back to.
                playbackTransitionID = nil
                presentWithoutAnimation { fullScreen = TVFullScreenItem(stream: stream, preview: preview) }
            } else if previewPlaybackStream?.id == stream.id {
                let transitionID = UUID()
                playbackTransitionID = transitionID
                // Remember what is being handed to full screen, so closing it
                // comes back to this channel still playing rather than to a
                // dark panel and a channel that has to be chosen again.
                resumeAfterFullscreen = pinnedPreviewItem
                previewPlaybackStream = nil
                pinnedPreviewItem = nil
                previewHidden = true
                Task { @MainActor in
                    try? await Task.sleep(for: .milliseconds(180))
                    guard playbackTransitionID == transitionID else { return }
                    playbackTransitionID = nil
                    fullScreen = TVFullScreenItem(stream: stream)
                }
            } else {
                playbackTransitionID = nil
                startPreview(stream, audible: true)
            }
            return
        }
        guard primary.id != stream.id else { return }
        // The two pictures open their own streams; the preview's would be a
        // third connection for nothing.
        stopPreview()
        multiviewPrimary = nil
        multiviewSession = MultiviewSession(primary: primary, secondary: stream,
                                           primaryGame: nil, secondaryGame: nil)
    }
}

private struct GuideFocusItem: Equatable {
    let stream: XtreamStream
    let program: CurrentProgram
}

private struct GuideControlBar: View {
    let title: String
    let channelCount: Int
    @Binding var searchActive: Bool
    @Binding var query: String
    let multiviewTitle: String?
    let now: Date
    @Binding var guideViewModeValue: String
    @Binding var selectedCategoryID: String?
    @Binding var favoritesOnly: Bool
    let onCancelMultiview: () -> Void

    var body: some View {
        HStack(alignment: .center, spacing: 20) {
            if let multiviewTitle {
                GuideTitleBlock(eyebrow: "MULTIVIEW  ·  CHOOSE A SECOND CHANNEL", title: multiviewTitle)
            } else if searchActive {
                HStack(spacing: 12) {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 20, weight: .semibold, design: .rounded))
                        .foregroundStyle(GuidePalette.secondary)
                    TextField("Search channels", text: $query)
                        .textFieldStyle(.plain).focusEffectDisabled()
                        .font(.inter(22, .medium))
                }
                .padding(.horizontal, 18).frame(maxWidth: 620, minHeight: 52)
                .background(GuidePalette.surface, in: Capsule())
            } else {
                GuideTitleBlock(eyebrow: "TV GUIDE", title: title)
            }
            if !searchActive && multiviewTitle == nil {
                GuideChannelFilterPicker(title: title,
                                         selectedCategoryID: $selectedCategoryID,
                                         favoritesOnly: $favoritesOnly)
            }
            Spacer(minLength: 12)
            Text("\(channelCount) CHANNELS")
                .font(.inter(13, .heavy)).tracking(0.6)
                .foregroundStyle(GuidePalette.secondary)
            Rectangle().fill(GuidePalette.line).frame(width: 1, height: 26)
            Text(now.formatted(date: .omitted, time: .shortened))
                .font(.interDigits(24, .semibold))
                .foregroundStyle(GuidePalette.text)
                .fixedSize()
                .accessibilityLabel("Current time, \(now.formatted(date: .omitted, time: .shortened))")
            GuideHeaderButton(title: searchActive ? "Close" : "Search", symbol: searchActive ? "xmark" : "magnifyingglass") {
                searchActive.toggle()
                if !searchActive { query = "" }
            }
            if !searchActive && multiviewTitle == nil {
                TVGuideViewModePicker(value: $guideViewModeValue)
            }
            if multiviewTitle != nil { GuideHeaderButton(title: "Cancel", symbol: "xmark", action: onCancelMultiview) }
        }
        .foregroundStyle(GuidePalette.text)
        .frame(height: 64)
    }
}

/// Favorites and IPTV categories sit in the Guide's top control row, with the
/// left-edge sidebar kept as an alternate way to browse on the remote.
private struct GuideChannelFilterPicker: View {
    @Environment(SportsLibrary.self) private var library
    let title: String
    @Binding var selectedCategoryID: String?
    @Binding var favoritesOnly: Bool
    @State private var choosing = false

    private var currentTitle: String { favoritesOnly ? "Favorites" : title }

    var body: some View {
        TVSelectable(scale: LineupStyle.controlLift, drawsFocusChrome: false,
                     action: { choosing = true }) {
            HStack(spacing: 9) {
                Image(systemName: favoritesOnly ? "star.fill" : "tv")
                    .font(.system(size: 18, weight: .semibold, design: .rounded))
                    .foregroundStyle(favoritesOnly ? LineupStyle.highlight : GuidePalette.channelText)
                Text(currentTitle).font(.inter(18, .semibold)).lineLimit(1).frame(maxWidth: 250)
                Image(systemName: "chevron.down")
                    .font(.system(size: 12, weight: .heavy, design: .rounded))
                    .foregroundStyle(GuidePalette.channelText)
            }
            .foregroundStyle(GuidePalette.rowText)
            .padding(.horizontal, 16).frame(height: 48)
            .background(GuidePalette.surface, in: Capsule())
            .overlay(Capsule().strokeBorder(GuidePalette.line, lineWidth: 1))
        }
        .tvChoices("TV Guide Channels", symbol: "tv", isPresented: $choosing) {
            [
                TVChoice("All Channels", symbol: "tv", id: "all",
                        isSelected: selectedCategoryID == nil && !favoritesOnly) {
                    selectedCategoryID = nil
                    favoritesOnly = false
                },
                TVChoice("Favorites", symbol: "star", id: "favorites", isSelected: favoritesOnly) {
                    selectedCategoryID = nil
                    favoritesOnly = true
                }
            ] + library.categories.map { category in
                TVChoice(category.categoryName, symbol: "rectangle.grid.1x2", id: "category-\(category.id)",
                         isSelected: selectedCategoryID == category.id && !favoritesOnly) {
                    selectedCategoryID = category.id
                    favoritesOnly = false
                }
            }
        }
        .accessibilityLabel("TV Guide channels: \(currentTitle)")
    }
}

/// Switch between the schedule grid and the channel-first list while keeping
/// the same remote-friendly choice sheet used by the rest of tvOS.
private struct TVGuideViewModePicker: View {
    @Binding var value: String
    @State private var choosing = false

    private var selection: TVGuideViewMode { TVGuideViewMode.restored(value) }

    var body: some View {
        TVSelectable(scale: LineupStyle.controlLift, drawsFocusChrome: false,
                     action: { choosing = true }) {
            HStack(spacing: 9) {
                Image(systemName: selection.symbol)
                    .font(.system(size: 18, weight: .semibold, design: .rounded))
                    .foregroundStyle(LineupStyle.highlight)
                Text(selection.title).font(.inter(17, .semibold)).lineLimit(1)
                Image(systemName: "chevron.down")
                    .font(.system(size: 12, weight: .heavy, design: .rounded))
                    .foregroundStyle(GuidePalette.channelText)
            }
            .foregroundStyle(GuidePalette.rowText)
            .padding(.horizontal, 15).frame(height: 48)
            .background(GuidePalette.surface, in: Capsule())
            .overlay(Capsule().strokeBorder(GuidePalette.line, lineWidth: 1))
        }
        .tvChoices("TV Guide View", symbol: "rectangle.grid.1x2", isPresented: $choosing) {
            TVGuideViewMode.allCases.map { mode in
                TVChoice(mode.title, symbol: mode.symbol, id: mode.rawValue,
                        isSelected: selection == mode) { value = mode.rawValue }
            }
        }
        .accessibilityLabel("View mode: \(selection.title)")
    }
}

/// A screen's name with a quiet line over it.
private struct GuideTitleBlock: View {
    let eyebrow: String
    let title: String

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(eyebrow)
                .font(.inter(15, .heavy)).tracking(LineupPanelStyle.headerTracking)
                .foregroundStyle(LineupPanelStyle.caption).lineLimit(1)
            Text(title)
                .font(.inter(32, .bold))
                .foregroundStyle(GuidePalette.text).lineLimit(1)
        }
    }
}

/// The picture fills the left of the Guide's upper section, with its heading
/// and programme information together on the right.
private struct GuidePreviewPanel: View {
    /// The whole room previously split between the 64pt heading, an 18pt gap,
    /// and the 216pt preview. The channel grid stays at the same height.
    static let height: CGFloat = 298

    let player: TVPlaybackController
    let controls: GuideControlBar
    let item: GuideFocusItem
    let categoryName: String
    let quality: String?
    let previewURLs: [URL]?
    /// Whether the playing channel's sound is on.
    let audible: Bool
    let now: Date

    private var progress: CGFloat {
        let duration = item.program.end.timeIntervalSince(item.program.start)
        guard duration > 0 else { return 0 }
        return CGFloat(min(max(now.timeIntervalSince(item.program.start) / duration, 0), 1))
    }

    /// "23 MIN LEFT", while the programme is on.
    private var remaining: String? {
        guard item.program.isLive else { return nil }
        let minutes = Int((item.program.end.timeIntervalSince(now) / 60).rounded(.up))
        guard minutes > 0 else { return nil }
        return minutes >= 60 ? "\(minutes / 60) HR \(minutes % 60) MIN LEFT" : "\(minutes) MIN LEFT"
    }

    var body: some View {
        let frame = RoundedRectangle(cornerRadius: 22, style: .continuous)
        HStack(alignment: .top, spacing: 20) {
            Group {
                if let previewURLs {
                    GuidePreviewVideo(controller: player, channelID: item.stream.id,
                                      urls: previewURLs, audible: audible)
                } else {
                    GuidePreviewArtwork(stream: item.stream)
                }
            }
            .frame(width: Self.height * 16 / 9, height: Self.height)
            .clipShape(frame)

            VStack(alignment: .leading, spacing: 12) {
                controls
                programInfo
                Spacer(minLength: 0)
                playbackHints.frame(maxWidth: .infinity, alignment: .trailing)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
    }

    private var programInfo: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 12) {
                if item.program.isLive { GuideLiveTag() }
                Text(item.stream.name.uppercased())
                    .font(.inter(14, .heavy)).tracking(0.6)
                    .foregroundStyle(GuidePalette.text).lineLimit(1)
                Text(categoryName.uppercased())
                    .font(.inter(14, .heavy)).tracking(0.6)
                    .foregroundStyle(GuidePalette.secondary).lineLimit(1)
                if let quality { GuideTinyBadge(title: quality) }
                if item.program.isNew == true { GuideTinyBadge(title: "NEW") }
            }
            Text(item.program.title.isEmpty ? "Untitled" : item.program.title)
                .font(.inter(38, .bold))
                .foregroundStyle(GuidePalette.text)
                .lineLimit(1).minimumScaleFactor(0.8)
            HStack(spacing: 16) {
                Text(guideTimeRange(item.program))
                    .font(.interDigits(18, .semibold))
                    .foregroundStyle(GuidePalette.secondary)
                if item.program.isLive {
                    GuideProgressBar(progress: progress).frame(width: 220)
                    if let remaining {
                        Text(remaining)
                            .font(.inter(13, .heavy)).tracking(0.6)
                            .foregroundStyle(GuidePalette.secondary)
                    }
                }
            }
            Text(item.program.detail.isEmpty ? "No description for this program." : item.program.detail)
                .font(.inter(19))
                .foregroundStyle(GuidePalette.secondary)
                .lineLimit(2)
                .frame(maxWidth: 980, alignment: .leading)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// Beside the picture, never over it: what Select does next.
    private var playbackHints: some View {
        VStack(alignment: .trailing, spacing: 6) {
            if previewURLs != nil {
                Label(audible ? "SELECT FOR FULL SCREEN" : "SELECT FOR SOUND",
                      systemImage: audible ? "arrow.up.left.and.arrow.down.right" : "speaker.slash.fill")
                    .foregroundStyle(GuidePalette.text.opacity(0.85))
            }
            Text("MENU HIDES THE PREVIEW")
                .foregroundStyle(GuidePalette.secondary.opacity(0.8))
        }
        .font(.inter(12, .heavy)).tracking(0.6)
        .fixedSize()
        .padding(.bottom, 8)
    }
}

/// The Guide's preview picture: the Guide's one player, on the channel the
/// remote rests on.
///
/// It used to be a player of its own for every channel, built as the remote
/// rested and thrown away as it moved on. Throwing a player away while its
/// stream is still closing is what froze the screen: VLC finishes the close
/// before the player can go, and parts of that wait on the main thread, so a
/// slow stream held the whole Guide still for a second or two. One player
/// that changes channel is never thrown away mid-close.
private struct GuidePreviewVideo: View {
    @ObservedObject var controller: TVPlaybackController
    let channelID: Int
    let urls: [URL]
    /// Silent while the remote only rests on the channel; on once chosen.
    let audible: Bool

    var body: some View {
        TVHostedSurface(controller: controller)
            .overlay(alignment: .bottomLeading) { TVPreviewFormatBadges(controller: controller) }
            .overlay { TVPlaybackStatus(controller: controller) }
            .background(Color.black)
            .onAppear { open() }
            .onChange(of: channelID) { _, _ in open() }
            // Chosen: the same stream carries on, its sound turned on.
            .onChange(of: audible) { _, on in controller.setMuted(!on) }
            .onDisappear {
                // Lent to full screen, it plays on there. Already on another
                // channel's preview, it is that preview's to stop.
                guard !controller.lentToFullScreen, controller.previewChannelID == channelID else { return }
                controller.stop()
            }
    }

    private func open() {
        // Back from full screen, where it played on: nothing to open, but
        // its sound is on, as it was there.
        if controller.isOpen, controller.previewChannelID == channelID {
            // Written only if it differs: VLC on Apple TV restarts its sound
            // for every mute written.
            if controller.isMuted == audible { controller.setMuted(!audible) }
            return
        }
        controller.previewChannelID = channelID
        controller.start(urls: urls, muted: !audible)
        TVPreviewHandoff.previewing(channelID, in: controller)
    }
}

/// The channel's mark on a dark plate, for a channel that is not playing.
private struct GuidePreviewArtwork: View {
    let stream: XtreamStream
    var body: some View {
        ZStack {
            GuidePalette.surface
            LineupArtView(url: stream.streamIcon.flatMap(URL.init(string:)), width: 420) { loaded in
                if let image = loaded {
                    image.resizable().scaledToFit().padding(40)
                } else {
                    VStack(spacing: 12) {
                        Image(systemName: "tv").font(.system(size: 38, weight: .light, design: .rounded))
                        Text(stream.name).font(.inter(18, .semibold))
                            .lineLimit(2).multilineTextAlignment(.center)
                    }
                    .foregroundStyle(GuidePalette.secondary)
                    .padding(24)
                }
            }
            .transaction { $0.animation = nil }
        }
    }
}

/// HD, NEW and the like: a small outlined tag, never a coloured one.
private struct GuideTinyBadge: View {
    let title: String

    var body: some View {
        Text(title)
            .font(.inter(12, .bold)).tracking(1.2)
            .foregroundStyle(GuidePalette.secondary)
            .padding(.horizontal, 7).frame(height: 22)
            .overlay(RoundedRectangle(cornerRadius: 5, style: .continuous)
                .strokeBorder(GuidePalette.secondary.opacity(0.5), lineWidth: 1))
            .fixedSize()
    }
}

private func guideQuality(_ stream: XtreamStream) -> String? {
    let value = stream.name.uppercased()
    if value.contains("4K") || value.contains("UHD") { return "UHD" }
    if value.contains("FHD") || value.contains("1080") { return "FHD" }
    if value.contains("HD") || value.contains("720") { return "HD" }
    return nil
}

private func guideTimeRange(_ program: CurrentProgram) -> String {
    "\(program.start.formatted(date: .omitted, time: .shortened)) — \(program.end.formatted(date: .omitted, time: .shortened))"
}

private struct MultiviewSession: Identifiable {
    let id = UUID()
    let primary: XtreamStream
    let secondary: XtreamStream
    let primaryGame: SportsGame?
    let secondaryGame: SportsGame?
}

private struct GuideSidebar: View {
    @Environment(SportsLibrary.self) private var library
    @Binding var selectedCategoryID: String?
    @Binding var favoritesOnly: Bool
    let focus: FocusState<String?>.Binding
    let onCollapse: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            GuideSidebarHeading(title: "BROWSE")
            GuideSidebarButton(title: "All channels", symbol: "square.grid.2x2", selected: selectedCategoryID == nil && !favoritesOnly, focus: focus, focusID: "all") {
                selectedCategoryID = nil; favoritesOnly = false
            }
            GuideSidebarButton(title: "Favorites", symbol: "star", selected: favoritesOnly, focus: focus, focusID: "favorites") {
                selectedCategoryID = nil; favoritesOnly = true
            }
            GuideSidebarHeading(title: "CATEGORIES").padding(.top, 10)
            ScrollView {
                LazyVStack(spacing: 4) {
                    ForEach(library.categories) { category in
                        GuideSidebarButton(title: category.categoryName, symbol: "rectangle.grid.1x2", selected: selectedCategoryID == category.id && !favoritesOnly, focus: focus, focusID: "category-" + category.id) {
                            selectedCategoryID = category.id; favoritesOnly = false
                        }
                    }
                }
                .padding(.vertical, 4)
            }
        }
        .padding(.horizontal, 12).padding(.top, 6)
        .onMoveCommand { direction in
            if direction == .right { onCollapse() }
        }
        .task {
            // All channels is always mounted; do not target an offscreen lazy category.
            focus.wrappedValue = favoritesOnly ? "favorites" : "all"
        }
    }
}

private struct GuideSidebarHeading: View {
    let title: String

    var body: some View {
        Text(title.uppercased())
            .font(.inter(16, .heavy)).tracking(LineupPanelStyle.headerTracking)
            .foregroundStyle(LineupPanelStyle.caption)
            .lineLimit(1)
            .padding(.leading, 16)
            .frame(height: 40, alignment: .bottomLeading)
            .padding(.bottom, 4)
    }
}

/// A sidebar row. The chosen one is white with a bar at its edge; the one the
/// remote is on wears the focus layer, so the two can never be confused.
private struct GuideSidebarButton: View {
    let title: String
    let symbol: String
    let selected: Bool
    let focus: FocusState<String?>.Binding
    let focusID: String
    private var isFocused: Bool { focus.wrappedValue == focusID }
    let action: () -> Void

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 10, style: .continuous)
        HStack(spacing: 14) {
            LineupIconTile(symbol: symbol, size: 32)
            Text(title)
                .font(.inter(21, selected ? .semibold : .medium))
                .lineLimit(2)
                .multilineTextAlignment(.leading)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .foregroundStyle(selected || isFocused ? GuidePalette.text : GuidePalette.secondary)
        .padding(.horizontal, 14).padding(.vertical, 10)
        .frame(minHeight: 50)
        .background(selected ? GuidePalette.surface : Color.clear, in: shape)
        .overlay(alignment: .leading) {
            if selected {
                Capsule().fill(GuidePalette.text).frame(width: 3, height: 22)
            }
        }
        .lineupFocusLayer(isFocused, in: shape)
        .contentShape(Rectangle()).focusable().focused(focus, equals: focusID).focusEffectDisabled().tvSelectAction(action)
        .animation(.easeOut(duration: 0.16), value: isFocused)
    }
}

private struct GuideHeaderButton: View {
    @FocusState private var isFocused: Bool
    let title: String
    let symbol: String
    var onMoveDown: (() -> Void)? = nil
    let action: () -> Void
    var body: some View {
        let shape = Capsule()
        LineupTileLabel(title: title, symbol: symbol, tileSize: 32)
            .font(.inter(18, .semibold))
            .foregroundStyle(GuidePalette.text)
            .padding(.leading, 8).padding(.trailing, 22).frame(height: 48)
            .background(GuidePalette.surface, in: shape)
            .lineupFocusLayer(isFocused, in: shape)
            .contentShape(shape).focusable().focused($isFocused).focusEffectDisabled().tvSelectAction(action)
            .focusLift(isFocused, scale: LineupStyle.controlLift)
            .onMoveCommand { direction in if direction == .down { onMoveDown?() } }
    }
}

/// The day over the channels, and a tick and a time at every half hour.
private struct GuideTimelineHeader: View {
    @Environment(\.guideLayout) private var layout
    let now: Date

    var body: some View {
        let anchor = guideTimelineAnchor(now)
        HStack(spacing: 0) {
            // Now, at the head of the channel column, as the phone's Guide
            // has it. There is no line down the grid for it: how far each
            // programme on now has run is washed across its own cell.
            VStack(spacing: 2) {
                Text("NOW").font(.inter(12, .heavy)).tracking(0.6)
                    .foregroundStyle(GuidePalette.secondary)
                Text(now.formatted(date: .omitted, time: .shortened))
                    .font(.interDigits(17, .semibold))
                    .foregroundStyle(GuidePalette.text)
            }
            .lineLimit(1)
            .frame(width: layout.channelWidth)
            ForEach(0..<guideVisibleSlotCount, id: \.self) { step in
                HStack(spacing: 10) {
                    Rectangle().fill(GuidePalette.secondary.opacity(0.5)).frame(width: 1, height: 14)
                    Text(anchor.addingTimeInterval(Double(step) * 1800)
                        .formatted(date: .omitted, time: .shortened))
                        .font(.interDigits(16, .semibold))
                        .foregroundStyle(GuidePalette.secondary)
                        .lineLimit(1)
                }
                .frame(width: layout.slotWidth, alignment: .leading)
            }
        }
        .padding(.horizontal, GuideLayout.inset)
        .frame(height: guideHeaderHeight)
        .overlay(alignment: .bottom) {
            Rectangle().fill(GuidePalette.line).frame(height: 1)
        }
    }
}

/// The programme grid and its time ruler share one dark leading-edge fade.
/// Keeping this overlay on the scrolling region blends each row into the
/// guide background without touching the pinned channel-logo rail.
private struct GuideEPGLeadingFade: View {
    let startX: CGFloat
    let width: CGFloat

    var body: some View {
        GeometryReader { bounds in
            LinearGradient(
                stops: [
                    .init(color: GuidePalette.background.opacity(0.96), location: 0),
                    .init(color: GuidePalette.background.opacity(0.82), location: 0.2),
                    .init(color: GuidePalette.background.opacity(0.54), location: 0.48),
                    .init(color: GuidePalette.background.opacity(0.2), location: 0.78),
                    .init(color: .clear, location: 1)
                ],
                startPoint: .leading,
                endPoint: .trailing
            )
            .frame(width: width, height: bounds.size.height)
            .position(x: startX + width / 2, y: bounds.size.height / 2)
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

/// The list has one programme column instead of a time ruler; this keeps the
/// channel and on-now information aligned to the exact same row boundaries.
private struct GuideListHeader: View {
    let now: Date
    let channelWidth: CGFloat

    var body: some View {
        HStack(spacing: 0) {
            Text("CHANNEL")
                .font(.inter(12, .heavy)).tracking(0.8)
                .foregroundStyle(GuidePalette.channelText)
                .frame(width: channelWidth, alignment: .leading)
            HStack(spacing: 8) {
                GuideLiveDot(size: 7)
                Text("NOW")
                    .font(.inter(12, .heavy)).tracking(0.8)
                    .foregroundStyle(GuidePalette.channelText)
                Text(now.formatted(date: .omitted, time: .shortened))
                    .font(.interDigits(16, .semibold))
                    .foregroundStyle(GuidePalette.rowText)
            }
            .padding(.leading, 20)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, GuideLayout.inset)
        .frame(height: guideHeaderHeight)
        .overlay(alignment: .bottom) { Rectangle().fill(GuidePalette.line).frame(height: 1) }
    }
}

/// The time bar's height, which is also where the line for now begins.
private let guideHeaderHeight: CGFloat = 48

private let guideVisibleSlotCount = 6

// Grow the grid cells in both dimensions without scaling typography or artwork.
// Keep the original channel/half-hour widths and row aspect ratio in sync.
private struct GuideLayout {
    /// The grid runs nearly the screen's full width. With each row's own
    /// inset (`inset`) its logos and programmes sit 20 points from the edges.
    /// The grid scales as a whole to fill it, cells and rows in proportion,
    /// so nothing is stretched.
    static let margin: CGFloat = 6
    /// A row's own padding either side, which the standalone header takes
    /// too, so it lines up with the logos.
    static let inset: CGFloat = 14
    let width: CGFloat
    var slotWidth: CGFloat { max(1, width - 2 * Self.inset) / CGFloat(guideVisibleSlotCount + 1) }
    var channelWidth: CGFloat { slotWidth }
    var listChannelWidth: CGFloat { min(350, max(270, width * 0.2)) }
    // A guide is worth having in proportion to how much of it you can see at
    // once, and at 132 this showed four channels on a 1080 screen. Ninety-two
    // is what a row needs for a title and a time under it at this type size
    // and no more, which is six or seven channels -- enough to scan without
    // the rows becoming a list of hairlines.
    var rowHeight: CGFloat { 92 * slotWidth / 245 }
}

private struct GuideLayoutKey: EnvironmentKey {
    static let defaultValue = GuideLayout(width: 1800)
}

private extension EnvironmentValues {
    var guideLayout: GuideLayout {
        get { self[GuideLayoutKey.self] }
        set { self[GuideLayoutKey.self] = newValue }
    }
}

private func guideTimelineAnchor(_ date: Date) -> Date {
    let calendar = Calendar.current
    var components = calendar.dateComponents([.year, .month, .day, .hour, .minute], from: date)
    components.minute = ((components.minute ?? 0) / 30) * 30
    components.second = 0
    let floor = calendar.date(from: components) ?? date
    return calendar.date(byAdding: .minute, value: -30, to: floor) ?? floor
}

private struct GuideGridFocus: Hashable {
    let streamID: Int
    let programStart: Date?
}

/// Where the remote is taking focus in the guide, and which rows exist.
///
/// A class, and so not observed: it changes with every press and every row
/// scrolled past, and redrawing the guide for either would be work for
/// nothing.
private final class GuideNavigation {
    var builtRows: Set<Int> = []
    private var target: GuideGridFocus?
    private var sentAt: TimeInterval = 0

    func heading(to focus: GuideGridFocus) {
        target = focus
        sentAt = ProcessInfo.processInfo.systemUptime
    }

    /// Where the last press sent focus, while it may still be on its way.
    /// After that, the focused cell itself is where a press starts.
    func headingTo() -> GuideGridFocus? {
        guard ProcessInfo.processInfo.systemUptime - sentAt < 0.45 else { return nil }
        return target
    }
}

// Only the first reachable cell receives a directional handler. Other cells
// remain entirely under the native tvOS focus engine's control.
private struct GuideLeftBoundary: ViewModifier {
    let enabled: Bool
    let onOpen: () -> Void

    @ViewBuilder func body(content: Content) -> some View {
        if enabled {
            content.onMoveCommand { direction in
                if direction == .left { onOpen() }
            }
        } else {
            content
        }
    }
}

private struct GuideChannelRow: View {
    @Environment(\.guideLayout) private var layout
    @Environment(SportsLibrary.self) private var library
    let stream: XtreamStream
    let favoritesMode: Bool
    let now: Date
    let gridFocus: FocusState<GuideGridFocus?>.Binding
    let multiviewPrimaryID: Int?
    let onPlay: () -> Void
    let onStartMultiview: () -> Void
    let onReorderFavorites: () -> Void
    /// The programme on now from its start, and the channel's past
    /// programmes: for a channel the provider records.
    let onStartOver: () -> Void
    let onCatchUp: () -> Void
    let onMoveFocus: (MoveCommandDirection, GuideGridFocus) -> Void
    let onFocusProgram: (CurrentProgram) -> Void
    private var programs: [CurrentProgram] { library.guidePrograms(for: stream) }

    private var visiblePrograms: [CurrentProgram] {
        let start = guideTimelineAnchor(now)
        let end = start.addingTimeInterval(Double(guideVisibleSlotCount) * 1800)
        return programs.filter { $0.end > start && $0.start < end }
            .sorted { $0.start < $1.start }
    }

    var body: some View {
        HStack(spacing: 0) {
            // On the guide's own ground, as on the phone: no plate behind it.
            GuideChannelArtwork(stream: stream, isFavorite: library.isFavorite(stream))
            .frame(width: layout.channelWidth - 8, height: layout.rowHeight - 8)
            .padding(.vertical, 4)
            .padding(.trailing, 8)
            .clipped()

            ZStack(alignment: .leading) {
                if visiblePrograms.isEmpty {
                    let focusID = GuideGridFocus(streamID: stream.id, programStart: nil)
                    GuideProgramCell(program: nil, empty: "No guide information", quality: guideQuality(stream), now: now, showsTime: true, onPlay: onPlay, onFocus: {}, gridFocus: gridFocus, focusID: focusID, onMove: { onMoveFocus($0, focusID) })
                        .frame(width: layout.slotWidth - 6, alignment: .leading)
                } else {
                    ForEach(Array(visiblePrograms.enumerated()), id: \.offset) { _, program in
                        let width = guideProgramWidth(program, now: now, layout: layout)
                        let focusID = GuideGridFocus(streamID: stream.id, programStart: program.start)
                        GuideProgramCell(program: program, empty: "", quality: guideQuality(stream), now: now, showsTime: width >= 110, onPlay: onPlay, onFocus: { onFocusProgram(program) }, gridFocus: gridFocus, focusID: focusID, onMove: { onMoveFocus($0, focusID) })
                            .frame(width: width, alignment: .leading)
                            .offset(x: guideProgramX(program, now: now, layout: layout))
                    }
                }
            }
            .frame(width: layout.slotWidth * CGFloat(guideVisibleSlotCount), alignment: .leading)
            .clipped()
        }
        .padding(.horizontal, GuideLayout.inset)
        .frame(width: layout.width, height: layout.rowHeight, alignment: .leading)
        .background {
            LineupChannelArtworkTint(url: stream.streamIcon.flatMap(URL.init(string:)),
                                     width: 150, fallback: GuidePalette.rail)
                .frame(width: layout.width, height: layout.rowHeight)
                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
        // Multiview's first channel keeps a white frame while the second is
        // chosen, so it is never mistaken for where the remote is.
        .overlay {
            if multiviewPrimaryID == stream.id {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(GuidePalette.text, lineWidth: 2)
                    .padding(.horizontal, 8)
            }
        }
        .contentShape(Rectangle())
        .tvHoldMenu(stream.name, symbol: "tv") {
            var items: [TVChoice] = []
            if stream.hasCatchUp {
                items.append(TVChoice("Start Over", symbol: "backward.end") { onStartOver() })
                items.append(TVChoice("Catch Up", symbol: "clock.arrow.circlepath") { onCatchUp() })
            }
            let first = multiviewPrimaryID == stream.id
            items.append(TVChoice(first ? "First Multiview Channel" : "Start Multiview", symbol: "rectangle.split.2x1",
                                  isEnabled: !first) { onStartMultiview() })
            if favoritesMode {
                items.append(TVChoice("Reorder Favorites", symbol: "arrow.up.arrow.down") { onReorderFavorites() })
                items.append(TVChoice("Move Up", symbol: "arrow.up",
                                      isEnabled: library.canMoveFavorite(stream, offset: -1)) {
                    library.moveFavorite(stream, offset: -1)
                })
                items.append(TVChoice("Move Down", symbol: "arrow.down",
                                      isEnabled: library.canMoveFavorite(stream, offset: 1)) {
                    library.moveFavorite(stream, offset: 1)
                })
                items.append(TVChoice("Remove from Favorites", symbol: "star.slash", isDestructive: true) {
                    library.removeFavorite(stream)
                })
            } else if library.isFavorite(stream) {
                items.append(TVChoice("Reorder Favorites", symbol: "arrow.up.arrow.down") { onReorderFavorites() })
                items.append(TVChoice("Remove from Favorites", symbol: "star.slash", isDestructive: true) {
                    library.removeFavorite(stream)
                })
            } else {
                items.append(TVChoice("Add to Favorites", symbol: "star") { library.addFavorite(stream) })
            }
            return items
        }
    }
}

/// A channel-first alternative to the timeline. The logo occupies the tinted
/// rail and current programme details fill the matching dark row to its right.
private struct GuideChannelListRow: View {
    @Environment(\.guideLayout) private var layout
    @Environment(SportsLibrary.self) private var library
    let stream: XtreamStream
    let program: CurrentProgram?
    let now: Date
    let quality: String?
    let favoritesMode: Bool
    let gridFocus: FocusState<GuideGridFocus?>.Binding
    let multiviewPrimaryID: Int?
    let onPlay: () -> Void
    let onStartMultiview: () -> Void
    let onReorderFavorites: () -> Void
    let onStartOver: () -> Void
    let onCatchUp: () -> Void
    let onMoveFocus: (MoveCommandDirection, GuideGridFocus) -> Void
    let onFocus: () -> Void

    private var focusID: GuideGridFocus { GuideGridFocus(streamID: stream.id, programStart: nil) }
    private var isFocused: Bool { gridFocus.wrappedValue == focusID }
    private var logoWidth: CGFloat { layout.listChannelWidth }
    private var rowHeight: CGFloat { min(128, max(106, layout.rowHeight * 0.9)) }

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 16, style: .continuous)
        let programTitle = program.map { $0.title.isEmpty ? "Untitled" : $0.title } ?? "Program guide not available"
        HStack(spacing: 0) {
            ZStack {
                LineupChannelArtworkTint(url: stream.streamIcon.flatMap(URL.init(string:)),
                                         width: 150, fallback: GuidePalette.rail)
                GuideChannelArtwork(stream: stream, isFavorite: library.isFavorite(stream))
            }
            .frame(width: logoWidth, height: rowHeight)
            .clipShape(shape)

            VStack(alignment: .leading, spacing: 9) {
                Text(programTitle)
                    .font(.inter(25, .semibold))
                    .foregroundStyle(program == nil ? GuidePalette.channelText.opacity(0.7) : GuidePalette.rowText)
                    .lineLimit(1).minimumScaleFactor(0.8)
                HStack(spacing: 12) {
                    if let program {
                        if program.start <= now && now < program.end {
                            HStack(spacing: 7) {
                                GuideLiveDot(size: 8)
                                Text("LIVE").foregroundStyle(LineupStyle.liveStatus)
                            }
                        } else {
                            Text(guideTimeRange(program)).foregroundStyle(GuidePalette.channelText)
                        }
                        if program.isNew == true { GuideTinyBadge(title: "NEW") }
                    }
                    if let quality { GuideTinyBadge(title: quality) }
                }
                .font(.inter(14, .heavy)).tracking(0.5)
                .foregroundStyle(GuidePalette.channelText)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
            .padding(.horizontal, 22)
            .background(GuidePalette.background.opacity(0.45))
        }
        .padding(.horizontal, GuideLayout.inset)
        .frame(width: layout.width, height: rowHeight, alignment: .leading)
        .background(GuidePalette.rail, in: shape)
        .clipShape(shape)
        .overlay(shape.strokeBorder(Color.white.opacity(0.045), lineWidth: 1))
        .lineupFocusLayer(isFocused, in: shape)
        .contentShape(shape)
        .focusable().focused(gridFocus, equals: focusID).focusEffectDisabled()
        .tvSelectAction(onPlay)
        .onMoveCommand { onMoveFocus($0, focusID) }
        .onChange(of: isFocused) { _, focused in if focused { onFocus() } }
        .modifier(GuideChannelListMenu(stream: stream, favoritesMode: favoritesMode,
                                       isPrimary: multiviewPrimaryID == stream.id,
                                       onReorderFavorites: onReorderFavorites,
                                       onStartOver: onStartOver, onCatchUp: onCatchUp,
                                       onStartMultiview: onStartMultiview))
        .animation(.easeOut(duration: 0.14), value: isFocused)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(stream.name), \(program?.title ?? "program guide not available")\(library.isFavorite(stream) ? ", favorite" : "")")
    }
}

/// Keep the Guide's long-press actions identical in List and TV Guide modes.
private struct GuideChannelListMenu: ViewModifier {
    @Environment(SportsLibrary.self) private var library
    let stream: XtreamStream
    let favoritesMode: Bool
    let isPrimary: Bool
    let onReorderFavorites: () -> Void
    let onStartOver: () -> Void
    let onCatchUp: () -> Void
    let onStartMultiview: () -> Void

    func body(content: Content) -> some View {
        content.tvHoldMenu(stream.name, symbol: "tv") {
            var items: [TVChoice] = []
            if stream.hasCatchUp {
                items.append(TVChoice("Start Over", symbol: "backward.end", action: onStartOver))
                items.append(TVChoice("Catch Up", symbol: "clock.arrow.circlepath", action: onCatchUp))
            }
            items.append(TVChoice(isPrimary ? "First Multiview Channel" : "Start Multiview",
                                  symbol: "rectangle.split.2x1", isEnabled: !isPrimary,
                                  action: onStartMultiview))
            if favoritesMode {
                items.append(TVChoice("Reorder Favorites", symbol: "arrow.up.arrow.down", action: onReorderFavorites))
                items.append(TVChoice("Move Up", symbol: "arrow.up",
                                      isEnabled: library.canMoveFavorite(stream, offset: -1)) {
                    library.moveFavorite(stream, offset: -1)
                })
                items.append(TVChoice("Move Down", symbol: "arrow.down",
                                      isEnabled: library.canMoveFavorite(stream, offset: 1)) {
                    library.moveFavorite(stream, offset: 1)
                })
                items.append(TVChoice("Remove from Favorites", symbol: "star.slash", isDestructive: true) {
                    library.removeFavorite(stream)
                })
            } else if library.isFavorite(stream) {
                items.append(TVChoice("Reorder Favorites", symbol: "arrow.up.arrow.down", action: onReorderFavorites))
                items.append(TVChoice("Remove from Favorites", symbol: "star.slash", isDestructive: true) {
                    library.removeFavorite(stream)
                })
            } else {
                items.append(TVChoice("Add to Favorites", symbol: "star") { library.addFavorite(stream) })
            }
            return items
        }
    }
}

/// A channel as the guide names it: its logo, its name under it, and a small
/// star in the corner if it is a favourite, as on the phone. Where there is no
/// logo, a quiet television mark holds its place so every name sits on the
/// same line.
private struct GuideChannelArtwork: View {
    let stream: XtreamStream
    let isFavorite: Bool

    var body: some View {
        VStack(spacing: 6) {
            LineupArtView(url: stream.streamIcon.flatMap(URL.init(string:)), width: 120) { loaded in
                if let image = loaded {
                    image.resizable().scaledToFit()
                } else {
                    Image(systemName: "tv")
                        .font(.system(size: 20, weight: .regular, design: .rounded))
                        .foregroundStyle(GuidePalette.secondary)
                }
            }
            .transaction { $0.animation = nil }
            .frame(width: 120, height: 36)
            Text(stream.name)
                .font(.inter(14, .semibold))
                .foregroundStyle(GuidePalette.channelText)
                .lineLimit(1).minimumScaleFactor(0.8)
                .allowsTightening(true)
                .truncationMode(.tail)
        }
        .padding(.horizontal, 22)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .overlay(alignment: .topTrailing) {
            if isFavorite {
                Image(systemName: "star.fill")
                    .font(.system(size: 11, weight: .bold, design: .rounded))
                    .foregroundStyle(GuidePalette.text)
                    .padding(9)
            }
        }
        .accessibilityHidden(true)
    }
}

/// Remote-friendly freeform ordering: select a channel to pick it up, focus any
/// destination, then select again to drop it at that position.
private struct TVFavoritesOrderView: View {
    @Environment(SportsLibrary.self) private var library
    @Environment(\.dismiss) private var dismiss
    @State private var pickedStreamID: Int?
    @FocusState private var focusedStreamID: Int?

    private var favorites: [XtreamStream] {
        library.guideStreams(categoryID: nil, favoritesOnly: true, query: "")
    }

    var body: some View {
        ZStack {
            LineupPresentationStyle.ground.ignoresSafeArea()

            VStack(alignment: .leading, spacing: 28) {
                HStack(alignment: .center, spacing: 32) {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("YOUR CHANNELS")
                            .font(.inter(13, .heavy)).tracking(0.6)
                            .foregroundStyle(LineupPresentationStyle.secondary)
                        Text("Arrange Favorites")
                            .font(.inter(46, .bold))
                        Text(instruction)
                            .font(.inter(.title3))
                            .foregroundStyle(LineupPresentationStyle.secondary)
                            .contentTransition(.opacity)
                    }
                    Spacer()
                    HStack(spacing: 10) {
                        Label("\(favorites.count) FAVORITES", systemImage: "star.fill")
                            .font(.inter(.caption, .bold)).tracking(1.2)
                            .padding(.horizontal, 16).frame(height: 46)
                            .nullGlass(clear: true, cornerRadius: 23)
                        TVReorderDoneButton { dismiss() }
                    }
                }

                Group {
                    if favorites.isEmpty {
                        LineupUnavailableView("No favorites", systemImage: "star",
                            description: Text("Add channels to Favorites from the TV Guide."))
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    } else {
                        ScrollViewReader { proxy in
                            ScrollView {
                                LazyVStack(spacing: 12) {
                                    ForEach(Array(favorites.enumerated()), id: \.element.id) { index, stream in
                                        favoriteRow(stream, position: index + 1)
                                            .id(stream.id)
                                    }
                                }
                                .padding(.horizontal, 28).padding(.vertical, 26)
                            }
                            .scrollClipDisabled()
                            .onChange(of: focusedStreamID) { _, streamID in
                                guard let streamID else { return }
                                withAnimation(.spring(response: 0.32, dampingFraction: 0.86)) {
                                    proxy.scrollTo(streamID, anchor: .center)
                                }
                            }
                        }
                    }
                }
                .background(GuidePalette.rail, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .strokeBorder(GuidePalette.line, lineWidth: 1))
            }
            .padding(.horizontal, 86).padding(.vertical, 58)
        }
        .foregroundStyle(LineupStyle.lightPurple)
        .task {
            if focusedStreamID == nil { focusedStreamID = favorites.first?.id }
        }
        .onExitCommand {
            if pickedStreamID != nil { pickedStreamID = nil }
            else { dismiss() }
        }
    }

    private var instruction: String {
        if let pickedStreamID, let stream = favorites.first(where: { $0.id == pickedStreamID }) {
            return "Moving \(stream.name)  ·  Choose any destination and press Select to place it."
        }
        return "Select a channel, move anywhere in the list, then Select again to place it."
    }

    private func favoriteRow(_ stream: XtreamStream, position: Int) -> some View {
        let isPicked = pickedStreamID == stream.id
        let isFocused = focusedStreamID == stream.id
        return HStack(spacing: 22) {
            ZStack {
                Circle().fill(isPicked ? LineupPresentationStyle.text : LineupPresentationStyle.row)
                Text("\(position)").font(.interDigits(.callout, .bold))
                    .foregroundStyle(isPicked ? GuidePalette.background : LineupPresentationStyle.secondary)
            }
            .frame(width: 44, height: 44)
            ZStack {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(LineupPresentationStyle.row.opacity(0.82))
                LineupArtView(url: stream.streamIcon.flatMap(URL.init(string:)), width: 100) { loaded in
                    if let image = loaded {
                        image.resizable().scaledToFit().padding(10)
                    } else {
                        Image(systemName: "tv").foregroundStyle(LineupPresentationStyle.secondary)
                    }
                }
                .transaction { $0.animation = nil }
            }
            .frame(width: 100, height: 60)
            VStack(alignment: .leading, spacing: 5) {
                Text(stream.name).font(.inter(.title3, .semibold)).lineLimit(1)
                Text(isPicked ? "Ready to move" : "Favorite channel")
                    .font(.inter(.caption)).foregroundStyle(LineupPresentationStyle.secondary)
            }
            Spacer()
            if isPicked {
                Label("PICKED UP", systemImage: "hand.draw.fill")
                    .font(.inter(.caption, .bold)).tracking(1.2)
                    .padding(.horizontal, 14).frame(height: 36)
                    .background(LineupStyle.lightPurple, in: Capsule())
                    .foregroundStyle(GuidePalette.background)
            } else if pickedStreamID != nil && isFocused {
                Label("PLACE HERE", systemImage: "arrow.down.to.line")
                    .font(.inter(.caption, .bold)).tracking(1.2)
                    .padding(.horizontal, 14).frame(height: 36)
                    .background(LineupStyle.lightPurple.opacity(0.12), in: Capsule())
            }
        }
        .padding(.horizontal, 24)
        .frame(height: 88)
        .background(isPicked ? GuidePalette.raised : GuidePalette.surface,
                    in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(
            isPicked ? LineupPresentationStyle.text : LineupStyle.line,
            lineWidth: isPicked ? 2 : 1
        ))
        .lineupFocusLayer(isFocused && !isPicked, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(alignment: .leading) {
            if pickedStreamID != nil && isFocused && !isPicked {
                Capsule().fill(LineupPresentationStyle.text).frame(width: 4, height: 44).offset(x: -2)
            }
        }
        .contentShape(Rectangle())
        .focusable()
        .focused($focusedStreamID, equals: stream.id)
        .focusEffectDisabled()
        .onTapGesture { select(stream) }
        // Smaller than either standard step, and deliberately so: these cells
        // sit shoulder to shoulder in a grid, and a card step here would push
        // one over its neighbours rather than above them.
        .scaleEffect(isPicked ? 1.025 : (isFocused ? 1.012 : 1))
        .offset(y: isPicked ? -3 : 0)
        .lineupShadow(.lifted, on: isPicked || isFocused)
        .zIndex(isPicked ? 2 : (isFocused ? 1 : 0))
        .animation(.spring(response: 0.25, dampingFraction: 0.8), value: isFocused)
        .animation(.spring(response: 0.3, dampingFraction: 0.72), value: isPicked)
    }

    private func select(_ stream: XtreamStream) {
        guard let pickedStreamID else {
            self.pickedStreamID = stream.id
            return
        }
        guard pickedStreamID != stream.id else {
            self.pickedStreamID = nil
            return
        }
        guard let source = favorites.firstIndex(where: { $0.id == pickedStreamID }),
              let destination = favorites.firstIndex(where: { $0.id == stream.id }) else {
            self.pickedStreamID = nil
            return
        }
        library.moveFavorites(favorites, fromOffsets: IndexSet(integer: source),
            toOffset: destination > source ? destination + 1 : destination)
        self.pickedStreamID = nil
        focusedStreamID = pickedStreamID
    }
}

private struct TVReorderDoneButton: View {
    @FocusState private var focused: Bool
    let action: () -> Void

    var body: some View {
        Label("Done", systemImage: "checkmark")
            .font(.inter(.callout, .semibold))
            .padding(.horizontal, 22).frame(height: 48)
            .background(LineupPresentationStyle.card, in: Capsule())
            .foregroundStyle(LineupPresentationStyle.text)
            .overlay(Capsule().strokeBorder(LineupStyle.line, lineWidth: 1))
            .lineupFocusLayer(focused, in: Capsule())
            .contentShape(Capsule())
            .focusable().focused($focused).focusEffectDisabled()
            .tvSelectAction(action)
            .focusLift(focused, scale: LineupStyle.controlLift)
    }
}

private func guideProgramX(_ program: CurrentProgram, now: Date, layout: GuideLayout) -> CGFloat {
    let anchor = guideTimelineAnchor(now)
    let visibleStart = max(program.start, anchor)
    return max(0, CGFloat(visibleStart.timeIntervalSince(anchor) / 1800) * layout.slotWidth)
}

private func guideProgramWidth(_ program: CurrentProgram, now: Date, layout: GuideLayout) -> CGFloat {
    let anchor = guideTimelineAnchor(now)
    let windowEnd = anchor.addingTimeInterval(Double(guideVisibleSlotCount) * 1800)
    let visibleStart = max(program.start, anchor)
    let visibleEnd = min(program.end, windowEnd)
    let durationWidth = CGFloat(max(0, visibleEnd.timeIntervalSince(visibleStart)) / 1800) * layout.slotWidth
    return max(1, durationWidth - 6)
}

/// A programme block on its channel's own colour. Elapsed time keeps its
/// translucent fill; remote focus adds an edge without washing out the tint.
private struct GuideProgramCell: View {
    @Environment(\.guideLayout) private var layout
    let program: CurrentProgram?
    let empty: String
    let quality: String?
    let now: Date
    let showsTime: Bool
    let onPlay: () -> Void
    let onFocus: () -> Void
    let gridFocus: FocusState<GuideGridFocus?>.Binding
    let focusID: GuideGridFocus
    let onMove: (MoveCommandDirection) -> Void
    private var isFocused: Bool { gridFocus.wrappedValue == focusID }

    private var isOnNow: Bool {
        guard let program else { return false }
        return program.start <= now && now < program.end
    }

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 14, style: .continuous)
        VStack(alignment: .leading, spacing: 6) {
            if let program {
                HStack(spacing: 8) {
                    Text(program.title.isEmpty ? "Untitled" : program.title)
                        .font(.inter(20, .semibold))
                        .foregroundStyle(GuidePalette.rowText)
                        .lineLimit(1)
                    if program.isNew == true { GuideTinyBadge(title: "NEW") }
                }
                if showsTime || isOnNow {
                    HStack(spacing: 8) {
                        if isOnNow {
                            GuideLiveDot(size: 8)
                            Text("LIVE")
                                .font(.inter(14, .semibold)).tracking(1.2)
                                .foregroundStyle(LineupStyle.liveStatus)
                        }
                        if showsTime {
                            Text(guideTimeRange(program))
                                .font(.interDigits(15, .medium))
                                .foregroundStyle(GuidePalette.secondary)
                                .lineLimit(1)
                            if let quality { GuideTinyBadge(title: quality) }
                        }
                    }
                }
            } else {
                Text(empty).font(.inter(18)).foregroundStyle(GuidePalette.channelText)
            }
        }
        .padding(.horizontal, 14).padding(.top, 12).padding(.bottom, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .frame(height: layout.rowHeight - 8, alignment: .topLeading)
        .background {
            ZStack(alignment: .leading) {
                if let program, isOnNow {
                    GeometryReader { geometry in
                        let played = GuideProgress.playedWidth(
                            start: program.start, end: program.end, now: now,
                            visibleStart: guideTimelineAnchor(now),
                            pointsPerSecond: Double(layout.slotWidth) / 1800,
                            cellWidth: Double(geometry.size.width))
                        // A low-contrast wash, not a second progress bar; its
                        // edge still ends where the timeline says now is.
                        Rectangle()
                            .fill(GuidePalette.rowText.opacity(0.13))
                            .frame(width: CGFloat(played), height: geometry.size.height)
                            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
                    }
                }
            }
            .clipShape(shape)
        }
        .overlay {
            if isFocused {
                shape.strokeBorder(LineupStyle.focusEdge, lineWidth: 1.5)
                    .allowsHitTesting(false)
            }
        }
        .zIndex(isFocused ? 2 : 0)
        .animation(.easeOut(duration: 0.14), value: isFocused)
        .contentShape(Rectangle()).focusable().focused(gridFocus, equals: focusID).focusEffectDisabled().tvSelectAction(onPlay)
        .onMoveCommand(perform: onMove)
        .accessibilityValue(isOnNow ? "On now" : "")
        // Keep the focused block in timeline coordinates so its fill stays aligned.
        .onChange(of: isFocused) { focused in if focused { onFocus() } }
    }
}

/// On air, as the app's small red dot.
private struct GuideLiveDot: View {
    var size: CGFloat = 10

    var body: some View {
        PulsingLiveDot(size: size)
    }
}

/// The dot and the word, for the preview of a programme on now.
private struct GuideLiveTag: View {
    var body: some View {
        HStack(spacing: 7) {
            GuideLiveDot(size: 10)
            Text("LIVE")
                .font(.inter(14, .heavy)).tracking(0.6)
                .foregroundStyle(LineupStyle.liveStatus)
        }
    }
}

private struct GuideProgressBar: View {
    let progress: CGFloat

    var body: some View {
        LineupProgressBar(value: Double(progress), height: 10)
    }
}

/// The Account screen: what the app is connected to, and how it is doing.
///
/// Two sources side by side -- the provider that fills Live and the Guide, and
/// the media server behind Library -- each a card that says what it is,
/// whether it answers, what it holds and what can be done with it. Below them
/// the library, diagnostics and the app itself, on the same two columns, so
/// every edge on the screen lines up with another.
struct AccountView: View {
    @Binding var selectedTab: Int
    @Environment(SportsLibrary.self) private var library
    @Environment(MediaLibrary.self) private var media
    @EnvironmentObject private var cloud: CloudSettingsSync
    @State private var addingProvider = false
    @State private var choosingProvider = false
    @State private var addingMediaServer = false
    @State private var configuringMDBList = false
    @State private var configuringSeerr = false
    @State private var showingTracking = false
    @State private var managingTeamChannels = false
    @State private var managingTeams = false
    @State private var choosingAccent = false
    /// The tab whose playback engine is being chosen.
    @State private var choosingEngineFor: TVPlaybackPlace?
    // What the Library tab's menu used to offer, now in Library below.
    @State private var showingCollections = false
    @State private var choosingShelf = false
    @State private var removingShelf = false
    @State private var reorderingShelves = false
    @State private var clearingHistory = false
    @AppStorage(TVPlaybackEngine.storageKey) private var playbackEngine = TVPlaybackEngine.vlc.rawValue
    // Each tab's own engine: empty until one is chosen, and the tab then
    // plays with the one above, which every tab used before they had their own.
    @AppStorage(TVPlaybackPlace.sports.storageKey) private var sportsEngine = ""
    @AppStorage(TVPlaybackPlace.guide.storageKey) private var guideEngine = ""
    @AppStorage(TVPlaybackPlace.library.storageKey) private var libraryEngine = ""
    @AppStorage(TVPlaybackPlace.search.storageKey) private var searchEngine = ""
    @State private var pendingAccent: String?
    /// The accent, chosen here too: iCloud brings the phone's choice over
    /// once it is switched on, and until then the two are set by hand.
    @AppStorage(LineupAccent.storageKey) private var accentHex = LineupAccent.red.hex

    private let columnWidth: CGFloat = 1400
    private let gutter: CGFloat = 24

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 56) {
                    header
                    // Each section a panel, as on the phone: the header
                    // and its hairline inside, the cards a step lighter.
                    sources.modifier(TVSettingsPanel())
                    teamsSettings.modifier(TVSettingsPanel())
                    libraryAndCatalogs.modifier(TVSettingsPanel())
                    appearance.modifier(TVSettingsPanel())
                    playbackSettings.modifier(TVSettingsPanel())
                    diagnostics.modifier(TVSettingsPanel())
                    about.modifier(TVSettingsPanel())
                }
                .frame(width: columnWidth, alignment: .topLeading)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 56)
            }
            .background(LineupPresentationStyle.ground)
            // The store decides and the store owns it, as on the Media
            // Servers tab: a load tied to this screen was cancelled by
            // leaving it, and left the flag raised behind.
            .onAppear {
                media.loadShelvesIfNeeded()
                media.loadMDBListIntegrationIfNeeded()
            }
            .onChange(of: media.profiles.map(\.id)) { _, _ in media.loadShelvesIfNeeded() }
            .tvChoices("\(choosingEngineFor?.title ?? "Playback") Engine", symbol: "play.rectangle",
                       isPresented: Binding(get: { choosingEngineFor != nil },
                                            set: { if !$0 { choosingEngineFor = nil } }),
                       message: "Used for the next stream you open in \(choosingEngineFor?.title ?? "this tab"). MPVKit is a trial; if it cannot open a stream, Lineup falls back to AetherEngine, then VLC.") {
                guard let place = choosingEngineFor else { return [] }
                return TVPlaybackEngine.allCases.map { engine in
                     TVChoice(engine.title, symbol: "play.rectangle", namesEngine: true, version: engine.version,
                              isSelected: self.engine(for: place) == engine) {
                        setEngine(engine, for: place)
                    }
                }
            }
            .tvChoices("Live TV Sources", symbol: "antenna.radiowaves.left.and.right", isPresented: $choosingProvider,
                       message: "Your provider supplies the streams. Connect its Xtream login or add an EPGenius / M3U playlist.") {
                library.profiles.map { profile in
                    TVChoice(profile.name, symbol: profile.isPlaylist ? "list.bullet.rectangle" : "server.rack",
                             id: profile.id.uuidString, isSelected: library.activeProfile?.id == profile.id) {
                        Task { await library.selectProfile(profile) }
                    }
                } + [TVChoice("Add TV Source", symbol: "plus", id: "add-provider") { addingProvider = true }]
            }
            .lineupSheet(isPresented: $addingProvider) {
                ProfileSetupView().environment(library)
            }
            .lineupSheet(isPresented: $addingMediaServer) {
                MediaServerSetupView().environment(media)
            }
            .lineupSheet(isPresented: $configuringMDBList) {
                MDBListIntegrationView().environment(media)
            }
            .lineupSheet(isPresented: $configuringSeerr) {
                NavigationStack { SeerrSettingsView().environment(media) }
            }
            .lineupSheet(isPresented: $showingTracking) {
                NavigationStack { LibraryTrackingSettingsView().environment(media) }
            }
            .lineupFullScreenCover(isPresented: $showingCollections) { TVCollectionsScreen().environment(media) }
            .lineupSheet(isPresented: $choosingShelf) { MediaShelfPicker().environment(media) }
            .lineupSheet(isPresented: $reorderingShelves) {
                LibraryShelfOrderSheet().environment(media).preferredColorScheme(.dark)
            }
            .tvChoices("Remove a Shelf", symbol: "minus.rectangle", isPresented: $removingShelf,
                       message: "Its titles stay on your server; only the shelf leaves the Library.") {
                media.removableShelves.map { shelf in
                    TVChoice(media.shelfName(shelf), id: "remove-\(shelf.id)", isDestructive: true) {
                        media.removeShelf(shelf)
                    }
                }
            }
            .tvChoices("Clear local tracking?", symbol: "trash", isPresented: $clearingHistory,
                       message: "This removes Continue Watching and local watched status from this Apple TV.") {
                [TVChoice("Clear Local Tracking", isDestructive: true) { media.clearLocalPlayback() }]
            }
            .lineupSheet(isPresented: $managingTeamChannels) {
                TVPreferredChannelsView().environment(library)
            }
            .lineupFullScreenCover(isPresented: $managingTeams) {
                SportsTeamsSettingsView().environment(library)
            }
            .lineupFullScreenCover(isPresented: $choosingAccent, onDismiss: {
                if let hex = pendingAccent {
                    pendingAccent = nil
                    choose(hex)
                }
            }) {
                TVAccentPicker(hex: accentHex) { pendingAccent = $0 }
            }
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("LINEUP")
                .font(.inter(13, .heavy)).tracking(0.6)
                .foregroundStyle(LineupPresentationStyle.secondary)
            Text("Settings")
                .font(.inter(52, .bold))
                .foregroundStyle(LineupPresentationStyle.text)
            Text("Your sources, your library, and how the app is running.")
                .font(.inter(21))
                .foregroundStyle(LineupPresentationStyle.secondary)
        }
    }

    // MARK: Live TV

    /// The IPTV side. The media servers are under Library, with the rest of
    /// what the Library tab is made from.
    private var sources: some View {
        VStack(alignment: .leading, spacing: 22) {
            AccountSectionHeading("LIVE TV")
            providerCard
                .fixedSize(horizontal: false, vertical: true)
            if library.activeProfile != nil {
                providersRow
                preferredChannelsRow
            }
        }
    }

    /// Adding a provider remains available after first setup. New connections
    /// are saved alongside the active one and can be selected from this menu.
    private var providersRow: some View {
        let shape = RoundedRectangle(cornerRadius: 18, style: .continuous)
        return TVSelectable(scale: 1.01, fillRadius: 18, action: { choosingProvider = true }) {
            HStack(spacing: 20) {
                Image(systemName: "antenna.radiowaves.left.and.right")
                    .font(.system(size: 28, weight: .semibold, design: .rounded)).foregroundStyle(LineupPresentationStyle.text)
                    .frame(width: 52)
                VStack(alignment: .leading, spacing: 4) {
                    Text("Live TV Sources").font(.inter(24, .semibold)).foregroundStyle(LineupPresentationStyle.text)
                    Text("Add an EPGenius / M3U playlist or switch saved connections")
                        .font(.inter(18)).foregroundStyle(LineupPresentationStyle.secondary).lineLimit(1)
                }
                Spacer(minLength: 16)
                Text("\(library.profiles.count) saved")
                    .font(.inter(18)).foregroundStyle(LineupPresentationStyle.secondary)
                Image(systemName: "chevron.right")
                    .font(.system(size: 20, weight: .semibold, design: .rounded)).foregroundStyle(LineupPresentationStyle.secondary)
            }
            .padding(.horizontal, 30)
            .frame(height: 96)
            .background(LineupPresentationStyle.row, in: shape)
        }
        .disabled(library.isSwitchingProfile)
    }

    /// The channels saved for teams, one press from their list.
    private var preferredChannelsRow: some View {
        let count = library.teamPreferences.count
        let shape = RoundedRectangle(cornerRadius: 18, style: .continuous)
        return TVSelectable(scale: 1.01, fillRadius: 18, action: { managingTeamChannels = true }) {
            HStack(spacing: 20) {
                Image(systemName: "star.square.on.square")
                    .font(.system(size: 28, weight: .semibold, design: .rounded)).foregroundStyle(LineupPresentationStyle.text)
                    .frame(width: 52)
                VStack(alignment: .leading, spacing: 4) {
                    Text("Preferred Channels").font(.inter(24, .semibold)).foregroundStyle(LineupPresentationStyle.text)
                    Text(count == 0
                         ? "None yet. Hold Select on a game and pick Choose Another Channel to save one for a team."
                         : "\(count) \(count == 1 ? "team opens" : "teams open") on a saved channel")
                        .font(.inter(18)).foregroundStyle(LineupPresentationStyle.secondary).lineLimit(1)
                }
                Spacer(minLength: 16)
                Image(systemName: "chevron.right")
                    .font(.system(size: 20, weight: .semibold, design: .rounded)).foregroundStyle(LineupPresentationStyle.secondary)
            }
            .padding(.horizontal, 30)
            .frame(height: 96)
            .background(LineupPresentationStyle.row, in: shape)
        }
    }

    @ViewBuilder private var providerCard: some View {
        if let profile = library.activeProfile {
            AccountSourceCard(
                symbol: "antenna.radiowaves.left.and.right",
                kind: profile.isPlaylist ? "PLAYLIST & GUIDE" : "IPTV PROVIDER",
                title: profile.name,
                subtitle: "\(profile.username) · \(URL(string: profile.serverURL)?.host ?? profile.serverURL)",
                status: library.channelsAreSyncing ? .busy("Updating")
                    : (library.streams.isEmpty ? .offline : .connected),
                stats: [
                    AccountStat("Channels", library.streams.count),
                    AccountStat("Favorites", library.favoriteStreamOrder.count),
                    AccountStat("Teams", library.teamPreferences.listed().count)
                ],
                refreshed: library.lastRefreshedAt
            ) {
                AccountButton(title: "Refresh", symbol: "arrow.clockwise") {
                    Task { await library.reload() }
                }
                .disabled(library.channelsAreSyncing || library.isSwitchingProfile)
                AccountButton(title: "TV Guide", symbol: "list.bullet.rectangle") { selectedTab = 1 }
                AccountButton(title: "Remove", symbol: "trash", quiet: true) {
                    library.removeActiveProfile()
                }
            }
        } else {
            AccountEmptySource(
                symbol: "antenna.radiowaves.left.and.right",
                kind: "LIVE TV SOURCE",
                title: "No TV source",
                detail: "Connect your provider or add an EPGenius / M3U playlist."
            ) {
                // The first-run screen is the only other place to sign in, and
                // it never returns once a media server is saved.
                AccountButton(title: "Add TV Source", symbol: "plus", prominent: true) {
                    addingProvider = true
                }
            }
        }
    }

    @ViewBuilder private var mediaCard: some View {
        if let profile = media.profiles.first {
            let several = media.profiles.count > 1
            AccountSourceCard(
                symbol: "play.square.stack",
                brand: MediaServerBrand.shared(by: media.profiles),
                kind: several ? "MEDIA SERVERS" : "MEDIA SERVER",
                title: several ? "\(media.profiles.count) media servers" : profile.name,
                subtitle: several
                    ? media.profiles.map(\.name).joined(separator: " · ")
                    : "\(profile.username) · \(profile.displayHost)",
                status: media.isLoading ? .busy("Connecting") : (media.isConnected ? .connected : .offline),
                stats: [
                    AccountStat("Movies", media.libraryCounts?.movies),
                    AccountStat("Shows", media.libraryCounts?.shows),
                    AccountStat("Episodes", media.libraryCounts?.episodes)
                ],
                refreshed: media.lastRefreshedAt
            ) {
                AccountButton(title: "Reload", symbol: "arrow.clockwise") {
                    Task { await media.reload() }
                }
                .disabled(media.isLoading)
                AccountButton(title: "Browse", symbol: "square.grid.2x2") { selectedTab = 2 }
                AccountButton(title: "Add", symbol: "plus") { addingMediaServer = true }
                if media.profiles.count == 1 {
                    AccountButton(title: "Remove", symbol: "trash", quiet: true) {
                        media.remove(profile)
                    }
                }
            }
        } else {
            AccountEmptySource(
                symbol: "play.square.stack",
                kind: "MEDIA SERVER",
                title: "No media server",
                detail: "Connect your Jellyfin, Emby or Plex server to watch your own library."
            ) {
                AccountButton(title: "Add Media Server", symbol: "plus", prominent: true) {
                    addingMediaServer = true
                }
            }
        }
    }

    private var teamsSettings: some View {
        VStack(alignment: .leading, spacing: 22) {
            AccountSectionHeading("MY TEAMS")
            TVSelectable(scale: 1.01, fillRadius: 18, action: { managingTeams = true }) {
                HStack(spacing: 20) {
                    LineupIconTile(symbol: "star.fill", size: 48)
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Follow Your Teams").font(.inter(24, .semibold))
                        Text("NFL, NBA, NHL, MLB, and college football")
                            .font(.inter(18)).foregroundStyle(LineupPresentationStyle.secondary)
                    }
                    Spacer()
                    Text("\(library.followedTeams.count) following")
                        .font(.inter(21, .semibold)).foregroundStyle(LineupPresentationStyle.secondary)
                    Image(systemName: "chevron.right").font(.inter(20, .semibold))
                }
                .padding(24)
                .background(LineupPresentationStyle.row, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            }
        }
    }

    // MARK: Library

    /// Everything the Library tab is made from and everything done to it:
    /// its servers and lists, its hero and metadata, and what its menu used
    /// to offer -- shelves, collections, refreshing, local tracking.
    private var libraryAndCatalogs: some View {
        VStack(alignment: .leading, spacing: 22) {
            AccountSectionHeading("LIBRARY")
            HStack(alignment: .top, spacing: gutter) {
                mediaCard
                catalogs
            }
            .fixedSize(horizontal: false, vertical: true)
            // Every server feeds the Library at once, so with more than one
            // the card above speaks for all of them and this list for each:
            // whether it answers, what it holds, and the way to remove it.
            if media.profiles.count > 1 {
                VStack(spacing: 0) {
                    ForEach(Array(media.profiles.enumerated()), id: \.element.id) { index, profile in
                        if index > 0 {
                            Rectangle().fill(LineupStyle.line).frame(height: 1).padding(.horizontal, 30)
                        }
                        AccountServerRow(profile: profile)
                    }
                }
                .background(LineupPresentationStyle.row, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
            }
            HStack(alignment: .top, spacing: gutter) {
                AccountLinkCard(
                    symbol: "sparkles.rectangle.stack",
                    kind: "LIBRARY",
                    title: "Library Hero",
                    detail: media.heroCatalog.map { "Top 10 from \($0.title)" }
                        ?? "Choose the catalog shown across the top of Library",
                    action: "Choose Catalog",
                    actionSymbol: "slider.horizontal.3"
                ) {
                    LibraryHeroSettingsView().environment(media)
                }
                .disabled(!media.hasAnySource)
                AccountLinkCard(
                    symbol: "text.book.closed", kind: "LIBRARY", title: "Metadata",
                    detail: "Movies and shows: \(media.metadataSource.title) · Episodes: \(media.episodeDataSource.title)",
                    action: "Choose Sources", actionSymbol: "slider.horizontal.3"
                ) {
                    LibraryMetadataSettingsView().environment(media)
                }
            }
            .fixedSize(horizontal: false, vertical: true)
            libraryActions
        }
    }

    /// What the Library tab's menu offered, two to a row. One that has
    /// nothing to act on stays in its place, dimmed, so the rest never move.
    private var libraryActions: some View {
        let own = media.personalCollections.count
        let removable = media.removableShelves.count
        return LazyVGrid(columns: [GridItem(.flexible(), spacing: gutter), GridItem(.flexible())],
                         alignment: .leading, spacing: gutter) {
            AccountActionRow(symbol: "checkmark.circle", title: "Watch Tracking",
                             detail: "Choose local tracking, MDBList, both, or neither") { showingTracking = true }
            AccountActionRow(symbol: "tray.and.arrow.down", title: "Seerr",
                             detail: media.seerr.isConnected ? "Discover, request and manage titles" : "Connect your request server") { configuringSeerr = true }
            AccountActionRow(symbol: "folder.fill", title: "Collections",
                             detail: own == 0 ? "Group titles your own way" : "\(own) of your own") {
                showingCollections = true
            }
            AccountActionRow(symbol: "plus.rectangle.on.rectangle", title: "Add Shelf",
                             detail: "A library, genre or list as a row") { choosingShelf = true }
                .disabled(!media.hasAnySource)
            AccountActionRow(symbol: "minus.rectangle", title: "Remove a Shelf",
                             detail: removable == 0 ? "No shelves to remove"
                                : "\(removable) \(removable == 1 ? "shelf" : "shelves") on the Library tab") {
                removingShelf = true
            }
            .disabled(removable == 0)
            AccountActionRow(symbol: "arrow.up.arrow.down", title: "Edit Shelves",
                             detail: "Put the Library's rows in order") { reorderingShelves = true }
                .disabled(media.libraryRows.count < 2)
            AccountActionRow(symbol: "arrow.clockwise", title: "Refresh Library",
                             detail: media.isLoading ? "Updating…" : "Fetch every server's shelves again") {
                Task { await media.reload() }
            }
            .disabled(!media.hasAnySource || media.isLoading)
            AccountActionRow(symbol: "trash", title: "Clear Local Tracking",
                             detail: "Continue Watching and watched marks here", destructive: true) {
                clearingHistory = true
            }
            .disabled(media.continueWatching.isEmpty && media.watchHistory.isEmpty)
        }
    }

    /// MDBList, which turns the viewer's lists into Library shelves.
    @ViewBuilder private var catalogs: some View {
        if media.isMDBListConnected {
            let account = media.mdbListAccount
            AccountSourceCard(
                symbol: "rectangle.stack.badge.play",
                kind: "CATALOGS",
                title: "MDBList",
                subtitle: account.map { "@\($0.username) · \($0.plan ?? "Connected")" } ?? "Catalog discovery",
                status: media.isMDBListLoading ? .busy("Updating") : .connected,
                stats: [
                    AccountStat("Catalogs", media.mdbListCatalogs.count),
                    AccountStat("Requests Left", account?.requestsRemaining),
                    AccountStat("Daily Limit", account?.dailyLimit)
                ],
                refreshed: nil
            ) {
                AccountButton(title: "Configure", symbol: "gearshape") { configuringMDBList = true }
                AccountButton(title: "Refresh", symbol: "arrow.clockwise") {
                    Task { await media.loadMDBListIntegration() }
                }
                .disabled(media.isMDBListLoading)
            }
        } else {
            AccountEmptySource(
                symbol: "rectangle.stack.badge.play",
                kind: "CATALOGS",
                title: "MDBList",
                detail: "Connect MDBList to use your movie and show lists as Library shelves."
            ) {
                AccountButton(title: "Connect MDBList", symbol: "link", prominent: true) {
                    configuringMDBList = true
                }
            }
        }
    }

    // MARK: Diagnostics and about

    /// The two screens that answer "why did it do that", side by side.
    private var diagnostics: some View {
        VStack(alignment: .leading, spacing: 22) {
            AccountSectionHeading("DIAGNOSTICS")
            HStack(alignment: .top, spacing: gutter) {
                AccountTile(title: "Channel matching", detail: "Why each game chose its channel",
                            symbol: "point.3.connected.trianglepath.dotted") { MatchDiagnosticsView() }
                AccountTile(title: "Launch timing", detail: "Where the last start spent its time",
                            symbol: "speedometer") { TVStartupTraceView() }
                AccountTile(title: "Playback log", detail: "What the player did, and why it stopped",
                            symbol: "list.bullet.rectangle.portrait") { TVPlaybackJournalView() }
            }
            .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: Appearance

    /// A playback engine for each tab that plays video: a source one engine
    /// struggles with can play on the other without moving everything.
    private var playbackSettings: some View {
        VStack(alignment: .leading, spacing: 22) {
            AccountSectionHeading("PLAYBACK")
            Text("Each tab plays with its own engine.")
                .font(.inter(19)).foregroundStyle(LineupPresentationStyle.secondary)
            VStack(spacing: 14) {
                ForEach(TVPlaybackPlace.allCases) { place in
                    AccountEngineRow(place: place, engine: engine(for: place)) { choosingEngineFor = place }
                }
            }
        }
    }

    private func engine(for place: TVPlaybackPlace) -> TVPlaybackEngine {
        let own = switch place {
        case .sports: sportsEngine
        case .guide: guideEngine
        case .library: libraryEngine
        case .search: searchEngine
        }
        return TVPlaybackEngine(rawValue: own) ?? TVPlaybackEngine(rawValue: playbackEngine) ?? .vlc
    }

    private func setEngine(_ engine: TVPlaybackEngine, for place: TVPlaybackPlace) {
        switch place {
        case .sports: sportsEngine = engine.rawValue
        case .guide: guideEngine = engine.rawValue
        case .library: libraryEngine = engine.rawValue
        case .search: searchEngine = engine.rawValue
        }
    }

    /// Opens the same preset, custom and saved color choices as the phone.
    private var appearance: some View {
        let chosen = LineupAccent.accent(forHex: accentHex)
        return VStack(alignment: .leading, spacing: 22) {
            AccountSectionHeading("APPEARANCE")
            TVSelectable(scale: 1.015, fillRadius: 18, action: { choosingAccent = true }) {
                HStack(spacing: 20) {
                    Circle().fill(chosen.color).frame(width: 48, height: 48)
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Accent Color").font(.inter(24, .semibold))
                        Text("Presets, custom colors, and My Colors")
                            .font(.inter(18)).foregroundStyle(LineupPresentationStyle.secondary)
                    }
                    Spacer()
                    Text(chosen.isPreset ? chosen.name : "#\(chosen.hex)")
                        .font(.inter(21, .semibold)).foregroundStyle(LineupPresentationStyle.secondary)
                    Image(systemName: "chevron.right").font(.inter(20, .semibold))
                }
                .padding(24)
                .background(LineupPresentationStyle.row, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            }
        }
    }

    private func choose(_ hex: String) {
        guard hex != accentHex else { return }
        accentHex = hex
        CloudSettingsSync.shared.localSettingsChanged()
    }

    private var about: some View {
        VStack(alignment: .leading, spacing: 22) {
            AccountSectionHeading("ABOUT")
            HStack(spacing: gutter) {
                AccountRow(label: "iCloud", value: cloud.status)
                AccountRow(label: "Version",
                           value: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.3.1")
            }
            AccountTile(title: "Playback acknowledgements", detail: "AetherEngine, MPVKit, and decoder licenses",
                        symbol: "doc.text") { TVPlaybackLicensesView() }
            .fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// A Settings section as a panel: the panels' fill and corners round its
/// header and everything under it.
private struct TVSettingsPanel: ViewModifier {
    func body(content: Content) -> some View {
        content
            .padding(LineupPanelStyle.inset)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(LineupPresentationStyle.card, in: RoundedRectangle(cornerRadius: LineupPanelStyle.radius,
                                                                  style: .continuous))
            .lineupPresentation()
    }
}

private struct AccountSectionHeading: View {
    let title: String
    init(_ title: String) { self.title = title }

    /// Each section's icon, by its name.
    private var symbol: String {
        switch title {
        case "LIVE TV": "antenna.radiowaves.left.and.right"
        case "LIBRARY": "rectangle.stack"
        case "DIAGNOSTICS": "waveform.path.ecg"
        case "APPEARANCE": "paintpalette"
        case "PLAYBACK": "play.rectangle"
        default: "info.circle"
        }
    }

    // The panels' header: icon and heavy caption in light grey, a hairline
    // under them.
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            LineupPanelHeader(title, systemImage: symbol)
            Rectangle().fill(LineupStyle.line).frame(height: 1)
        }
    }
}

/// One figure on a card: a number over its name.
private struct AccountStat: Identifiable {
    let label: String
    let count: Int?
    var id: String { label }

    init(_ label: String, _ count: Int?) {
        self.label = label
        self.count = count
    }
}

/// Whether a source answers, in words with a mark beside them.
private enum AccountSourceStatus {
    case connected, offline
    case busy(String)

    var title: String {
        switch self {
        case .connected: "Connected"
        case .offline: "Offline"
        case .busy(let word): word
        }
    }
}

private struct AccountStatusMark: View {
    let status: AccountSourceStatus

    var body: some View {
        HStack(spacing: 9) {
            switch status {
            case .connected:
                Circle().fill(LineupPresentationStyle.text).frame(width: 8, height: 8)
            case .offline:
                Circle().strokeBorder(LineupPresentationStyle.secondary, lineWidth: 1.5).frame(width: 9, height: 9)
            case .busy:
                ProgressView().controlSize(.small).scaleEffect(0.7).frame(width: 9, height: 9)
            }
            Text(status.title.uppercased())
                .font(.inter(13, .heavy)).tracking(0.6)
        }
        .foregroundStyle(tint)
        .fixedSize()
    }

    private var tint: Color {
        if case .connected = status { return LineupPresentationStyle.text }
        return LineupPresentationStyle.secondary
    }
}

/// A connected source: what it is, whether it answers, what it holds, and
/// what can be done with it, in that order from the top.
private struct AccountSourceCard<Actions: View>: View {
    let symbol: String
    /// A media server's own mark, in place of the symbol.
    var brand: MediaServerBrand? = nil
    let kind: String
    let title: String
    let subtitle: String
    let status: AccountSourceStatus
    let stats: [AccountStat]
    let refreshed: Date?
    @ViewBuilder var actions: Actions

    var body: some View {
        VStack(alignment: .leading, spacing: 26) {
            HStack(alignment: .top, spacing: 18) {
                AccountGlyph(symbol: symbol, brand: brand)
                VStack(alignment: .leading, spacing: 4) {
                    Text(kind)
                        .font(.inter(12, .heavy)).tracking(0.6)
                        .foregroundStyle(LineupPresentationStyle.secondary)
                    Text(title)
                        .font(.inter(28, .bold)).foregroundStyle(LineupPresentationStyle.text)
                        .lineLimit(1).minimumScaleFactor(0.8)
                    Text(subtitle)
                        .font(.inter(17)).foregroundStyle(LineupPresentationStyle.secondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 12)
                AccountStatusMark(status: status)
            }
            HStack(spacing: 0) {
                ForEach(Array(stats.enumerated()), id: \.element.id) { index, stat in
                    if index > 0 {
                        Rectangle().fill(LineupStyle.line).frame(width: 1, height: 52)
                    }
                    VStack(alignment: .leading, spacing: 4) {
                        Text(stat.count.map { $0.formatted() } ?? "—")
                            .font(.interDigits(34, .bold)).foregroundStyle(LineupPresentationStyle.text)
                            .lineLimit(1).minimumScaleFactor(0.7)
                        Text(stat.label.uppercased())
                            .font(.inter(12, .heavy)).tracking(0.6)
                            .foregroundStyle(LineupPresentationStyle.secondary)
                            .lineLimit(1)
                    }
                    .padding(.leading, index > 0 ? 24 : 0)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            Spacer(minLength: 0)
            HStack(spacing: 12) { actions }
            if let refreshed {
                Text("Updated \(refreshed, style: .relative) ago")
                    .font(.inter(14)).foregroundStyle(LineupPresentationStyle.secondary)
            }
        }
        .padding(32)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(LineupPresentationStyle.card, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 22, style: .continuous)
            .strokeBorder(LineupStyle.line, lineWidth: 1))
    }
}

/// A source that is not connected, in the shape of the card that would be
/// there if it were, holding the one action that connects it.
private struct AccountEmptySource<Action: View>: View {
    let symbol: String
    /// A media server's own mark, in place of the symbol.
    var brand: MediaServerBrand? = nil
    let kind: String
    let title: String
    let detail: String
    @ViewBuilder var action: Action

    var body: some View {
        VStack(alignment: .leading, spacing: 26) {
            HStack(alignment: .top, spacing: 18) {
                AccountGlyph(symbol: symbol, brand: brand)
                VStack(alignment: .leading, spacing: 4) {
                    Text(kind)
                        .font(.inter(12, .heavy)).tracking(0.6)
                        .foregroundStyle(LineupPresentationStyle.secondary)
                    Text(title)
                        .font(.inter(28, .bold)).foregroundStyle(LineupPresentationStyle.text)
                    Text(detail)
                        .font(.inter(17)).foregroundStyle(LineupPresentationStyle.secondary)
                        .lineLimit(2).fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
            }
            Spacer(minLength: 0)
            HStack(spacing: 12) { action }
        }
        .padding(32)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(LineupPresentationStyle.card.opacity(0.55), in: RoundedRectangle(cornerRadius: 22, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 22, style: .continuous)
            .strokeBorder(LineupStyle.line, style: StrokeStyle(lineWidth: 1, dash: [6, 6])))
    }
}

/// A card's symbol, on a raised disc.
private struct AccountGlyph: View {
    let symbol: String
    /// A media server's own mark, drawn in the same plate instead.
    var brand: MediaServerBrand? = nil

    // The coloured tile the phone's Settings rows carry, at television size.
    var body: some View {
        if let brand {
            MediaServerLogoTile(brand: brand, size: 64)
        } else {
            LineupIconTile(symbol: symbol, size: 64)
        }
    }
}

/// One connected server, in the list that appears when there is more than
/// one. They all feed the Library at once, so a row says how its own server
/// is doing -- whether it answers and what it holds -- rather than offering a
/// choice between them.
private struct AccountServerRow: View {
    @Environment(MediaLibrary.self) private var media
    let profile: MediaServerProfile

    var body: some View {
        let state = media.state(of: profile)
        HStack(spacing: 24) {
            MediaServerLogo(brand: .of(profile)).frame(width: 34, height: 34)
            VStack(alignment: .leading, spacing: 4) {
                Text(profile.name).font(.inter(22, .semibold)).foregroundStyle(LineupPresentationStyle.text)
                    .lineLimit(1)
                Text(detail(state))
                    .font(.inter(16)).foregroundStyle(LineupPresentationStyle.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 20)
            AccountStatusMark(status: state.isLoading ? .busy("Connecting")
                              : (state.isConnected ? .connected : .offline))
            AccountButton(title: "Remove", symbol: "trash", quiet: true) { media.remove(profile) }
                .fixedSize()
        }
        .padding(.horizontal, 30).padding(.vertical, 20)
    }

    /// Its address, and what it holds once it has said.
    private func detail(_ state: MediaServerState) -> String {
        var parts = [profile.displayHost]
        if let counts = state.counts {
            parts.append("\(counts.movies.formatted()) movies")
            parts.append("\(counts.shows.formatted()) shows")
        }
        return parts.joined(separator: "  ·  ")
    }
}

/// A tile that goes somewhere, sized like its neighbour so a row of them reads
/// as a row rather than as whatever length each title happened to be.
private struct AccountTile<Destination: View>: View {
    @Environment(\.isEnabled) private var enabled
    @FocusState private var isFocused: Bool
    let title: String
    let detail: String
    let symbol: String
    @ViewBuilder var destination: Destination

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 22, style: .continuous)
        NavigationLink { destination } label: {
            HStack(spacing: 20) {
                AccountGlyph(symbol: symbol)
                VStack(alignment: .leading, spacing: 4) {
                    Text(title).font(.inter(24, .bold)).foregroundStyle(LineupPresentationStyle.text)
                    PlaybackEngineMark.text(detail, pointSize: 17).font(.inter(17)).lineLimit(2)
                        .foregroundStyle(LineupPresentationStyle.secondary)
                        .multilineTextAlignment(.leading)
                }
                Spacer(minLength: 0)
                Image(systemName: "chevron.right")
                    .font(.system(size: 18, weight: .bold, design: .rounded))
                    .foregroundStyle(LineupPresentationStyle.secondary)
            }
            .padding(28)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
            .frame(minHeight: 132)
            .background(LineupPresentationStyle.card, in: shape)
            .overlay(shape.strokeBorder(LineupStyle.line, lineWidth: 1))
            .lineupFocusLayer(isFocused, in: shape)
            .scaleEffect(isFocused ? LineupStyle.cardLift : 1)
            .lineupShadow(.lifted, on: isFocused)
            .opacity(enabled ? 1 : 0.45)
        }
        .lineupFlatButton()
        .focused($isFocused)
        .animation(.easeOut(duration: 0.18), value: isFocused)
    }
}

/// A button on a card. Standard is a raised capsule, prominent adds a white
/// edge for the one thing a card is asking for, and quiet is an outline for
/// what removes something.
/// The channels saved for teams: each team, the channel its games open on,
/// and a press to forget it. The iPhone's Preferred Channels, on the
/// television.
private struct TVPreferredChannelsView: View {
    @Environment(SportsLibrary.self) private var library
    @Environment(\.dismiss) private var dismiss
    @State private var forgetting: TeamChannelEntry?
    @State private var clearingAll = false

    var body: some View {
        let entries = library.teamPreferences.listed()
        ScrollView {
            VStack(alignment: .leading, spacing: 30) {
                PageTitle(eyebrow: "Settings", title: "Preferred Channels",
                          detail: "Games for these teams open on the channel saved for them. If it is unavailable, Lineup uses its own match and keeps the preference.")
                if entries.isEmpty {
                    Text("No preferred channels yet. Hold Select on any game, pick Choose Another Channel, and Lineup can remember it for either team.")
                        .font(.inter(22)).foregroundStyle(LineupPresentationStyle.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    VStack(spacing: 12) {
                        ForEach(entries) { entry in
                            TVSelectable(scale: 1.01, fillRadius: 16, action: { forgetting = entry },
                                         requestInitialFocus: entry.id == entries.first?.id) {
                                row(entry)
                            }
                        }
                    }
                }
                HStack(spacing: 20) {
                    if !entries.isEmpty {
                        Button("Remove All", role: .destructive) { clearingAll = true }
                    }
                    Button("Done") { dismiss() }
                }
                .lineupButtonStyle()
            }
            .padding(.horizontal, 90)
            .padding(.vertical, 56)
        }
        .background(LineupPresentationStyle.ground.ignoresSafeArea())
        .tvChoices("Forget this channel?", symbol: "trash",
                   isPresented: Binding(get: { forgetting != nil }, set: { if !$0 { forgetting = nil } }),
                   message: forgetting.map { "\(name(of: $0)) games will open on Lineup's own match again." }) {
            guard let entry = forgetting else { return [] }
            return [TVChoice("Forget", isDestructive: true) {
                library.removePreference(for: entry.key)
                forgetting = nil
            }]
        } onCancel: { forgetting = nil }
        .tvChoices("Remove every preferred channel?", symbol: "trash", isPresented: $clearingAll,
                   message: "This clears the saved channels for \(library.activeProfile?.name ?? "this provider") only.") {
            [TVChoice("Remove All", isDestructive: true) { library.removeAllPreferences() }]
        }
    }

    private func name(of entry: TeamChannelEntry) -> String {
        entry.preference.teamName.isEmpty ? entry.key.team : entry.preference.teamName
    }

    private func row(_ entry: TeamChannelEntry) -> some View {
        let shape = RoundedRectangle(cornerRadius: 16, style: .continuous)
        return HStack(spacing: 20) {
            VStack(alignment: .leading, spacing: 6) {
                Text(name(of: entry)).font(.inter(26, .semibold)).foregroundStyle(LineupPresentationStyle.text)
                HStack(spacing: 10) {
                    Text(entry.preference.channelName)
                        .font(.inter(20)).foregroundStyle(LineupPresentationStyle.secondary).lineLimit(1)
                    // A provider can drop a channel and carry it again later,
                    // so this is a note, not a reason to delete the preference.
                    if !library.preferenceChannelIsAvailable(entry.preference) {
                        Text("UNAVAILABLE")
                            .font(.inter(13, .bold)).tracking(0.8)
                            .padding(.horizontal, 8).frame(height: 24)
                            .background(LineupPresentationStyle.row, in: Capsule())
                            .foregroundStyle(LineupPresentationStyle.secondary)
                    }
                }
            }
            Spacer(minLength: 16)
            Text(entry.key.league.uppercased())
                .font(.inter(16, .bold)).tracking(1.2).foregroundStyle(LineupPresentationStyle.secondary)
            Image(systemName: "trash")
                .font(.system(size: 20, weight: .semibold, design: .rounded)).foregroundStyle(LineupPresentationStyle.secondary)
        }
        .padding(.horizontal, 28)
        .frame(height: 96)
        .background(LineupPresentationStyle.card, in: shape)
        .overlay(shape.strokeBorder(LineupStyle.line, lineWidth: 1))
        .accessibilityElement(children: .combine)
        .accessibilityHint("Forget this team's channel")
    }
}

private struct AccountButton: View {
    @Environment(\.isEnabled) private var enabled
    @FocusState private var isFocused: Bool
    let title: String
    let symbol: String
    var prominent = false
    var quiet = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            AccountButtonFace(title: title, symbol: symbol, prominent: prominent, quiet: quiet,
                              focused: isFocused, enabled: enabled)
        }
        .lineupFlatButton()
        .focused($isFocused)
        .animation(.easeOut(duration: 0.18), value: isFocused)
        .frame(maxWidth: .infinity)
    }
}

/// The same button, opening a screen rather than running an action.
private struct AccountLinkButton<Destination: View>: View {
    @Environment(\.isEnabled) private var enabled
    @FocusState private var isFocused: Bool
    let title: String
    let symbol: String
    @ViewBuilder var destination: Destination

    var body: some View {
        NavigationLink { destination } label: {
            AccountButtonFace(title: title, symbol: symbol, prominent: false, quiet: false,
                              focused: isFocused, enabled: enabled)
        }
        .lineupFlatButton()
        .focused($isFocused)
        .animation(.easeOut(duration: 0.18), value: isFocused)
        .frame(maxWidth: .infinity)
    }
}

/// What every account button looks like. The symbol and the words are laid
/// side by side on their centres: a label lines text up with the symbol's
/// baseline, which lifted some words a point or two above their neighbours'.
private struct AccountButtonFace: View {
    let title: String
    let symbol: String
    let prominent: Bool
    let quiet: Bool
    let focused: Bool
    let enabled: Bool

    var body: some View {
        let shape = Capsule()
        HStack(spacing: 12) {
            LineupIconTile(symbol: symbol, size: 34)
            Text(title).font(.inter(18, .semibold))
                .lineLimit(1).minimumScaleFactor(0.75)
        }
        .foregroundStyle(quiet && !focused ? LineupPresentationStyle.secondary : LineupPresentationStyle.text)
        .padding(.leading, 11).padding(.trailing, 24).frame(height: 56)
        .frame(maxWidth: .infinity)
        // On a card, a step lighter than the card, as a pressed row is.
        .background(quiet ? Color.clear : LineupPresentationStyle.row, in: shape)
        .overlay(shape.strokeBorder(prominent ? LineupPresentationStyle.text.opacity(0.7) : LineupStyle.line,
                                    lineWidth: prominent ? 1.5 : 1))
        .lineupFocusLayer(focused, in: shape)
        .scaleEffect(focused ? LineupStyle.controlLift : 1)
        .opacity(enabled ? 1 : 0.45)
    }
}

/// A tab and the engine it plays with, which choosing the row changes.
private struct AccountEngineRow: View {
    let place: TVPlaybackPlace
    let engine: TVPlaybackEngine
    let action: () -> Void

    var body: some View {
        TVSelectable(scale: 1.015, fillRadius: 18, action: action) {
            HStack(spacing: 20) {
                LineupIconTile(symbol: place.symbol, size: 48)
                VStack(alignment: .leading, spacing: 6) {
                    Text(place.title).font(.inter(24, .semibold))
                    Text(place.detail).font(.inter(18)).foregroundStyle(LineupPresentationStyle.secondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 16)
                PlaybackEngineText(engine.title, size: 21)
                    .font(.inter(21, .semibold)).foregroundStyle(LineupPresentationStyle.secondary)
                Image(systemName: "chevron.right").font(.inter(20, .semibold))
            }
            .padding(24)
            .background(LineupPresentationStyle.row, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        }
        .accessibilityLabel("\(place.title) playback engine, \(engine.title)")
    }
}

/// One of the Library's own actions: its tile, its name and a line on what it
/// does, in the well the other Settings rows sit in.
private struct AccountActionRow: View {
    @Environment(\.isEnabled) private var enabled
    let symbol: String
    let title: String
    let detail: String
    var destructive = false
    let action: () -> Void

    var body: some View {
        TVSelectable(scale: 1.015, fillRadius: 18, action: action) {
            HStack(spacing: 20) {
                LineupIconTile(symbol: symbol, size: 48)
                VStack(alignment: .leading, spacing: 6) {
                    Text(title).font(.inter(24, .semibold))
                        .foregroundStyle(destructive ? LineupIconTile.red : LineupPresentationStyle.text)
                    Text(detail).font(.inter(18)).foregroundStyle(LineupPresentationStyle.secondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 12)
                Image(systemName: "chevron.right").font(.inter(20, .semibold))
                    .foregroundStyle(LineupPresentationStyle.secondary)
            }
            .padding(24)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(LineupPresentationStyle.row, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        }
        .opacity(enabled ? 1 : 0.42)
    }
}

/// A card that leads somewhere: what it sets, and a button that opens it. The
/// same shape as a source card, so a row of the two lines up.
private struct AccountLinkCard<Destination: View>: View {
    let symbol: String
    let kind: String
    let title: String
    let detail: String
    let action: String
    let actionSymbol: String
    @ViewBuilder var destination: Destination

    var body: some View {
        VStack(alignment: .leading, spacing: 26) {
            HStack(alignment: .top, spacing: 18) {
                AccountGlyph(symbol: symbol)
                VStack(alignment: .leading, spacing: 4) {
                    Text(kind)
                        .font(.inter(12, .heavy)).tracking(0.6)
                        .foregroundStyle(LineupPresentationStyle.secondary)
                    Text(title)
                        .font(.inter(28, .bold)).foregroundStyle(LineupPresentationStyle.text)
                    Text(detail)
                        .font(.inter(17)).foregroundStyle(LineupPresentationStyle.secondary)
                        .lineLimit(2).fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
            }
            Spacer(minLength: 0)
            AccountLinkButton(title: action, symbol: actionSymbol) { destination }
        }
        .padding(32)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(LineupPresentationStyle.card, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 22, style: .continuous)
            .strokeBorder(LineupStyle.line, lineWidth: 1))
    }
}

/// The last launch, step by step -- the same trace the phone shows.
///
/// It was being recorded on the television all along and thrown away, because
/// only the phone had a screen to read it on. Which meant the one question
/// worth asking about a slow start on a set -- which part is slow -- could
/// only be guessed at, and guessing is what cost days on the phone.
private struct TVStartupTraceView: View {
    @ObservedObject private var trace = StartupTrace.shared

    var body: some View {
        ScrollView {
            Text(trace.report)
                .font(.interDigits(21))
                .foregroundStyle(LineupPresentationStyle.text)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(40)
        }
        .focusable()
        .background(LineupPresentationStyle.ground)
    }
}

/// What the player did, newest first, on the television itself: the trail a
/// film that stopped on its own leaves behind, read without a device log.
private struct TVPlaybackJournalView: View {
    @ObservedObject private var journal = PlaybackJournal.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            HStack(alignment: .firstTextBaseline, spacing: 24) {
                ScreenHeading(title: "Playback log", detail: "What the player did and why it stopped, newest first")
                Spacer()
                Button("Clear") { journal.clear() }
                    .lineupButtonStyle()
                    .disabled(journal.entries.isEmpty)
            }
            if journal.entries.isEmpty {
                Text("Nothing has played since the log was cleared.")
                    .font(.inter(.title3)).foregroundStyle(LineupPresentationStyle.secondary)
            }
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 8) {
                    ForEach(journal.days) { day in
                        Text(day.name.uppercased())
                            .font(.inter(13, .heavy)).tracking(0.6)
                            .foregroundStyle(LineupPresentationStyle.secondary)
                            .padding(.top, 18)
                        ForEach(Array(day.entries.enumerated()), id: \.offset) { _, entry in
                            TVPlaybackJournalRow(entry: entry)
                        }
                    }
                }
                .padding(.vertical, 4)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 120).padding(.vertical, 48)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(LineupPresentationStyle.ground)
    }
}

/// One thing the player did: the time, then what.
private struct TVPlaybackJournalRow: View {
    @FocusState private var focused: Bool
    let entry: PlaybackJournal.Entry

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 12, style: .continuous)
        HStack(alignment: .firstTextBaseline, spacing: 24) {
            Text(PlaybackJournal.time(of: entry))
                .font(.interDigits(19, .semibold))
                .foregroundStyle(LineupPresentationStyle.secondary)
            Text(entry.text)
                .font(.inter(21))
                .foregroundStyle(LineupPresentationStyle.text)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 20).padding(.vertical, 12)
        .background(LineupPresentationStyle.card, in: shape)
        .lineupFocusLayer(focused, in: shape)
        .contentShape(shape)
        .focusable().focused($focused).focusEffectDisabled()
        .accessibilityElement(children: .combine)
    }
}

/// Why each game matched the channel it did. A game that opens the wrong feed
/// should be able to name the rule that chose it, without a device log.
private struct MatchDiagnosticsView: View {
    @Environment(SportsLibrary.self) private var library

    private var games: [SportsGame] {
        library.games(for: nil).filter { $0.isLive || $0.isUpcoming }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            HStack(alignment: .firstTextBaseline, spacing: 24) {
                ScreenHeading(title: "Channel matching", detail: "The rule that chose each game's channel")
                Spacer()
            }
            if games.isEmpty {
                Text("No live or upcoming games to match.").foregroundColor(LineupPresentationStyle.text)
                    .font(.inter(.title3)).foregroundStyle(LineupPresentationStyle.secondary)
            }
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 12) {
                    ForEach(games) { MatchDiagnosticsRow(game: $0) }
                }.padding(.vertical, 4)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 120).padding(.vertical, 48)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(LineupPresentationStyle.ground)
    }
}

private struct MatchDiagnosticsRow: View {
    @Environment(SportsLibrary.self) private var library
    @FocusState private var focused: Bool
    let game: SportsGame

    private var stream: XtreamStream? { library.stream(for: game) }
    private var evidence: SportsLibrary.MatchEvidence? { library.matchEvidence(for: game) }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(game.matchupLine).foregroundColor(LineupPresentationStyle.text)
                .font(.inter(24, .semibold))
            Text("\(game.league.shortName)  ·  \(game.broadcast.isEmpty ? "No network listed" : game.broadcast)")
                .foregroundColor(LineupPresentationStyle.text)
                .font(.inter(16)).foregroundStyle(LineupPresentationStyle.secondary)
            if let stream {
                Text(stream.name).foregroundColor(LineupPresentationStyle.text)
                    .font(.inter(17, .medium)).lineLimit(1)
                if let rejection = library.playbackRejection(for: game) {
                    Text(rejection.rawValue).foregroundColor(LineupStyle.warning).font(.inter(15))
                } else {
                    Text(evidence?.rawValue ?? "Matched earlier, evidence not recorded yet")
                        .foregroundColor(evidence == .dedicatedFeed ? LineupPresentationStyle.text : LineupStyle.warning)
                        .font(.inter(15))
                }
            } else {
                Text("No match — opens the channel picker").foregroundColor(LineupPresentationStyle.text)
                    .font(.inter(15)).foregroundStyle(LineupPresentationStyle.secondary)
            }
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(LineupPresentationStyle.card, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .lineupFocusLayer(focused, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .contentShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .focusable().focused($focused).focusEffectDisabled()
        .accessibilityElement(children: .combine)
    }
}

private struct AccountRow: View {
    let label: String
    let value: String
    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 24) {
            Text(label.uppercased())
                .font(.inter(13, .heavy)).tracking(0.6)
                .foregroundStyle(LineupPresentationStyle.secondary)
            Spacer(minLength: 12)
            Text(value)
                .font(.inter(19, .medium)).foregroundStyle(LineupPresentationStyle.text)
                .multilineTextAlignment(.trailing).lineLimit(2)
        }
        .padding(.horizontal, 28).padding(.vertical, 22)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(LineupPresentationStyle.card, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
    }
}

/// How a multiview session arranges its two pictures. The last one chosen is
/// remembered for the next session.
private enum MultiviewLayout: String {
    /// Two pictures the same size, side by side.
    case sideBySide
    /// One large picture with a smaller one beside it.
    case bigAndSmall

    var title: String {
        switch self {
        case .sideBySide: "Side by Side"
        case .bigAndSmall: "Big + Small"
        }
    }

    var symbol: String {
        switch self {
        case .sideBySide: "rectangle.split.2x1"
        case .bigAndSmall: "pip"
        }
    }

    var other: MultiviewLayout { self == .sideBySide ? .bigAndSmall : .sideBySide }
}

/// The session's two players, made once and kept for as long as it runs.
///
/// Nothing here is published, deliberately: each picture watches its own
/// player, so a stream reporting its progress redraws that picture and not
/// the arrangement around it.
@MainActor
private final class MultiviewPlayers: ObservableObject {
    let tiles = [TVPlaybackController(primaryOutput: true), TVPlaybackController(primaryOutput: false)]
}

/// A game whose stream failed everywhere, waiting for a channel to be chosen.
private struct MultiviewChannelChoice: Identifiable {
    let tile: Int
    let game: SportsGame
    var id: String { "\(tile)|\(game.id)" }
}

/// Two games at once.
///
/// Both players are made when the session starts and kept until it ends.
/// Every change of arrangement -- side by side, big and small, a swap, full
/// screen and back -- moves and scales the two pictures and never touches the
/// players, so neither stream stops, buffers or loses its place.
///
/// Sound follows the picture with focus. It is handed over, never shared: the
/// old picture's sound goes out before the new one's comes in, so the two are
/// never heard together. When focus leaves both for a moment -- a menu, a
/// sheet -- the sound stays where it was rather than going quiet.
private struct MultiviewView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(SportsLibrary.self) private var library
    /// Sports or the TV Guide, whichever it was opened from.
    @Environment(\.tvPlaybackPlace) private var place
    @StateObject private var players = MultiviewPlayers()
    @AppStorage("Lineup.multiviewLayout") private var storedLayout = MultiviewLayout.sideBySide.rawValue
    @FocusState private var focusedTile: Int?
    /// The picture whose sound is playing.
    @State private var audibleTile = 0
    /// Brings the new picture's sound in once the old one's is out.
    @State private var soundTask: Task<Void, Never>?
    /// In Big + Small, which picture is the big one.
    @State private var bigTile = 0
    /// A picture filling the screen, with the other still playing, unseen.
    @State private var fullScreenTile: Int?
    /// Names and the guide to the remote, shown for a few seconds after
    /// anything changes and then cleared off the pictures.
    @State private var chromeVisible = true
    @State private var chromeTask: Task<Void, Never>?
    @State private var choosingChannel: MultiviewChannelChoice?
    @State private var pickedChannel: TVPickedChannel?
    @State private var scopingChannel: TVPickedChannel?
    @State private var chosenTitles: [Int: String] = [:]
    let primary: XtreamStream
    let secondary: XtreamStream
    let primaryURLs: [URL]
    let secondaryURLs: [URL]
    let primaryGame: SportsGame?
    let secondaryGame: SportsGame?

    private var layout: MultiviewLayout { MultiviewLayout(rawValue: storedLayout) ?? .sideBySide }
    private var arrangement: Animation { .spring(response: 0.5, dampingFraction: 0.88) }

    var body: some View {
        GeometryReader { proxy in
            let screen = proxy.size
            ZStack {
                (fullScreenTile == nil ? LineupStyle.background : Color.black)
                ForEach(0..<2, id: \.self) { index in
                    tile(index, screen: screen)
                }
                if fullScreenTile == nil {
                    controls
                        .frame(maxHeight: .infinity, alignment: .bottom)
                        .padding(.bottom, 52)
                        .transition(.opacity)
                } else {
                    fullScreenHint
                        .frame(maxHeight: .infinity, alignment: .bottom)
                        .padding(.bottom, 56)
                        .opacity(chromeVisible ? 1 : 0)
                        .allowsHitTesting(false)
                }
            }
            .frame(width: screen.width, height: screen.height)
        }
        .ignoresSafeArea()
        .onAppear(perform: begin)
        .onDisappear {
            chromeTask?.cancel()
            soundTask?.cancel()
            players.tiles.forEach { $0.stop() }
        }
        .onChange(of: focusedTile) { _, tile in
            showChrome()
            // Focus in the bar below leaves the sound where it was.
            guard let tile, tile != audibleTile else { return }
            listen(to: tile)
        }
        .onPlayPauseCommand { switchLayout() }
        .onExitCommand(perform: back)
        .lineupFullScreenCover(item: $choosingChannel, onDismiss: {
            scopingChannel = library.asksScope(for: pickedChannel)
            pickedChannel = nil
        }) { choice in
            ManualGameChannelPicker(game: choice.game) { chosen in
                library.saveGameSelection(chosen, for: choice.game)
                pickedChannel = TVPickedChannel(game: choice.game, stream: chosen, startsMultiview: false)
                choosingChannel = nil
                chosenTitles[choice.tile] = chosen.name
                players.tiles[choice.tile].start(urls: library.playbackURLs(for: chosen),
                                                 muted: audibleTile != choice.tile, channelID: chosen.id)
            }
        }
        .channelScopePrompt($scopingChannel)
    }

    private func tile(_ index: Int, screen: CGSize) -> some View {
        let frame = tileFrame(index, screen: screen)
        let shown = fullScreenTile == nil || fullScreenTile == index
        let controller = players.tiles[index]
        let game = currentGame(index)
        return MultiviewTile(controller: controller,
                             game: game,
                             fallbackTitle: chosenTitles[index] ?? stream(index).name,
                             sharedTitle: chosenTitles[index] == nil
                                ? game.flatMap { library.sharedCoverageTitle(for: $0, on: stream(index)) } : nil,
                             size: frame.size,
                             audible: audibleTile == index,
                             fullScreen: fullScreenTile == index,
                             showsLabel: chromeVisible)
            .contentShape(Rectangle())
            // Only a picture on screen can hold focus: the one behind a full
            // screen picture keeps playing, but is out of the way.
            .focusable(shown)
            .focused($focusedTile, equals: index)
            .focusEffectDisabled()
            .tvSelectAction { select(index) }
            .onMoveCommand(perform: flip(from: index))
            .tvHoldMenu(currentGame(index)?.matchupLine ?? stream(index).name, symbol: "rectangle.split.2x1") {
                menuItems(for: index)
            }
            .position(x: frame.midX, y: frame.midY)
            .opacity(shown ? 1 : 0)
            .zIndex(zIndex(index))
    }

    /// Left and right flip between the two games while one fills the screen.
    /// Otherwise there is no handler, and focus moves between the pictures on
    /// its own.
    private func flip(from index: Int) -> ((MoveCommandDirection) -> Void)? {
        guard fullScreenTile == index else { return nil }
        return { direction in
            if direction == .left || direction == .right { showFullScreen(1 - index) }
        }
    }

    /// Held on a picture: the arrangement, the stream, and the way out.
    private func menuItems(for index: Int) -> [TVChoice] {
        var items: [TVChoice] = []
        if fullScreenTile == nil {
            items.append(TVChoice(layout.other.title, symbol: layout.other.symbol) { switchLayout() })
            if layout == .bigAndSmall {
                items.append(TVChoice("Swap Screens", symbol: "arrow.left.arrow.right") { swapPictures() })
            }
            items.append(TVChoice("Full Screen", symbol: "arrow.up.left.and.arrow.down.right") { showFullScreen(index) })
        } else {
            items.append(TVChoice("Back to Multiview", symbol: "arrow.down.right.and.arrow.up.left") { leaveFullScreen() })
        }
        items.append(TVChoice("Retry Stream", symbol: "arrow.clockwise") { players.tiles[index].retry() })
        if let game = currentGame(index), players.tiles[index].failover != nil {
            items.append(TVChoice("Choose Another Channel", symbol: "list.bullet.rectangle") {
                choosingChannel = MultiviewChannelChoice(tile: index, game: game)
            })
        }
        items.append(TVChoice("Exit Multiview", symbol: "xmark", isDestructive: true) { dismiss() })
        return items
    }

    // MARK: Arrangement

    /// Where a picture sits. A picture hidden behind a full screen one keeps
    /// its own place, so coming back is the same move in reverse.
    private func tileFrame(_ index: Int, screen: CGSize) -> CGRect {
        if fullScreenTile == index { return CGRect(origin: .zero, size: screen) }
        // Inside tvOS's safe area, which a television's overscan can trim
        // past, and centred in the space above the control bar.
        let margin: CGFloat = 90
        let gap: CGFloat = 24
        let middle = 60 + (screen.height - 60 - 170) / 2
        switch layout {
        case .sideBySide:
            let width = (screen.width - margin * 2 - gap) / 2
            let height = width * 9 / 16
            return CGRect(x: margin + CGFloat(index) * (width + gap), y: middle - height / 2,
                          width: width, height: height)
        case .bigAndSmall:
            let available = screen.width - margin * 2 - gap
            let bigWidth = (available * 0.72).rounded()
            let bigHeight = bigWidth * 9 / 16
            let top = middle - bigHeight / 2
            if index == bigTile {
                return CGRect(x: margin, y: top, width: bigWidth, height: bigHeight)
            }
            // Level with the middle of the big picture.
            let smallWidth = available - bigWidth
            let smallHeight = smallWidth * 9 / 16
            return CGRect(x: margin + bigWidth + gap, y: top + (bigHeight - smallHeight) / 2,
                          width: smallWidth, height: smallHeight)
        }
    }

    /// The full screen picture over everything. In Big + Small the big one
    /// passes over the small one, so a swap reads as the small picture
    /// coming forward.
    private func zIndex(_ index: Int) -> Double {
        if fullScreenTile == index { return 2 }
        if layout == .bigAndSmall { return index == bigTile ? 1 : 0 }
        return index == audibleTile ? 1 : 0
    }

    // MARK: Actions

    private func begin() {
        PlaybackJournal.shared.note("Split screen: " + primary.name + " and " + secondary.name)
        // Both are being watched: each holds the screen saver off while it
        // plays, and notes what it does under its channel's name.
        players.tiles[0].watched = .splitScreen(primary.name)
        players.tiles[1].watched = .splitScreen(secondary.name)
        for index in 0..<2 {
            let controller = players.tiles[index]
            if let game = index == 0 ? primaryGame : secondaryGame {
                configureGameFailover(controller, game: game, library: library) {
                    choosingChannel = MultiviewChannelChoice(tile: index, game: game)
                }
            }
        }
        // The second picture starts silent and at zero, so its sound has
        // somewhere to fade up from.
        players.tiles[1].fadeAudio(audible: false, over: 0)
        for tile in players.tiles { tile.place = place }
        players.tiles[0].start(urls: primaryURLs, muted: false, channelID: primary.id)
        players.tiles[1].start(urls: secondaryURLs, muted: true, channelID: secondary.id)
        audibleTile = 0
        bigTile = 0
        Task { @MainActor in
            await Task.yield()
            focusedTile = 0
        }
        showChrome()
    }

    /// Selecting a picture: a stream that failed is tried again; in Big +
    /// Small the small picture comes forward; otherwise the picture fills the
    /// screen.
    private func select(_ index: Int) {
        let controller = players.tiles[index]
        if controller.error != nil {
            controller.retry()
            return
        }
        if fullScreenTile != nil { return }
        if layout == .bigAndSmall && index != bigTile {
            swapPictures()
        } else {
            showFullScreen(index)
        }
    }

    private func swapPictures() {
        withAnimation(arrangement) { bigTile = 1 - bigTile }
        showChrome()
    }

    private func choose(_ option: MultiviewLayout) {
        guard option != layout else { return }
        switchLayout()
    }

    private func switchLayout() {
        guard fullScreenTile == nil else { return }
        withAnimation(arrangement) {
            // The game being listened to is the one that becomes big.
            if layout == .sideBySide { bigTile = audibleTile }
            storedLayout = layout.other.rawValue
        }
        showChrome()
    }

    private func showFullScreen(_ index: Int) {
        withAnimation(arrangement) { fullScreenTile = index }
        if focusedTile != index {
            // Focus can only land once the picture is on screen to take it.
            Task { @MainActor in
                await Task.yield()
                focusedTile = index
            }
        }
        showChrome()
    }

    private func leaveFullScreen() {
        withAnimation(arrangement) { fullScreenTile = nil }
        showChrome()
    }

    private func back() {
        if fullScreenTile != nil {
            leaveFullScreen()
        } else {
            PlaybackJournal.shared.note("Split screen closed: Back pressed")
            dismiss()
        }
    }

    /// Hand the sound to a picture: the other's goes out first, and only then
    /// does this one's come in. A crossfade had both playing at once while it
    /// ran, and a stream that reconnected partway through could be left
    /// playing under the other for good.
    private func listen(to index: Int) {
        audibleTile = index
        soundTask?.cancel()
        let heard = players.tiles[index]
        let quiet = players.tiles[1 - index]
        quiet.fadeAudio(audible: false, over: Self.soundOut)
        // Held silent until the other is out -- it may still be on its way
        // out itself, after a quick move there and back.
        heard.fadeAudio(audible: false, over: 0)
        soundTask = Task { @MainActor in
            do { try await Task.sleep(for: .seconds(Self.soundOut + 0.02)) } catch { return }
            heard.fadeAudio(audible: true, over: 0.25)
        }
    }

    private static let soundOut = 0.18

    private func showChrome() {
        withAnimation(.easeOut(duration: 0.25)) { chromeVisible = true }
        chromeTask?.cancel()
        chromeTask = Task { @MainActor in
            do { try await Task.sleep(for: .seconds(4)) } catch { return }
            withAnimation(.easeInOut(duration: 0.5)) { chromeVisible = false }
        }
    }

    // MARK: Labels

    private func stream(_ index: Int) -> XtreamStream { index == 0 ? primary : secondary }

    /// The game as the schedule has it now, so its score stays current while
    /// the session runs.
    private func currentGame(_ index: Int) -> SportsGame? {
        guard let game = index == 0 ? primaryGame : secondaryGame else { return nil }
        return library.games(for: nil).first { $0.id == game.id } ?? game
    }

    /// The bar under the pictures: the two layouts, the arrangement and the
    /// way out. Down from either picture reaches it, and up goes back.
    private var controls: some View {
        VStack(spacing: 14) {
            Label("Move between the games to switch the sound", systemImage: "speaker.wave.2.fill")
                .font(.inter(15, .medium))
                .foregroundStyle(LineupStyle.lightPurple.opacity(0.6))
                .opacity(chromeVisible ? 1 : 0)
            LineupGlassGroup {
            HStack(spacing: 14) {
                ForEach([MultiviewLayout.sideBySide, .bigAndSmall], id: \.self) { option in
                    TVSelectable(scale: LineupStyle.controlLift, drawsFocusChrome: false,
                                 action: { choose(option) }) {
                        MultiviewControlLabel(title: option.title, symbol: option.symbol,
                                              selected: layout == option)
                    }
                }
                Rectangle().fill(LineupStyle.line).frame(width: 1, height: 34).padding(.horizontal, 6)
                if layout == .bigAndSmall {
                    TVSelectable(scale: LineupStyle.controlLift, drawsFocusChrome: false,
                                 action: { swapPictures() }) {
                        MultiviewControlLabel(title: "Swap", symbol: "arrow.left.arrow.right")
                    }
                }
                // The game being listened to, which is the outlined one.
                TVSelectable(scale: LineupStyle.controlLift, drawsFocusChrome: false,
                             action: { showFullScreen(audibleTile) }) {
                    MultiviewControlLabel(title: "Full Screen", symbol: "arrow.up.left.and.arrow.down.right")
                }
                TVSelectable(scale: LineupStyle.controlLift, drawsFocusChrome: false,
                             action: { dismiss() }) {
                    MultiviewControlLabel(title: "Exit", symbol: "xmark")
                }
            }
            .lineupFocusRegion()
            }
        }
    }

    /// Words only, not controls: a game filling the screen has nothing on
    /// top of it to select.
    private var fullScreenHint: some View {
        HStack(spacing: 26) {
            Label("Other game", systemImage: "arrow.left.and.right")
            Label("Back to multiview", systemImage: "arrow.uturn.backward")
        }
        .font(.inter(16, .semibold))
        .foregroundStyle(.white.opacity(0.9))
        .shadow(color: .black.opacity(0.85), radius: 8, y: 2)
    }
}

/// One picture in a multiview session.
///
/// The video is drawn at the size of the whole screen and scaled to the size
/// it is shown at, so moving between a small place, a large one and the
/// full screen never resizes what VLC draws into -- the move is a transform,
/// and the picture plays straight through it.
private struct MultiviewTile: View {
    @ObservedObject var controller: TVPlaybackController
    let game: SportsGame?
    let fallbackTitle: String
    /// A tournament on the channel it shares, by what the channel is
    /// showing (`SportsLibrary.sharedCoverageTitle`).
    let sharedTitle: String?
    let size: CGSize
    let audible: Bool
    let fullScreen: Bool
    let showsLabel: Bool

    var body: some View {
        let radius: CGFloat = fullScreen ? 0 : 14
        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
        TVHostedSurface(controller: controller, fullScreen: true)
            .frame(width: size.width, height: size.height)
            .overlay { MultiviewStatus(controller: controller) }
            .overlay(alignment: .bottomLeading) { label }
            .clipShape(shape)
            // The picture with the sound wears the edge; it is also the one
            // with focus whenever focus is on a picture at all.
            .overlay {
                shape.strokeBorder(Color.white.opacity(audible && !fullScreen ? 0.92 : (fullScreen ? 0 : 0.1)),
                                   lineWidth: audible && !fullScreen ? 3 : 1)
            }
            .shadow(color: .black.opacity(audible && !fullScreen ? 0.55 : 0), radius: 26, y: 12)
            .animation(.easeOut(duration: 0.2), value: audible)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(title + ", " + controller.engineTitle + (audible ? ", playing sound" : ""))
    }

    private var title: String {
        guard let game else { return controller.activeChannelName ?? fallbackTitle }
        // Until failover moves it to another channel.
        if controller.activeChannelName == nil, let sharedTitle { return sharedTitle }
        return liveHeadline(game)
    }

    /// The channel, under a game's score.
    private var detail: String? {
        guard game != nil else { return nil }
        return controller.activeChannelName ?? fallbackTitle
    }

    private var label: some View {
        HStack(spacing: 12) {
            Image(systemName: audible ? "speaker.wave.2.fill" : "speaker.slash.fill")
                .font(.system(size: 16, weight: .semibold, design: .rounded))
                .frame(width: 24)
                .opacity(audible ? 1 : 0.6)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.inter(19, .semibold)).lineLimit(1)
                if let detail {
                    Text(detail).font(.inter(14, .medium)).opacity(0.7).lineLimit(1)
                }
            }
            VStack(alignment: .leading, spacing: 6) {
                TVPlaybackEngineBadge(engine: controller.engineKind)
                PlaybackBadgeFlow {
                    if controller.videoHeight > 0 { PlaybackFormatBadge(text: controller.qualityLabel) }
                    ForEach(controller.mediaInfo.badges, id: \.self) { PlaybackFormatBadge(text: $0) }
                }
            }
            Spacer(minLength: 0)
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 18).padding(.top, 28).padding(.bottom, 14)
        .background {
            LinearGradient(colors: [.clear, .black.opacity(0.78)], startPoint: .top, endPoint: .bottom)
        }
        .opacity(showsLabel ? 1 : 0)
    }
}

/// A picture's own trouble, said on the picture. Nothing in it takes focus:
/// selecting the picture retries a stream that failed, and holding it offers
/// the rest.
private struct MultiviewStatus: View {
    @ObservedObject var controller: TVPlaybackController

    var body: some View {
        if controller.error != nil {
            VStack(spacing: 8) {
                Image(systemName: "exclamationmark.triangle.fill").font(.system(size: 26, weight: .semibold, design: .rounded))
                Text("Stream unavailable").font(.inter(18, .semibold))
                Text("Select to retry  ·  Hold for more").font(.inter(14)).opacity(0.72)
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 24).padding(.vertical, 20)
            .lineupLiquidGlass(RoundedRectangle(cornerRadius: 22, style: .continuous),
                               fallback: Color.black.opacity(0.7), border: .clear)
        } else if controller.reconnecting {
            VStack(spacing: 12) {
                ProgressView()
                Text("Reconnecting…").font(.inter(15, .semibold))
            }
            .foregroundStyle(.white)
            .padding(20)
            .lineupLiquidGlass(RoundedRectangle(cornerRadius: 22, style: .continuous),
                               fallback: Color.black.opacity(0.6), border: .clear)
        } else if let notice = controller.failoverNotice {
            Text(notice).font(.inter(15, .medium)).foregroundStyle(.white)
                .padding(.horizontal, 20).padding(.vertical, 14)
                .lineupLiquidGlass(Capsule(), fallback: Color.black.opacity(0.7), border: .clear)
        } else if !controller.isPlaying {
            ProgressView()
        }
    }
}

/// A control in the multiview bar, in the same dress as the player's own.
private struct MultiviewControlLabel: View {
    @Environment(\.lineupTVSelectableFocused) private var focused
    let title: String
    let symbol: String
    /// The layout in use, which carries a check.
    var selected = false

    var body: some View {
        let shape = Capsule()
        HStack(spacing: 10) {
            Image(systemName: symbol).font(.system(size: 17, weight: .bold, design: .rounded)).frame(width: 22)
            Text(title).font(.inter(18, .semibold)).fixedSize()
            if selected {
                Image(systemName: "checkmark").font(.system(size: 13, weight: .heavy, design: .rounded))
            }
        }
        .foregroundStyle(LineupStyle.lightPurple)
        .padding(.horizontal, 22).frame(height: 52)
        .lineupLiquidGlass(shape, fallback: selected ? LineupStyle.raised : LineupStyle.surface.opacity(0.88),
                           border: selected ? LineupStyle.lightPurple.opacity(0.5) : LineupStyle.line,
                           prominent: selected)
        .lineupFocusLayer(focused, in: shape)
        .lineupShadow(.resting)
    }
}

/// What the player says about a recorded title, in the corner its controls
/// keep for that: what it is, the line under it, and a line of detail.
struct TVPlayerSynopsis {
    let title: String
    let subtitle: String?
    let detail: String?
}

/// The episode after the one playing, offered in the player's last half
/// minute. Choosing it plays it at once, on the best stream there is.
struct TVNextEpisodeOffer {
    /// Its season and number, as S02E05.
    let code: String?
    let title: String
    let play: () -> Void
}

/// One episode of the season playing, in the player's Episodes row.
struct TVEpisodeChoice: Identifiable {
    let id: String
    /// Its season and number, as S3: E5.
    let code: String?
    /// Its length, as 58 min.
    let runtime: String?
    let title: String
    let image: URL?
    let isCurrent: Bool
    let watched: Bool
    /// How far into it the viewer got, from 0 to 1, when it was begun and
    /// not finished.
    let progress: Double?
    /// Plays it at once, on the best stream there is, as Next Episode does.
    let play: () -> Void
}

/// The season playing, for the player's Episodes button: what it is called,
/// and its episodes, fetched as the player opens.
struct TVEpisodeList {
    let season: String?
    let load: @MainActor () async -> [TVEpisodeChoice]
}

/// The Episodes row, while it is up: the season, its episodes as far as they
/// have come, and what choosing one and going Back do.
private struct TVEpisodesShown {
    let season: String?
    let episodes: [TVEpisodeChoice]
    let loading: Bool
    let choose: (TVEpisodeChoice) -> Void
    let close: () -> Void
}

/// The season's episodes in the lower part of the player, in place of the
/// seek bar and buttons, as Apple's own player has them: a grey panel only as
/// tall as its row, running off the right of the screen, each episode on its
/// still with its number, length and name. Select plays one; Back puts the
/// controls back.
private struct TVEpisodesPanel: View {
    let row: TVEpisodesShown
    let focus: FocusState<TVPlayerControl?>.Binding

    /// Inside the panel, before the first still and between stills.
    static let gutter: CGFloat = 30
    /// How far the panel runs past the right of the screen, so it has no
    /// right edge of its own.
    static let overhang: CGFloat = 60

    /// Where the remote lands as the row opens: the episode after the one
    /// playing, else the one playing, else the first.
    static func landing(in episodes: [TVEpisodeChoice]) -> String? {
        guard let current = episodes.firstIndex(where: \.isCurrent) else { return episodes.first?.id }
        return episodes.indices.contains(current + 1) ? episodes[current + 1].id : episodes[current].id
    }

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 30, style: .continuous)
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline, spacing: 16) {
                Text("Episodes").font(.inter(32, .bold)).foregroundStyle(LineupPresentationStyle.text)
                if let season = row.season {
                    Text(season).font(.inter(22, .semibold)).foregroundStyle(LineupPresentationStyle.secondary)
                }
            }
            .padding(.horizontal, Self.gutter + 4).padding(.top, 26)
            if row.episodes.isEmpty {
                // Somewhere for the remote to be while the list comes, or
                // when the server has none to give.
                TVSelectable(scale: LineupStyle.controlLift, action: row.close) {
                    Text(row.loading ? "Finding this season's episodes…" : "No other episodes in this season")
                        .font(.inter(22, .medium)).foregroundStyle(LineupPanelStyle.caption)
                        .padding(.horizontal, 18).frame(height: 60)
                }
                .focused(focus, equals: .episode(""))
                .padding(.horizontal, Self.gutter - 4).padding(.top, 18).padding(.bottom, 30)
            } else {
                ScrollViewReader { proxy in
                    ScrollView(.horizontal, showsIndicators: false) {
                        // The gap sits before each still, inside its id, so
                        // the one scrolled to lands a gap in from the edge
                        // rather than against it.
                        // Not lazy: a season is a couple of dozen at most,
                        // and the one scrolled to must be there to be found.
                        HStack(alignment: .top, spacing: 0) {
                            ForEach(row.episodes) { episode in
                                TVEpisodeTile(episode: episode, focus: focus) { row.choose(episode) }
                                    .padding(.leading, Self.gutter)
                                    .id(episode.id)
                            }
                        }
                        .padding(.trailing, Self.gutter + Self.overhang)
                        // Room for the lift of the one the remote is on.
                        .padding(.top, 22).padding(.bottom, 30)
                    }
                    // Its own height, not all the screen offers: a sideways
                    // scroll view takes every point it is given.
                    .fixedSize(horizontal: false, vertical: true)
                    .onAppear {
                        if let landing = Self.landing(in: row.episodes) { proxy.scrollTo(landing, anchor: .leading) }
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(LineupPresentationStyle.row.opacity(0.94), in: shape)
        .overlay(shape.strokeBorder(Color.white.opacity(0.08), lineWidth: 1))
        .clipShape(shape)
        .padding(.trailing, -Self.overhang)
        .focusSection()
        .onExitCommand(perform: row.close)
    }
}

/// Where the episode playing has got to, over the Episodes row: the time,
/// and a pause mark while it is paused.
private struct TVEpisodesClock: View {
    @ObservedObject var controller: TVPlaybackController
    @ObservedObject var clock: PlaybackClock

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 14) {
            Text(TVSeekBar.clock(clock.elapsed)).font(.interDigits(28, .semibold))
            if !controller.isPlaying {
                Image(systemName: "pause.fill").font(.system(size: 22, weight: .bold, design: .rounded))
            }
            if controller.duration > 0 {
                Text("−" + TVSeekBar.clock(max(0, controller.duration - clock.elapsed)))
                    .font(.interDigits(22, .medium)).opacity(0.66)
            }
        }
        .foregroundStyle(LineupStyle.mediaText)
        .shadow(color: .black.opacity(0.45), radius: 8, y: 2)
    }
}

/// One episode in the row: its still, marked when it is the one playing or
/// one already watched, and its number, length and name under it. The one
/// the remote is on lifts, with a white rim round its still.
private struct TVEpisodeTile: View {
    let episode: TVEpisodeChoice
    let focus: FocusState<TVPlayerControl?>.Binding
    let action: () -> Void

    static let still = CGSize(width: 396, height: 223)

    var body: some View {
        let selected = focus.wrappedValue == .episode(episode.id)
        let shape = RoundedRectangle(cornerRadius: 16, style: .continuous)
        Button(action: action) {
            VStack(alignment: .leading, spacing: 14) {
                ZStack(alignment: .bottom) {
                    LinearGradient(colors: [LineupPresentationStyle.row, LineupPresentationStyle.card],
                                   startPoint: .topLeading, endPoint: .bottomTrailing)
                    LineupArtView(url: episode.image, width: Self.still.width) { loaded in
                        if let loaded { loaded.resizable().scaledToFill() }
                        else {
                            Image(systemName: "film").font(.system(size: 38, weight: .light, design: .rounded))
                                .foregroundStyle(LineupPresentationStyle.secondary)
                        }
                    }
                    if let progress = episode.progress, !episode.isCurrent {
                        LineupProgressBar(value: progress, height: 6, track: .white.opacity(0.28))
                            .padding(.horizontal, 14).padding(.bottom, 14)
                    }
                }
                .frame(width: Self.still.width, height: Self.still.height)
                .clipShape(shape)
                .overlay(shape.strokeBorder(selected ? Color.white : Color.white.opacity(0.1),
                                            lineWidth: selected ? 4 : 1))
                .overlay(alignment: .topLeading) { mark.padding(12) }
                .shadow(color: .black.opacity(selected ? 0.5 : 0), radius: 22, y: 12)
                VStack(alignment: .leading, spacing: 3) {
                    let facts = [episode.code, episode.runtime].compactMap { $0 }
                    if !facts.isEmpty {
                        Text(facts.joined(separator: " · "))
                            .font(.interDigits(21, .semibold)).foregroundStyle(LineupPanelStyle.caption)
                    }
                    Text(episode.title).font(.inter(25, .bold)).foregroundStyle(LineupPresentationStyle.text)
                        .lineLimit(1)
                }
                .padding(.horizontal, 2)
                .frame(width: Self.still.width, alignment: .leading)
            }
            .scaleEffect(selected ? 1.05 : 1)
            .animation(.spring(response: 0.26, dampingFraction: 0.82), value: selected)
        }
        // The tile draws its own focus, so tvOS's plate would sit on top of
        // it as a second, larger highlight.
        .lineupFlatButton().focused(focus, equals: .episode(episode.id)).focusEffectDisabled()
        .accessibilityLabel([episode.code, episode.title, episode.isCurrent ? "playing now" : nil]
            .compactMap { $0 }.joined(separator: ", "))
    }

    @ViewBuilder private var mark: some View {
        if episode.isCurrent {
            Text("NOW PLAYING")
                .font(.inter(14, .heavy)).tracking(0.8)
                .foregroundStyle(LineupPresentationStyle.text)
                .padding(.horizontal, 12).frame(height: 28)
                .background(LineupPresentationStyle.card.opacity(0.9), in: Capsule())
        } else if episode.watched {
            Image(systemName: "checkmark").font(.system(size: 14, weight: .bold, design: .rounded))
                .foregroundStyle(LineupPresentationStyle.ground)
                .frame(width: 30, height: 30)
                .background(LineupStyle.lightPurple, in: Circle())
        }
    }
}

/// Next Episode, in the bottom corner over the picture: a panel with the
/// panels' header, the episode's number and name, and Play Now. The whole
/// card is the button; Back sends it away.
private struct TVNextEpisodeCard: View {
    let offer: TVNextEpisodeOffer
    var focused: FocusState<Bool>.Binding
    let play: () -> Void
    let decline: () -> Void

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: LineupPanelStyle.radius, style: .continuous)
        VStack(alignment: .leading, spacing: 0) {
            LineupPanelHeader("Next Episode", systemImage: "forward.end.fill")
                .padding(.bottom, 14)
            Rectangle().fill(LineupStyle.line).frame(height: 1)
            VStack(alignment: .leading, spacing: 6) {
                if let code = offer.code {
                    Text(code).font(.interDigits(18, .heavy)).tracking(LineupPanelStyle.headerTracking)
                        .foregroundStyle(LineupPanelStyle.quiet)
                }
                Text(offer.title).font(.inter(28, .bold)).foregroundStyle(LineupStyle.text)
                    .lineLimit(2)
            }
            .padding(.top, 16)
            HStack(spacing: 10) {
                Image(systemName: "play.fill").font(.system(size: 20, weight: .bold, design: .rounded))
                Text("Play Now").font(.inter(22, .bold))
            }
            .foregroundStyle(LineupStyle.onHighlight)
            .padding(.horizontal, 26).frame(height: 56)
            .background(LineupStyle.highlight, in: Capsule())
            .padding(.top, 20)
        }
        .padding(LineupPanelStyle.inset)
        .frame(width: 520, alignment: .leading)
        .background(LineupPanelStyle.fill.opacity(0.96), in: shape)
        .lineupFocusLayer(focused.wrappedValue, in: shape)
        .scaleEffect(focused.wrappedValue ? LineupStyle.cardLift : 1)
        .animation(.easeOut(duration: 0.18), value: focused.wrappedValue)
        .contentShape(shape)
        .focusable()
        .focused(focused)
        .focusEffectDisabled()
        .onTapGesture(perform: play)
        .onExitCommand(perform: decline)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Next episode, \(offer.code.map { $0 + ", " } ?? "")\(offer.title)")
        .accessibilityAddTraits(.isButton)
    }
}

/// What Skip does: the end of the recap or the intro the picture is in.
private struct TVSkipAction: Equatable {
    enum Kind: Hashable { case intro, recap }
    let kind: Kind
    let destination: Double
    var title: String { kind == .recap ? "Skip Recap" : "Skip Intro" }
}

/// Skip Intro or Skip Recap, in the bottom corner over the picture: the
/// panels' fill, the icon on its tile, and the words. Select skips; Back
/// sends it away for the rest of that segment.
private struct TVSkipSegmentButton: View {
    let action: TVSkipAction
    var focused: FocusState<Bool>.Binding
    let skip: () -> Void
    let decline: () -> Void

    var body: some View {
        let shape = Capsule()
        HStack(spacing: 14) {
            LineupIconTile(symbol: "forward.end.fill", size: 38)
            Text(action.title).font(.inter(24, .bold)).foregroundStyle(LineupStyle.text)
        }
        .padding(.leading, 12).padding(.trailing, 30)
        .frame(height: 66)
        .background(LineupPanelStyle.fill.opacity(0.96), in: shape)
        .overlay(shape.strokeBorder(Color.white.opacity(0.08), lineWidth: 1))
        .lineupFocusLayer(focused.wrappedValue, in: shape)
        .scaleEffect(focused.wrappedValue ? LineupStyle.cardLift : 1)
        .animation(.easeOut(duration: 0.18), value: focused.wrappedValue)
        .contentShape(shape)
        .focusable()
        .focused(focused)
        .focusEffectDisabled()
        .onTapGesture(perform: skip)
        .onExitCommand(perform: decline)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(action.title)
        .accessibilityAddTraits(.isButton)
    }
}

/// A film's credits, with a scene after them: said in the corner, and
/// gone when the scene begins.
private struct TVPostCreditsNotice: View {
    var body: some View {
        let shape = Capsule()
        HStack(spacing: 12) {
            LineupIconTile(symbol: "film.stack", size: 32)
            Text("Post-credit scene ahead").font(.inter(20, .semibold)).foregroundStyle(LineupStyle.text)
        }
        .padding(.leading, 10).padding(.trailing, 24)
        .frame(height: 54)
        .background(LineupPanelStyle.fill.opacity(0.94), in: shape)
        .overlay(shape.strokeBorder(Color.white.opacity(0.08), lineWidth: 1))
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.updatesFrequently)
    }
}

private struct TVPlaybackPlaceKey: EnvironmentKey {
    static let defaultValue: TVPlaybackPlace = .library
}

extension EnvironmentValues {
    /// The tab a player is opened in, for that tab's playback engine. Each
    /// tab says which it is; a title's streams are opened by the same screen
    /// from the Library, Search and Settings, so this is how it knows.
    var tvPlaybackPlace: TVPlaybackPlace {
        get { self[TVPlaybackPlaceKey.self] }
        set { self[TVPlaybackPlaceKey.self] = newValue }
    }
}

struct PlayerView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(SportsLibrary.self) private var library
    /// The tab it was opened from, whose engine it plays with.
    @Environment(\.tvPlaybackPlace) private var place
    let urls: [URL]
    var title: String = "Live TV"
    var program: CurrentProgram? = nil
    var isLive = true
    var initialPosition: TimeInterval? = nil
    var expectedDuration: TimeInterval? = nil
    var nativeSiloPlayback: SiloPlaybackSession? = nil
    var onProgress: ((TimeInterval, TimeInterval) -> Void)? = nil
    var onTrackingSample: ((LibraryPlaybackSample) -> Void)? = nil
    var game: SportsGame? = nil
    var channelID: Int? = nil
    /// For a Library title: its show, episode and details, which the stream
    /// URL and name alone cannot say.
    var synopsis: TVPlayerSynopsis? = nil
    /// The channels Up and Down step through, in the order the screen it
    /// was opened from lists them. Empty: Up and Down just bring up the
    /// controls.
    var lineup: [XtreamStream] = []
    /// Told when the viewer moves to another channel, so the screen beneath
    /// can show that channel when full screen closes.
    var onChannelChange: ((XtreamStream) -> Void)? = nil
    /// An episode's next one, offered in the last half minute.
    var nextEpisode: TVNextEpisodeOffer? = nil
    /// Told when the title played to its end, before the player closes, so
    /// the screen beneath can lead on from it.
    var onReachedEnd: (() -> Void)? = nil
    /// A Library title's intro, recap and credits from IntroDB, as the
    /// phone's player has them.
    var segmentsLookup: (() async -> MobilePlaybackSegments?)? = nil
    /// A Library title as OpenSubtitles knows it, for Find Subtitles Online.
    var subtitleIdentityLookup: (() async -> MobileSubtitleIdentity?)? = nil
    /// An episode's show: its sound and subtitles are kept for the next one.
    var trackMemoryShow: String? = nil
    /// The server's scrubbing thumbnails for the copy playing, where it
    /// has them.
    var seekPreviewLookup: (() async -> MobileSeekPreviewSource?)? = nil
    /// An episode's season, for the Episodes button.
    var episodeList: TVEpisodeList? = nil
    /// The season's episodes, once fetched.
    @State private var episodeChoices: [TVEpisodeChoice] = []
    @State private var episodesLoaded = false
    /// The Episodes row is up in place of the seek bar and buttons.
    @State private var episodesShown = false
    @State private var findingSubtitles = false
    @State private var subtitleSettingsShown = false
    @State private var onlineSubtitleSession = UUID()
    /// Holds the thumbnails without the player redrawing for each one: only
    /// the seek bar watches them.
    @StateObject private var seekPreview = MobileSeekPreviewSession()
    @StateObject private var controller: TVPlaybackController
    @ObservedObject private var alerts = GameAlertCenter.shared
    /// The channel on screen, which Up and Down change.
    @State private var currentChannel: XtreamStream?
    /// The channel before it, for Last Channel.
    @State private var previousChannel: XtreamStream?
    /// What the guide says is on the channel on screen.
    @State private var channelProgram: CurrentProgram?
    /// The game being watched, which an alert about it would be no news of.
    @State private var watchingGame: SportsGame?
    /// A game recovered from exact, current channel evidence when playback was
    /// opened from the Guide without a Sports-tab event attached.
    @State private var channelStatsGame: SportsGame?
    @State private var statsResolvedChannelID: Int?
    /// The channel just moved to, named for a moment over the picture.
    @State private var channelBanner: XtreamStream?
    @State private var bannerTask: Task<Void, Never>?
    /// The viewer has moved off the channel full screen opened on. A
    /// preview's player isn't given back playing someone else's channel.
    @State private var channelChanged = false
    /// Opened on a recording or from the programme's start rather than
    /// live; each is acted on once, when the channel's recording is ready.
    @State private var openingRecording: CatchUpProgramme?
    @State private var openingStartOver: Bool
    /// The preview's player, already playing, rather than one of its own.
    /// It is not opened here, and closing full screen gives it back to the
    /// preview still playing rather than stopping it.
    @State private var continuesPreview: Bool
    /// What the preview does when its channel fails, put back with it.
    @State private var previewFailover: TVPlaybackController.FailoverContext? = nil
    @State private var choosingGame: SportsGame? = nil
    @State private var pickedChannel: TVPickedChannel? = nil
    @State private var scopingChannel: TVPickedChannel? = nil
    @State private var chosenTitle: String? = nil
    @State private var controlsVisible = true
    @State private var hideControlsTask: Task<Void, Never>? = nil
    /// A subtitle, audio, video or quality list is open. The controls stay up
    /// until it closes: the lists hang off the controls, so hiding them on the
    /// usual timer closed a list before anything could be chosen in it.
    @State private var chooserOpen = false
    @FocusState private var focusedControl: TVPlayerControl?
    @FocusState private var surfaceFocused: Bool
    /// In the last half minute of an episode with one after it.
    @State private var nextEpisodeDue = false
    /// The viewer pressed Back on Next Episode: it stays away.
    @State private var nextEpisodeDeclined = false
    @FocusState private var nextEpisodeFocused: Bool
    /// The title's intro, recap and credits, once IntroDB has answered.
    @State private var segments: MobilePlaybackSegments?
    /// Skip Intro or Skip Recap, while the picture is inside one.
    @State private var skipAction: TVSkipAction?
    /// The segments the viewer pressed Back on: their prompts stay away.
    @State private var declinedSkips: Set<TVSkipAction.Kind> = []
    @FocusState private var skipFocused: Bool
    /// The credits of a film with a scene after them.
    @State private var postCreditsAhead = false
    @AppStorage("Lineup.library.introDB.v1") private var introEnabled = true
    @AppStorage("Lineup.library.skipRecaps.v1") private var recapEnabled = true
    @AppStorage("Lineup.library.creditsPrompt.v1") private var creditsEnabled = true
    @AppStorage("Lineup.library.postCreditsNotice.v1") private var postCreditsEnabled = true
    @State private var lastReportedPosition: TimeInterval = 0
    /// A replay: the recording or nothing. Without a recording to play it
    /// says so, rather than going to the channel live.
    var recordingOnly = false
    /// The player is closing because the viewer or the film said so. Any other
    /// way of going -- the screens around it torn down -- is noted in the log
    /// as such, because that is the one nobody asked for.
    @State private var closing = false
    /// The live stats beside the picture, for a game ESPN keeps an account
    /// of, and the scoreboard reading that keeps them in step.
    @StateObject private var gameStats = MobileGameStats()
    @StateObject private var autoSync = MobileAutoSync()
    /// Open from one game to the next, until the viewer closes them.
    @AppStorage("Lineup.tv.liveStats.v1") private var statsWanted = false
    /// The remote on the stats' sync chip, as it comes into the panel.
    @FocusState private var statsEntryFocused: Bool

    init(urls: [URL], title: String = "Live TV", program: CurrentProgram? = nil, isLive: Bool = true,
         initialPosition: TimeInterval? = nil, expectedDuration: TimeInterval? = nil,
         nativeSiloPlayback: SiloPlaybackSession? = nil,
         onProgress: ((TimeInterval, TimeInterval) -> Void)? = nil,
         onTrackingSample: ((LibraryPlaybackSample) -> Void)? = nil,
         game: SportsGame? = nil, channelID: Int? = nil, synopsis: TVPlayerSynopsis? = nil,
         channel: XtreamStream? = nil, lineup: [XtreamStream] = [],
         recording: CatchUpProgramme? = nil, startsOver: Bool = false, recordingOnly: Bool = false,
         onChannelChange: ((XtreamStream) -> Void)? = nil,
         nextEpisode: TVNextEpisodeOffer? = nil, onReachedEnd: (() -> Void)? = nil,
         segmentsLookup: (() async -> MobilePlaybackSegments?)? = nil,
         subtitleIdentityLookup: (() async -> MobileSubtitleIdentity?)? = nil,
         trackMemoryShow: String? = nil,
         seekPreviewLookup: (() async -> MobileSeekPreviewSource?)? = nil,
         episodes: TVEpisodeList? = nil,
         continuing preview: TVPreviewHandoff? = nil, playbackController: TVPlaybackController? = nil) {
        self.urls = urls
        self.title = title
        self.program = program
        self.isLive = isLive
        self.initialPosition = initialPosition
        self.expectedDuration = expectedDuration
        self.nativeSiloPlayback = nativeSiloPlayback
        self.onProgress = onProgress
        self.onTrackingSample = onTrackingSample
        self.game = game
        self.channelID = channelID
        self.synopsis = synopsis
        self.lineup = lineup
        self.onChannelChange = onChannelChange
        self.nextEpisode = nextEpisode
        self.onReachedEnd = onReachedEnd
        self.segmentsLookup = segmentsLookup
        self.subtitleIdentityLookup = subtitleIdentityLookup
        self.trackMemoryShow = trackMemoryShow
        self.seekPreviewLookup = seekPreviewLookup
        self.episodeList = episodes
        self.recordingOnly = recordingOnly
        _controller = StateObject(wrappedValue: preview?.controller ?? playbackController ?? TVPlaybackController())
        _continuesPreview = State(initialValue: preview != nil)
        _currentChannel = State(initialValue: channel)
        _channelProgram = State(initialValue: program)
        _watchingGame = State(initialValue: game)
        _openingRecording = State(initialValue: recording)
        _openingStartOver = State(initialValue: startsOver)
    }

    /// An alert about a game other than the one being watched.
    private var visibleAlert: GameAlert? {
        guard isLive, let alert = alerts.current, alert.game.id != watchingGame?.id else { return nil }
        return alert
    }

    /// The channel Last Channel goes back to: the one before this in full
    /// screen, else the last one watched anywhere.
    private var lastChannel: XtreamStream? {
        guard isLive else { return nil }
        if let previousChannel, previousChannel.id != currentChannel?.id { return previousChannel }
        return library.recentStreams.first { $0.id != currentChannel?.id }
    }

    /// The game the stats can follow: one ESPN keeps an account of, on a
    /// channel. Guide playback has no event context, so it may use the unique
    /// live event that the current channel is verified to carry.
    private var statsGame: SportsGame? {
        guard isLive else { return nil }
        if let watchingGame, MobileGameStats.supports(watchingGame) { return watchingGame }
        guard watchingGame == nil, statsResolvedChannelID == currentChannel?.id else { return nil }
        return channelStatsGame
    }
    private var statsResolutionKey: String {
        "\(currentChannel?.id ?? -1)|\(watchingGame?.id ?? "")|\(library.gamesRevision)|\(library.guideRevision)|\(library.activeProfile?.id.uuidString ?? "")"
    }
    private var statsShown: Bool { statsWanted && statsGame != nil }
    /// The room the stats take from the right of the screen. The picture,
    /// the controls and anything over them keep the rest.
    private var statsInset: CGFloat { statsShown ? TVGameStatsPanel.width : 0 }
    private var statsChannelID: Int? { currentChannel?.id ?? channelID }
    private var statsFollowKey: String { "\(statsGame?.id ?? "")|\(statsChannelID ?? -1)" }
    private var autoSyncKey: String { statsFollowKey + "|\(statsShown)|\(autoSync.isEnabled)" }

    var body: some View {
        ZStack {
            // Narrowed by a value, never by a modifier that comes and goes:
            // the surface keeps its identity, and VLC its drawable.
            TVHostedSurface(controller: controller, fullScreen: true)
                .overlay { TVPlaybackStatus(controller: controller) }
                .padding(.trailing, statsInset)
                .background(Color.black).ignoresSafeArea()
            // Hiding the chrome removes every focusable view, and the remote
            // only reaches a view that holds focus, so this stands in for it
            // and summons the chrome back on any press.
            //
            // It is a sibling of the video rather than a set of modifiers on
            // their shared container. A modifier that comes and goes gives the
            // container a new identity, which rebuilds the video surface with
            // it, and a rebuilt surface loses the drawable VLC is decoding
            // into: the picture stops while the audio carries on. Siblings
            // appear and disappear without disturbing the surface, which is
            // why the chrome itself has always been safe to toggle.
            //
            // Nothing consumes a direction while the chrome is up either, so
            // focus can move between the seek bar and the buttons.
            //
            // With the controls away, Up and Down change channel, Left and
            // Right step back and on through a channel the provider records,
            // and Select answers an alert when one is up.
            if !controlsVisible {
                Color.clear
                    .contentShape(Rectangle())
                    .focusable()
                    .focused($surfaceFocused)
                    .onMoveCommand(perform: moveWithControlsHidden)
                    .onTapGesture {
                        if let alert = visibleAlert { watch(alert.game) } else { revealControls(focus: true) }
                    }
                    .padding(.trailing, statsInset)
            }
            if controlsVisible && controller.error == nil {
                TVPlayerChrome(title: controller.activeChannelName ?? chosenTitle ?? title,
                    program: channelProgram, synopsis: synopsis, isLive: isLive, controller: controller,
                    focusedControl: $focusedControl, lastChannelName: lastChannel?.name,
                    alert: visibleAlert, onInteraction: keepControlsVisible,
                    onChooserChange: chooserChanged,
                    onLastChannel: { if let lastChannel { tune(lastChannel) } },
                    onWatchAlert: { if let alert = visibleAlert { watch(alert.game) } },
                    onChooseChannel: chooseChannelAction,
                    statsShown: statsShown,
                    onToggleStats: statsGame == nil ? nil : toggleStats,
                    onFindSubtitles: findSubtitlesAction,
                    onSubtitleSettings: isLive ? nil : { subtitleSettingsShown = true },
                    seekPreview: seekPreview.store,
                    onShowEpisodes: showsEpisodesButton ? showEpisodes : nil,
                    episodes: episodesShown
                        ? TVEpisodesShown(season: episodeList?.season, episodes: episodeChoices,
                                          loading: !episodesLoaded, choose: chooseEpisode, close: closeEpisodes)
                        : nil)
                    .padding(.trailing, statsInset)
                    .transition(.opacity)
            }
            if statsShown, let statsGame {
                TVGameStatsPanel(stats: gameStats, autoSync: autoSync, game: statsGame,
                                 entry: $statsEntryFocused, onClose: closeStats)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .trailing)
                    .ignoresSafeArea()
                    .transition(.move(edge: .trailing))
            }
            if !controlsVisible, let channelBanner {
                TVChannelBanner(stream: channelBanner, program: channelProgram)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    .padding(.horizontal, 72).padding(.top, 56)
                    .allowsHitTesting(false)
                    .transition(.opacity)
            }
            if let alert = visibleAlert {
                TVGameAlertBanner(alert: alert, selectWatches: !controlsVisible)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
                    .padding(.leading, 72).padding(.trailing, 72 + statsInset).padding(.top, 56)
                    .allowsHitTesting(false)
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
            if showsNextEpisode, let nextEpisode {
                TVNextEpisodeCard(offer: nextEpisode, focused: $nextEpisodeFocused,
                                  play: { playNext(nextEpisode) },
                                  decline: declineNextEpisode)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
                    .padding(.trailing, 80).padding(.bottom, 72)
                    .transition(.opacity.combined(with: .move(edge: .trailing)))
            }
            if let skipAction, showsSkip {
                TVSkipSegmentButton(action: skipAction, focused: $skipFocused,
                                    skip: { skip(skipAction) },
                                    decline: { declineSkip(skipAction) })
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
                    // Above the seek bar and buttons while they are up.
                    .padding(.trailing, 80).padding(.bottom, controlsVisible ? 360 : 72)
                    .transition(.opacity.combined(with: .move(edge: .trailing)))
            }
            if postCreditsAhead && controller.error == nil && !controller.isScrubbing {
                TVPostCreditsNotice()
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
                    .padding(.trailing, 80).padding(.top, 56)
                    .allowsHitTesting(false)
                    .transition(.opacity)
            }
            if urls.isEmpty {
                Text("This stream is unavailable").font(.inter(.title2))
                    .foregroundStyle(LineupStyle.mediaText).padding(60)
            }
        }
        .background(Color.black)
        .lineupFullScreenCover(item: $choosingGame, onDismiss: {
            scopingChannel = library.asksScope(for: pickedChannel)
            pickedChannel = nil
        }) { game in
            ManualGameChannelPicker(game: game) { chosen in
                library.saveGameSelection(chosen, for: game)
                pickedChannel = TVPickedChannel(game: game, stream: chosen, startsMultiview: false)
                choosingGame = nil
                tune(chosen, for: game)
            }
        }
        .channelScopePrompt($scopingChannel)
        .onPlayPauseCommand { controller.togglePlayback(); revealControls() }
        // Back clears the controls first, as Apple's own player does, and
        // closes the player from there. One press used to end the film even
        // when it was only meant to clear the screen.
        .onExitCommand {
            if episodesShown {
                closeEpisodes()
            } else if controlsVisible && controller.error == nil {
                hideControls()
            } else {
                close(because: "Back pressed")
            }
        }
        .onAppear {
            if continuesPreview { previewFailover = controller.failover }
            controller.libraryTrackingEvent = onTrackingSample
            controller.configureSiloPlayback(nativeSiloPlayback)
            if let game {
                configureGameFailover(controller, game: game, library: library) { choosingGame = game }
            }
            controller.watched = .fullScreen
            // Nothing plays under full screen but its own player: two would
            // be two sounds at once.
            TVPreviewHandoff.stopPreviews(except: controller)
            // Its tab's engine, before anything opens on it. A preview's own
            // player already has its tab.
            if !continuesPreview { controller.place = place }
            if continuesPreview && controller.isOpen {
                PlaybackJournal.shared.note(openingNote + ", carried on from the preview")
            } else if openingRecording != nil || openingStartOver {
                // Opened by the task below, once the channel's recording can
                // be addressed.
                PlaybackJournal.shared.note(openingNote)
            } else {
                PlaybackJournal.shared.note(openingNote)
                controller.remembersTracks(forShow: isLive ? nil : trackMemoryShow)
                controller.start(urls: urls, initialPosition: isLive ? nil : initialPosition,
                                 channelID: channelID, isLive: isLive, expectedDuration: expectedDuration)
            }
            if isLive, let currentChannel { library.recordRecentChannel(currentChannel) }
            if continuesPreview { controller.lentToFullScreen = true }
            revealControls(focus: true)
        }
        .onDisappear {
            if !closing {
                PlaybackJournal.shared.note("Closed by the app, not by Back or the end of the title"
                    + (isLive ? "" : " (at \(PlaybackJournal.clock(controller.elapsed)))"))
            }
            controller.finishScrubbing(resume: false)
            reportProgress(force: true)
            hideControlsTask?.cancel()
            bannerTask?.cancel()
            autoSync.stop()
            gameStats.stop()
            seekPreview.store.cancel()
            finishPlayback()
        }
        .lineupFullScreenCover(isPresented: $findingSubtitles, onDismiss: { revealControls(focus: true, on: .subtitles) }) {
            if let subtitleIdentityLookup {
                TVOnlineSubtitlesScreen(name: synopsis?.title ?? title, identity: subtitleIdentityLookup) { data, subtitle in
                    try await controller.addOnlineSubtitle(data, title: subtitle.title, language: subtitle.language,
                                                           session: onlineSubtitleSession)
                }
            }
        }
        .lineupFullScreenCover(isPresented: $subtitleSettingsShown, onDismiss: { revealControls(focus: true, on: .subtitles) }) {
            TVSubtitleSettingsScreen(controller: controller)
        }
        // The server's thumbnails for this copy, as the phone's player asks.
        .task(id: urls) {
            seekPreview.store.configure(nil)
            guard !isLive, let seekPreviewLookup else { return }
            let source = await seekPreviewLookup()
            guard !Task.isCancelled else { return }
            seekPreview.store.configure(source)
        }
        // The stats follow the game on screen from the moment it opens,
        // shown or not, so what the picture needs is there when they are.
        .task(id: statsFollowKey) { followStats() }
        .task(id: statsResolutionKey) { resolveChannelStatsGame() }
        // Auto Sync reads the scoreboard while the stats are open beside a
        // game, from whichever engine is playing it.
        .task(id: autoSyncKey) {
            guard statsShown, autoSync.isEnabled else { autoSync.stop(); return }
            // Following first: Auto Sync reads the game the stats follow.
            followStats()
            let player = controller
            autoSync.run(for: gameStats, channel: statsChannelID,
                         frames: { [weak player] in await player?.captureFrame() },
                         release: { [weak player] in player?.releaseFrameOutput() })
        }
        // Gone with the game -- another channel, or one with no account --
        // the panel leaves the remote on the picture.
        .onChange(of: statsShown) { _, shown in
            if !shown, !controlsVisible { surfaceFocused = true }
        }
        // The channel's recording, once the server's time zone is known:
        // Start Over, rewinding, and pausing live all need it.
        .task(id: currentChannel?.id) {
            guard isLive, let stream = currentChannel else { return }
            let source = await library.catchUpSource(for: stream)
            guard currentChannel?.id == stream.id else { return }
            controller.catchUpSource = source
            if let recording = openingRecording {
                openingRecording = nil
                if source != nil {
                    controller.playRecording(of: recording)
                } else if recordingOnly {
                    controller.unavailable("This recording can't be opened from your provider right now.")
                } else {
                    startLive(stream)
                }
            } else if openingStartOver {
                openingStartOver = false
                if controller.canStartOver { controller.startOver() } else { startLive(stream) }
            }
        }
        // Scores kept fresh while a channel plays, wherever it was opened
        // from, so an alert can say when one of the viewer's teams' games
        // needs watching.
        .task(id: isLive) {
            guard isLive else { return }
            while !Task.isCancelled {
                library.refreshSchedule(includeTomorrow: false)
                do { try await Task.sleep(for: .seconds(45)) } catch { return }
            }
        }
        .onReceive(controller.clock.$elapsed) { position in
            reportProgress(at: position)
            updateNextEpisode(at: position)
            updateSegments(at: position)
        }
        // The season's episodes, fetched as the player opens so the
        // Episodes row is full the moment it is asked for.
        .task(id: urls) {
            episodeChoices = []
            episodesLoaded = false
            guard !isLive, let episodeList else { return }
            let found = await episodeList.load()
            guard !Task.isCancelled else { return }
            episodeChoices = found
            episodesLoaded = true
        }
        .animation(.easeInOut(duration: 0.28), value: episodesShown)
        // IntroDB's answer for this title; nothing is shown until it comes.
        .task(id: urls) {
            segments = nil
            guard !isLive, let segmentsLookup else { return }
            let found = await segmentsLookup()
            guard !Task.isCancelled else { return }
            segments = found
        }
        // Skip takes the remote when it appears over a bare picture, so one
        // press of Select skips; with the controls up it waits above them.
        .onChange(of: showsSkip) { _, shown in
            if shown, !controlsVisible { skipFocused = true }
            else if !shown, skipFocused { surfaceFocused = true }
        }
        .animation(.easeInOut(duration: 0.3), value: showsSkip)
        .animation(.easeInOut(duration: 0.3), value: postCreditsAhead)
        // A film or an episode played to its end is saved as watched and the
        // player closes, as it would on the remote's Menu button; the screen
        // beneath is told first, so it can lead on to what comes next.
        .onChange(of: controller.finished) { _, finished in
            guard finished else { return }
            onReachedEnd?()
            close(because: "Reached the end")
        }
        // Next Episode takes the remote when it appears over the picture, so
        // one press of Select plays it.
        .onChange(of: showsNextEpisode) { _, shown in
            if shown { nextEpisodeFocused = true }
        }
        .animation(.easeInOut(duration: 0.3), value: showsNextEpisode)
        .onChange(of: controller.isPlaying) { _, playing in
            if playing { scheduleAutoHide() }
            else { hideControlsTask?.cancel(); controlsVisible = true }
        }
        // Moving from one control to the next is using the controls. The
        // countdown used to run from when they appeared, so they went away
        // under a viewer still looking through them.
        .onChange(of: focusedControl) { _, control in
            if control != nil, controlsVisible { scheduleAutoHide() }
        }
        .animation(.easeInOut(duration: 0.22), value: controlsVisible)
        .animation(.easeInOut(duration: 0.3), value: statsShown)
        .animation(.easeInOut(duration: 0.22), value: channelBanner?.id)
        .animation(.easeInOut(duration: 0.3), value: visibleAlert?.id)
    }

    private func revealControls(focus: Bool = false, on control: TVPlayerControl? = nil) {
        controlsVisible = true
        if focus {
            let destination = control ?? (showsEpisodesButton ? .episodes : .goLive)
            Task { @MainActor in await Task.yield(); focusedControl = destination }
        }
        scheduleAutoHide()
    }

    /// A press while the controls are away. Up and Down move through the
    /// channels in the order of the screen full screen came from; Left and
    /// Right step back and on through a recorded channel and bring up its
    /// timeline. Anything else brings up the controls.
    private func moveWithControlsHidden(_ direction: MoveCommandDirection) {
        switch direction {
        case .up where !lineup.isEmpty:
            flip(by: -1)
        case .down where !lineup.isEmpty:
            flip(by: 1)
        case .left where isLive && controller.catchUpSource != nil:
            controller.skip(by: -CatchUpPolicy.skip)
            revealControls(focus: true, on: .scrubber)
        case .right where isLive && controller.catchUp != nil:
            controller.skip(by: CatchUpPolicy.skip)
            revealControls(focus: true, on: .scrubber)
        case .right where statsShown:
            // Into the stats beside the picture.
            statsEntryFocused = true
        default:
            revealControls(focus: true)
        }
    }

    /// The next or previous channel in the list, round from the end to the
    /// start. A channel not in the list starts from the top of it.
    private func flip(by step: Int) {
        guard !lineup.isEmpty else { return }
        let index = lineup.firstIndex { $0.id == currentChannel?.id }
        let next: Int
        if let index {
            next = (index + step + lineup.count) % lineup.count
        } else {
            next = step > 0 ? 0 : lineup.count - 1
        }
        tune(lineup[next])
    }

    /// Changes the channel in place: the same player, the controls left as
    /// they are, the channel named over the picture for a moment.
    private func tune(_ stream: XtreamStream, for game: SportsGame? = nil) {
        guard stream.id != currentChannel?.id || game != nil else { return }
        if let currentChannel, currentChannel.id != stream.id { previousChannel = currentChannel }
        currentChannel = stream
        channelChanged = true
        watchingGame = game
        chosenTitle = stream.name
        channelProgram = library.guidePrograms(for: stream).normalizedEPG().first { $0.isLive }
        controller.catchUpSource = nil
        controller.failover = nil
        if let game {
            configureGameFailover(controller, game: game, library: library) { choosingGame = game }
        }
        PlaybackJournal.shared.note("Changed channel to " + stream.name)
        startLive(stream)
        library.recordRecentChannel(stream)
        onChannelChange?(stream)
        showChannelBanner(stream)
    }

    private func startLive(_ stream: XtreamStream) {
        controller.start(urls: library.playbackURLs(for: stream), muted: controller.isMuted,
                         channelID: stream.id, isLive: true)
    }

    /// One of the viewer's teams' games, from an alert: on its channel, or
    /// the channel list to choose one when it has none.
    /// Offered while a game is on screen: another channel for it.
    private var chooseChannelAction: (() -> Void)? {
        guard isLive, let game = watchingGame else { return nil }
        return { choosingGame = game }
    }

    private func watch(_ game: SportsGame) {
        alerts.dismiss()
        guard case let .play(streamID, _) = library.preferredChannel(for: game),
              let stream = library.stream(withID: streamID) else {
            choosingGame = game
            return
        }
        tune(stream, for: game)
    }

    private func showChannelBanner(_ stream: XtreamStream) {
        channelBanner = stream
        bannerTask?.cancel()
        bannerTask = Task { @MainActor in
            do { try await Task.sleep(for: .seconds(3)) } catch { return }
            if channelBanner?.id == stream.id { channelBanner = nil }
        }
    }

    /// The controls cleared at once, with focus handed to the picture so the
    /// next press has somewhere to land, as when they time out.
    private func hideControls() {
        hideControlsTask?.cancel()
        let inChrome = focusedControl != nil
        controlsVisible = false
        Task { @MainActor in
            await Task.yield()
            // The remote in the stats stays there as the controls go.
            if inChrome || !statsShown { focusPicture() }
        }
    }

    /// Where the remote lands as the controls go: Skip when it is up, so
    /// one press skips, else the picture itself.
    private func focusPicture() {
        if showsSkip { skipFocused = true } else { surfaceFocused = true }
    }

    /// The stats on the game on screen, on the channel it is on, held behind
    /// the picture by however far the viewer has paused or rewound it.
    private func followStats() {
        let player = controller
        gameStats.playerLag = { [weak player] in player?.secondsBehindLive ?? 0 }
        gameStats.follow(statsGame, channelID: statsChannelID)
    }

    /// Recover stats context for a live channel opened from the Guide. A
    /// provider/channel name alone is insufficient; only SportsLibrary's
    /// current verified game match is accepted, and ambiguous broadcasts stay
    /// without a stats button rather than showing another event's data.
    private func resolveChannelStatsGame() {
        guard isLive, watchingGame == nil, let currentChannel else {
            channelStatsGame = nil
            statsResolvedChannelID = currentChannel?.id
            return
        }
        let candidates = library.games(for: nil).filter { candidate in
            candidate.isLive && MobileGameStats.supports(candidate)
                && library.isStream(currentChannel, verifiedFor: candidate)
        }
        channelStatsGame = LiveStatsGameSelection.uniqueVerifiedGame(from: candidates)
        statsResolvedChannelID = currentChannel.id
    }

    /// Find Subtitles Online, where the title is one OpenSubtitles can be
    /// asked about and the engine can take a file.
    private var findSubtitlesAction: (() -> Void)? {
        guard !isLive, subtitleIdentityLookup != nil, MobileOpenSubtitles.configured,
              controller.canAttachOnlineSubtitles else { return nil }
        return {
            onlineSubtitleSession = controller.subtitleSession
            findingSubtitles = true
        }
    }

    /// Stats from the controls: open, with the remote in them, or closed.
    private func toggleStats() {
        if statsShown { closeStats(); return }
        statsWanted = true
        PlaybackJournal.shared.note("Live stats opened")
        Task { @MainActor in await Task.yield(); statsEntryFocused = true }
    }

    private func closeStats() {
        statsWanted = false
        PlaybackJournal.shared.note("Live stats closed")
        if controlsVisible { focusedControl = .stats } else { surfaceFocused = true }
    }

    /// Next Episode is up: the last half minute of an episode with one after
    /// it, with the controls away. They share the bottom of the screen, so
    /// the card waits while the viewer is using them.
    private var showsNextEpisode: Bool {
        nextEpisode != nil && nextEpisodeDue && !nextEpisodeDeclined && !controlsVisible
            && controller.error == nil
    }

    private func updateNextEpisode(at position: TimeInterval) {
        guard nextEpisode != nil, !isLive else { return }
        let duration = controller.duration
        // From the credits when IntroDB knows where they start, as on the
        // phone; otherwise the last half minute.
        let due = position < duration
            && (segments ?? MobilePlaybackSegments()).offersNext(at: position, duration: duration,
                                                                 creditsEnabled: creditsEnabled)
        if due != nextEpisodeDue { nextEpisodeDue = due }
    }

    /// Skip Intro or Skip Recap while the picture is inside one, and the
    /// post-credits notice while a film's credits run.
    private func updateSegments(at position: TimeInterval) {
        let duration = controller.duration
        var action: TVSkipAction?
        if !isLive, let segments, duration > 0 {
            if recapEnabled, let to = segments.recap?.destination(at: position, duration: duration) {
                action = TVSkipAction(kind: .recap, destination: to)
            } else if introEnabled, let to = segments.intro?.destination(at: position, duration: duration) {
                action = TVSkipAction(kind: .intro, destination: to)
            }
        }
        if action != skipAction { skipAction = action }
        let credits = !isLive && postCreditsEnabled
            && segments?.hasPostCreditsAhead(at: position, duration: duration) == true
        if credits != postCreditsAhead { postCreditsAhead = credits }
    }

    /// Skip is up: inside an intro or recap the viewer hasn't sent away,
    /// while nothing else holds the bottom corner.
    private var showsSkip: Bool {
        guard let skipAction else { return false }
        return !declinedSkips.contains(skipAction.kind) && controller.error == nil
            && !controller.isScrubbing && !showsNextEpisode
    }

    private func skip(_ action: TVSkipAction) {
        PlaybackJournal.shared.note(action.title + " to " + PlaybackJournal.clock(action.destination))
        controller.seek(to: action.destination)
        skipAction = nil
        surfaceFocused = true
    }

    private func declineSkip(_ action: TVSkipAction) {
        declinedSkips.insert(action.kind)
        surfaceFocused = true
    }

    private func playNext(_ offer: TVNextEpisodeOffer) {
        offer.play()
        close(because: "Next episode")
    }

    /// Episodes, while there is a season to show: until the list has come,
    /// and then only with an episode in it besides this one.
    private var showsEpisodesButton: Bool {
        !isLive && episodeList != nil && (!episodesLoaded || episodeChoices.contains { !$0.isCurrent })
    }

    /// The row in place of the seek bar and buttons, with the remote on the
    /// episode after this one. The controls stay up while it is.
    private func showEpisodes() {
        episodesShown = true
        chooserChanged(true)
        PlaybackJournal.shared.note("Episodes opened")
        let landing = TVEpisodesPanel.landing(in: episodeChoices).map(TVPlayerControl.episode) ?? .episode("")
        Task { @MainActor in await Task.yield(); focusedControl = landing }
    }

    private func closeEpisodes() {
        episodesShown = false
        chooserChanged(false)
        revealControls(focus: true, on: .episodes)
    }

    /// An episode from the row plays on its best stream, as Next Episode
    /// does; the one already playing just puts the controls back.
    private func chooseEpisode(_ episode: TVEpisodeChoice) {
        guard !episode.isCurrent else { closeEpisodes(); return }
        episode.play()
        close(because: "Chose " + ([episode.code, episode.title].compactMap { $0 }.joined(separator: " ")) + " from Episodes")
    }

    private func declineNextEpisode() {
        nextEpisodeDeclined = true
        surfaceFocused = true
    }

    private func close(because reason: String) {
        closing = true
        controller.finishScrubbing(resume: false)
        PlaybackJournal.shared.note("Closed: " + reason
            + (isLive ? "" : " at \(PlaybackJournal.clock(controller.elapsed))"))
        reportProgress(force: true)
        finishPlayback()
        dismiss()
    }

    /// Stops the player, or gives the preview's back to it still playing.
    /// The picture goes back at once, so the preview is already playing as
    /// full screen fades away from over it.
    private func finishPlayback() {
        guard continuesPreview else { controller.stop(); return }
        guard controller.lentToFullScreen else { return }
        controller.watched = nil
        controller.failover = previewFailover
        controller.lentToFullScreen = false
        controller.catchUpSource = nil
        // A preview is given back its own channel, live, or nothing: moved
        // to another channel or into a recording, the player stops, and the
        // preview opens its channel again as it reappears.
        if channelChanged || controller.catchUp != nil {
            controller.stop()
            return
        }
        // A preview that has gone meanwhile has nowhere to show the picture,
        // and its sound would play on over whatever is there instead.
        if !controller.isShownOutsideFullScreen { controller.stop() }
    }

    /// The log's first line for this title.
    private var openingNote: String {
        if isLive { return "Watching " + (chosenTitle ?? title) }
        let name = synopsis?.title ?? title
        guard let initialPosition, initialPosition >= 10 else { return "Playing " + name + " from the beginning" }
        return "Playing " + name + " from " + PlaybackJournal.clock(initialPosition)
    }

    private func keepControlsVisible() { controlsVisible = true; scheduleAutoHide() }

    private func chooserChanged(_ open: Bool) {
        chooserOpen = open
        if open {
            hideControlsTask?.cancel()
            controlsVisible = true
        } else {
            scheduleAutoHide()
        }
    }

    private func reportProgress(force: Bool = false, at position: TimeInterval? = nil) {
        guard !isLive, !controller.isScrubbing, controller.duration > 0 else { return }
        let position = position ?? controller.elapsed
        guard force || abs(position - lastReportedPosition) >= 5 else { return }
        lastReportedPosition = position
        onProgress?(position, controller.duration)
    }

    private func scheduleAutoHide() {
        hideControlsTask?.cancel()
        guard controller.isPlaying, !chooserOpen, !controller.isScrubbing else { return }
        // Counted from the last press, not from when the controls appeared.
        hideControlsTask = Task {
            do { try await Task.sleep(for: .seconds(6)) } catch { return }
            guard !Task.isCancelled, !controller.isScrubbing else { return }
            let inChrome = focusedControl != nil
            controlsVisible = false
            // Hand focus to the video surface as the chrome leaves, so the next
            // press on the remote has somewhere to arrive -- unless it is in
            // the stats, which stay.
            await Task.yield()
            if inChrome || !statsShown { focusPicture() }
        }
    }
}

private enum TVPlayerControl: Hashable {
    case scrubber, goLive, startOver, mute, lastChannel, chooseChannel, stats, alert, subtitles, audio, video, quality
    case episodes
    /// One of the season's episodes in the Episodes row, by its id.
    case episode(String)
}

private struct TVPlayerChrome: View {
    @State private var showingQuality = false
    @State private var showingSubtitles = false
    @State private var showingAudio = false
    @State private var showingVideo = false
    let title: String
    let program: CurrentProgram?
    let synopsis: TVPlayerSynopsis?
    let isLive: Bool
    @ObservedObject var controller: TVPlaybackController
    let focusedControl: FocusState<TVPlayerControl?>.Binding
    /// The channel Last Channel goes back to, when there is one.
    let lastChannelName: String?
    /// An alert about another game, offered as a button while it is up.
    let alert: GameAlert?
    let onInteraction: () -> Void
    let onChooserChange: (Bool) -> Void
    let onLastChannel: () -> Void
    let onWatchAlert: () -> Void
    /// Another channel for the game on screen, as on iPhone.
    let onChooseChannel: (() -> Void)?
    let statsShown: Bool
    /// The live stats, for a game ESPN keeps an account of.
    let onToggleStats: (() -> Void)?
    /// Find Subtitles Online and Subtitle Settings, for a Library title.
    let onFindSubtitles: (() -> Void)?
    let onSubtitleSettings: (() -> Void)?
    /// The server's scrubbing thumbnails, shown over the seek bar.
    let seekPreview: MobileSeekPreviewStore
    /// The season's other episodes, for an episode with some.
    let onShowEpisodes: (() -> Void)?
    /// The Episodes row, while it is up. The seek bar and the buttons make
    /// way for it, and the time sits over it.
    let episodes: TVEpisodesShown?

    private var choosing: Bool { showingQuality || showingSubtitles || showingAudio || showingVideo }

    /// Keep the first visible action consistent with the order in the row.
    private var firstAction: TVPlayerControl { onShowEpisodes == nil ? .goLive : .episodes }

    /// The channel's timeline, while the provider records it: the programme
    /// on now, or the one a recording is playing.
    private var showsTimeline: Bool {
        isLive && controller.catchUpSource != nil && (controller.catchUp != nil || controller.canStartOver)
    }

    /// LIVE, BEHIND LIVE, REPLAY, or for a film NOW PLAYING.
    private var stateLabel: String {
        guard isLive else { return "NOW PLAYING" }
        guard let catchUp = controller.catchUp, let position = controller.catchUpPosition else {
            return controller.isAtLiveEdge ? "LIVE" : "BEHIND LIVE"
        }
        // A programme from the past is a replay of a day, not a delay.
        if controller.recordingEndsWithProgramme {
            return "REPLAY · " + catchUp.programmeStart
                .formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day()).uppercased()
        }
        let behind = max(0, Int(Date().timeIntervalSince(position) / 60))
        return behind < 1 ? "REPLAY" : "REPLAY · \(TVCatchUpBar.duration(minutes: behind)) BEHIND LIVE"
    }

    /// A track's name as a control shows it: long stream descriptions are cut
    /// short so the row of controls keeps its shape.
    private func short(_ name: String) -> String {
        name.count > 24 ? String(name.prefix(23)) + "…" : name
    }

    private var nowPlayingTitle: String {
        if let synopsis { return synopsis.title }
        if let catchUp = controller.catchUp { return catchUp.title }
        guard let program, !program.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return title }
        return program.title
    }
    private var subtitle: String? {
        if let synopsis { return synopsis.subtitle }
        if let catchUp = controller.catchUp {
            return "\(title)  ·  \(catchUp.programmeStart.formatted(date: .omitted, time: .shortened)) – \(catchUp.programmeEnd.formatted(date: .omitted, time: .shortened))"
        }
        guard let program else { return title == nowPlayingTitle ? nil : title }
        let time = "\(program.start.formatted(date: .omitted, time: .shortened)) – \(program.end.formatted(date: .omitted, time: .shortened))"
        return title == nowPlayingTitle ? time : "\(title)  ·  \(time)"
    }

    var body: some View {
        VStack(spacing: 0) {
            LinearGradient(colors: [.black.opacity(0.72), .black.opacity(0.18), .clear], startPoint: .top, endPoint: .bottom)
                .frame(height: 286)
                .overlay(alignment: .topLeading) {
                    VStack(alignment: .leading, spacing: 7) {
                        HStack(spacing: 9) {
                            if isLive && controller.catchUp == nil { PulsingLiveDot(size: 8) }
                            PlaybackClockReader(clock: controller.clock) {
                                Text(stateLabel)
                                    .font(.inter(15, .heavy)).tracking(0.6)
                                    .foregroundStyle(isLive && controller.catchUp == nil
                                                     ? LineupStyle.liveStatus : LineupStyle.mediaText)
                            }
                        }
                        Text(nowPlayingTitle).font(.inter(36, .semibold)).lineLimit(1)
                        if let subtitle { Text(subtitle).font(.inter(19, .medium)).opacity(0.78).lineLimit(1) }
                        if controller.catchUp == nil, let detail = synopsis?.detail ?? program?.detail, !detail.isEmpty {
                            Text(detail).font(.inter(22, .medium)).opacity(0.84).lineLimit(2)
                                .fixedSize(horizontal: false, vertical: true)
                                .frame(maxWidth: 1200, alignment: .leading)
                        }
                    }
                    .foregroundStyle(LineupStyle.mediaText)
                    .padding(.horizontal, 72).padding(.top, 48)
                }
            Spacer()
            // Lighter than it was: glass shows what is behind it, and over a
            // band of near-black there was nothing behind it to show.
            LinearGradient(colors: [.clear, .black.opacity(0.22), .black.opacity(0.62)], startPoint: .top, endPoint: .bottom)
                .frame(height: episodes == nil ? 340 : 640)
                .overlay(alignment: .bottom) {
                    if let episodes {
                        VStack(alignment: .leading, spacing: 22) {
                            if !isLive { TVEpisodesClock(controller: controller, clock: controller.clock) }
                            TVEpisodesPanel(row: episodes, focus: focusedControl)
                        }
                        .padding(.leading, 72).padding(.bottom, 52)
                        .transition(.opacity.combined(with: .move(edge: .bottom)))
                    } else {
                    LineupGlassGroup {
                    VStack(alignment: .leading, spacing: 26) {
                    // What is playing and how -- the engine, the picture's
                    // size, its formats -- sat on the bar they describe,
                    // large enough to read from the couch.
                    VStack(alignment: .leading, spacing: 14) {
                        PlaybackBadgeFlow(spacing: 10) {
                            TVPlaybackEngineBadge(engine: controller.engineKind, large: true)
                            if controller.videoHeight > 0 { PlaybackFormatBadge(text: controller.qualityLabel, large: true) }
                            ForEach(controller.mediaInfo.badges, id: \.self) { PlaybackFormatBadge(text: $0, large: true) }
                        }
                        if !isLive && controller.duration > 0 {
                            TVSeekBar(controller: controller, clock: controller.clock, preview: seekPreview,
                                      focus: focusedControl, firstAction: firstAction, onInteraction: onInteraction)
                        }
                        if showsTimeline {
                            TVCatchUpBar(controller: controller, clock: controller.clock, focus: focusedControl,
                                         firstAction: firstAction, onInteraction: onInteraction)
                        }
                    }
                    HStack(spacing: 14) {
                        if let onShowEpisodes {
                            TVPlayerButton(title: "Episodes", symbol: "rectangle.stack.fill",
                                           focus: focusedControl, id: .episodes) {
                                onShowEpisodes()
                            }
                        }
                        TVPlayerButton(title: isLive ? (controller.isAtLiveEdge ? "Live" : "Go Live") : "Restart",
                            symbol: isLive ? "dot.radiowaves.left.and.right" : "backward.end.fill",
                            focus: focusedControl, id: .goLive) {
                                controller.goLive(); onInteraction()
                            }
                        if isLive && controller.canStartOver {
                            TVPlayerButton(title: "Start Over", symbol: "backward.end.fill",
                                           focus: focusedControl, id: .startOver) {
                                controller.startOver(); onInteraction()
                            }
                        }
                        TVPlayerButton(title: controller.isMuted ? "Unmute" : "Mute",
                            symbol: controller.isMuted ? "speaker.slash.fill" : "speaker.wave.2.fill",
                            focus: focusedControl, id: .mute) { controller.toggleMute(); onInteraction() }
                        if let lastChannelName {
                            TVPlayerButton(title: "Last · " + short(lastChannelName), symbol: "arrow.uturn.backward",
                                           focus: focusedControl, id: .lastChannel) {
                                onLastChannel(); onInteraction()
                            }
                        }
                        if let onChooseChannel {
                            TVPlayerButton(title: "Choose Channel", symbol: "list.bullet",
                                           focus: focusedControl, id: .chooseChannel) {
                                onChooseChannel(); onInteraction()
                            }
                        }
                        if let onToggleStats {
                            TVPlayerButton(title: statsShown ? "Hide Stats" : "Stats", symbol: "chart.bar.fill",
                                           focus: focusedControl, id: .stats) {
                                onToggleStats(); onInteraction()
                            }
                        }
                        if let alert {
                            TVPlayerButton(title: "Watch " + TVGameAlertBanner.matchup(alert.game),
                                           symbol: "sportscourt.fill", focus: focusedControl, id: .alert) {
                                onWatchAlert(); onInteraction()
                            }
                        }
                        // Every Library title: its own subtitles, any found
                        // online, and how they look.
                        if !isLive && (controller.subtitleTracks.count > 1 || onFindSubtitles != nil
                                       || onSubtitleSettings != nil) {
                            TVSelectable(scale: 1, drawsFocusChrome: false, action: { showingSubtitles = true }) {
                                TVPlayerMenuLabel(title: "Subtitles · \(short(controller.selectedSubtitleTitle))",
                                                  symbol: "captions.bubble.fill",
                                                  focused: focusedControl.wrappedValue == .subtitles)
                            }
                            .focused(focusedControl, equals: .subtitles)
                            .tvChoices("Subtitles", symbol: "captions.bubble", isPresented: $showingSubtitles,
                                       message: controller.trackMemoryShow == nil ? nil
                                           : "Kept for every episode of this show.") {
                                var choices = controller.subtitleTracks.map { track in
                                    TVChoice(track.title, id: "\(track.id)",
                                             isSelected: track.id == controller.selectedSubtitleID) {
                                        controller.selectSubtitle(track)
                                        onInteraction()
                                    }
                                }
                                if let onFindSubtitles {
                                    choices.append(TVChoice("Find Subtitles Online", symbol: "magnifyingglass",
                                                            id: "find-online", action: onFindSubtitles))
                                }
                                if let onSubtitleSettings {
                                    choices.append(TVChoice("Subtitle Settings", symbol: "textformat.size",
                                                            id: "settings", action: onSubtitleSettings))
                                }
                                return choices
                            } onCancel: { onInteraction() }
                        }
                        // A file with more than one audio stream -- languages,
                        // commentary, a stereo mix beside the surround one.
                        if !isLive && controller.audioTracks.count > 1 {
                            TVSelectable(scale: 1, drawsFocusChrome: false, action: { showingAudio = true }) {
                                TVPlayerMenuLabel(title: "Audio · \(short(controller.selectedAudioTitle))",
                                                  symbol: "waveform",
                                                  focused: focusedControl.wrappedValue == .audio)
                            }
                            .focused(focusedControl, equals: .audio)
                            .tvChoices("Audio", symbol: "waveform", isPresented: $showingAudio,
                                       message: controller.trackMemoryShow == nil ? nil
                                           : "Kept for every episode of this show.") {
                                controller.audioTracks.map { track in
                                    TVChoice(track.title, id: "\(track.id)",
                                             isSelected: track.id == controller.selectedAudioTrackID) {
                                        controller.selectAudioTrack(track)
                                        onInteraction()
                                    }
                                }
                            } onCancel: { onInteraction() }
                        }
                        // And one with more than one video stream.
                        if !isLive && controller.videoTracks.count > 1 {
                            TVSelectable(scale: 1, drawsFocusChrome: false, action: { showingVideo = true }) {
                                TVPlayerMenuLabel(title: "Video · \(short(controller.selectedVideoTitle))",
                                                  symbol: "film",
                                                  focused: focusedControl.wrappedValue == .video)
                            }
                            .focused(focusedControl, equals: .video)
                            .tvChoices("Video", symbol: "film", isPresented: $showingVideo) {
                                controller.videoTracks.map { track in
                                    TVChoice(track.title, id: "\(track.id)",
                                             isSelected: track.id == controller.selectedVideoTrackID) {
                                        controller.selectVideoTrack(track)
                                        onInteraction()
                                    }
                                }
                            } onCancel: { onInteraction() }
                        }
                        // A Menu renders through tvOS's own chrome, so this is a
                        // plain selectable with a dialog, like every other control.
                        TVSelectable(scale: 1, drawsFocusChrome: false, action: { showingQuality = true }) {
                            TVPlayerMenuLabel(title: "Quality · \(controller.qualityLabel)",
                                              symbol: "gearshape.fill",
                                              focused: focusedControl.wrappedValue == .quality)
                        }
                        .focused(focusedControl, equals: .quality)
                        .tvChoices("Quality · \(controller.qualityLabel)", symbol: "gearshape", isPresented: $showingQuality) {
                            [TVChoice(isLive ? "Refresh Stream" : "Restart Playback", symbol: "arrow.clockwise") {
                                controller.goLive(); onInteraction()
                            }]
                        } onCancel: { onInteraction() }
                        Spacer(minLength: 0)
                    }
                    }
                    }
                    .padding(.horizontal, 72).padding(.bottom, 52)
                    }
                }
        }
        .ignoresSafeArea()
        .onChange(of: choosing) { _, open in onChooserChange(open) }
        // If the controls go while a list is open -- playback failing takes
        // them away -- the player must not wait on a list that is gone.
        .onDisappear { if choosing { onChooserChange(false) } }
    }
}

/// A recorded channel's timeline: the programme from its start to its end,
/// lit as far as the broadcast has got, with the picture's place on it.
///
/// Left and right step ten seconds back and on -- from live, back goes into
/// the recording, and on through a recording that reaches the present goes
/// back to live. Up and down hand focus back to the controls.
private struct TVCatchUpBar: View {
    @ObservedObject var controller: TVPlaybackController
    @ObservedObject var clock: PlaybackClock
    let focus: FocusState<TVPlayerControl?>.Binding
    let firstAction: TVPlayerControl
    let onInteraction: () -> Void

    /// "12 MIN", "1 HR 5 MIN".
    static func duration(minutes: Int) -> String {
        minutes < 60 ? "\(minutes) MIN" : "\(minutes / 60) HR" + (minutes % 60 == 0 ? "" : " \(minutes % 60) MIN")
    }

    private func timelineSpan(now: Date) -> (start: Date, end: Date) {
        if let catchUp = controller.catchUp { return (catchUp.programmeStart, catchUp.programmeEnd) }
        if let programme = controller.catchUpSource?.programme(now) { return (programme.start, programme.end) }
        return (now.addingTimeInterval(-1800), now)
    }

    private func fraction(_ time: Date, in span: (start: Date, end: Date)) -> CGFloat {
        let length = span.end.timeIntervalSince(span.start)
        guard length > 0 else { return 0 }
        return CGFloat(min(1, max(0, time.timeIntervalSince(span.start) / length)))
    }

    private func caption(position: Date, now: Date) -> String {
        guard let catchUp = controller.catchUp else { return "LIVE" }
        if catchUp.programmeEnd <= now.addingTimeInterval(-60), position < catchUp.programmeEnd {
            // A programme from the past: how far into it.
            let seconds = max(0, Int(position.timeIntervalSince(catchUp.programmeStart)))
            return PlaybackJournal.clock(TimeInterval(seconds))
        }
        let behind = max(0, Int(now.timeIntervalSince(position) / 60))
        return behind < 1 ? "LIVE" : Self.duration(minutes: behind) + " BEHIND"
    }

    var body: some View {
        let selected = focus.wrappedValue == .scrubber
        let now = Date()
        let span = timelineSpan(now: now)
        let position = controller.catchUpPosition ?? now
        let reached = fraction(now, in: span)
        let place = controller.catchUp == nil ? reached : fraction(position, in: span)
        let panel = RoundedRectangle(cornerRadius: 26, style: .continuous)
        VStack(spacing: 12) {
            // As far as the broadcast has got, the part that can be played,
            // in the softer accent; where the picture is, in the accent.
            LineupProgressBar(value: place, reach: reached,
                              height: selected ? 16 : LineupProgressBar.standardHeight)
            HStack {
                Text(span.start.formatted(date: .omitted, time: .shortened))
                Spacer(minLength: 0)
                Text(caption(position: position, now: now))
                    .foregroundStyle(LineupStyle.lightPurple)
                Spacer(minLength: 0)
                Text(span.end.formatted(date: .omitted, time: .shortened))
            }
            .font(.interDigits(15, .semibold))
            .foregroundStyle(LineupStyle.lightPurple.opacity(selected ? 1 : 0.68))
        }
        .padding(.horizontal, 26).padding(.vertical, 18)
        .lineupLiquidGlass(panel, fallback: LineupStyle.surface.opacity(0.88), border: LineupStyle.line)
        .lineupFocusLayer(selected, in: panel)
        .contentShape(Rectangle())
        .focusable()
        .focused(focus, equals: .scrubber)
        .focusEffectDisabled()
        .onMoveCommand { direction in
            switch direction {
            case .left: controller.skip(by: -CatchUpPolicy.skip)
            case .right: controller.skip(by: CatchUpPolicy.skip)
            case .down, .up: focus.wrappedValue = firstAction
            default: break
            }
            onInteraction()
        }
        .onTapGesture {
            controller.togglePlayback()
            onInteraction()
        }
        .animation(.easeOut(duration: 0.18), value: selected)
        .accessibilityLabel("Program timeline")
        .accessibilityValue(caption(position: position, now: now))
    }
}

/// The channel just moved to, named over the picture for a moment: its
/// mark, its name and what is on.
private struct TVChannelBanner: View {
    let stream: XtreamStream
    let program: CurrentProgram?

    var body: some View {
        HStack(spacing: 18) {
            LineupArtView(url: stream.streamIcon.flatMap(URL.init(string:)), width: 120) { loaded in
                if let loaded {
                    loaded.resizable().scaledToFit()
                } else {
                    Image(systemName: "tv").font(.system(size: 26, weight: .light, design: .rounded)).opacity(0.6)
                }
            }
            .frame(width: 84, height: 56)
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 10) {
                    if let number = stream.num {
                        Text(String(number)).font(.interDigits(20, .bold)).opacity(0.6)
                    }
                    Text(stream.name).font(.inter(26, .bold)).lineLimit(1)
                }
                if let program {
                    Text(program.title).font(.inter(18, .semibold)).opacity(0.85).lineLimit(1)
                    Text("\(program.start.formatted(date: .omitted, time: .shortened)) – \(program.end.formatted(date: .omitted, time: .shortened))")
                        .font(.interDigits(15, .medium)).opacity(0.6)
                }
            }
        }
        .foregroundStyle(LineupStyle.mediaText)
        .padding(.horizontal, 26).padding(.vertical, 18)
        .frame(maxWidth: 760, alignment: .leading)
        .lineupLiquidGlass(RoundedRectangle(cornerRadius: 22, style: .continuous),
                           fallback: Color.black.opacity(0.72), border: .clear)
        .accessibilityElement(children: .combine)
    }
}

/// One of the viewer's teams' games, breaking into the picture: what
/// happened, the score, and -- with the controls away -- that Select goes
/// to it.
private struct TVGameAlertBanner: View {
    let alert: GameAlert
    let selectWatches: Bool

    /// "BOS @ NYY", or an event's name.
    static func matchup(_ game: SportsGame) -> String {
        game.isEvent ? game.matchupLine
            : "\(game.awayAbbreviation) \(game.sidesSymbol) \(game.homeAbbreviation)"
    }

    private var scoreline: String {
        let game = alert.game
        guard !game.isEvent, game.isLive, !game.awayScore.isEmpty, !game.homeScore.isEmpty else {
            return Self.matchup(game)
        }
        return "\(game.awayAbbreviation) \(game.awayScore)  –  \(game.homeAbbreviation) \(game.homeScore)"
    }

    var body: some View {
        let game = alert.game
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                Circle().fill(LineupStyle.liveDot).frame(width: 8, height: 8)
                Text(alert.headline.uppercased())
                    .font(.inter(14, .heavy)).tracking(0.6)
                    .foregroundStyle(LineupStyle.liveStatus)
                if !game.status.isEmpty {
                    Text(game.status.uppercased())
                        .font(.inter(14, .bold)).tracking(1.2).opacity(0.7)
                        .lineLimit(1)
                }
            }
            HStack(spacing: 14) {
                LeagueLogo(league: game.isNFLRedZone ? .nfl : game.league, size: 26)
                Text(scoreline).font(.interDigits(26, .bold)).lineLimit(1)
            }
            if selectWatches {
                Text("Press Select to watch").font(.inter(15, .semibold)).opacity(0.7)
            }
        }
        .foregroundStyle(LineupStyle.mediaText)
        .padding(.horizontal, 24).padding(.vertical, 18)
        .lineupLiquidGlass(RoundedRectangle(cornerRadius: 22, style: .continuous),
                           fallback: Color.black.opacity(0.75), border: .clear)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(alert.headline). \(scoreline). \(game.status)")
    }
}

/// A minimal transport bar for recorded media.
///
/// A short left/right click skips fifteen seconds; a held press moves a local
/// destination at display cadence and accelerates. Decoder previews are
/// coalesced separately.
private struct TVSeekBar: View {
    @ObservedObject var controller: TVPlaybackController
    @ObservedObject var clock: PlaybackClock
    /// The server's thumbnails: the one for where the remote has got to
    /// rides over the bar while it scrubs.
    let preview: MobileSeekPreviewStore
    let focus: FocusState<TVPlayerControl?>.Binding
    let firstAction: TVPlayerControl
    let onInteraction: () -> Void
    @State private var target: Double?
    @State private var nativeRemoteSeekActive = false
    @State private var fallbackDirection: Double?
    @State private var fallbackEndTask: Task<Void, Never>?
    @Environment(\.scenePhase) private var scenePhase

    private var shown: Double { target ?? controller.elapsed }

    private var progress: Double {
        guard controller.duration > 0 else { return 0 }
        return min(max(shown / controller.duration, 0), 1)
    }

    var body: some View {
        let selected = focus.wrappedValue == .scrubber
        let panel = RoundedRectangle(cornerRadius: 26, style: .continuous)
        VStack(spacing: 12) {
            LineupProgressBar(value: progress,
                              height: selected ? 16 : LineupProgressBar.standardHeight)
                .overlay(alignment: .topLeading) {
                    if let target {
                        GeometryReader { bar in
                            let width = TVSeekPreviewBubble.size.width
                            TVSeekPreviewBubble(store: preview, seconds: target)
                                .offset(x: min(max(0, progress * bar.size.width - width / 2), max(0, bar.size.width - width)),
                                        y: -TVSeekPreviewBubble.size.height - 34)
                        }
                        .allowsHitTesting(false)
                    }
                }
            HStack {
                Text(Self.clock(shown))
                Spacer(minLength: 0)
                Text("-" + Self.clock(max(0, controller.duration - shown)))
            }
            .font(.interDigits(15, .semibold))
            .foregroundStyle(LineupStyle.lightPurple.opacity(selected ? 1 : 0.68))
        }
        .padding(.horizontal, 26).padding(.vertical, 18)
        .lineupLiquidGlass(panel, fallback: LineupStyle.surface.opacity(0.88), border: LineupStyle.line)
        .lineupFocusLayer(selected, in: panel)
        .contentShape(Rectangle())
        .focusable()
        .focused(focus, equals: .scrubber)
        .focusEffectDisabled()
        .background(TVSeekRemoteInput(active: selected && scenePhase == .active, onBegin: { direction in
            nativeRemoteSeekActive = true
            fallbackEndTask?.cancel()
            fallbackEndTask = nil
            // onMoveCommand can deliver the click before UIKit recognizes the
            // same held press. Keep that first 15-second step and let the
            // display-cadence hold continue from it instead of double-skipping.
            if target == nil || fallbackDirection == nil {
                beginRemoteSeek(direction: direction)
            }
            fallbackDirection = nil
        }, onFrame: { direction, heldFor, delta in
            guard let target else { return }
            let next = PlaybackSeekPolicy.clamped(target + direction * PlaybackSeekPolicy.rate(heldFor: heldFor) * delta,
                                                   duration: controller.duration)
            guard abs(next - target) > 0.001 else { return }
            self.target = next
            controller.previewScrubbing(at: next)
            preview.request(at: next)
        }, onEnd: {
            nativeRemoteSeekActive = false
            finishScrubbing()
        }).frame(width: 1, height: 1).accessibilityHidden(true))
        .onMoveCommand { direction in
            switch direction {
            case .left:
                handleRemoteMove(-1)
            case .right:
                handleRemoteMove(1)
            case .down, .up:
                finishScrubbing()
                focus.wrappedValue = firstAction
                onInteraction()
            default: break
            }
        }
        .onTapGesture {
            finishScrubbing()
            controller.togglePlayback()
            onInteraction()
        }
        .onChange(of: selected) { _, active in if !active { finishScrubbing() } }
        .onChange(of: scenePhase) { _, phase in if phase != .active { finishScrubbing() } }
        .onDisappear {
            fallbackEndTask?.cancel()
            fallbackEndTask = nil
            fallbackDirection = nil
            nativeRemoteSeekActive = false
            controller.finishScrubbing(resume: false)
            target = nil
            preview.cancel()
        }
        .transaction { if target != nil { $0.animation = nil } }
        .accessibilityLabel("Playback position")
        .accessibilityValue(Self.clock(shown) + " of " + Self.clock(controller.duration))
        .accessibilityHint("Select to play or pause. Hold left or right to seek.")
    }

    private func finishScrubbing() {
        fallbackEndTask?.cancel()
        fallbackEndTask = nil
        fallbackDirection = nil
        guard let target else { return }
        controller.endScrubbing(at: target)
        self.target = nil
        preview.cancel()
        onInteraction()
    }

    /// SwiftUI's standard directional command is the reliable click path on
    /// tvOS. It also acts as a repeat fallback if UIKit does not own a held
    /// press on a particular Siri Remote. Repeats advance in 15-second steps;
    /// the native gesture, when available, takes over for smooth acceleration.
    private func handleRemoteMove(_ direction: Double) {
        guard !nativeRemoteSeekActive else { return }

        if target == nil {
            controller.beginScrubbing()
            guard controller.isScrubbing else { return }
        }
        let base = target ?? controller.elapsed
        let destination = PlaybackSeekPolicy.remoteCommandTarget(
            from: base, direction: direction, duration: controller.duration)
        target = destination
        fallbackDirection = direction
        controller.previewScrubbing(at: destination)
        preview.request(at: destination)
        scheduleFallbackFinish(direction: direction)
        onInteraction()
    }

    private func scheduleFallbackFinish(direction: Double) {
        fallbackEndTask?.cancel()
        fallbackEndTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 280_000_000)
            guard !Task.isCancelled,
                  !nativeRemoteSeekActive,
                  fallbackDirection == direction else { return }
            finishScrubbing()
        }
    }

    private func beginRemoteSeek(direction: Double) {
        controller.beginScrubbing()
        guard controller.isScrubbing else { return }
        let destination = PlaybackSeekPolicy.clamped(
            controller.elapsed + direction * PlaybackSeekPolicy.remoteTapSkip,
            duration: controller.duration)
        target = destination
        controller.previewScrubbing(at: destination)
        preview.request(at: destination)
        onInteraction()
    }

    static func clock(_ seconds: TimeInterval) -> String {
        let total = Int(seconds.rounded())
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        let secs = total % 60
        return hours > 0
            ? String(format: "%d:%02d:%02d", hours, minutes, secs)
            : String(format: "%d:%02d", minutes, secs)
    }
}

/// The picture at the place being scrubbed to, from the server's
/// thumbnails, with its time under it. Only drawn where the server has them.
private struct TVSeekPreviewBubble: View {
    static let size = CGSize(width: 336, height: 222)
    @ObservedObject var store: MobileSeekPreviewStore
    let seconds: Double

    var body: some View {
        if let info = store.source?.info {
            let index = info.index(at: seconds)
            let shape = RoundedRectangle(cornerRadius: 18, style: .continuous)
            VStack(spacing: 8) {
                ZStack {
                    Color.black
                    if let frame = store.frame, frame.index == index {
                        Image(decorative: frame.image, scale: 1).resizable().scaledToFill()
                    } else {
                        ProgressView().tint(.white)
                    }
                }
                .frame(width: Self.size.width - 16, height: 180)
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                Text(PlaybackJournal.clock(seconds)).font(.interDigits(17, .bold))
                    .foregroundStyle(LineupStyle.mediaText)
            }
            .padding(8)
            .frame(width: Self.size.width, height: Self.size.height)
            .background(Color.black.opacity(0.82), in: shape)
            .overlay(shape.strokeBorder(Color.white.opacity(0.14), lineWidth: 1))
            .lineupShadow(.overlay)
            .accessibilityHidden(true)
        }
    }
}

private struct TVPlayerButton: View {
    let title: String
    let symbol: String
    let focus: FocusState<TVPlayerControl?>.Binding
    let id: TVPlayerControl
    let action: () -> Void

    var body: some View {
        let selected = focus.wrappedValue == id
        Button(action: action) {
            TVPlayerControlGlyph(symbol: symbol, focused: selected)
        }
        // The button draws its own focus state, so tvOS's plate would sit on top
        // of it as a second, larger highlight.
        .lineupFlatButton().focused(focus, equals: id).focusEffectDisabled()
        .accessibilityLabel(title)
    }
}

private struct TVPlayerMenuLabel: View {
    let title: String
    let symbol: String
    let focused: Bool
    var body: some View {
        TVPlayerControlGlyph(symbol: symbol, focused: focused)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(title)
    }
}

/// Every player action uses the same compact, outlined glyph target. The
/// focus treatment follows the symbol's own shape instead of a text capsule.
private struct TVPlayerControlGlyph: View {
    let symbol: String
    let focused: Bool

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 15, style: .continuous)
        Image(systemName: symbol)
            .font(.system(size: 23, weight: .semibold, design: .rounded))
            .symbolRenderingMode(.hierarchical)
            .foregroundStyle(LineupStyle.mediaText)
            .frame(width: 58, height: 56)
            .lineupLiquidGlass(shape, fallback: LineupStyle.surface.opacity(0.9), border: LineupStyle.line)
            .lineupFocusLayer(focused, in: shape)
            .lineupShadow(.resting)
            .scaleEffect(focused ? LineupStyle.controlLift : 1)
            .animation(.spring(response: 0.22, dampingFraction: 0.76), value: focused)
    }
}

/// Where playback has got to, for the views that show it and nothing else.
@MainActor final class PlaybackClock: ObservableObject {
    @Published var elapsed: TimeInterval = 0
}

/// Redraws what it holds as playback moves, and nothing around it.
private struct PlaybackClockReader<Content: View>: View {
    @ObservedObject var clock: PlaybackClock
    @ViewBuilder let content: () -> Content
    var body: some View { content() }
}

@MainActor final class TVPlaybackController: ObservableObject {
    @Published private(set) var engineKind: TVPlaybackEngine
    private var backend: any TVPlaybackBackend
    private let defaults: UserDefaults
    private let backendFactory: @MainActor (TVPlaybackEngine) -> any TVPlaybackBackend
    private let primaryOutput: Bool
    private let uptime: @MainActor () -> TimeInterval
    private let connectionCooldown: TimeInterval
    private var sourceIsRecording = false
    /// The tab this player plays in, whose engine it opens each stream with.
    /// A preview's player keeps its tab when full screen carries it on.
    var place: TVPlaybackPlace?

    init(place: TVPlaybackPlace? = nil, defaults: UserDefaults = .standard, primaryOutput: Bool = true,
         uptime: @escaping @MainActor () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
         connectionCooldown: TimeInterval = 1,
         backendFactory: @escaping @MainActor (TVPlaybackEngine) -> any TVPlaybackBackend = makeTVPlaybackBackend) {
        self.place = place
        self.defaults = defaults
        self.primaryOutput = primaryOutput
        self.uptime = uptime
        self.connectionCooldown = connectionCooldown
        self.backendFactory = backendFactory
        let selected = TVPlaybackEngine.selected(for: place, in: defaults)
        let initial = backendFactory(selected)
        backend = initial
        engineKind = initial.kind
        mountBackend()
        subtitlePreferences = MobileSubtitlePreferences(defaults: defaults)
    }

    private func mountBackend() {
        surface.subviews.forEach { $0.removeFromSuperview() }
        let picture = backend.surface
        picture.frame = surface.bounds
        picture.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        surface.addSubview(picture)
    }

    private func selectConfiguredBackend() {
        let selected = TVPlaybackEngine.selected(for: place, in: defaults)
        guard selected != backend.kind else { return }
        backend.stop()
        backend = backendFactory(selected)
        engineKind = backend.kind
        mountBackend()
    }

    var engineTitle: String { engineKind.title }
    /// The view the selected engine draws into, for as long as this player lives. It is
    /// drawn at the television's size and moved, never resized, between the
    /// places it is shown; see `TVHostedSurface`.
    let surface: UIView = {
        let view = UIView(frame: CGRect(x: 0, y: 0, width: 1920, height: 1080))
        view.backgroundColor = .black
        return view
    }()
    /// Every place showing this player, oldest first.
    private var hosts: [TVSurfaceHost] = []
    /// The channel a Guide preview last opened on this player, so the
    /// preview can tell its own stream from one already moved on.
    var previewChannelID: Int?
    /// Full screen has this preview's player for now. The preview neither
    /// stops it when it is covered nor opens it again when it is uncovered.
    var lentToFullScreen = false {
        didSet { if lentToFullScreen != oldValue { placeSurface() } }
    }
    @Published private(set) var reconnecting = false
    @Published private(set) var error: String?
    @Published private(set) var isPlaying = false { didSet { reportLibraryTracking() } }
    var libraryTrackingEvent: ((LibraryPlaybackSample) -> Void)?
    private var lastLibraryTrackingSample: LibraryPlaybackSample?
    private func reportLibraryTracking() {
        guard let libraryTrackingEvent, !isScrubbing else { return }
        let sample = LibraryPlaybackSample(playing: isPlaying, pictureInPicture: false, position: elapsed, duration: duration)
        guard sample.differs(from: lastLibraryTrackingSample) else { return }
        lastLibraryTrackingSample = sample
        libraryTrackingEvent(sample)
    }
    @Published private(set) var isMuted = false
    @Published private(set) var videoHeight = 0
    @Published private(set) var mediaInfo = PlaybackMediaInfo()
    private let liveQualityReporter = LivePlaybackQualityReporter()
    @Published private(set) var activeChannelName: String?
    @Published private(set) var failoverNotice: String?
    @Published private(set) var subtitleTracks: [PlaybackSubtitleTrack] = [.off]
    @Published private(set) var selectedSubtitleID = PlaybackSubtitleTrack.off.id
    /// The file's audio and video streams, and the one of each playing.
    @Published private(set) var audioTracks: [PlaybackStreamTrack] = []
    @Published private(set) var selectedAudioTrackID: Int?
    @Published private(set) var videoTracks: [PlaybackStreamTrack] = []
    @Published private(set) var selectedVideoTrackID: Int?
    /// Seconds. Zero duration means the item is not seekable, which is how a
    /// live channel presents, so the seek bar simply does not appear for it.
    ///
    /// Kept in a clock of its own: it moves twice a second, and published
    /// with the rest it redrew the whole player and every control on each
    /// tick, which is what made moving through the controls catch.
    let clock = PlaybackClock()
    private(set) var elapsed: TimeInterval {
        get { clock.elapsed }
        set { if clock.elapsed != newValue { clock.elapsed = newValue }; reportLibraryTracking() }
    }
    @Published private(set) var duration: TimeInterval = 0 { didSet { reportLibraryTracking() } }
    private var nativeSiloPlayback: SiloPlaybackSession?
    private var pendingSiloSidecars: [SiloPlaybackSession.Sidecar] = []
    private var siloSidecarRestore: Task<Void, Never>?
    private var siloSubtitleWasOff = false
    private var siloSubtitleTitle: String?

    func configureSiloPlayback(_ session: SiloPlaybackSession?) {
        nativeSiloPlayback = session
        session?.assetChanged = { [weak self] asset in
            guard let self else { return }
            let paused = self.pausedByUser
            let delay = self.subtitleDelaySeconds
            let off = self.selectedSubtitleID == PlaybackSubtitleTrack.off.id
            let selected = self.subtitleTracks.first { $0.id == self.selectedSubtitleID }?.title
            let sidecars = self.nativeSiloPlayback?.sidecars ?? []
            self.discardOnlineSubtitles()
            self.chosenSubtitle = nil
            self.scrubSeeks.cancel()
            self.start(urls: [asset.url], muted: self.muted, initialPosition: asset.lease.playerStart,
                       isLive: false, keepTrackChoices: true, expectedDuration: asset.duration)
            self.subtitleDelaySeconds = delay
            self.pendingSiloSidecars = sidecars; self.siloSubtitleWasOff = off; self.siloSubtitleTitle = selected
            if paused { self.togglePlayback() }
        }
        session?.failed = { [weak self] message in self?.failoverNotice = message }
        session?.preparing = { [weak self] in self?.error = nil; self?.loading = true }
        session?.retryFailed = { [weak self] message in self?.loading = false; self?.error = message }
    }
    /// How to play this channel's recording, while a channel the provider
    /// records is playing live. Nil for a channel that isn't recorded, for a
    /// film, and until the server's time zone is known.
    @Published var catchUpSource: CatchUpSource?
    /// Playing the channel's recording rather than the channel live: where
    /// the stream starts and the programme its timeline is drawn across.
    @Published private(set) var catchUp: CatchUpTimeline?
    /// Where a skip is taking the recording, while it waits to see whether
    /// another press follows before reopening the stream there.
    @Published private(set) var skipTarget: Date?
    /// A programme chosen from the past ends with it. Start Over, a pause and
    /// a rewind carry on through whatever came next, up to live.
    private(set) var recordingEndsWithProgramme = false
    /// When a live channel the provider records was paused, to pick up from.
    private var pausedAt: Date?
    /// A live channel paused and played on from its buffer is that far behind
    /// the broadcast: the stats hold back by as much.
    private var liveHoldSince: Date?
    private var liveHeldSeconds: TimeInterval = 0
    private var skipTask: Task<Void, Never>?
    private var monitor: Task<Void, Never>?
    private var urls: [URL] = []
    private var urlIndex = 0
    private var muted = false
    private var pausedByUser = false
    private(set) var isScrubbing = false
    private var resumeAfterScrubbing = false
    private var scrubDestination: Double?
    private let scrubSeeks = PlaybackSeekCoalescer()
    private var seekLanding = PlaybackSeekLanding()
    private var requestedInitialPosition: TimeInterval?
    private var appliedInitialPosition = false
    /// A channel, or a film or an episode. A channel that stops is
    /// reconnected at the live edge. A recorded title that stops is reopened
    /// where it was, and one that reaches its end has finished, not failed.
    private var isLive = true
    /// Where to put a recorded title back once its stream has reopened.
    private var reopenPosition: TimeInterval?
    /// A recorded title played to its end. The player closes on it.
    @Published private(set) var finished = false
    private var health = LivePlaybackHealth(now: ProcessInfo.processInfo.systemUptime)
    private var retries = LivePlaybackRetry()
    private var retryAt: TimeInterval?
    struct FailoverContext {
        let plan: @MainActor () -> [FailoverChannel]
        let urls: @MainActor (Int) -> [URL]
        let didPlay: @MainActor (Int) -> Void
        let chooseChannel: @MainActor () -> Void
    }
    var failover: FailoverContext?
    private var currentChannelID: Int?
    private var pendingWorkingChannelID: Int?
    private var failoverState = StreamFailoverState()
    private var noticeTask: Task<Void, Never>?
    /// The level the sound is held at between fades. The playback monitor
    /// keeps it there: a reconnect can build a fresh audio output, and a
    /// picture meant to be quiet must not come back at full volume.
    private var targetVolume: Int32 = 100
    private var fadeTask: Task<Void, Never>?
    /// Set for a player that is being watched -- full screen, or one of split
    /// screen's two -- rather than previewed. Such a player holds the screen
    /// saver off while it plays and notes what it does in the playback log;
    /// a preview playing in a corner does neither.
    var watched: Watched?
    enum Watched {
        case fullScreen
        /// One of split screen's pictures, named in the log by its game.
        case splitScreen(String)
    }
    /// The tracks the viewer chose. A reconnect opens the file afresh and VLC
    /// goes back to its default tracks, so these are put back once the
    /// reopened file lists them.
    private var chosenAudioTrack: Int?
    private var chosenVideoTrack: Int?
    private var chosenSubtitle: PlaybackSubtitleTrack?
    /// The viewer's subtitle size, background and language, kept on this
    /// Apple TV; and this title's subtitle timing, which is its alone.
    @Published private(set) var subtitlePreferences = MobileSubtitlePreferences()
    @Published private(set) var subtitleDelaySeconds: Double = 0
    /// Subtitle files found online for this title: added again after a
    /// reconnect reopens it, and thrown away with it.
    private struct OnlineSubtitle { let file: URL; let title: String; let language: String }
    private var onlineSubtitles: [OnlineSubtitle] = []
    private var onlineSubtitlesToAdd: [OnlineSubtitle] = []
    /// The engine chooses a subtitle as it is added; the next look at the
    /// tracks makes that the viewer's choice, so it is kept through a
    /// reconnect like any other.
    private var adoptsAddedSubtitle = false
    /// Which title the online subtitles are for, so one found for the last
    /// title never lands on the next.
    private(set) var subtitleSession = UUID()
    /// The show whose episodes keep their sound and subtitles, and what was
    /// kept; put back once an episode, as soon as its tracks are known.
    private(set) var trackMemoryShow: String?
    private var showTracks: MobileShowTracks?
    private var appliedShowAudio = false
    private var appliedShowSubtitle = false
    /// What the log last said the stream was doing, so it notes changes
    /// rather than ticks.
    private var loggedCondition: String?
    /// Whether this stream has shown a picture since it was opened, which is
    /// what tells a stall from a stream that never started.
    private var sawPicture = false
    /// Inside `start`, whose own `stop` is no reason to let the screen saver
    /// in for the moment before the stream opens again.
    private var restarting = false

    deinit {
        // A player let go without being stopped gives up its hold too.
        let id = ObjectIdentifier(self)
        Task { @MainActor in TVScreenAwake.release(id) }
    }

    var isAtLiveEdge: Bool { isPlaying && !pausedByUser && catchUp == nil }
    /// A stream has been opened and not stopped since.
    var isOpen: Bool { !urls.isEmpty }
    /// Whether a preview is still there to show the picture.
    var isShownOutsideFullScreen: Bool { hosts.contains { !$0.fullScreen } }

    fileprivate func show(in host: TVSurfaceHost) {
        host.owner = self
        hosts.removeAll { $0 === host }
        hosts.append(host)
        placeSurface()
    }

    fileprivate func stopShowing(in host: TVSurfaceHost) {
        hosts.removeAll { $0 === host }
        placeSurface()
    }

    /// The picture goes to full screen while it has the player, and
    /// otherwise to the newest place showing it.
    private func placeSurface() {
        let front = (lentToFullScreen ? hosts.last(where: \.fullScreen) : nil)
            ?? hosts.last(where: { !$0.fullScreen }) ?? hosts.last
        guard let front, surface.superview !== front else { return }
        front.addSubview(surface)
        front.setNeedsLayout()
        front.layoutIfNeeded()
    }
    var selectedSubtitleTitle: String {
        subtitleTracks.first(where: { $0.id == selectedSubtitleID })?.title ?? "Off"
    }
    var selectedAudioTitle: String {
        audioTracks.first(where: { $0.id == selectedAudioTrackID })?.title ?? "Default"
    }
    var selectedVideoTitle: String {
        videoTracks.first(where: { $0.id == selectedVideoTrackID })?.title ?? "Default"
    }
    var qualityLabel: String {
        switch videoHeight {
        case 2160...: "4K"
        case 1440...: "1440p"
        case 1080...: "1080p"
        case 720...: "720p"
        case 480...: "480p"
        case 1...: "\(videoHeight)p"
        default: "Auto"
        }
    }

    func start(urls: [URL], muted: Bool = false, initialPosition: TimeInterval? = nil,
               channelID: Int? = nil, resetFailover: Bool = true, isLive: Bool = true,
               keepTrackChoices: Bool = false, expectedDuration: TimeInterval? = nil, recording: Bool = false) {
        let previousDuration = duration
        restarting = true
        stop()
        restarting = false
        selectConfiguredBackend()
        sourceIsRecording = recording
        self.urls = Array(urls.reversed())
        // A picture turned down to nothing stays muted whatever it is
        // reopened with: a retry or a change of channel passes on the mute
        // as it stood, which partway through fading out was still off.
        self.muted = muted || targetVolume == 0
        self.isLive = isLive
        let durationHint = expectedDuration ?? (keepTrackChoices && previousDuration > 0 ? previousDuration : nil)
        if !isLive, let durationHint, durationHint.isFinite, durationHint > 0 { duration = durationHint }
        finished = false
        if !keepTrackChoices {
            chosenAudioTrack = nil
            chosenVideoTrack = nil
            chosenSubtitle = nil
            // Another title: its own timing, its own show's tracks put back,
            // and no subtitles found for the last one.
            subtitleDelaySeconds = 0
            appliedShowAudio = false
            appliedShowSubtitle = false
            discardOnlineSubtitles()
        }
        currentChannelID = channelID
        if resetFailover {
            failoverState.reset()
            activeChannelName = nil
            failoverNotice = nil
        }
        requestedInitialPosition = initialPosition
        appliedInitialPosition = false
        retries.reset()
        urlIndex = 0
        error = nil
        guard !self.urls.isEmpty else { error = "This stream is unavailable."; return }
        holdScreenAwake()
        // A player stopped a moment ago -- the preview, as its channel goes
        // full screen -- is still closing its connection on VLC's own thread.
        // An account allowed one connection at a time refuses a second one
        // opened over it, or drops the first, and both read as a stream that
        // failed. The new one waits until the old has had a second to go. A
        // player reopening its own stream needs no wait: VLC finishes closing
        // a player's last stream before it opens that player's next.
        let now = uptime()
        if connectionCooldown > 0, let closed = Self.lastStreamClosed,
           closed.by != ObjectIdentifier(self), now - closed.at < connectionCooldown {
            retryAt = closed.at + connectionCooldown
            health = freshHealth()
        } else {
            openCurrent()
        }
        monitor = Task { [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(for: .milliseconds(500)) } catch { return }
                guard let self else { return }
                self.checkPlayback()
            }
        }
    }

    private func openCurrent() {
        liveQualityReporter.reset()
        backend.stop()
        mediaInfo = PlaybackMediaInfo()
        videoHeight = 0
        resetSubtitles()
        sawPicture = false
        loggedCondition = nil
        let place = isLive ? nil : openingPlace
        log((retries.attempts == 0 ? "Opening" : "Reopening") + " the stream with " + engineTitle
            + (place.map { " at " + PlaybackJournal.clock($0) } ?? ""))
        let fullscreen: Bool
        if case .fullScreen? = watched { fullscreen = true } else { fullscreen = false }
        backend.setOpeningLanguages(isLive ? PlaybackLanguages() : openingLanguages)
        backend.styleSubtitles(isLive ? PlaybackSubtitleStyle() : subtitleStyle)
        onlineSubtitlesToAdd = onlineSubtitles
        backend.load(url: urls[urlIndex], startPosition: place, isLive: isLive && !sourceIsRecording,
                     expectedDuration: !isLive && duration > 0 ? duration : nil,
                     primary: fullscreen || (watched != nil && primaryOutput), matchContent: fullscreen)
        health = freshHealth()
        retryAt = nil
        setMuted(muted)
        backend.volume = targetVolume
        backend.play()
        setMuted(muted)
        backend.volume = targetVolume
    }

    /// Where a recorded title's stream is opened: back where it was after a
    /// drop, or where it was left off.
    private var openingPlace: TimeInterval? {
        if let native = nativeSiloPlayback, let asset = native.asset {
            return reopenPosition.map { max(0, $0 - asset.lease.timelineOffset) } ?? asset.lease.playerStart
        }
        if let reopenPosition { return reopenPosition }
        guard !appliedInitialPosition, let requestedInitialPosition, requestedInitialPosition >= 10 else {
            return nil
        }
        return requestedInitialPosition
    }

    /// Whether a stream asked to open at a place did. The first frames land on
    /// the keyframe before it, so close counts; a stream that ignored the
    /// request starts at its beginning instead, and is moved.
    private func opened(at place: TimeInterval, time: TimeInterval) -> Bool {
        abs(time - place) <= 15
    }

    /// Position has to keep updating while paused too, so the bar still reads
    /// correctly after a seek that the viewer makes without resuming.
    private func updateProgress() {
        guard !isScrubbing else { return }
        if let native = nativeSiloPlayback, let asset = native.asset {
            guard let time = native.sourcePosition(playerTime: backend.time) else { return }
            if let length = asset.duration, duration != length { duration = length }
            elapsed = time
            appliedInitialPosition = true
            return
        }
        let length = backend.duration
        if length.isFinite, length > 0, length != duration { duration = length }
        let time = backend.time
        guard time.isFinite else { return }
        if let reopenPosition {
            // Until the reopened stream is back where it was, its clock reads
            // from nothing, and showing or saving that would lose the
            // viewer's place. The last good position stands in meanwhile.
            // Only the reopened stream is judged: until it is playing, the
            // stopped one is still the player's media.
            guard retryAt == nil, backend.isPlaying, length > 0, time > 0 else { return }
            let target = min(max(reopenPosition, 0), max(duration - 1, 0))
            if opened(at: target, time: time) {
                elapsed = time
            } else {
                backend.seek(to: target)
                elapsed = target
            }
            self.reopenPosition = nil
            return
        }
        if duration > 0, !appliedInitialPosition, let requestedInitialPosition,
           requestedInitialPosition >= 10, requestedInitialPosition < duration - 30 {
            // The place it was left off holds the bar until the picture is
            // there, rather than a zero that jumps.
            guard backend.isPlaying, time > 0 else { elapsed = requestedInitialPosition; return }
            let target = min(max(requestedInitialPosition, 0), duration - 1)
            if opened(at: target, time: time) {
                elapsed = time
            } else {
                backend.seek(to: target)
                elapsed = target
            }
            appliedInitialPosition = true
            return
        }
        // A stream that has dropped reads its clock as nothing. The place it
        // was playing stands until it plays again, so neither the bar, nor
        // the place saved, nor the place it is reopened at is lost with it:
        // reopening "where it was" from a zero started films over.
        if time <= 0, !backend.isPlaying, elapsed > 0 { return }
        guard seekLanding.accepts(time, now: uptime()) else { return }
        elapsed = duration > 0 ? min(max(time, 0), duration) : max(time, 0)
    }

    func beginScrubbing() {
        guard !isLive, duration.isFinite, duration > 0, !isScrubbing else { return }
        isScrubbing = true
        scrubDestination = elapsed
        scrubSeeks.cancel()
        resumeAfterScrubbing = !pausedByUser
        if resumeAfterScrubbing { togglePlayback() }
    }

    func previewScrubbing(at seconds: Double) {
        guard isScrubbing, seconds.isFinite else { return }
        let target = PlaybackSeekPolicy.clamped(seconds, duration: duration)
        scrubDestination = target
        guard nativeSiloPlayback?.asset?.requiresServerSeek != true else { return }
        scrubSeeks.preview(target) { [weak self] in self?.backend.seek(to: $0) }
    }

    func endScrubbing(at seconds: Double) {
        guard isScrubbing else { return }
        isScrubbing = false
        scrubDestination = nil
        seek(to: seconds)
        if resumeAfterScrubbing { togglePlayback() }
        resumeAfterScrubbing = false
    }

    func finishScrubbing(resume: Bool = true) {
        guard isScrubbing else { return }
        if !resume { resumeAfterScrubbing = false }
        endScrubbing(at: scrubDestination ?? elapsed)
    }

    func seek(to seconds: Double) {
        guard duration > 0, seconds.isFinite else { return }
        let target = PlaybackSeekPolicy.clamped(seconds, duration: duration)
        if let native = nativeSiloPlayback, native.asset?.requiresServerSeek == true {
            scrubSeeks.cancel()
            native.seek(to: target)
            elapsed = target
            return
        }
        appliedInitialPosition = true
        reopenPosition = nil
        seekLanding.expect(target, now: uptime())
        scrubSeeks.commit(target) { [weak self] in self?.backend.seek(to: $0) }
        elapsed = target
    }

    /// Steps by `seconds` and clamps inside the item through the active engine.
    func seek(by seconds: TimeInterval) {
        guard duration > 0 else { return }
        seek(to: elapsed + seconds)
    }

    func checkPlayback() {
        let nextMediaInfo = backend.mediaInfo
        if mediaInfo != nextMediaInfo { mediaInfo = nextMediaInfo }
        guard !isScrubbing else { return }
        holdAudioLevel()
        updateProgress()
        if seekLanding.isWaiting(now: uptime()) { health = freshHealth(); return }
        followRecordingIntoNextProgramme()
        addOnlineSubtitlesAgain()
        refreshSubtitleTracks()
        refreshStreamTracks()
        applyShowTracks()
        restoreTrackChoices()
        holdScreenAwake()
        noteCondition()
        guard !pausedByUser, error == nil, !urls.isEmpty else { return }
        let now = uptime()
        guard UIApplication.shared.applicationState == .active else {
            health = freshHealth()
            return
        }
        if let retryAt {
            if now >= retryAt { openCurrent() }
            return
        }
        // VLC finishes a stop on its own thread, so a stream reopened a moment
        // ago can still read as stopped or ended while the new one starts.
        // A channel has only stopped or ended once it has played since it was
        // opened, or once it has had long enough to; before that it is judged
        // by whether a picture comes at all.
        let state = backend.state
        if state == .error, engineKind == .mpv {
            fallbackFromMPVToVLC("MPV reported a playback error")
            return
        }
        let failed = state == .error
            || ((state == .ended || state == .stopped)
                && (!isLive || health.hasShownPicture || health.age(now: now) >= 8))
        // A film or an episode that stops at its end has finished. The same
        // stop anywhere earlier is a dropped stream, reopened below.
        if !isLive, reopenPosition == nil,
           LocalMediaTrackingPolicy.reachedEnd(ended: state == .ended, failed: failed,
               hasPlayed: sawPicture, position: elapsed, duration: duration, fraction: duration > 0 ? elapsed / duration : 0) {
            log("Reached the end at \(PlaybackJournal.clock(elapsed)) of \(PlaybackJournal.clock(duration))")
            finish()
            return
        }
        // What has been read from the server tells a feed VLC is catching up
        // on from one that has stopped coming.
        let recover = health.observe(now: now, playing: backend.isPlaying, video: backend.hasVideoOut,
            time: backend.time.isFinite ? Int32(clamping: Int64(min(max(backend.time * 1000, 0), Double(Int32.max)))) : 0,
            frames: backend.frames,
            bytes: backend.bytes, failed: failed)
        if health.isStable(now: now) {
            retries.reset()
            if let id = pendingWorkingChannelID, id == currentChannelID {
                pendingWorkingChannelID = nil
                failover?.didPlay(id)
            }
        }
        if isPlaying != backend.isPlaying { isPlaying = backend.isPlaying }
        if backend.isPlaying && backend.hasVideoOut {
            if reconnecting { reconnecting = false }
            sawPicture = true
            let height = Int(backend.videoSize.height)
            if height > 0, height != videoHeight { videoHeight = height }
            liveQualityReporter.observe(url: urls.indices.contains(urlIndex) ? urls[urlIndex] : nil,
                width: Int(backend.videoSize.width), height: height, frameRate: mediaInfo.frameRate,
                live: isLive && catchUp == nil, playing: backend.isPlaying, picture: health.hasShownPicture)
        }
        guard recover else { return }
        if isLive, !health.hasShownPicture, urls.indices.contains(urlIndex) {
            let url = urls[urlIndex]
            Task { await LiveQualityVerifier.shared.forgetPlayback(url: url) }
        }
        if engineKind == .mpv, !health.hasShownPicture {
            fallbackFromMPVToVLC("MPV did not produce a picture")
            return
        }
        let reason: String
        switch health.stall {
        case .frozenWhileArriving:
            reason = "The picture stood still for \(isLive ? 45 : 60) seconds while the stream kept arriving"
        case .nothingArriving:
            reason = "Nothing arrived for \(isLive ? 12 : 30) seconds"
        case .neverPlayed:
            reason = "No picture came within 30 seconds"
        case .failed, nil:
            reason = engineTitle + " reported the stream " + Self.describe(state)
        }
        // A channel the server closed while it played is opened again at once
        // on the same address, as other players do. Waiting, then trying the
        // other address, turned a moment's drop into a long "Reconnecting".
        let droppedWhilePlaying = isLive && health.stall == .failed && state != .error && health.hasShownPicture
        let neverPlayed = !health.hasShownPicture
        backend.stop()
        // A recorded title goes back to where it was, not to its beginning:
        // reconnecting a film used to start it over.
        if !isLive, reopenPosition == nil, elapsed > 0 {
            reopenPosition = max(0, elapsed - 2)
        }
        // A recording that stops is picked up from where it had got to --
        // or, having reached the present or the end of its programme, isn't.
        if catchUp != nil, recordingStopped() { return }
        guard var delay = retries.nextDelay() else {
            log(reason + ". Gave up after \(retries.attempts) tries")
            // Another channel live is no answer to a recording that won't play.
            if catchUp == nil, switchToNextChannel() { return }
            error = "The stream disconnected. Select Retry to reconnect."
            reconnecting = false
            holdScreenAwake()
            return
        }
        if droppedWhilePlaying { delay = 0 }
        log(reason + (isLive || elapsed <= 0 ? "" : " at " + PlaybackJournal.clock(elapsed))
            + (delay == 0 ? ". Reconnecting now" : ". Reconnecting in \(Int(delay)) s")
            + " (try \(retries.attempts))")
        // An address that will not open twice is swapped for the channel's
        // other one. An address that played and then dropped stays: it works.
        if neverPlayed, retries.attempts > 1 { urlIndex = (urlIndex + 1) % urls.count }
        reconnecting = true
        retryAt = now + delay
    }

    /// MPV is an opt-in trial. Preserve the current title and position, then
    /// move this playback session to VLC if MPV rejects or cannot render it.
    private func fallbackFromMPVToVLC(_ reason: String) {
        guard engineKind == .mpv, !urls.isEmpty else { return }
        log(reason + ". Switching to VLC")
        backend.stop()
        backend = backendFactory(.vlc)
        engineKind = backend.kind
        mountBackend()
        if !isLive, reopenPosition == nil, elapsed > 0 {
            reopenPosition = max(0, elapsed - 2)
        }
        retryAt = nil
        reconnecting = true
        error = nil
        failoverNotice = "MPV trial could not play this stream. Switched to VLC."
        noticeTask?.cancel()
        noticeTask = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(6)) } catch { return }
            self?.failoverNotice = nil
        }
        openCurrent()
    }

    private func switchToNextChannel() -> Bool {
        guard let failover else { return false }
        while let next = failoverState.next(from: failover.plan(), current: currentChannelID) {
            let nextURLs = failover.urls(next.streamID)
            guard !nextURLs.isEmpty else { continue }
            log("Switching to another channel: " + next.name)
            start(urls: nextURLs, muted: muted, channelID: next.streamID, resetFailover: false)
            activeChannelName = next.name
            pendingWorkingChannelID = next.streamID
            failoverNotice = next.notice
            noticeTask?.cancel()
            noticeTask = Task { [weak self] in
                do { try await Task.sleep(for: .seconds(5)) } catch { return }
                self?.failoverNotice = nil
            }
            return true
        }
        return false
    }

    func setMuted(_ muted: Bool) {
        self.muted = muted
        isMuted = muted
        backend.isMuted = muted
    }

    /// Bring this picture's sound in or out over a moment instead of cutting
    /// it, so moving between two pictures crossfades between their sound.
    /// A quiet picture ends muted as well as at zero, which is the state the
    /// playback monitor then holds it in.
    func fadeAudio(audible: Bool, over duration: Double = 0.35) {
        fadeTask?.cancel()
        fadeTask = nil
        let target: Int32 = audible ? 100 : 0
        targetVolume = target
        if audible && muted {
            // Up from silence, never from wherever the level was left.
            backend.volume = 0
            setMuted(false)
        }
        let start = muted ? 0 : max(0, backend.volume)
        guard duration > 0, start != target else {
            backend.volume = target
            if !audible { setMuted(true) }
            return
        }
        let steps = max(1, Int(duration * 50))
        fadeTask = Task { [weak self] in
            for step in 1...steps {
                do { try await Task.sleep(for: .seconds(duration / Double(steps))) } catch { return }
                guard let self else { return }
                // Eased at both ends, so the change has no audible corner.
                let t = Double(step) / Double(steps)
                let eased = t * t * (3 - 2 * t)
                self.backend.volume = Int32((Double(start) + Double(target - start) * eased).rounded())
            }
            guard let self, !Task.isCancelled else { return }
            if !audible { self.setMuted(true) }
            self.fadeTask = nil
        }
    }

    /// Every tick, and before anything else the monitor does: mute and level
    /// are held where they were last set rather than trusted to survive a
    /// reconnect, which is how a quiet picture used to leak sound.
    ///
    /// Only what differs is written. VLC's audio output on Apple TV mutes by
    /// stopping its audio unit and unmutes by starting it again, so writing
    /// the same mute twice a second -- while paused too -- kept restarting
    /// the sound under a playing picture.
    private func holdAudioLevel() {
        // Turned down to nothing and not fading: muted, however it got here.
        if fadeTask == nil, targetVolume == 0, !muted { setMuted(true) }
        if backend.isMuted != muted { backend.isMuted = muted }
        guard fadeTask == nil, backend.volume != targetVolume else { return }
        backend.volume = targetVolume
    }
    func toggleMute() { setMuted(!muted) }
    func retry() {
        if let nativeSiloPlayback { nativeSiloPlayback.retry(); return }
        let place = isLive ? nil : (reopenPosition ?? (elapsed > 0 ? elapsed : nil))
        log("Retry chosen")
        // Asked for before the stream opens, so it opens there.
        start(urls: Array(urls.reversed()), muted: muted, initialPosition: place,
              channelID: currentChannelID, isLive: isLive, keepTrackChoices: true, recording: sourceIsRecording)
    }
    /// A channel reconnects at its live edge; a film or an episode starts over
    /// from its beginning -- and stays a film. Restart used to reopen it as a
    /// channel, which took away its ending: a drop or the real end then
    /// started it over again.
    func goLive() {
        if let nativeSiloPlayback {
            if pausedByUser { togglePlayback() }
            if nativeSiloPlayback.asset?.requiresServerSeek == true {
                nativeSiloPlayback.seek(to: 0); elapsed = 0
            } else { seek(to: 0) }
            return
        }
        if catchUp != nil || pausedAt != nil, let source = catchUpSource {
            log("Back to live")
            skipTask?.cancel()
            skipTarget = nil
            catchUp = nil
            pausedAt = nil
            start(urls: source.liveURLs, muted: muted, channelID: source.stream.id,
                  resetFailover: false, isLive: true, keepTrackChoices: true)
            return
        }
        guard !urls.isEmpty else { return }
        log(isLive ? "Go Live chosen" : "Restart chosen")
        start(urls: Array(urls.reversed()), muted: muted, channelID: currentChannelID, isLive: isLive,
              keepTrackChoices: true)
    }
    func togglePlayback() {
        pausedByUser.toggle()
        if pausedByUser {
            backend.pause()
            // A channel the provider records picks up from here, however
            // long the pause: the broadcast doesn't wait, but its recording
            // does.
            if isLive, catchUp == nil, catchUpSource != nil { pausedAt = Date() }
            if isLive, catchUp == nil { liveHoldSince = Date() }
        } else if let pausedAt, catchUp == nil, catchUpSource != nil,
                  Date().timeIntervalSince(pausedAt) >= CatchUpPolicy.resumeFromPauseAfter {
            self.pausedAt = nil
            liveHoldSince = nil
            log("Resumed from the pause, behind live")
            rewindFromLive(to: pausedAt.addingTimeInterval(-CatchUpPolicy.liveLatency))
            return
        } else {
            pausedAt = nil
            if let since = liveHoldSince {
                liveHeldSeconds += Date().timeIntervalSince(since)
                liveHoldSince = nil
            }
            health = freshHealth()
            if retryAt == nil { backend.play() }
        }
        isPlaying = backend.isPlaying
        holdScreenAwake()
    }

    // MARK: Catch-up

    /// What is on screen while a recording plays: a skip's destination while
    /// it waits, else where the stream has got to.
    var catchUpPosition: Date? {
        guard let catchUp else { return nil }
        return skipTarget ?? catchUp.position(playedSeconds: elapsed)
    }

    /// How far the viewer's own doing has put the picture behind live: a
    /// channel's recording played behind the broadcast, or a pause on it.
    /// What the live stats hold back on top of the stream's own delay.
    var secondsBehindLive: TimeInterval {
        guard isLive else { return 0 }
        if let position = catchUpPosition {
            return max(0, Date().timeIntervalSince(position) - CatchUpPolicy.liveLatency)
        }
        var held = liveHeldSeconds
        if let liveHoldSince { held += Date().timeIntervalSince(liveHoldSince) }
        return held
    }

    // MARK: Frames for Auto Sync

    /// The picture on screen, for Auto Sync to read the scoreboard in.
    func captureFrame() async -> CapturedVideoFrame? {
        guard error == nil, isPlaying else { return nil }
        return await backend.captureFrame()
    }

    /// Done reading frames.
    func releaseFrameOutput() { backend.releaseFrameOutput() }

    /// The programme from its start -- the one a recording is playing, or
    /// the one on now when the provider records the channel and the guide
    /// knows what is on.
    var canStartOver: Bool {
        guard isLive, let catchUpSource else { return false }
        return catchUp != nil || catchUpSource.programme(Date()) != nil
    }

    /// The programme from its beginning: the one a recording is playing, or
    /// the one on now, carrying on past its end.
    func startOver() {
        if let catchUp {
            log("Start Over chosen")
            playRecording(from: catchUp.programmeStart, programmeStart: catchUp.programmeStart,
                          programmeEnd: catchUp.programmeEnd, title: catchUp.title,
                          endsWithProgramme: recordingEndsWithProgramme)
            return
        }
        guard let source = catchUpSource, let programme = source.programme(Date()) else { return }
        log("Start Over chosen")
        playRecording(from: programme.start, programmeStart: programme.start,
                      programmeEnd: programme.end, title: programme.title, endsWithProgramme: false)
    }

    /// A programme from the past, from its start to its end.
    /// Nothing to play: the reason, in place of the picture, and nothing
    /// else opened in its stead.
    func unavailable(_ message: String) {
        stop()
        error = message
        log("Unavailable: " + message)
    }

    func playRecording(of programme: CatchUpProgramme) {
        log("Playing a recording from " + programme.start.formatted(date: .abbreviated, time: .shortened))
        playRecording(from: programme.start, programmeStart: programme.start,
                      programmeEnd: programme.end, title: programme.title,
                      endsWithProgramme: programme.end <= Date())
    }

    /// Back or on by `seconds`. A film steps through itself. A channel the
    /// provider records goes back into its recording, and a recording that
    /// is brought up to the present goes back to live. Presses in quick
    /// succession add up before the stream is reopened, so holding the
    /// remote doesn't reopen it on every step.
    func skip(by seconds: TimeInterval) {
        guard isLive else { seek(by: seconds); return }
        guard catchUpSource != nil else { return }
        let now = Date()
        guard let catchUp else {
            // Already live: only back means anything.
            guard seconds < 0 else { return }
            rewindFromLive(to: now.addingTimeInterval(seconds - CatchUpPolicy.liveLatency))
            return
        }
        var target = (catchUpPosition ?? now).addingTimeInterval(seconds)
        if recordingEndsWithProgramme {
            target = min(max(target, catchUp.programmeStart), catchUp.programmeEnd.addingTimeInterval(-5))
        } else if now.timeIntervalSince(target) < CatchUpPolicy.liveTolerance {
            goLive()
            return
        }
        // Within the open stream, when the server lets it be moved through.
        let offset = target.timeIntervalSince(catchUp.streamStart)
        if skipTarget == nil, backend.isSeekable, offset >= 0, offset <= max(elapsed, 0) + 60 {
            backend.seek(to: offset)
            elapsed = offset
            return
        }
        skipTarget = target
        skipTask?.cancel()
        skipTask = Task { [weak self] in
            do { try await Task.sleep(for: .milliseconds(700)) } catch { return }
            guard let self, let target = self.skipTarget, let catchUp = self.catchUp else { return }
            self.skipTarget = nil
            self.playRecording(from: target, programmeStart: catchUp.programmeStart,
                               programmeEnd: catchUp.programmeEnd, title: catchUp.title,
                               endsWithProgramme: self.recordingEndsWithProgramme)
        }
    }

    /// From live into the recording, at a time just gone.
    private func rewindFromLive(to time: Date) {
        guard let source = catchUpSource else { return }
        let programme = source.programme(time)
        playRecording(from: time,
                      programmeStart: programme?.start ?? CatchUpPolicy.minute(time),
                      programmeEnd: programme?.end ?? Date().addingTimeInterval(30 * 60),
                      title: programme?.title ?? source.stream.name,
                      endsWithProgramme: false)
    }

    private func playRecording(from position: Date, programmeStart: Date, programmeEnd: Date,
                               title: String, endsWithProgramme: Bool) {
        guard let source = catchUpSource else { return }
        let begin = CatchUpPolicy.minute(max(position, programmeStart.addingTimeInterval(-60)))
        // A programme from the past is asked for to its end. Anything still
        // being shown is asked for up to now, and picked up again from where
        // it got to when that runs out.
        let until = endsWithProgramme ? programmeEnd : Date()
        let addresses = source.addresses(begin, until)
        guard !addresses.isEmpty else { return }
        skipTask?.cancel()
        skipTarget = nil
        recordingEndsWithProgramme = endsWithProgramme
        pausedAt = nil
        // `start` tries the last address first, as it does a channel's two.
        start(urls: Array(addresses.reversed()), muted: muted, channelID: source.stream.id,
              resetFailover: false, isLive: true, keepTrackChoices: true, recording: true)
        catchUp = CatchUpTimeline(programmeStart: programmeStart, programmeEnd: programmeEnd,
                                  title: title, streamStart: begin)
    }

    /// A recording's stream has stopped: the end of the programme, the
    /// present caught up with, or a drop. True when it has been dealt with
    /// here; false to reconnect, from where it had got to.
    private func recordingStopped() -> Bool {
        guard let catchUp, let source = catchUpSource else { return false }
        let position = catchUp.position(playedSeconds: elapsed)
        if recordingEndsWithProgramme, position >= catchUp.programmeEnd.addingTimeInterval(-30) {
            log("The recording reached the end of the program")
            finish()
            return true
        }
        if !recordingEndsWithProgramme, Date().timeIntervalSince(position) < CatchUpPolicy.liveTolerance {
            log("Caught up with the channel")
            goLive()
            return true
        }
        let begin = CatchUpPolicy.minute(position)
        let addresses = source.addresses(begin, recordingEndsWithProgramme ? catchUp.programmeEnd : Date())
        guard !addresses.isEmpty else { return false }
        // Stored in the order they are tried, as `start` leaves them.
        urls = addresses
        urlIndex = 0
        elapsed = 0
        self.catchUp = CatchUpTimeline(programmeStart: catchUp.programmeStart, programmeEnd: catchUp.programmeEnd,
                                       title: catchUp.title, streamStart: begin)
        return false
    }

    /// A recording that carries on past its programme's end takes the next
    /// programme's name and timeline.
    private func followRecordingIntoNextProgramme() {
        guard let catchUp, !recordingEndsWithProgramme, let source = catchUpSource,
              let position = catchUpPosition, position >= catchUp.programmeEnd,
              let next = source.programme(position), next.start >= catchUp.programmeEnd.addingTimeInterval(-60)
        else { return }
        self.catchUp = CatchUpTimeline(programmeStart: next.start, programmeEnd: next.end,
                                       title: next.title, streamStart: catchUp.streamStart)
    }

    /// A subtitle track, or Off. Chosen by the viewer, it is kept for the
    /// show's next episodes too.
    func selectSubtitle(_ track: PlaybackSubtitleTrack, byViewer: Bool = true) {
        backend.selectSubtitle(index: track.engineIndex)
        selectedSubtitleID = track.id
        chosenSubtitle = track
        adoptsAddedSubtitle = false
        if byViewer {
            appliedShowSubtitle = true
            rememberSubtitle(track)
        }
    }

    private func refreshSubtitleTracks() {
        let discovered = backend.subtitles
        if discovered != subtitleTracks { subtitleTracks = discovered }
        let selected = discovered.first { $0.engineIndex == backend.selectedSubtitleIndex }
        if adoptsAddedSubtitle, let selected, selected.id != PlaybackSubtitleTrack.off.id {
            adoptsAddedSubtitle = false
            chosenSubtitle = selected
        }
        let selectedID = selected?.id ?? PlaybackSubtitleTrack.off.id
        if selectedID != selectedSubtitleID { selectedSubtitleID = selectedID }
    }

    private func resetSubtitles() {
        subtitleTracks = [.off]
        selectedSubtitleID = PlaybackSubtitleTrack.off.id
        audioTracks = []
        selectedAudioTrackID = nil
        videoTracks = []
        selectedVideoTrackID = nil
    }

    /// An audio track. Chosen by the viewer, it is kept for the show's next
    /// episodes too.
    func selectAudioTrack(_ track: PlaybackStreamTrack, byViewer: Bool = true) {
        backend.selectAudio(index: track.id)
        selectedAudioTrackID = track.id
        chosenAudioTrack = track.id
        guard byViewer else { return }
        appliedShowAudio = true
        guard let show = trackMemoryShow else { return }
        var kept = showTracks ?? MobileShowTracks()
        kept.audio = MobileTrackMemory.choice(for: Self.option(track))
        showTracks = kept
        MobileTrackMemory.save(kept, for: show, defaults: defaults)
    }

    // MARK: Subtitle settings, online subtitles, and a show's tracks

    func setSubtitlePreferences(_ value: MobileSubtitlePreferences) {
        guard value != subtitlePreferences else { return }
        subtitlePreferences = value
        value.save(to: defaults)
        if !isLive { backend.styleSubtitles(subtitleStyle) }
    }

    func setSubtitleDelay(_ seconds: Double) {
        let delay = MobileSubtitlePreferences.delay(seconds)
        guard delay != subtitleDelaySeconds else { return }
        subtitleDelaySeconds = delay
        if !isLive { backend.styleSubtitles(subtitleStyle) }
    }

    private var subtitleStyle: PlaybackSubtitleStyle {
        PlaybackSubtitleStyle(scale: subtitlePreferences.scale, background: subtitlePreferences.background,
                              delay: subtitleDelaySeconds)
    }

    /// VLC sets a title's subtitle size and background as it opens it.
    var subtitleLooksApplyNextTitle: Bool { engineKind == .vlc }

    /// What a title opens with: the show's kept languages, else the viewer's
    /// subtitle language. Subtitles kept off open with none.
    private var openingLanguages: PlaybackLanguages {
        var languages = PlaybackLanguages()
        if let showTracks, showTracks.hasSubtitleChoice {
            languages.subtitles = showTracks.subtitlesOff ? [] : [showTracks.subtitle?.language].compactMap { $0 }
        } else if !subtitlePreferences.language.isEmpty {
            languages.subtitles = [subtitlePreferences.language]
        }
        if let audio = showTracks?.audio?.language { languages.audio = [audio] }
        return languages
    }

    /// Keeps the sound and subtitles chosen for a show's episodes and puts
    /// them back on the next one. Set before `start`, so the title opens on
    /// the kept languages rather than switching to them.
    func remembersTracks(forShow show: String?) {
        trackMemoryShow = show
        showTracks = show.flatMap { MobileTrackMemory.load($0, defaults: defaults) }
    }

    var canAttachOnlineSubtitles: Bool { !isLive && error == nil && !urls.isEmpty }

    /// A subtitle file found online, for the title in `session`: checked,
    /// written to a file of its own off the main thread, and added to what
    /// is playing.
    func addOnlineSubtitle(_ data: Data, title: String, language: String, session: UUID) async throws {
        guard session == subtitleSession, canAttachOnlineSubtitles else { throw MobileSubtitleFailure.unsupported }
        let offset = nativeSiloPlayback?.asset?.lease.timelineOffset ?? 0
        let preparation = Task.detached(priority: .userInitiated) { () throws -> URL in
            guard let data = MobileOpenSubtitles.normalizedSubtitle(data) else { throw MobileSubtitleFailure.invalidFile }
            let prepared = try SubtitleSourceTimeline.rebase(data, offset: offset)
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent("LineupSubtitles", isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let file = directory.appendingPathComponent(UUID().uuidString).appendingPathExtension("srt")
            try prepared.write(to: file, options: .atomic)
            return file
        }
        let file = try await withTaskCancellationHandler(operation: { try await preparation.value },
                                                         onCancel: { preparation.cancel() })
        guard !Task.isCancelled, session == subtitleSession, canAttachOnlineSubtitles else {
            try? FileManager.default.removeItem(at: file)
            throw MobileSubtitleFailure.unsupported
        }
        guard backend.addSubtitle(file: file, title: title, language: language) else {
            try? FileManager.default.removeItem(at: file)
            throw MobileSubtitleFailure.invalidFile
        }
        onlineSubtitles.append(OnlineSubtitle(file: file, title: title, language: language))
        nativeSiloPlayback?.rememberSubtitle(data, title: title, language: language)
        chosenSubtitle = nil
        adoptsAddedSubtitle = true
        log("Added subtitles found online")
    }

    /// After a reconnect: the subtitles found online, added to the reopened
    /// title once it is showing.
    private func addOnlineSubtitlesAgain() {
        if backend.hasVideoOut, !pendingSiloSidecars.isEmpty, siloSidecarRestore == nil {
            let saved = pendingSiloSidecars, session = subtitleSession
            pendingSiloSidecars = []
            siloSidecarRestore = Task { [weak self] in
                guard let self else { return }
                defer { self.siloSidecarRestore = nil }
                do {
                    for subtitle in saved {
                        try await self.addOnlineSubtitle(subtitle.data, title: subtitle.title, language: subtitle.language, session: session)
                    }
                    guard self.subtitleSession == session else { return }
                    self.refreshSubtitleTracks()
                    if self.siloSubtitleWasOff { self.selectSubtitle(.off, byViewer: false) }
                    else if let title = self.siloSubtitleTitle, let selected = self.subtitleTracks.first(where: { $0.title == title }) {
                        self.selectSubtitle(selected, byViewer: false)
                    }
                } catch { if !Task.isCancelled { self.failoverNotice = "Subtitles could not be restored after seeking. " + error.localizedDescription } }
            }
        }
        guard !onlineSubtitlesToAdd.isEmpty, backend.hasVideoOut else { return }
        for subtitle in onlineSubtitlesToAdd {
            _ = backend.addSubtitle(file: subtitle.file, title: subtitle.title, language: subtitle.language)
        }
        onlineSubtitlesToAdd = []
    }

    private func discardOnlineSubtitles() {
        siloSidecarRestore?.cancel(); siloSidecarRestore = nil; pendingSiloSidecars = []
        for subtitle in onlineSubtitles { try? FileManager.default.removeItem(at: subtitle.file) }
        onlineSubtitles = []
        onlineSubtitlesToAdd = []
        adoptsAddedSubtitle = false
        subtitleSession = UUID()
    }

    private func rememberSubtitle(_ track: PlaybackSubtitleTrack) {
        guard let show = trackMemoryShow else { return }
        var kept = showTracks ?? MobileShowTracks()
        if track.id == PlaybackSubtitleTrack.off.id {
            kept.subtitlesOff = true
            kept.subtitle = nil
        } else {
            kept.subtitlesOff = false
            kept.subtitle = MobileTrackMemory.choice(for: Self.option(track))
        }
        showTracks = kept
        MobileTrackMemory.save(kept, for: show, defaults: defaults)
    }

    /// The show's kept sound and subtitles, put back once an episode, as
    /// soon as its tracks are known. A track the viewer picks meanwhile wins.
    private func applyShowTracks() {
        guard let showTracks, !isLive else { return }
        if !appliedShowAudio, let audio = showTracks.audio, audioTracks.count > 1 {
            appliedShowAudio = true
            if let match = MobileTrackMemory.match(audio, in: audioTracks.map(Self.option)),
               let track = audioTracks.first(where: { $0.id == match.engineIndex }), track.id != selectedAudioTrackID {
                selectAudioTrack(track, byViewer: false)
                log("Put back the sound kept for this show")
            }
        }
        let offered = subtitleTracks.filter { $0.id != PlaybackSubtitleTrack.off.id }
        if !appliedShowSubtitle, showTracks.hasSubtitleChoice, !offered.isEmpty {
            appliedShowSubtitle = true
            if showTracks.subtitlesOff {
                if selectedSubtitleID != PlaybackSubtitleTrack.off.id { selectSubtitle(.off, byViewer: false) }
            } else if let subtitle = showTracks.subtitle,
                      let match = MobileTrackMemory.match(subtitle, in: offered.map(Self.option)),
                      match.id != selectedSubtitleID,
                      let track = offered.first(where: { $0.id == match.id }) {
                selectSubtitle(track, byViewer: false)
                log("Put back the subtitles kept for this show")
            }
        }
    }

    /// A track as the show memory reads it, its language from its name: the
    /// engines' names carry it ("English · AC3 5.1", "Track 2 - [Spanish]").
    private static func option(_ track: PlaybackStreamTrack) -> MobileTrackOption {
        MobileTrackOption(id: "audio-\(track.id)", title: track.title,
                          language: MobileTrackMemory.language(inTitle: track.title), engineIndex: track.id)
    }

    private static func option(_ track: PlaybackSubtitleTrack) -> MobileTrackOption {
        MobileTrackOption(id: track.id, title: track.title,
                          language: MobileTrackMemory.language(inTitle: track.title), engineIndex: track.engineIndex)
    }

    func selectVideoTrack(_ track: PlaybackStreamTrack) {
        backend.selectVideo(index: track.id)
        selectedVideoTrackID = track.id
        chosenVideoTrack = track.id
    }

    private func restoreTrackChoices() {
        if let chosen = chosenAudioTrack, audioTracks.contains(where: { $0.id == chosen }),
           backend.selectedAudioIndex != chosen {
            backend.selectAudio(index: chosen)
            log("Put the chosen audio track back")
        }
        if let chosen = chosenVideoTrack, videoTracks.contains(where: { $0.id == chosen }),
           backend.selectedVideoIndex != chosen { backend.selectVideo(index: chosen) }
        if let chosen = chosenSubtitle, backend.selectedSubtitleIndex != chosen.engineIndex,
           chosen.engineIndex == nil || subtitleTracks.contains(where: { $0.engineIndex == chosen.engineIndex }) {
            backend.selectSubtitle(index: chosen.engineIndex)
        }
    }

    private func refreshStreamTracks() {
        let audio = backend.audioTracks
        if audio != audioTracks { audioTracks = audio }
        let audioID = backend.selectedAudioIndex.flatMap { index in audio.first { $0.id == index }?.id }
        if audioID != selectedAudioTrackID { selectedAudioTrackID = audioID }
        let video = backend.videoTracks
        if video != videoTracks { videoTracks = video }
        let videoID = backend.selectedVideoIndex.flatMap { index in video.first { $0.id == index }?.id }
        if videoID != selectedVideoTrackID { selectedVideoTrackID = videoID }
    }

    func stop() {
        isScrubbing = false
        resumeAfterScrubbing = false
        scrubDestination = nil
        scrubSeeks.cancel()
        seekLanding.reset()
        monitor?.cancel()
        monitor = nil
        fadeTask?.cancel()
        fadeTask = nil
        // A fade out cut short ends where it was going: muted.
        if targetVolume == 0, !muted { setMuted(true) }
        retryAt = nil
        reopenPosition = nil
        pendingWorkingChannelID = nil
        urls = []
        pausedByUser = false
        // Opened again, the channel plays from its live edge.
        liveHoldSince = nil
        liveHeldSeconds = 0
        reconnecting = false
        isPlaying = false
        videoHeight = 0
        mediaInfo = PlaybackMediaInfo()
        duration = 0
        elapsed = 0
        resetSubtitles()
        if backend.isOpen {
            Self.lastStreamClosed = (uptime(), ObjectIdentifier(self))
        }
        backend.stop()
        if !restarting {
            skipTask?.cancel()
            skipTarget = nil
            catchUp = nil
            pausedAt = nil
            discardOnlineSubtitles()
            holdScreenAwake()
        }
    }

    /// When a player last let a stream go, and which, for the next player
    /// to open its own after.
    private static var lastStreamClosed: (at: TimeInterval, by: ObjectIdentifier)?

    /// A channel's picture standing still for twelve seconds means the feed is
    /// gone. A film on a slow link can buffer for longer and come back by
    /// itself, and reopening it costs the buffer it was filling.
    private func freshHealth() -> LivePlaybackHealth {
        LivePlaybackHealth(now: uptime(), stallLimit: isLive ? 12 : 30)
    }

    /// The end of a film or an episode: the monitor stops, and the position
    /// reads as the end, so it is saved as watched.
    private func finish() {
        monitor?.cancel()
        monitor = nil
        retryAt = nil
        reconnecting = false
        isPlaying = false
        if duration > 0 { elapsed = duration }
        finished = true
        holdScreenAwake()
    }

    // MARK: The screen saver and the log

    /// The screen saver stays away while a watched title plays, as it would
    /// with Apple's own player, and comes back once it is paused, stopped or
    /// given up on. VLC leaves this to the app, and the app had not done it:
    /// a film left alone for the screen saver's few minutes was covered by
    /// it, and the television then went to sleep and the film with it.
    private func holdScreenAwake() {
        let holds = watched != nil && !urls.isEmpty && !pausedByUser && error == nil && !finished
        TVScreenAwake.hold(holds, for: self)
    }

    /// What the stream is doing, noted when it changes.
    private func noteCondition() {
        guard watched != nil else { return }
        let condition: String?
        switch backend.state {
        case .playing where backend.hasVideoOut: condition = "Playing"
        case .paused: condition = pausedByUser ? "Paused" : nil
        case .ended, .error, .stopped: condition = retryAt == nil ? "Stream " + Self.describe(backend.state) : nil
        default: condition = nil
        }
        guard let condition, condition != loggedCondition else { return }
        loggedCondition = condition
        let place = !isLive && elapsed > 0 ? " at " + PlaybackJournal.clock(elapsed) : ""
        log(condition + place)
    }

    private func log(_ text: String) {
        switch watched {
        case .fullScreen: PlaybackJournal.shared.note(text)
        case .splitScreen(let name): PlaybackJournal.shared.note(name + ": " + text)
        case nil: break
        }
    }

    private static func describe(_ state: TVPlaybackState) -> String {
        switch state {
        case .ended: "ended"
        case .error: "failed"
        case .stopped: "stopped"
        case .opening: "opening"
        case .buffering: "buffering"
        case .playing: "playing"
        case .paused: "paused"
        case .esAdded: "listing its tracks"
        @unknown default: "in an unknown state"
        }
    }
}

/// Holds the screen saver off while any watched player is playing: full
/// screen, or either of split screen's pictures. tvOS has one switch for the
/// whole app, so each player holds or releases its own claim on it.
@MainActor private enum TVScreenAwake {
    private static var holders: Set<ObjectIdentifier> = []

    static func hold(_ holds: Bool, for owner: AnyObject) {
        let id = ObjectIdentifier(owner)
        if holds {
            holders.insert(id)
        } else {
            holders.remove(id)
        }
        // Playback checks call this repeatedly. Reconcile the app-wide flag
        // even when this player's claim is unchanged, in case another tvOS
        // component reset it while a stream was still playing.
        apply()
    }

    static func release(_ id: ObjectIdentifier) {
        guard holders.remove(id) != nil else { return }
        apply()
    }

    private static func apply() {
        let awake = !holders.isEmpty
        guard UIApplication.shared.isIdleTimerDisabled != awake else { return }
        UIApplication.shared.isIdleTimerDisabled = awake
        PlaybackJournal.shared.note(awake ? "Screen saver held off while playing" : "Screen saver allowed again")
    }
}

private struct TVPlaybackEngineBadge: View {
    let engine: TVPlaybackEngine
    /// Full screen, read from across the room.
    var large = false
    var body: some View {
        PlaybackEngineText(engine.title, size: large ? 21 : 13)
            .font(.inter(large ? 21 : 13, .semibold))
            .foregroundStyle(.white)
            .padding(.horizontal, large ? 12 : 8).padding(.vertical, large ? 7 : 4)
            .background(LineupPanelStyle.fill.opacity(0.9), in: RoundedRectangle(cornerRadius: large ? 9 : 6))
            .accessibilityLabel("Playback engine: \(engine.title)")
            .accessibilityIdentifier("lineup.playback.activeEngine")
            .allowsHitTesting(false)
    }
}

/// Preview metadata appears briefly on tune/format changes, then leaves the
/// picture clear. Fullscreen uses the existing controls' visibility instead.
private struct TVPreviewFormatBadges: View {
    @ObservedObject var controller: TVPlaybackController
    @State private var visible = true
    var body: some View {
        PlaybackBadgeFlow {
            TVPlaybackEngineBadge(engine: controller.engineKind)
            if controller.videoHeight > 0 { PlaybackFormatBadge(text: controller.qualityLabel) }
            ForEach(controller.mediaInfo.badges, id: \.self) { PlaybackFormatBadge(text: $0) }
        }
        .padding(10)
        .opacity(visible && controller.isPlaying && controller.error == nil ? 1 : 0)
        .allowsHitTesting(false)
        .task(id: controller.mediaInfo.badges + [controller.engineTitle, controller.qualityLabel, String(controller.isPlaying)]) {
            visible = true
            do { try await Task.sleep(for: .seconds(4)) } catch { return }
            withAnimation(.easeOut(duration: 0.2)) { visible = false }
        }
    }
}

@MainActor private func configureGameFailover(_ controller: TVPlaybackController,
                                               game: SportsGame, library: SportsLibrary,
                                               chooseChannel: @escaping @MainActor () -> Void) {
    let automaticID = library.verifiedStream(for: game)?.id
    controller.failover = TVPlaybackController.FailoverContext(
        plan: { library.failoverPlan(for: game) },
        urls: { id in library.stream(withID: id).map { library.playbackURLs(for: $0) } ?? [] },
        didPlay: { id in
            guard id != automaticID else { return }
            if let working = library.stream(withID: id) {
                library.saveGameSelection(working, for: game)
            }
        },
        chooseChannel: chooseChannel)
}

private struct TVPlaybackStatus: View {
    @ObservedObject var controller: TVPlaybackController
    var body: some View {
        if let error = controller.error {
            VStack(spacing: 16) {
                Text(error).multilineTextAlignment(.center)
                // Over video this is the one thing focusable, so it carries the
                // app's own focus rather than a plate laid over the picture.
                Button("Retry", action: controller.retry).lineupButtonStyle()
                if let choose = controller.failover?.chooseChannel {
                    Button("Choose Another Channel", action: choose).lineupButtonStyle()
                }
            }
            .padding(30)
            .lineupLiquidGlass(RoundedRectangle(cornerRadius: 28, style: .continuous),
                               fallback: Color.black.opacity(0.8), border: .clear)
        } else if let notice = controller.failoverNotice {
            Text(notice).font(.inter(.callout)).foregroundStyle(LineupStyle.mediaText)
                .padding(.horizontal, 22).padding(.vertical, 14)
                .lineupLiquidGlass(Capsule(), fallback: Color.black.opacity(0.8), border: .clear)
        } else if controller.reconnecting {
            ProgressView("Reconnecting…").padding(26)
                .lineupLiquidGlass(RoundedRectangle(cornerRadius: 24, style: .continuous),
                                   fallback: Color.black.opacity(0.8), border: .clear)
        }
    }
}

/// Where a player's picture is shown: a preview, or full screen over it.
///
/// VLC draws into one view for as long as the player lives -- the
/// controller's `surface` -- and each place the picture can be shown holds
/// that view while it is the one in front. Going full screen from a preview
/// moves the view, which VLC never notices: the stream is not closed,
/// reopened or rebuffered, and the picture carries straight on. Handing VLC
/// a new view to draw into instead stops the picture while the sound plays
/// on.
private struct TVHostedSurface: UIViewRepresentable {
    let controller: TVPlaybackController
    /// Full screen comes in front of the preview it was opened from.
    var fullScreen = false

    func makeUIView(context: Context) -> TVSurfaceHost {
        let host = TVSurfaceHost(fullScreen: fullScreen)
        controller.show(in: host)
        return host
    }

    func updateUIView(_ host: TVSurfaceHost, context: Context) {}

    static func dismantleUIView(_ host: TVSurfaceHost, coordinator: ()) {
        host.owner?.stopShowing(in: host)
    }
}

private final class TVSurfaceHost: UIView {
    let fullScreen: Bool
    weak var owner: TVPlaybackController?

    init(fullScreen: Bool) {
        self.fullScreen = fullScreen
        super.init(frame: .zero)
        backgroundColor = .black
        clipsToBounds = true
    }

    required init?(coder: NSCoder) { nil }

    /// The surface keeps the size it is drawn at and is scaled to fit here.
    /// Resizing the view VLC draws into makes it rebuild its output, which
    /// is a hitch in the picture.
    override func layoutSubviews() {
        super.layoutSubviews()
        for surface in subviews {
            let drawn = surface.bounds.size
            guard drawn.width > 0, drawn.height > 0, bounds.width > 0, bounds.height > 0 else { continue }
            let scale = min(bounds.width / drawn.width, bounds.height / drawn.height)
            surface.center = CGPoint(x: bounds.midX, y: bounds.midY)
            surface.transform = CGAffineTransform(scaleX: scale, y: scale)
        }
    }
}

/// Opens full screen at once rather than sliding it in. The picture is
/// already playing, and an entrance would only hold it back behind the
/// screen it is leaving.
@MainActor private func presentWithoutAnimation(_ change: () -> Void) {
    var transaction = Transaction()
    transaction.disablesAnimations = true
    withTransaction(transaction, change)
}

/// What full screen opens on.
private struct TVFullScreenItem: Identifiable {
    let stream: XtreamStream
    var game: SportsGame? = nil
    /// The preview's player, to carry on with rather than open the channel.
    var preview: TVPreviewHandoff? = nil
    /// A programme from the past to play instead of the channel live.
    var recording: CatchUpProgramme? = nil
    /// The programme on now, from its beginning, instead of live.
    var startsOver = false
    /// A replay: the recording or nothing, never the channel live instead.
    var recordingOnly = false
    var id: Int { stream.id }
}


/// A preview's player, lent to full screen.
///
/// Going full screen from a preview closed the preview's stream and opened
/// the same channel again in a second player: a wait for the first
/// connection to close, a black screen while the second buffered, and the
/// game picking up a few seconds on. The preview's own player now goes full
/// screen, and comes back to the preview after, without a break.
final class TVPreviewHandoff {
    fileprivate let controller: TVPlaybackController
    fileprivate init(_ controller: TVPlaybackController) { self.controller = controller }

    private final class Entry {
        let channelID: Int
        weak var controller: TVPlaybackController?
        init(channelID: Int, controller: TVPlaybackController) {
            self.channelID = channelID
            self.controller = controller
        }
    }

    @MainActor private static var previews: [Entry] = []

    /// A preview has opened this channel.
    @MainActor fileprivate static func previewing(_ channelID: Int, in controller: TVPlaybackController) {
        previews.removeAll { $0.controller == nil || $0.controller === controller }
        previews.append(Entry(channelID: channelID, controller: controller))
    }

    /// Stops every preview but this player. A preview covered by full screen
    /// opens again when it is uncovered.
    @MainActor static func stopPreviews(except kept: TVPlaybackController? = nil) {
        for entry in previews {
            guard let controller = entry.controller, controller !== kept, controller.isOpen else { continue }
            controller.lentToFullScreen = false
            controller.stop()
        }
    }

    /// The preview playing this channel, lent to full screen from now:
    /// covered by it, the preview leaves the player playing.
    @MainActor static func lend(playing channelID: Int) -> TVPreviewHandoff? {
        previews.removeAll { $0.controller == nil }
        guard let controller = previews.last(where: { $0.channelID == channelID })?.controller,
              controller.isOpen else { return nil }
        controller.lentToFullScreen = true
        return TVPreviewHandoff(controller)
    }
}
