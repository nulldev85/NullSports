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
struct TVPickedChannel: Identifiable {
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
    func channelScopePrompt(_ picked: Binding<TVPickedChannel?>) -> some View {
        modifier(TVChannelScopePrompt(picked: picked))
    }
}

extension SportsLibrary {
    /// Whether a pick for this game has a team to be kept for.
    func asksScope(for picked: TVPickedChannel?) -> TVPickedChannel? {
        guard let picked, !preferenceSides(for: picked.game).isEmpty else { return nil }
        return picked
    }
}

/// Opens the channel picker for a game, from wherever the game's card is.
private struct LiveChooseChannelKey: EnvironmentKey {
    static let defaultValue: ((SportsGame) -> Void)? = nil
}

extension EnvironmentValues {
    var liveChooseChannel: ((SportsGame) -> Void)? {
        get { self[LiveChooseChannelKey.self] }
        set { self[LiveChooseChannelKey.self] = newValue }
    }
}

/// Choosing the channel to watch a game on: the whole screen, browsed the
/// way the TV Guide is. The provider's categories down the left, as the
/// Guide's sidebar has them, with Lineup's own suggestions first -- its
/// match and the channels saved for either team -- and the chosen list
/// across the rest, each channel with what it is showing now.
struct ManualGameChannelPicker: View {
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
