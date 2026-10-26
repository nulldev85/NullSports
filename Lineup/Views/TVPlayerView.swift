import SwiftUI
import UIKit
import LineupAetherPlayback
import LineupMPVPlayback

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
