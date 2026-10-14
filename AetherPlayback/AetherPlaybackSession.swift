import UIKit
import AVFoundation
import Combine
import AetherEngine

public enum AetherPlaybackPhase: Equatable { case idle, loading, buffering, playing, paused, ended, failed }

public struct AetherPlaybackTrack {
    public let id: Int
    public let title: String
}

/// A dynamic-framework boundary keeps Aether's FFmpeg references bound to its
/// own dylibs when Lineup also links the FFmpeg bundled inside TVVLCKit.
/// No Aether or FFmpeg types cross this public interface.
@MainActor
public final class AetherPlaybackSession {
    private let engine: AetherEngine
    private let canvas: AetherPlaybackCanvas
    private var subscriptions = Set<AnyCancellable>()
    private var loadTask: Task<Void, Never>?
    private var seekTask: Task<Void, Never>?
    private var generation = UUID()
    private var loading = false
    private var wantsToPlay = false
    private var failure: String?
    private var level: Float = 1
    private var muted = false
    private var initialPosition: Double = 0
    public private(set) var isOpen = false
    private var probedVideoSize: CGSize = .zero
    public var videoSize: CGSize {
        let current = engine.softwareDisplaySize ?? engine.currentAVPlayerItem?.presentationSize ?? .zero
        return current.width > 0 && current.height > 0 ? current : probedVideoSize
    }
    public var surface: UIView { canvas }

    public init() throws {
        engine = try AetherEngine()
        canvas = AetherPlaybackCanvas(frame: CGRect(x: 0, y: 0, width: 1920, height: 1080))
        canvas.backgroundColor = .black
        engine.bind(view: canvas.picture)
        engine.videoGravity = .resizeAspect
        // A custom transport owns Now Playing through the engine's session,
        // never by writing MPNowPlayingInfoCenter directly on tvOS 26.
        engine.liveSourceReset.receive(on: DispatchQueue.main).sink { [weak self] in
            guard let self, self.isOpen else { return }
            self.failure = "The live stream disconnected."
        }.store(in: &subscriptions)
        Publishers.CombineLatest(engine.clock.$sourceTime, engine.$subtitleCues)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _, _ in
                guard let self, self.isOpen, !self.loading else { return }
                // Read the current session after the queue hop; queued cues
                // from a stopped/replaced source must not reappear.
                self.canvas.display(cues: self.engine.subtitleCues, at: self.engine.sourceTime,
                                    videoSize: self.videoSize)
            }.store(in: &subscriptions)
    }

    deinit {
        loadTask?.cancel()
        seekTask?.cancel()
        // Aether's stop tears down its decode work asynchronously. Keep that
        // operation on its main actor without blocking a tab transition.
        let retained = engine
        Task { @MainActor in retained.stop() }
    }

    public var phase: AetherPlaybackPhase {
        if failure != nil { return .failed }
        guard isOpen else { return .idle }
        if loading { return .loading }
        switch engine.state {
        case .idle: return .idle
        case .loading: return .loading
        case .playing: return engine.isBuffering ? .buffering : .playing
        case .paused: return .paused
        case .seeking: return wantsToPlay ? .buffering : .paused
        case .ended: return .ended
        case .error: return .failed
        }
    }
    public var errorMessage: String? {
        if let failure { return failure }
        if case .error(let message) = engine.state { return message }
        return nil
    }
    public var isPlaying: Bool { wantsToPlay && (phase == .playing || phase == .buffering) }
    public var hasPicture: Bool { isOpen && engine.hasFirstFrameReadyForDisplay }
    public var duration: Double { engine.duration.isFinite ? max(0, engine.duration) : 0 }
    public var position: Double {
        if loading { return initialPosition }
        let time = engine.seekTarget ?? engine.currentTime
        return time.isFinite ? max(0, time) : 0
    }
    public var canSeek: Bool { engine.canSeek }
    public var bytesReceived: Int? {
        guard let value = engine.liveTelemetry?.demuxerBytesFetched else { return nil }
        return Int(clamping: value)
    }
    public var volume: Float {
        get { level }
        set { level = min(max(newValue, 0), 1); applyVolume() }
    }
    public var isMuted: Bool {
        get { muted }
        set { muted = newValue; applyVolume() }
    }
    private func applyVolume() { engine.volume = muted ? 0 : level }

    public var subtitles: [AetherPlaybackTrack] {
        engine.subtitleTracks.map { .init(id: $0.id, title: Self.title($0, fallback: "Subtitle")) }
    }
    public var selectedSubtitleIndex: Int? { engine.activeSubtitleTrackIndex }
    public var audioTracks: [AetherPlaybackTrack] {
        engine.audioTracks.map { .init(id: $0.id, title: Self.title($0, fallback: "Audio")) }
    }
    public var selectedAudioIndex: Int? { engine.activeAudioTrackIndex }
    private static func title(_ track: TrackInfo, fallback: String) -> String {
        let name = track.name.trimmingCharacters(in: .whitespacesAndNewlines)
        let language = track.language.flatMap { Locale.current.localizedString(forLanguageCode: $0) ?? $0 }
        let title = [name.isEmpty ? nil : name, language, track.codec.uppercased()]
            .compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · ")
        return title.isEmpty ? "\(fallback) \(track.id)" : title
    }

    public func load(url: URL, startPosition: Double?, isLive: Bool, expectedDuration: Double?, primary: Bool, matchContent: Bool) {
        stop()
        let token = generation
        isOpen = true
        loading = true
        initialPosition = startPosition ?? 0
        wantsToPlay = true
        engine.ownsVideoNowPlayingSession = primary && matchContent
        var options = LoadOptions()
        options.isLive = isLive
        options.liveJoinProfile = .fastZap
        options.autoplay = false
        options.preferredAudioLanguages = ["en", "eng"]
        options.declaredDurationSeconds = expectedDuration
        options.suppressDisplayCriteria = !matchContent
        options.matchContentEnabled = matchContent
        options.sharedOutputRole = primary ? .primary : .secondary
        // Lineup's provider-backed catch-up is shared by both players. Do not
        // silently enable a second DVR window with different pause semantics.
        options.dvrWindowSeconds = nil
        loadTask = Task { [weak self] in
            guard let self else { return }
            do {
                guard !Task.isCancelled, self.generation == token else { return }
                let probe = try await self.engine.load(url: url, startPosition: startPosition, options: options)
                guard !Task.isCancelled, self.generation == token else { return }
                // load() awaits the engine's audio-category declaration. Bare
                // AVPlayerLayer hosts activate it before starting transport.
                try await AetherAudioActivation.shared.activate()
                guard !Task.isCancelled, self.generation == token else { return }
                self.probedVideoSize = probe.map { CGSize(width: Int($0.videoWidth), height: Int($0.videoHeight)) }
                    ?? self.engine.softwareDisplaySize ?? self.engine.currentAVPlayerItem?.presentationSize ?? .zero
                self.loading = false
                self.applyVolume()
                if self.wantsToPlay { self.engine.play() } else { self.engine.pause() }
            } catch is CancellationError {
                // A newer tune or stop owns the session now.
            } catch {
                guard self.generation == token, !Task.isCancelled else { return }
                self.loading = false
                self.failure = error.localizedDescription
            }
        }
    }

    public func play() { wantsToPlay = true; if !loading { engine.play() } }
    public func pause() { wantsToPlay = false; engine.pause() }
    public func stop() {
        generation = UUID()
        loadTask?.cancel(); loadTask = nil
        seekTask?.cancel(); seekTask = nil
        isOpen = false
        loading = false
        wantsToPlay = false
        failure = nil
        probedVideoSize = .zero
        engine.stop()
        canvas.display(cues: [], at: 0, videoSize: .zero)
    }
    public func seek(to seconds: Double) {
        guard seconds.isFinite, engine.canSeek else { return }
        seekTask?.cancel()
        let token = generation
        seekTask = Task { [weak self] in
            guard let self, self.generation == token, !Task.isCancelled else { return }
            await self.engine.seek(to: seconds)
        }
    }
    public func selectSubtitle(index: Int?) {
        if let index { engine.selectSubtitleTrack(index: index) } else { engine.clearSubtitle() }
    }
    public func selectAudio(index: Int) { engine.selectAudioTrack(index: index) }

    public static func openSourceNotices() -> String {
        guard let directory = Bundle(for: AetherPlaybackSession.self).resourceURL?
            .appendingPathComponent("AetherLicenses"),
              let files = try? FileManager.default.contentsOfDirectory(at: directory,
                  includingPropertiesForKeys: nil) else { return "Playback acknowledgements are unavailable." }
        let ordered = files.filter { $0.pathExtension == "txt" }.sorted {
            if $0.lastPathComponent == "README.txt" { return true }
            if $1.lastPathComponent == "README.txt" { return false }
            return $0.lastPathComponent < $1.lastPathComponent
        }
        return ordered.compactMap { file -> String? in
            guard let text = try? String(contentsOf: file, encoding: .utf8) else { return nil }
            return file.lastPathComponent + "\n\n" + text
        }.joined(separator: "\n\n────────────────────────\n\n")
    }
}

private actor AetherAudioActivation {
    static let shared = AetherAudioActivation()
    func activate() throws { try AVAudioSession.sharedInstance().setActive(true) }
}

/// Text and bitmap subtitles ride inside the retained video surface, so they
/// follow preview/full-screen handoffs and Multiview transforms with the video.
@MainActor
private final class AetherPlaybackCanvas: UIView {
    let picture = AetherPlayerView(frame: .zero)
    private var cues: [SubtitleCue] = []
    private var videoSize: CGSize = .zero

    override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = false
        addSubview(picture)
    }
    required init?(coder: NSCoder) { nil }

    func display(cues: [SubtitleCue], at time: Double, videoSize: CGSize) {
        let active = cues.filter { $0.startTime <= time && time < $0.endTime }
        guard !Self.sameCues(active, self.cues) || self.videoSize != videoSize else { return }
        self.cues = active
        self.videoSize = videoSize
        subviews.filter { $0 !== picture }.forEach { $0.removeFromSuperview() }
        for cue in active {
            if case .image(let image) = cue.body {
                let view = UIImageView(image: UIImage(cgImage: image.cgImage))
                view.contentMode = .scaleToFill
                addSubview(view)
            } else {
                let label = UILabel()
                label.numberOfLines = 0
                let column = ((cue.placement?.alignment ?? 2) - 1) % 3
                label.textAlignment = column == 0 ? .left : column == 2 ? .right : .center
                label.attributedText = Self.styledText(cue)
                label.layer.shadowColor = UIColor.black.cgColor
                label.layer.shadowOpacity = 1
                label.layer.shadowRadius = 3
                label.layer.shadowOffset = CGSize(width: 0, height: 2)
                addSubview(label)
            }
        }
        setNeedsLayout()
    }

    private static func sameCues(_ lhs: [SubtitleCue], _ rhs: [SubtitleCue]) -> Bool {
        guard lhs.count == rhs.count else { return false }
        return zip(lhs, rhs).allSatisfy { a, b in
            guard a == b, a.placement == b.placement else { return false }
            switch (a.body, b.body) {
            case (.text(let x), .text(let y)): return x == y
            case (.richText(let x), .richText(let y)): return x == y
            case (.image(let x), .image(let y)):
                return x.cgImage === y.cgImage && x.position == y.position && x.canvasSize == y.canvasSize
            default: return false
            }
        }
    }

    private static func styledText(_ cue: SubtitleCue) -> NSAttributedString {
        let base: [NSAttributedString.Key: Any] = [
            .font: UIFont.systemFont(ofSize: 42, weight: .semibold), .foregroundColor: UIColor.white,
            .strokeColor: UIColor.black, .strokeWidth: -3
        ]
        guard case .richText(let runs) = cue.body else {
            return NSAttributedString(string: cue.text ?? "", attributes: base)
        }
        let text = NSMutableAttributedString(string: "")
        for run in runs {
            var attributes = base
            let size = CGFloat(min(max(run.fontSize ?? 42, 20), 84))
            let font = run.fontName.flatMap { UIFont(name: $0, size: size) }
                ?? UIFont.systemFont(ofSize: size, weight: .semibold)
            var traits = font.fontDescriptor.symbolicTraits
            if run.isBold { traits.insert(.traitBold) }
            if run.isItalic { traits.insert(.traitItalic) }
            attributes[.font] = font.fontDescriptor.withSymbolicTraits(traits).map { UIFont(descriptor: $0, size: size) } ?? font
            if let color = run.color {
                attributes[.foregroundColor] = UIColor(red: CGFloat(color.r) / 255, green: CGFloat(color.g) / 255,
                                                       blue: CGFloat(color.b) / 255, alpha: 1)
            }
            if run.isUnderlined { attributes[.underlineStyle] = NSUnderlineStyle.single.rawValue }
            if run.isStruckThrough { attributes[.strikethroughStyle] = NSUnderlineStyle.single.rawValue }
            text.append(NSAttributedString(string: run.text, attributes: attributes))
        }
        return text
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        picture.frame = bounds
        let video = videoSize.width > 0 && videoSize.height > 0
            ? AVMakeRect(aspectRatio: videoSize, insideRect: bounds) : bounds
        var bottom = video.maxY - 42
        for (cue, view) in zip(cues.reversed(), subviews.dropFirst().reversed()) {
            if case .image(let image) = cue.body {
                let canvas = image.canvasSize.width > 0 ? image.canvasSize : video.size
                let scale = canvas.width > 0 ? video.width / canvas.width : 1
                let canvasFrame = CGRect(x: video.minX, y: video.midY - canvas.height * scale / 2,
                                         width: canvas.width * scale, height: canvas.height * scale)
                view.frame = CGRect(x: canvasFrame.minX + image.position.minX * canvasFrame.width,
                    y: canvasFrame.minY + image.position.minY * canvasFrame.height,
                    width: image.position.width * canvasFrame.width, height: image.position.height * canvasFrame.height)
            } else {
                let size = view.sizeThatFits(CGSize(width: video.width * 0.9, height: video.height))
                let alignment = cue.placement?.alignment ?? 2
                let column = (alignment - 1) % 3
                let row = (alignment - 1) / 3
                let anchor = cue.placement?.position.map {
                    CGPoint(x: video.minX + $0.x * video.width, y: video.minY + $0.y * video.height)
                } ?? CGPoint(x: column == 0 ? video.minX + 42 : column == 2 ? video.maxX - 42 : video.midX,
                             y: row == 2 ? video.minY + 42 : row == 1 ? video.midY : bottom)
                let x = anchor.x - (column == 0 ? 0 : column == 2 ? size.width : size.width / 2)
                let y = anchor.y - (row == 2 ? 0 : row == 1 ? size.height / 2 : size.height)
                view.frame = CGRect(origin: CGPoint(x: x, y: y), size: size)
                if cue.placement == nil { bottom = y - 8 }
            }
        }
    }
}
