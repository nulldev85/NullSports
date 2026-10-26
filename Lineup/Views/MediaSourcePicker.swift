import SwiftUI
import Observation
#if os(tvOS)
import UIKit
#endif

/// One place asked for a title's streams: a media server, or the IPTV
/// provider.
enum StreamLookup {
    case server(MediaServerProfile)
    case provider(id: UUID, name: String)

    var id: UUID {
        switch self {
        case .server(let server): server.id
        case .provider(let id, _): id
        }
    }

    /// The server's logo; the provider, not a media server, has none.
    var brand: MediaServerBrand? {
        switch self {
        case .server(let server): MediaServerBrand.of(server)
        case .provider: nil
        }
    }

    /// The tab it is listed under: a server by its name, the provider as
    /// VOD -- the name its streams are grouped under.
    var name: String {
        switch self {
        case .server(let server): server.name
        case .provider: "VOD"
        }
    }
}

/// How one server's search for a title's streams went.
struct StreamServerStatus: Identifiable {
    enum Phase {
        case looking
        /// Waiting on what the looking needs first, and saying so: the IPTV
        /// provider's list, read from the device or downloaded.
        case preparing(String)
        case found(Int)
        /// Carries how the title was looked for there.
        case notOnServer(tried: String)
        case failed(String)
    }

    let id: UUID
    let name: String
    /// The server's logo; nil for VOD, which is the IPTV provider's.
    var brand: MediaServerBrand? = nil
    var phase: Phase

    var detail: String {
        switch phase {
        case .looking: "Looking…"
        case .preparing(let note): note
        case .found(let count): count == 0 ? "No streams" : (count == 1 ? "1 stream" : "\(count) streams")
        case .notOnServer: "Doesn't have this title"
        case .failed(let message): "Didn't answer · " + message
        }
    }

    /// How a server that has no copy of the title was asked for one.
    var tried: String? {
        if case .notOnServer(let tried) = phase { return tried }
        return nil
    }

    var symbol: String {
        switch phase {
        case .looking, .preparing: "hourglass"
        case .found(let count): count > 0 ? "checkmark.circle.fill" : "minus.circle"
        case .notOnServer: "minus.circle"
        case .failed: "exclamationmark.triangle.fill"
        }
    }

    var isGood: Bool {
        if case .found(let count) = phase { return count > 0 }
        return false
    }

    /// Still asking, or still getting ready to.
    var isWaiting: Bool {
        switch phase {
        case .looking, .preparing: true
        default: false
        }
    }

    var isPreparing: Bool {
        if case .preparing = phase { return true }
        return false
    }

    /// What went wrong, for a server that did not answer.
    var failure: String? {
        if case .failed(let message) = phase { return message }
        return nil
    }

    /// What its tab says after its name.
    var mark: MediaStreamTab.Mark {
        switch phase {
        case .looking, .preparing: .looking
        case .found(let count): .count(count)
        case .notOnServer: .missing
        case .failed: .failed
        }
    }
}

extension Notification.Name {
    /// An episode ended with nothing after it: the Library goes back to its
    /// front page.
    static let lineupReturnToLibraryFront = Notification.Name("Lineup.returnToLibraryFront")
}

struct MediaSourcePicker: View {
    @Environment(MediaLibrary.self) private var media
    @Environment(\.dismiss) private var dismiss
    /// The title the streams are for. An episode's end can move it on to the
    /// next one, so the list follows the viewer from one to the next.
    @State private var originalItem: MediaItem
    private var item: MediaItem {
        get { media.displayItem(originalItem) }
        nonmutating set { originalItem = newValue.withMetadata(nil) }
    }
    /// Play from the beginning rather than from the saved place.
    @State private var startsOver: Bool
    /// The episode after this one, when there is one to play, for the
    /// player's Next Episode and for where this one's end leads.
    @State private var nextEpisode: MediaItem?
    /// What the player's closing leads to, set as it closes.
    @State private var advance: Advance?
    /// Play the best stream as soon as it is known: Next Episode was chosen.
    @State private var autoPicks = false

    private enum Advance {
        case playNext(MediaItem)
        case reachedEnd
    }

    init(item: MediaItem, startsOver: Bool = false) {
        _originalItem = State(initialValue: item.withMetadata(nil))
        _startsOver = State(initialValue: startsOver)
    }
    /// Set when the picker went straight to the only stream there was, so
    /// closing the player closes the picker too, rather than leaving a list
    /// of one to back out of.
    @State private var playedOnlySource = false
    @State private var sources: [MediaPlaybackSource] = []
    @State private var loading = true
    @State private var error: String?
    @State private var selectedSource: MediaPlaybackSource?
    @State private var trackingSessionID = UUID()
    @State private var providerFilter: String?
    /// Servers still being asked. What the others found is listed meanwhile.
    @State private var pendingServers = 0
    /// How each server's search for this title went, said at the top of the
    /// list so a server that added nothing says why.
    @State private var serverStatus: [StreamServerStatus] = []

    var body: some View {
        #if os(tvOS)
        // No NavigationStack: its bar is what drew the oversized title and the
        // Close button. The remote's Menu button is how a viewer leaves a
        // screen on this platform.
        board
            .onExitCommand { dismiss() }
            .task(id: media.metadataRequestKey(for: originalItem)) { await media.resolveMetadata(for: originalItem) }
            .task(id: item.libraryKey) { await loadSources() }
            .task(id: item.libraryKey) {
                nextEpisode = nil
                nextEpisode = await media.episodeAfter(item)
            }
            .lineupFullScreenCover(item: $selectedSource, onDismiss: playerClosed) { source in
                playback(for: source)
            }
        #else
        board
        .presentationBackground(.clear)
        .task(id: media.metadataRequestKey(for: originalItem)) { await media.resolveMetadata(for: originalItem) }
        .presentationDragIndicator(.hidden)
        .presentationDetents([.large])
        .task(id: item.libraryKey) { await loadSources() }
        .task(id: item.libraryKey) {
            nextEpisode = nil
            nextEpisode = await media.episodeAfter(item)
        }
        .lineupFullScreenCover(item: $selectedSource, onDismiss: playerClosed) { source in playback(for: source) }
        #endif
    }

    /// Where the player's closing leads. Next Episode plays the next one on
    /// its best stream. An episode that ran to its end without it leads to
    /// the next one's streams to choose from, or, with none after it, back to
    /// the Library's front page. Backing out of the player is where it was.
    private func playerClosed() {
        media.endPlaybackSession(trackingSessionID)
        trackingSessionID = UUID()
        let step = advance
        advance = nil
        switch step {
        case .playNext(let next)?:
            lead(to: next, playing: true)
        case .reachedEnd?:
            if let next = nextEpisode {
                lead(to: next, playing: false)
            } else if item.type == "Episode" {
                dismiss()
                // Once this screen has gone, so the pages under it are not
                // taken away while it is still leaving.
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                    NotificationCenter.default.post(name: .lineupReturnToLibraryFront, object: nil)
                }
            } else if playedOnlySource {
                dismiss()
            }
        case nil:
            if playedOnlySource { dismiss() }
        }
    }

    private func lead(to next: MediaItem, playing: Bool) {
        autoPicks = playing
        playedOnlySource = false
        startsOver = false
        nextEpisode = nil
        item = next
    }

    /// The best stream, as soon as it is known: the first place in the list's
    /// order to answer with streams, once every place before it has answered
    /// with none. Waiting for the slowest server would hold Next Episode up
    /// for a stream that would be listed below the one in hand.
    private static func bestSource(found: [Int: [MediaPlaybackSource]], places: Int) -> MediaPlaybackSource? {
        for index in 0..<places {
            guard let streams = found[index] else { return nil }
            if let best = MediaStreamSection.sections(of: streams).first?.sources.first { return best }
        }
        return nil
    }

    private var board: some View {
        #if os(tvOS)
        MediaStreamBoard(heading: heading, statuses: serverStatus, sources: sources,
                         loading: loading, error: error, filter: $providerFilter,
                         choose: { selectedSource = $0 })
        #else
        MobileStreamPickerBoard(heading: heading, statuses: serverStatus, sources: sources,
                                loading: loading, error: error, filter: $providerFilter,
                                choose: { selectedSource = $0 }, cancel: dismiss.callAsFunction)
        #endif
    }

    /// What the list is for: an episode as its show, number and name, a film
    /// as its name, year and length. The art behind it is the title's own
    /// wide picture -- an episode's still when it has no other -- and never a
    /// poster stretched across the screen.
    private var heading: MediaStreamHeading {
        let line = { (parts: [String?]) -> String? in
            let text = parts.compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: "  ·  ")
            return text.isEmpty ? nil : text
        }
        let backdrop = media.backdropURL(for: item, width: 1920)
            ?? (item.type == "Episode" ? media.imageURL(for: item, width: 1920) : nil)
        if let series = item.seriesName, !series.isEmpty {
            return MediaStreamHeading(title: series, subtitle: line([item.episodeCode, item.name]),
                                      backdrop: backdrop)
        }
        return MediaStreamHeading(title: item.name,
                                  subtitle: line([item.productionYear.map(String.init), item.formattedRuntime]),
                                  backdrop: backdrop)
    }

    /// Every connected server is asked at once: the title's own server about
    /// the title, each other server about its own copy of it. Streams are
    /// listed as they arrive -- the IPTV provider's first, then the title's
    /// own server's, then the others in the order they were added -- rather
    /// than held for the slowest server.
    @MainActor
    private func loadSources() async {
        loading = true
        error = nil
        sources = []
        providerFilter = nil
        let library = media
        let title = item
        // Every server, each about its own copy, and the IPTV provider ahead
        // of them all: its copies are in hand at once and play straight from
        // it. The title's own place -- its server, or the provider for one of
        // the provider's own titles -- failing is the screen's error.
        var lookups = library.streamServers(for: title).map { StreamLookup.server($0) }
        var ownIndex = 0
        if let provider = library.streamProvider(for: title) {
            lookups.insert(.provider(id: provider.id, name: provider.name), at: 0)
            if !title.isProviderTitle, lookups.count > 1 { ownIndex = 1 }
        }
        pendingServers = lookups.count
        let providerWait = library.providerVOD.waitNote
        serverStatus = lookups.map { lookup -> StreamServerStatus in
            var phase = StreamServerStatus.Phase.looking
            if case .provider = lookup, let providerWait { phase = .preparing(providerWait) }
            return StreamServerStatus(id: lookup.id, name: lookup.name, brand: lookup.brand, phase: phase)
        }
        var found: [Int: [MediaPlaybackSource]] = [:]
        var failure: Error?
        await withTaskGroup(of: (Int, Result<[MediaPlaybackSource], Error>).self) { group in
            for (index, lookup) in lookups.enumerated() {
                group.addTask {
                    do {
                        switch lookup {
                        case .server(let server):
                            return (index, .success(try await library.playbackSources(for: title, on: server)))
                        case .provider:
                            return (index, .success(try await library.providerSources(for: title)))
                        }
                    } catch { return (index, .failure(error)) }
                }
            }
            for await (index, answer) in group {
                pendingServers -= 1
                switch answer {
                case .success(let streams):
                    found[index] = streams
                    serverStatus[index].phase = .found(streams.count)
                // The title's own place failing is the error for the screen.
                // Any server's outcome is said in its tab at the top.
                case .failure(let problem):
                    found[index] = found[index] ?? []
                    if index == ownIndex { failure = problem }
                    if let miss = problem as? MediaLibrary.StreamLookupError {
                        serverStatus[index].phase = .notOnServer(tried: miss.tried)
                    } else if !MediaLibrary.isCancellation(problem) {
                        serverStatus[index].phase = .failed(problem.localizedDescription)
                    }
                }
                sources = found.keys.sorted().flatMap { found[$0] ?? [] }
                if !sources.isEmpty { loading = false }
                if autoPicks, selectedSource == nil,
                   let best = Self.bestSource(found: found, places: lookups.count) {
                    autoPicks = false
                    playedOnlySource = true
                    // After a moment, as below: a cover asked for while this
                    // screen is still arriving is dropped.
                    Task { @MainActor in
                        try? await Task.sleep(for: .milliseconds(400))
                        if selectedSource == nil { selectedSource = best }
                    }
                }
            }
        }
        // Nothing to play: the list says so, and the viewer chooses from here.
        autoPicks = false
        guard !Task.isCancelled else { return }
        if sources.isEmpty, let failure { error = failure.localizedDescription }
        pendingServers = 0
        loading = false
        #if os(tvOS)
        // One stream is not a choice: play it. After a moment, so this screen
        // has finished arriving -- a cover asked for mid-presentation is
        // dropped rather than shown.
        if sources.count == 1, error == nil, selectedSource == nil, !playedOnlySource {
            try? await Task.sleep(for: .milliseconds(400))
            guard !Task.isCancelled else { return }
            playedOnlySource = true
            selectedSource = sources.first
        }
        #endif
    }

    // The synopsis type and the player that shows it are both iPhone-only;
    // tvOS has its own player and never builds this.
    #if !os(tvOS)
    /// What is playing, for the panel the player shows with its controls. The
    /// player is handed a URL and a name; everything else about the title lives
    /// here, so it is gathered here.
    private var playerSynopsis: MobilePlayerSynopsis {
        let heading: String?
        if let series = item.seriesName, !series.isEmpty {
            heading = [series, item.episodeCode, item.name]
                .compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · ")
        } else {
            heading = item.name
        }
        let detail = [item.formattedAirDate.map { "Aired \($0)" } ?? item.productionYear.map(String.init),
                      item.formattedRuntime,
                      item.officialRating]
            .compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · ")
        return MobilePlayerSynopsis(heading: heading,
                                    detail: detail.isEmpty ? nil : detail,
                                    overview: item.overview)
    }
    #endif

    #if os(tvOS)
    /// An episode reads as its show, its number and its name; a film as its
    /// name, its year, its length and its rating.
    private var tvPlayerSynopsis: TVPlayerSynopsis {
        let facts = { (parts: [String?]) -> String? in
            let line = parts.compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: "  ·  ")
            return line.isEmpty ? nil : line
        }
        if let series = item.seriesName, !series.isEmpty {
            return TVPlayerSynopsis(
                title: series,
                subtitle: facts([item.episodeCode, item.name]),
                detail: facts([item.formattedAirDate.map { "Aired \($0)" }, item.formattedRuntime,
                               item.officialRating]))
        }
        return TVPlayerSynopsis(
            title: item.name,
            subtitle: facts([item.productionYear.map(String.init), item.formattedRuntime, item.officialRating]),
            detail: item.overview)
    }

    /// The season playing, for the player's Episodes row: each episode on
    /// its still, with its number, length and name as the series page has
    /// them. Choosing one closes the player and plays it on its best
    /// stream, the way Next Episode does.
    private func seasonEpisodes(around playing: MediaItem) -> TVEpisodeList? {
        guard playing.type == "Episode", !playing.isUpcomingPlaceholder else { return nil }
        let library = media
        return TVEpisodeList(season: playing.parentIndexNumber.map { $0 == 0 ? "Specials" : "Season \($0)" }) {
            await library.seasonEpisodes(of: playing).map { original in
                let episode = library.displayItem(original)
                let playback = library.cardPlayback(for: episode, asShow: false)
                return TVEpisodeChoice(
                    id: episode.libraryKey,
                    code: episode.indexNumber.map { "S\(episode.parentIndexNumber ?? 1): E\($0)" },
                    runtime: episode.runtimeMinutes.map { "\($0) min" },
                    title: episode.name,
                    image: library.imageURL(for: episode, width: 640),
                    isCurrent: original.id == playing.id,
                    watched: playback?.watched == true,
                    progress: playback.flatMap { $0.watched || $0.fraction <= 0 ? nil : $0.fraction },
                    play: { advance = .playNext(original) })
            }
        }
    }
    #endif

    private func playback(for source: MediaPlaybackSource) -> some View {
        SiloPlaybackPreparation(item: item, source: source, startsOver: startsOver) { prepared, native in
            playback(for: prepared, nativeSilo: native)
        }
    }

    @ViewBuilder
    private func playback(for source: MediaPlaybackSource, nativeSilo: SiloPlaybackSession?) -> some View {
        if let url = media.playbackURL(for: item, source: source) {
            // Capture this presentation's identity. A late callback from the
            // previous episode must not write progress for the next one.
            let trackedItem = item
            let sessionID = trackingSessionID
            let fromBeginning = startsOver
            #if os(tvOS)
            PlayerView(urls: [url], title: item.name, isLive: false,
                       initialPosition: nativeSilo?.asset?.lease.playerStart ?? (startsOver ? nil : media.resumePosition(for: item)),
                       expectedDuration: nativeSilo != nil ? nativeSilo?.asset?.duration : item.runTimeTicks.map { Double($0) / 10_000_000 },
                       nativeSiloPlayback: nativeSilo,
                       onProgress: { position, duration in
                           media.trackPlayback(of: trackedItem, position: position, duration: duration,
                                               sessionID: sessionID)
                       },
                       onTrackingSample: { sample in media.reportTrackingSample(sample, for: trackedItem, sessionID: sessionID) },
                       synopsis: tvPlayerSynopsis,
                       nextEpisode: nextEpisode.map { next in
                           TVNextEpisodeOffer(code: next.episodeCode, title: next.name) {
                               advance = .playNext(next)
                           }
                       },
                       onReachedEnd: {
                           media.completePlayback(of: trackedItem, sessionID: sessionID)
                           if advance == nil { advance = .reachedEnd }
                       },
                       segmentsLookup: ["Episode", "Movie"].contains(item.type) ? {
                           await media.playbackSegments(for: trackedItem)
                       } : nil,
                       // As on the phone: subtitles found online, the
                       // show's kept tracks, and the server's scrubbing
                       // thumbnails for this copy.
                       subtitleIdentityLookup: { await media.onlineSubtitleIdentity(for: trackedItem) },
                       trackMemoryShow: item.type == "Episode"
                           ? MobileTrackMemory.showKey(seriesName: item.seriesName) : nil,
                       seekPreviewLookup: { await media.seekPreview(for: trackedItem, source: source) },
                       episodes: seasonEpisodes(around: trackedItem))
            .onAppear { media.beginPlaybackSession(for: trackedItem, id: sessionID, startsOver: fromBeginning, nativeSilo: nativeSilo) }
            // After the player's own last report, which it makes as it goes.
            .onDisappear { DispatchQueue.main.async { media.endPlaybackSession(sessionID) } }
            #else
            MobilePlayerView(name: item.name, urls: [url], isLive: false, nativeSiloPlayback: nativeSilo,
                             sourceBitrate: source.formattedBitrate,
                             sourceQuality: source.quality,
                             synopsis: playerSynopsis,
                             segmentsLookup: ["Episode", "Movie"].contains(item.type) ? {
                                 await media.playbackSegments(for: trackedItem)
                             } : nil,
                             subtitleIdentityLookup: {
                                 await media.onlineSubtitleIdentity(for: trackedItem)
                             },
                             trackMemoryShow: item.type == "Episode"
                                 ? MobileTrackMemory.showKey(seriesName: item.seriesName) : nil,
                             seekPreviewLookup: {
                                 await media.seekPreview(for: trackedItem, source: source)
                             },
                             // Start Over starts over here too; it resumed.
                             initialPosition: nativeSilo?.asset?.lease.playerStart ?? (startsOver ? nil : media.resumePosition(for: item)),
                             onProgress: { position, duration in
                                 media.trackPlayback(of: trackedItem, position: position, duration: duration,
                                                     sessionID: sessionID)
                             },
                             onTrackingSample: { sample in media.reportTrackingSample(sample, for: trackedItem, sessionID: sessionID) },
                             nextEpisode: nextEpisode.map { next in
                                 MobileNextEpisodeOffer(code: next.episodeCode, title: next.name) {
                                     advance = .playNext(next)
                                 }
                             },
                             onReachedEnd: {
                                 media.completePlayback(of: trackedItem, sessionID: sessionID)
                                 if advance == nil { advance = .reachedEnd }
                             })
            .onAppear { media.beginPlaybackSession(for: trackedItem, id: sessionID, startsOver: fromBeginning, nativeSilo: nativeSilo) }
            .onDisappear { DispatchQueue.main.async { media.endPlaybackSession(sessionID) } }
            #endif
        } else {
            LineupUnavailableView("Playback Unavailable", systemImage: "play.slash")
        }
    }

}

/// The chip draws its own selection and its own focus, so a remote moving across
/// the row reads the same as a finger tapping one.
/// tvOS lights whatever has focus by drawing a white plate behind it, sized to
/// the whole control. On a poster that plate covers the title under the art as
/// well, and white belongs to no part of this palette. Every focusable thing in
/// these screens turns that effect off and draws its own focus instead: the
/// cards and rows already did, and this is what the chrome around them uses.
/// Something for the remote to hold on to while a screen has nothing else.
///
/// tvOS cannot leave focus nowhere. A pushed screen that is still loading -- or
/// one showing "nothing here" -- contains no focusable view at all, so the
/// engine hands focus back to the tab bar: the bar the viewer cannot see
/// appears to have swallowed their press, and the next press moves them to
/// another tab entirely. That is the whole of the bug where browsing the media
/// tab would suddenly land somewhere else.
///
/// This draws nothing and does nothing. It exists so focus has a home on a
/// screen that is between states, and it goes away with the state that needed
/// it, by which time there is real content to take focus.
extension View {
    func mediaFocusAnchor() -> some View {
        #if os(tvOS)
        overlay(alignment: .center) {
            Color.clear.frame(width: 1, height: 1).focusable()
        }
        #else
        self
        #endif
    }
}

struct MediaChromeSurface: ViewModifier {
    var focused = false
    var prominent = false
    /// A field the viewer types into. It marks focus with its edge only: filling
    /// it would put dark text on a light field mid-sentence, which is the same
    /// jarring inversion this is all here to remove.
    var outline = false
    var radius: CGFloat = 12

    // The search field and the rest of the media chrome sit on the same glass
    // as the player's controls and the Account tab. A prominent control is the
    // exception: it is a call to action and stays filled, because glass is a
    // surface to read through and that one is meant to be looked at.
    @ViewBuilder
    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
        if filled {
            content
                .foregroundStyle(LineupPresentationStyle.ground)
                .background(LineupPresentationStyle.text, in: shape)
                .animation(.spring(response: 0.22, dampingFraction: 0.8), value: focused)
        } else {
            content
                .foregroundStyle(LineupPresentationStyle.text)
                .lineupLiquidGlass(shape, fallback: LineupPresentationStyle.card, border: border)
                .lineupFocusLayer(focused, in: shape)
                .animation(.spring(response: 0.22, dampingFraction: 0.8), value: focused)
        }
    }

    // Focus marks the edge. Only a deliberate call to action fills, and it
    // fills whether or not it happens to be focused, so focus never turns a
    // control into a pale slab.
    private var filled: Bool { !outline && prominent }

    // Constant: a control must look the same whether or not it holds focus.
    private var border: Color { prominent ? .clear : LineupStyle.line }
}

/// The same surface, reading focus from the button wrapped around it rather
/// than being told. A Menu's label cannot read focus this way, so the two menus
/// carry their own focus binding instead.
struct MediaChromeFocus: ViewModifier {
    @Environment(\.isFocused) private var focused
    var prominent = false

    func body(content: Content) -> some View {
        content
            .modifier(MediaChromeSurface(focused: focused, prominent: prominent))
            .scaleEffect(focused ? LineupStyle.controlLift : 1)
            .animation(.spring(response: 0.22, dampingFraction: 0.8), value: focused)
    }
}

/// Padded chrome -- Add Shelf, See All, remove -- around a focusable button.
struct MediaChromeLabel<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        content
            .padding(.horizontal, 12).padding(.vertical, 7)
            .modifier(MediaChromeFocus())
    }
}

// MARK: - The stream list
