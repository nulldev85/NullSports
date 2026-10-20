#if os(tvOS)
import UIKit
import AVFoundation
import ImageIO
import VLCKitSPM
import LineupAetherPlayback

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
    /// The picture on screen now, for Auto Sync to read the scoreboard in.
    /// Nil when there is none to give yet.
    func captureFrame() async -> CapturedVideoFrame?
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

@MainActor
func makeTVPlaybackBackend(_ kind: TVPlaybackEngine) -> any TVPlaybackBackend {
    switch kind {
    case .vlc: TVVLCBackend()
    case .aether: TVAetherBackend()
    }
}

@MainActor
final class TVVLCBackend: TVPlaybackBackend {
    let kind = TVPlaybackEngine.vlc
    private let player = VLCMediaPlayer()
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
    var mediaInfo: PlaybackMediaInfo { VLCPlaybackMediaInfo.read(player) }
    var duration: TimeInterval { Double(player.media?.length.intValue ?? 0) / 1000 }
    var time: TimeInterval { Double(player.time.intValue) / 1000 }
    var frames: Int? { player.media?.numberOfDisplayedPictures }
    var bytes: Int? { player.media?.numberOfReadBytesOnInput }
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
        PlaybackSubtitleTrack.vlcTracks(names: player.videoSubTitlesNames as? [String] ?? [],
            indexes: (player.videoSubTitlesIndexes as? [NSNumber] ?? []).map(\.intValue))
    }
    var selectedSubtitleIndex: Int? {
        let value = Int(player.currentVideoSubTitleIndex)
        return value >= 0 ? value : nil
    }
    var audioTracks: [PlaybackStreamTrack] {
        PlaybackStreamTrack.vlcTracks(names: player.audioTrackNames as? [String] ?? [],
            indexes: (player.audioTrackIndexes as? [NSNumber] ?? []).map(\.intValue), kind: "Audio")
    }
    var selectedAudioIndex: Int? { Int(player.currentAudioTrackIndex) }
    var videoTracks: [PlaybackStreamTrack] {
        PlaybackStreamTrack.vlcTracks(names: player.videoTrackNames as? [String] ?? [],
            indexes: (player.videoTrackIndexes as? [NSNumber] ?? []).map(\.intValue), kind: "Video")
    }
    var selectedVideoIndex: Int? { Int(player.currentVideoTrackIndex) }

    private var languages = PlaybackLanguages()
    private var subtitleStyle = PlaybackSubtitleStyle()

    func load(url: URL, startPosition: TimeInterval?, isLive: Bool, expectedDuration: TimeInterval?, primary: Bool, matchContent: Bool) {
        player.stop()
        let media = VLCMedia(url: url)
        media.addOption(":network-caching=5000")
        if isLive {
            media.addOption(":live-caching=5000")
            media.addOption(":audio-language=en")
        } else {
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
        player.addPlaybackSlave(file, type: .subtitle, enforce: true) == 0
    }
    func play() { player.play() }
    func pause() { player.pause() }
    func stop() { player.stop(); player.media = nil }
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
        guard player.hasVideoOut else { return nil }
        let file = FileManager.default.temporaryDirectory
            .appendingPathComponent("lineup-scoreboard-\(UUID().uuidString).png")
        player.saveVideoSnapshot(at: file.path, withWidth: 1280, andHeight: 0)
        defer { try? FileManager.default.removeItem(at: file) }
        for _ in 0..<15 {
            try? await Task.sleep(for: .milliseconds(100))
            guard let data = try? Data(contentsOf: file),
                  let source = CGImageSourceCreateWithData(data as CFData, nil),
                  CGImageSourceGetStatus(source) == .statusComplete,
                  let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { continue }
            return .image(image)
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
    func stop() { session?.stop() }
    func seek(to seconds: TimeInterval) { session?.seek(to: seconds) }
    func selectSubtitle(index: Int?) { session?.selectSubtitle(index: index) }
    func selectAudio(index: Int) { session?.selectAudio(index: index) }
    func selectVideo(index: Int) {}

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
#endif
