import SwiftUI
import UIKit
import LineupAetherPlayback
import LineupMPVPlayback

/// Where playback has got to, for the views that show it and nothing else.
@MainActor final class PlaybackClock: ObservableObject {
    @Published var elapsed: TimeInterval = 0
}

/// Redraws what it holds as playback moves, and nothing around it.
struct PlaybackClockReader<Content: View>: View {
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
        session?.preparing = { [weak self] in self?.error = nil; self?.reconnecting = true }
        session?.retryFailed = { [weak self] message in self?.reconnecting = false; self?.error = message }
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
        // A Silo retry owns the next signed URL. Do not let the old input's
        // watchdog reopen its expired lease while that plan is being fetched.
        if nativeSiloPlayback?.isReplanning == true {
            health = freshHealth()
            holdScreenAwake()
            return
        }
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
        let preparation = Task.detached(priority: .userInitiated) {
            try OnlineSubtitleFiles.write(data, offset: offset)
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

struct TVPlaybackEngineBadge: View {
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
struct TVPreviewFormatBadges: View {
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

@MainActor func configureGameFailover(_ controller: TVPlaybackController,
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

struct TVPlaybackStatus: View {
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
struct TVHostedSurface: UIViewRepresentable {
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

final class TVSurfaceHost: UIView {
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
@MainActor func presentWithoutAnimation(_ change: () -> Void) {
    var transaction = Transaction()
    transaction.disablesAnimations = true
    withTransaction(transaction, change)
}

/// What full screen opens on.
struct TVFullScreenItem: Identifiable {
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
    let controller: TVPlaybackController
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
    @MainActor static func previewing(_ channelID: Int, in controller: TVPlaybackController) {
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
