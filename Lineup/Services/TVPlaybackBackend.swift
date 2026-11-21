#if os(tvOS)
import UIKit
import AVFoundation
import ImageIO
import VLCKitSPM
import LineupAetherPlayback
import LineupMPVPlayback

enum TVPlaybackState: Equatable {
    case stopped, opening, buffering, playing, paused, ended, error, esAdded
}

/// The languages a title opens with: a show's kept ones, else the viewer's
/// subtitle preference. Empty is the engine's own choice.
struct PlaybackLanguages: Equatable {
    var audio: [String] = []
    var subtitles: [String] = []
}

/// How text subtitles look and when they appear.
struct PlaybackSubtitleStyle: Equatable {
    var scale: Double = 1
    var background = false
    /// Seconds later than the file has them; less than zero, earlier.
    var delay: Double = 0
}

/// Only the engine adapter knows its native player. Lineup owns recovery,
/// catch-up, handoff, screen-awake policy, and local progress for both engines.
@MainActor
protocol TVPlaybackBackend: AnyObject {
    var kind: TVPlaybackEngine { get }
    var surface: UIView { get }
    var state: TVPlaybackState { get }
    var errorMessage: String? { get }
    var isPlaying: Bool { get }
    var hasVideoOut: Bool { get }
    var videoSize: CGSize { get }
    func playbackMetadata() -> (info: PlaybackMediaInfo, pictureSize: CGSize)
    var mediaInfo: PlaybackMediaInfo { get }
    var duration: TimeInterval { get }
    var time: TimeInterval { get }
    var frames: Int? { get }
    var bytes: Int? { get }
    var isSeekable: Bool { get }
    var isOpen: Bool { get }
    var volume: Int32 { get set }
    var isMuted: Bool { get set }
    var subtitles: [PlaybackSubtitleTrack] { get }
    var selectedSubtitleIndex: Int? { get }
    var audioTracks: [PlaybackStreamTrack] { get }
    var selectedAudioIndex: Int? { get }
    var videoTracks: [PlaybackStreamTrack] { get }
    var selectedVideoIndex: Int? { get }
    func load(url: URL, startPosition: TimeInterval?, isLive: Bool, expectedDuration: TimeInterval?, primary: Bool, matchContent: Bool)
    func play()
    func pause()
    func stop()
    func seek(to seconds: TimeInterval)
    func selectSubtitle(index: Int?)
    func selectAudio(index: Int)
    func selectVideo(index: Int)
    var chapters: [PlaybackChapter] { get }
    var forwardBufferSeconds: Double? { get }
    var droppedFrames: Int? { get }
    var networkMbps: Double? { get }
    var canFillVideo: Bool { get }
    func setPlaybackSpeed(_ rate: Double)
    func setVideoFill(_ fills: Bool)
    var canPositionSubtitles: Bool { get }
    func setSubtitlesAtTop(_ top: Bool)
    /// The picture on screen now, for Auto Sync to read the scoreboard in.
    /// Nil when there is none to give yet.
    func captureFrame() async -> CapturedVideoFrame?
    func captureAmbientFrame() async -> CapturedVideoFrame?
    /// Done reading frames: anything attached to read them comes off.
    func releaseFrameOutput()
    /// The languages the next `load` opens with.
    func setOpeningLanguages(_ languages: PlaybackLanguages)
    /// Text subtitles' size, background and timing. VLC takes the size and
    /// background as a title opens and the timing at once; Aether all three
    /// at once.
    func styleSubtitles(_ style: PlaybackSubtitleStyle)
    /// A subtitle file added to what is playing, and chosen. False if the
    /// engine would not take it.
    func addSubtitle(file: URL, title: String, language: String) -> Bool
}

extension TVPlaybackBackend {
    var chapters: [PlaybackChapter] { [] }
    var forwardBufferSeconds: Double? { nil }
    var droppedFrames: Int? { nil }
    var networkMbps: Double? { nil }
    var canFillVideo: Bool { false }
    func setPlaybackSpeed(_ rate: Double) {}
    func setVideoFill(_ fills: Bool) {}
    var canPositionSubtitles: Bool { false }
    func setSubtitlesAtTop(_ top: Bool) {}

    func playbackMetadata() -> (info: PlaybackMediaInfo, pictureSize: CGSize) { (mediaInfo, .zero) }
    func captureAmbientFrame() async -> CapturedVideoFrame? { await captureFrame() }
}

@MainActor
func makeTVPlaybackBackend(_ kind: TVPlaybackEngine) -> any TVPlaybackBackend {
    switch kind {
    case .vlc: TVVLCBackend()
    case .aether: TVAetherBackend()
    case .mpv: TVMPVBackend()
    }
}

@MainActor
final class TVVLCBackend: TVPlaybackBackend {
    let kind = TVPlaybackEngine.vlc
    private let player = VLCMediaPlayer()
    private var chapterCache: (count: Int32, entries: [PlaybackChapter])?

    var chapters: [PlaybackChapter] {
        guard player.hasVideoOut else { return [] }
        let count = player.numberOfChapters(forTitle: -1)
        if let chapterCache, chapterCache.count == count { return chapterCache.entries }
        guard count > 0 else { return [] }
        let descriptions = player.chapterDescriptions(ofTitle: -1) as? [[String: Any]] ?? []
        let entries: [PlaybackChapter] = descriptions.compactMap { description in
            guard let time = description[VLCChapterDescriptionTimeOffset] as? NSNumber else { return nil }
            return PlaybackChapter(start: time.doubleValue / 1_000, title: description[VLCChapterDescriptionName] as? String)
        }
        if !entries.isEmpty { chapterCache = (count, entries) }
        return entries
    }
    func setPlaybackSpeed(_ rate: Double) { player.rate = Float(rate) }
    var canFillVideo: Bool { true }
    func setVideoFill(_ fills: Bool) {
        if fills {
            var ratio = Array("16:9".utf8CString)
            ratio.withUnsafeMutableBufferPointer { player.videoCropGeometry = $0.baseAddress }
        } else {
            player.videoCropGeometry = nil
        }
    }

    private struct MetadataSnapshot {
        let capturedAt: TimeInterval
        let audioTrack: Int32
        let videoTrack: Int32
        let videoSize: CGSize
        let value: (info: PlaybackMediaInfo, pictureSize: CGSize)
    }
    private var cachedMetadata: MetadataSnapshot?
    private var cachedSubtitles: (at: TimeInterval, tracks: [PlaybackSubtitleTrack])?
    private var cachedAudioTracks: (at: TimeInterval, tracks: [PlaybackStreamTrack])?
    private var cachedVideoTracks: (at: TimeInterval, tracks: [PlaybackStreamTrack])?
    let surface = UIView(frame: CGRect(x: 0, y: 0, width: 1920, height: 1080))

    init() {
        surface.backgroundColor = .black
        player.drawable = surface
    }

    deinit { VLCPlayerDisposal.release(player) }

    var state: TVPlaybackState {
        switch player.state {
        case .opening: .opening
        case .buffering: .buffering
        case .playing: .playing
        case .paused: .paused
        case .ended: .ended
        case .error: .error
        case .esAdded: .esAdded
        default: .stopped
        }
    }
    var errorMessage: String? { nil }
    var isPlaying: Bool { player.isPlaying }
    var hasVideoOut: Bool { player.hasVideoOut }
    var videoSize: CGSize { player.videoSize }
    var mediaInfo: PlaybackMediaInfo { playbackMetadata().info }
    func playbackMetadata() -> (info: PlaybackMediaInfo, pictureSize: CGSize) {
        guard player.hasVideoOut else {
            cachedMetadata = nil
            return (PlaybackMediaInfo(), .zero)
        }
        let now = ProcessInfo.processInfo.systemUptime
        let audio = player.currentAudioTrackIndex
        let video = player.currentVideoTrackIndex
        let size = player.videoSize
        if let cachedMetadata, now - cachedMetadata.capturedAt < 2,
           cachedMetadata.audioTrack == audio, cachedMetadata.videoTrack == video,
           cachedMetadata.videoSize == size {
            return cachedMetadata.value
        }
        // VLCKit builds Objective-C dictionaries for all tracks on this call.
        // Keep quality changes and track switches immediate without rebuilding
        // those dictionaries on every progress and health check.
        let value = VLCPlaybackMediaInfo.snapshot(player)
        cachedMetadata = MetadataSnapshot(capturedAt: now, audioTrack: audio, videoTrack: video,
                                          videoSize: size, value: value)
        return value
    }
    var duration: TimeInterval { Double(player.media?.length.intValue ?? 0) / 1000 }
    var time: TimeInterval { Double(player.time.intValue) / 1000 }
    var frames: Int? { player.media.map { Int($0.statistics.displayedPictures) } }
    var bytes: Int? { player.media.map { Int($0.statistics.readBytes) } }
    var isSeekable: Bool { player.isSeekable }
    var isOpen: Bool { player.media != nil }
    var volume: Int32 {
        get { player.audio?.volume ?? 100 }
        set { player.audio?.volume = newValue }
    }
    var isMuted: Bool {
        get { player.audio?.isMuted ?? false }
        set { player.audio?.isMuted = newValue }
    }
    var subtitles: [PlaybackSubtitleTrack] {
        let now = ProcessInfo.processInfo.systemUptime
        if let cachedSubtitles, now - cachedSubtitles.at < 2, !cachedSubtitles.tracks.isEmpty {
            return cachedSubtitles.tracks
        }
        let tracks = PlaybackSubtitleTrack.vlcTracks(names: player.videoSubTitlesNames as? [String] ?? [],
            indexes: (player.videoSubTitlesIndexes as? [NSNumber] ?? []).map(\.intValue))
        cachedSubtitles = (now, tracks)
        return tracks
    }
    var selectedSubtitleIndex: Int? {
        let value = Int(player.currentVideoSubTitleIndex)
        return value >= 0 ? value : nil
    }
    var audioTracks: [PlaybackStreamTrack] {
        let now = ProcessInfo.processInfo.systemUptime
        if let cachedAudioTracks, now - cachedAudioTracks.at < 2, !cachedAudioTracks.tracks.isEmpty {
            return cachedAudioTracks.tracks
        }
        let tracks = PlaybackStreamTrack.vlcTracks(names: player.audioTrackNames as? [String] ?? [],
            indexes: (player.audioTrackIndexes as? [NSNumber] ?? []).map(\.intValue), kind: "Audio")
        cachedAudioTracks = (now, tracks)
        return tracks
    }
    var selectedAudioIndex: Int? { Int(player.currentAudioTrackIndex) }
    var videoTracks: [PlaybackStreamTrack] {
        let now = ProcessInfo.processInfo.systemUptime
        if let cachedVideoTracks, now - cachedVideoTracks.at < 2, !cachedVideoTracks.tracks.isEmpty {
            return cachedVideoTracks.tracks
        }
        let tracks = PlaybackStreamTrack.vlcTracks(names: player.videoTrackNames as? [String] ?? [],
            indexes: (player.videoTrackIndexes as? [NSNumber] ?? []).map(\.intValue), kind: "Video")
        cachedVideoTracks = (now, tracks)
        return tracks
    }
    var selectedVideoIndex: Int? { Int(player.currentVideoTrackIndex) }

    private var languages = PlaybackLanguages()
    private var subtitleStyle = PlaybackSubtitleStyle()

    func load(url: URL, startPosition: TimeInterval?, isLive: Bool, expectedDuration: TimeInterval?, primary: Bool, matchContent: Bool) {
        cachedMetadata = nil
        cachedSubtitles = nil
        cachedAudioTracks = nil
        cachedVideoTracks = nil
        chapterCache = nil
        if player.media != nil { player.stop() }
        let media = VLCMedia(url: url)
        if isLive {
            // Keep live zap times near-instant (~1.2s buffer instead of a forced
            // 5-second black screen on every channel tune).
            media.addOption(":network-caching=1200")
            media.addOption(":live-caching=1200")
            media.addOption(":audio-language=en")
        } else {
            media.addOption(":network-caching=2500")
            if let startPosition { media.addOption(":start-time=\(startPosition)") }
            // VLC reads each language by its code and its two-letter form.
            if !languages.audio.isEmpty { media.addOption(":audio-language=" + Self.vlcLanguages(languages.audio)) }
            if !languages.subtitles.isEmpty { media.addOption(":sub-language=" + Self.vlcLanguages(languages.subtitles)) }
            media.addOption(":freetype-rel-fontsize=\(Int((16 / max(0.5, subtitleStyle.scale)).rounded()))")
            media.addOption(":freetype-background-opacity=\(subtitleStyle.background ? 204 : 0)")
            media.addOption(":freetype-background-color=0")
        }
        media.addOption(":http-reconnect=true")
        player.media = media
        player.currentVideoSubTitleDelay = Int((subtitleStyle.delay * 1_000_000).rounded())
    }

    private static func vlcLanguages(_ codes: [String]) -> String {
        var seen: [String] = []
        for code in codes {
            for form in [code, String(code.prefix(2))] where !form.isEmpty && !seen.contains(form) { seen.append(form) }
        }
        return seen.joined(separator: ",")
    }

    func setOpeningLanguages(_ languages: PlaybackLanguages) { self.languages = languages }

    func styleSubtitles(_ style: PlaybackSubtitleStyle) {
        subtitleStyle = style
        // Microseconds. The size and background wait for the next title.
        player.currentVideoSubTitleDelay = Int((style.delay * 1_000_000).rounded())
    }

    func addSubtitle(file: URL, title: String, language: String) -> Bool {
        cachedSubtitles = nil
        return player.addPlaybackSlave(file, type: .subtitle, enforce: true) == 0
    }
    func play() { player.play() }
    func pause() { player.pause() }
    func stop() {
        cachedMetadata = nil
        cachedSubtitles = nil
        cachedAudioTracks = nil
        cachedVideoTracks = nil
        player.stop()
        player.media = nil
    }
    func seek(to seconds: TimeInterval) {
        guard duration > 0 else { return }
        player.position = Float(min(max(seconds / duration, 0), 1))
    }
    func selectSubtitle(index: Int?) { player.currentVideoSubTitleIndex = Int32(index ?? -1) }
    func selectAudio(index: Int) { player.currentAudioTrackIndex = Int32(index) }
    func selectVideo(index: Int) { player.currentVideoTrackIndex = Int32(index) }

    /// VLC writes the picture to a file on its own thread; it is read once
    /// it is whole, then thrown away.
    func captureFrame() async -> CapturedVideoFrame? {
        await snapshot(width: 1280)
    }

    func captureAmbientFrame() async -> CapturedVideoFrame? {
        await snapshot(width: 96)
    }

    private func snapshot(width: Int32) async -> CapturedVideoFrame? {
        guard !Task.isCancelled, player.hasVideoOut else { return nil }
        let file = FileManager.default.temporaryDirectory
            .appendingPathComponent("lineup-scoreboard-\(UUID().uuidString).png")
        player.saveVideoSnapshot(at: file.path, withWidth: width, andHeight: 0)
        let worker = Task.detached(priority: .utility) { await Self.readSnapshot(file) }
        // VLC's write cannot be canceled. Let the reader clean up a late file
        // even if the view that requested it has already gone away.
        let image = await worker.value
        return Task.isCancelled ? nil : image.map(CapturedVideoFrame.image)
    }

    nonisolated private static func readSnapshot(_ file: URL) async -> CGImage? {
        defer { try? FileManager.default.removeItem(at: file) }
        for _ in 0..<15 {
            do { try await Task.sleep(for: .milliseconds(100)) } catch { return nil }
            guard let data = try? Data(contentsOf: file),
                  let source = CGImageSourceCreateWithData(data as CFData, nil),
                  CGImageSourceGetStatus(source) == .statusComplete,
                  let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { continue }
            return image
        }
        return nil
    }
    func releaseFrameOutput() {}
}

@MainActor
final class TVAetherBackend: TVPlaybackBackend {
    let kind = TVPlaybackEngine.aether
    private let session: AetherPlaybackSession?
    private let initializationError: String?
    let surface: UIView

    init() {
        do {
            let session = try AetherPlaybackSession()
            self.session = session
            initializationError = nil
            surface = session.surface
        } catch {
            session = nil
            initializationError = error.localizedDescription
            surface = UIView(frame: CGRect(x: 0, y: 0, width: 1920, height: 1080))
        }
    }

    var state: TVPlaybackState {
        guard let session else { return .error }
        switch session.phase {
        case .idle: return .stopped
        case .loading: return .opening
        case .buffering: return .buffering
        case .playing: return .playing
        case .paused: return .paused
        case .ended: return .ended
        case .failed: return .error
        }
    }
    var errorMessage: String? { initializationError ?? session?.errorMessage }
    var isPlaying: Bool { session?.isPlaying == true }
    var hasVideoOut: Bool { session?.hasPicture == true }
    var videoSize: CGSize { session?.videoSize ?? .zero }
    func playbackMetadata() -> (info: PlaybackMediaInfo, pictureSize: CGSize) {
        (mediaInfo, session?.displayedPictureSize ?? .zero)
    }
    var mediaInfo: PlaybackMediaInfo { session?.mediaInfo ?? PlaybackMediaInfo() }
    var duration: TimeInterval { session?.duration ?? 0 }
    var time: TimeInterval { session?.position ?? 0 }
    var frames: Int? { nil }
    var bytes: Int? { session?.bytesReceived }
    var isSeekable: Bool { session?.canSeek == true }
    var isOpen: Bool { session?.isOpen == true }
    var volume: Int32 {
        get { Int32(((session?.volume ?? 1) * 100).rounded()) }
        set { session?.volume = Float(newValue) / 100 }
    }
    var isMuted: Bool {
        get { session?.isMuted == true }
        set { session?.isMuted = newValue }
    }
    var subtitles: [PlaybackSubtitleTrack] {
        [.off] + (session?.subtitles ?? []).map {
            PlaybackSubtitleTrack(id: "aether-\($0.id)", title: $0.title, engineIndex: $0.id)
        }
    }
    var selectedSubtitleIndex: Int? { session?.selectedSubtitleIndex }
    var audioTracks: [PlaybackStreamTrack] {
        (session?.audioTracks ?? []).map { PlaybackStreamTrack(id: $0.id, title: $0.title) }
    }
    var selectedAudioIndex: Int? { session?.selectedAudioIndex }
    // Aether exposes the active video representation, not arbitrary container
    // video-track selection. Its adaptive HLS quality remains automatic.
    var videoTracks: [PlaybackStreamTrack] { [] }
    var selectedVideoIndex: Int? { nil }

    private var languages = PlaybackLanguages()
    private var subtitleStyle = PlaybackSubtitleStyle()

    func load(url: URL, startPosition: TimeInterval?, isLive: Bool, expectedDuration: TimeInterval?, primary: Bool, matchContent: Bool) {
        session?.load(url: url, startPosition: startPosition, isLive: isLive,
                      expectedDuration: expectedDuration, primary: primary, matchContent: matchContent,
                      preferredSubtitleLanguages: isLive ? [] : languages.subtitles,
                      preferredAudioLanguages: (isLive ? [] : languages.audio) + ["en", "eng"])
        if !isLive { applySubtitleStyle() }
    }

    func setOpeningLanguages(_ languages: PlaybackLanguages) { self.languages = languages }

    func styleSubtitles(_ style: PlaybackSubtitleStyle) {
        subtitleStyle = style
        applySubtitleStyle()
    }

    private func applySubtitleStyle() {
        session?.configureSubtitles(scale: subtitleStyle.scale, background: subtitleStyle.background,
                                    delay: subtitleStyle.delay)
    }

    func addSubtitle(file: URL, title: String, language: String) -> Bool {
        guard let session else { return false }
        _ = session.addSubtitle(url: file, title: title, language: language)
        return true
    }
    func play() { session?.play() }
    func pause() { session?.pause() }
    func stop() { releaseFrameOutput(); session?.stop() }
    func seek(to seconds: TimeInterval) { session?.seek(to: seconds) }
    func selectSubtitle(index: Int?) { session?.selectSubtitle(index: index) }
    func selectAudio(index: Int) { session?.selectAudio(index: index) }
    func selectVideo(index: Int) {}
    var chapters: [PlaybackChapter] {
        (session?.chapters ?? []).map { PlaybackChapter(start: $0.start, title: $0.title) }
    }
    var forwardBufferSeconds: Double? { session?.forwardBufferSeconds }
    var droppedFrames: Int? { session?.droppedFrames }
    var networkMbps: Double? { session?.networkMbps }
    var canFillVideo: Bool { true }
    func setPlaybackSpeed(_ rate: Double) { session?.setPlaybackSpeed(rate) }
    func setVideoFill(_ fills: Bool) { session?.setVideoFill(fills) }
    var canPositionSubtitles: Bool { true }
    func setSubtitlesAtTop(_ top: Bool) { session?.setSubtitlesAtTop(top) }

    private var frameOutput: AVPlayerItemVideoOutput?
    private weak var frameOutputItem: AVPlayerItem?

    /// The software renderer's own frame, or on a route AVPlayer draws, the
    /// item's picture through an output attached on the first ask.
    func captureFrame() async -> CapturedVideoFrame? {
        guard let session else { return nil }
        if let shown = session.displayedFrame() { return .pixelBuffer(shown) }
        guard let item = session.currentPlayerItem else { return nil }
        if frameOutputItem !== item {
            releaseFrameOutput()
            let output = AVPlayerItemVideoOutput(pixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA
            ])
            item.add(output)
            frameOutput = output
            frameOutputItem = item
            return nil
        }
        guard let output = frameOutput else { return nil }
        let time = output.itemTime(forHostTime: CACurrentMediaTime())
        return output.copyPixelBuffer(forItemTime: time, itemTimeForDisplay: nil).map(CapturedVideoFrame.pixelBuffer)
    }

    func releaseFrameOutput() {
        if let output = frameOutput, let item = frameOutputItem { item.remove(output) }
        frameOutput = nil
        frameOutputItem = nil
    }
}

@MainActor
final class TVMPVBackend: TVPlaybackBackend {
    let kind = TVPlaybackEngine.mpv
    private let session: MPVPlaybackSession?
    private let initializationError: String?
    var surface: UIView { session?.surface ?? fallbackSurface }
    private let fallbackSurface = UIView(frame: CGRect(x: 0, y: 0, width: 1920, height: 1080))

    init() {
        do {
            let session = try MPVPlaybackSession()
            self.session = session
            initializationError = nil
        } catch {
            session = nil
            initializationError = error.localizedDescription
        }
    }

    var state: TVPlaybackState {
        guard let session else { return .error }
        switch session.phase {
        case .idle: return .stopped
        case .loading: return .opening
        case .buffering: return .buffering
        case .playing: return .playing
        case .paused: return .paused
        case .ended: return .ended
        case .failed: return .error
        }
    }
    var errorMessage: String? { initializationError ?? session?.errorMessage }
    var isPlaying: Bool { session?.isPlaying == true }
    var hasVideoOut: Bool { session?.hasVideoOut == true }
    var videoSize: CGSize { session?.videoSize ?? .zero }
    var mediaInfo: PlaybackMediaInfo {
        guard let session else { return PlaybackMediaInfo() }
        return PlaybackMediaInfo(dynamicRange: session.dynamicRange, videoCodec: session.videoCodec,
            frameRate: session.frameRate, audioCodec: session.audioCodec,
            audioProfile: session.audioProfile, audioChannels: session.audioChannels,
            audioLayout: session.audioLayout)
    }
    var duration: TimeInterval { session?.duration ?? 0 }
    var time: TimeInterval { session?.position ?? 0 }
    var frames: Int? { nil }
    var bytes: Int? { nil }
    var isSeekable: Bool { session?.isSeekable == true }
    var isOpen: Bool { session?.isOpen == true }
    var volume: Int32 {
        get { Int32(session?.volume ?? 100) }
        set { session?.volume = min(max(Int(newValue), 0), 100) }
    }
    var isMuted: Bool {
        get { session?.isMuted == true }
        set { session?.isMuted = newValue }
    }
    var subtitles: [PlaybackSubtitleTrack] {
        [.off] + (session?.subtitleTracks ?? []).map {
            PlaybackSubtitleTrack(id: "mpv-\($0.id)", title: $0.title, engineIndex: $0.id)
        }
    }
    var selectedSubtitleIndex: Int? { session?.selectedSubtitleIndex }
    var audioTracks: [PlaybackStreamTrack] {
        (session?.audioTracks ?? []).map { PlaybackStreamTrack(id: $0.id, title: $0.title) }
    }
    var selectedAudioIndex: Int? { session?.selectedAudioIndex }
    var videoTracks: [PlaybackStreamTrack] {
        (session?.videoTracks ?? []).map { PlaybackStreamTrack(id: $0.id, title: $0.title) }
    }
    var selectedVideoIndex: Int? { session?.selectedVideoIndex }

    private var languages = PlaybackLanguages()
    private var subtitleStyle = PlaybackSubtitleStyle()

    func load(url: URL, startPosition: TimeInterval?, isLive: Bool, expectedDuration: TimeInterval?, primary: Bool, matchContent: Bool) {
        session?.load(url: url, startPosition: startPosition, isLive: isLive,
                      preferredSubtitleLanguage: isLive || languages.subtitles.isEmpty ? nil : languages.subtitles.joined(separator: ","),
                      preferredAudioLanguage: isLive || languages.audio.isEmpty ? nil : languages.audio.joined(separator: ","))
        if !isLive { applySubtitleStyle() }
    }
    func play() { session?.play() }
    func pause() { session?.pause() }
    func stop() { session?.stop() }
    func seek(to seconds: TimeInterval) { session?.seek(to: seconds) }
    func selectSubtitle(index: Int?) { session?.selectSubtitle(index: index) }
    func selectAudio(index: Int) { session?.selectAudio(index: index) }
    func selectVideo(index: Int) { session?.selectVideo(index: index) }
    var chapters: [PlaybackChapter] {
        (session?.chapters ?? []).map { PlaybackChapter(start: $0.start, title: $0.title) }
    }
    var forwardBufferSeconds: Double? { session?.forwardBufferSeconds }
    var canFillVideo: Bool { true }
    func setPlaybackSpeed(_ rate: Double) { session?.setPlaybackSpeed(rate) }
    func setVideoFill(_ fills: Bool) { session?.setVideoFill(fills) }
    var canPositionSubtitles: Bool { true }
    func setSubtitlesAtTop(_ top: Bool) { session?.setSubtitlesAtTop(top) }
    func setOpeningLanguages(_ languages: PlaybackLanguages) { self.languages = languages }
    func styleSubtitles(_ style: PlaybackSubtitleStyle) {
        subtitleStyle = style
        applySubtitleStyle()
    }
    private func applySubtitleStyle() {
        session?.configureSubtitles(scale: subtitleStyle.scale, background: subtitleStyle.background,
                                    delay: subtitleStyle.delay, language: languages.subtitles.joined(separator: ","))
    }
    func addSubtitle(file: URL, title: String, language: String) -> Bool {
        guard let session else { return false }
        session.addSubtitle(url: file, title: title, language: language)
        return true
    }
    // MPVKit renders to a Metal surface and does not expose decoded-frame
    // readback, so Auto Sync cannot sample the scoreboard with this backend.
    func captureFrame() async -> CapturedVideoFrame? { nil }
    func releaseFrameOutput() {}
}
#endif
