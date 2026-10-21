import Foundation
import UIKit
import Metal
import Libmpv

public enum MPVPlaybackPhase: Equatable { case idle, loading, buffering, playing, paused, ended, failed }

public struct MPVPlaybackTrack: Equatable, Sendable {
    public let id: Int
    public let title: String
}

private struct MPVPlaybackSnapshot: @unchecked Sendable {
    var phase: MPVPlaybackPhase = .idle
    var error: String?
    var isOpen = false
    var isPlaying = false
    var isMuted = false
    var hasVideoOut = false
    var size = CGSize.zero
    var duration: Double = 0
    var position: Double = 0
    var seekable = false
    var volume = 100.0
    var videoCodec: String?
    var audioCodec: String?
    var audioChannels: Int?
    var audioLayout: String?
    var dynamicRange: String?
    var frameRate: Double?
    var subtitleTracks: [MPVPlaybackTrack] = []
    var audioTracks: [MPVPlaybackTrack] = []
    var videoTracks: [MPVPlaybackTrack] = []
    var selectedSubtitleIndex: Int?
    var selectedAudioIndex: Int?
    var selectedVideoIndex: Int?
}

/// A small Lineup-owned libmpv adapter. MPVKit's Metal renderer is experimental;
/// this class keeps its C context and decoder symbols inside a separate dylib.
@MainActor
public final class MPVPlaybackSession {
    public let surface: UIView
    public private(set) var phase: MPVPlaybackPhase = .idle
    public private(set) var errorMessage: String?
    public private(set) var isOpen = false
    public private(set) var isPlaying = false
    public var isMuted: Bool {
        get { requestedMute ?? snapshot.isMuted }
        set {
            requestedMute = newValue
            core.setFlag("mute", newValue)
        }
    }
    public private(set) var hasVideoOut = false
    public private(set) var videoSize = CGSize.zero
    public private(set) var duration: Double = 0
    public private(set) var position: Double = 0
    public private(set) var isSeekable = false
    public var volume: Int {
        get { Int(snapshot.volume.rounded()) }
        set { core.setNumber("volume", Double(min(max(newValue, 0), 100))) }
    }
    public private(set) var videoCodec: String?
    public private(set) var audioCodec: String?
    public private(set) var audioProfile: String?
    public private(set) var audioChannels: Int?
    public private(set) var audioLayout: String?
    public private(set) var dynamicRange: String?
    public private(set) var frameRate: Double?
    public private(set) var subtitleTracks: [MPVPlaybackTrack] = []
    public private(set) var audioTracks: [MPVPlaybackTrack] = []
    public private(set) var videoTracks: [MPVPlaybackTrack] = []
    public private(set) var selectedSubtitleIndex: Int?
    public private(set) var selectedAudioIndex: Int?
    public private(set) var selectedVideoIndex: Int?

    private let core: MPVPlaybackCore
    private var snapshot = MPVPlaybackSnapshot()
    private var requestedMute: Bool?

    public init() throws {
        let host = MPVMetalSurface(frame: CGRect(x: 0, y: 0, width: 1920, height: 1080))
        host.backgroundColor = .black
        surface = host
        core = try MPVPlaybackCore(layer: host.metalLayer)
        core.onSnapshot = { [weak self] value in
            Task { @MainActor in self?.apply(value) }
        }
    }

    deinit { core.shutdown() }

    public var subtitles: [MPVPlaybackTrack] { subtitleTracks }

    public func load(url: URL, startPosition: Double? = nil, isLive: Bool = false,
                     preferredSubtitleLanguage: String? = nil,
                     preferredAudioLanguage: String? = nil) {
        phase = .loading
        errorMessage = nil
        isOpen = true
        position = max(0, startPosition ?? 0)
        duration = 0
        hasVideoOut = false
        core.load(url: url, startPosition: startPosition, isLive: isLive,
                  preferredSubtitleLanguage: preferredSubtitleLanguage,
                  preferredAudioLanguage: preferredAudioLanguage)
    }

    public func play() { core.setFlag("pause", false) }
    public func pause() { core.setFlag("pause", true) }
    public func stop() {
        isOpen = false
        isPlaying = false
        phase = .idle
        position = 0
        duration = 0
        hasVideoOut = false
        core.stop()
    }
    public func seek(to seconds: Double) {
        guard seconds.isFinite, isSeekable else { return }
        core.seek(to: max(0, duration > 0 ? min(seconds, duration) : seconds))
    }
    public func selectSubtitle(index: Int?) { core.selectTrack(type: "sub", id: index) }
    public func selectAudio(index: Int) { core.selectTrack(type: "audio", id: index) }
    public func selectVideo(index: Int) { core.selectTrack(type: "video", id: index) }
    public func addSubtitle(url: URL, title: String, language: String) {
        core.addSubtitle(url: url, title: title, language: language)
    }
    public func configureSubtitles(scale: Double, background: Bool, delay: Double, language: String = "") {
        core.configureSubtitles(scale: scale, background: background, delay: delay, language: language)
    }

    public static func openSourceNotices() -> String {
        let bundle = Bundle(for: MPVPlaybackSession.self)
        let licenseNames = ["LGPL-3.0"]
        let texts = licenseNames.compactMap { name -> String? in
            guard let url = bundle.url(forResource: name, withExtension: "txt", subdirectory: "MPVLicenses") else { return nil }
            return try? String(contentsOf: url, encoding: .utf8)
        }
        let notice = "MPVKit (LGPL v3.0) is included as the optional trial engine. The separate GPL-only MPVKit-GPL product is not used. MPVKit upstream describes its Metal renderer as experimental and the project as primarily suitable for learning libmpv.\n\nSource: https://github.com/mpvkit/MPVKit\nmpv project: https://github.com/mpv-player/mpv\nOfficial mpv logo: https://github.com/mpv-player/mpv.io/blob/master/source/images/mpv-logo-128.png"
        return ([notice] + texts
            + ["License file: https://github.com/mpvkit/MPVKit/blob/main/LICENSE"])
            .joined(separator: "\n\n")
    }

    private func apply(_ value: MPVPlaybackSnapshot) {
        snapshot = value
        if requestedMute == value.isMuted { requestedMute = nil }
        phase = value.phase
        errorMessage = value.error
        isOpen = value.isOpen
        isPlaying = value.isPlaying
        hasVideoOut = value.hasVideoOut
        videoSize = value.size
        duration = value.duration
        position = value.position
        isSeekable = value.seekable
        videoCodec = value.videoCodec
        audioCodec = value.audioCodec
        audioChannels = value.audioChannels
        audioLayout = value.audioLayout
        dynamicRange = value.dynamicRange
        frameRate = value.frameRate
        subtitleTracks = value.subtitleTracks
        audioTracks = value.audioTracks
        videoTracks = value.videoTracks
        selectedSubtitleIndex = value.selectedSubtitleIndex
        selectedAudioIndex = value.selectedAudioIndex
        selectedVideoIndex = value.selectedVideoIndex
    }
}

private final class MPVMetalSurface: UIView {
    override class var layerClass: AnyClass { CAMetalLayer.self }
    var metalLayer: CAMetalLayer { layer as! CAMetalLayer }
    override init(frame: CGRect) {
        super.init(frame: frame)
        metalLayer.device = MTLCreateSystemDefaultDevice()
        metalLayer.pixelFormat = .bgra8Unorm
        metalLayer.framebufferOnly = true
        metalLayer.contentsScale = UIScreen.main.nativeScale
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
    override func layoutSubviews() {
        super.layoutSubviews()
        metalLayer.drawableSize = CGSize(width: bounds.width * contentScaleFactor,
                                         height: bounds.height * contentScaleFactor)
    }
}

private final class MPVPlaybackCore: @unchecked Sendable {
    private let queue = DispatchQueue(label: "com.lineup.mpv.core", qos: .userInitiated)
    private var context: OpaquePointer?
    private var timer: DispatchSourceTimer?
    private var pendingStart: Double?
    private var lastKnownPosition = 0.0
    private var lastKnownDuration = 0.0
    private var wantsToPlay = true
    private var isOpen = false
    private var terminalPhase: MPVPlaybackPhase?
    private var failureMessage: String?
    fileprivate var onSnapshot: (@Sendable (MPVPlaybackSnapshot) -> Void)?

    init(layer: CAMetalLayer) throws {
        var failure: String?
        queue.sync {
            guard let mpv = mpv_create() else { failure = "MPV could not create a playback context."; return }
            _ = mpv_set_option_string(mpv, "terminal", "no")
            _ = mpv_set_option_string(mpv, "vo", "gpu-next")
            _ = mpv_set_option_string(mpv, "gpu-api", "vulkan")
            _ = mpv_set_option_string(mpv, "gpu-context", "moltenvk")
            _ = mpv_set_option_string(mpv, "hwdec", "videotoolbox")
            _ = mpv_set_option_string(mpv, "audio-client-name", "Lineup")
            _ = mpv_set_option_string(mpv, "input-default-bindings", "no")
            _ = mpv_set_option_string(mpv, "osc", "no")
            _ = mpv_set_option_string(mpv, "sub-auto", "all")
            _ = mpv_set_option_string(mpv, "subs-match-os-language", "yes")
            _ = mpv_set_option_string(mpv, "subs-fallback", "yes")
            // libmpv's `wid` is a signed 64-bit native handle. The MPVKit
            // Apple renderer expects the CAMetalLayer object's address here.
            var drawable = Int64(bitPattern: UInt64(UInt(bitPattern: Unmanaged.passUnretained(layer).toOpaque())))
            let windowStatus = mpv_set_option(mpv, "wid", MPV_FORMAT_INT64, &drawable)
            guard windowStatus >= 0 else {
                mpv_terminate_destroy(mpv)
                failure = Self.message(windowStatus)
                return
            }
            let initialized = mpv_initialize(mpv)
            guard initialized >= 0 else {
                mpv_terminate_destroy(mpv)
                failure = Self.message(initialized)
                return
            }
            context = mpv
            let timer = DispatchSource.makeTimerSource(queue: queue)
            timer.schedule(deadline: .now(), repeating: .milliseconds(250), leeway: .milliseconds(30))
            timer.setEventHandler { [weak self] in self?.poll() }
            self.timer = timer
            timer.resume()
        }
        if let failure { throw MPVPlaybackError.initialization(failure) }
    }

    func load(url: URL, startPosition: Double?, isLive: Bool,
              preferredSubtitleLanguage: String?, preferredAudioLanguage: String?) {
        queue.async { [weak self] in
            guard let self, let context = self.context else { return }
            self.isOpen = true
            self.wantsToPlay = true
            self.terminalPhase = nil
            self.failureMessage = nil
            self.pendingStart = isLive ? nil : startPosition.flatMap { $0 > 0 && $0.isFinite ? $0 : nil }
            self.lastKnownPosition = self.pendingStart ?? 0
            self.lastKnownDuration = 0
            var snapshot = MPVPlaybackSnapshot(phase: .loading, isOpen: true)
            snapshot.position = self.pendingStart ?? 0
            self.onSnapshot?(snapshot)
            _ = mpv_set_property_string(context, "slang", preferredSubtitleLanguage ?? "")
            _ = mpv_set_property_string(context, "alang", preferredAudioLanguage ?? "")
            let result = self.command(context, ["loadfile", url.absoluteString, "replace"])
            if result < 0 {
                self.isOpen = false
                self.failureMessage = Self.message(result)
                self.terminalPhase = .failed
                var failed = MPVPlaybackSnapshot(phase: .failed)
                failed.error = self.failureMessage
                self.onSnapshot?(failed)
            }
        }
    }

    func play() { setFlag("pause", false) }
    func pause() { setFlag("pause", true) }
    func stop() {
        queue.async { [weak self] in
            guard let self, let context = self.context else { return }
            self.isOpen = false
            self.pendingStart = nil
            self.failureMessage = nil
            self.lastKnownPosition = 0
            self.lastKnownDuration = 0
            self.terminalPhase = .idle
            self.command(context, ["stop"])
        }
    }
    func seek(to seconds: Double) {
        guard seconds.isFinite else { return }
        queue.async { [weak self] in
            guard let self, let context = self.context else { return }
            self.command(context, ["seek", String(format: "%.3f", locale: Locale(identifier: "en_US_POSIX"), seconds), "absolute+exact"])
        }
    }
    func setFlag(_ name: String, _ value: Bool) {
        queue.async { [weak self] in
            guard let self, let context = self.context else { return }
            var flag: Int32 = value ? 1 : 0
            _ = mpv_set_property(context, name, MPV_FORMAT_FLAG, &flag)
            if name == "pause" { self.wantsToPlay = !value }
        }
    }
    func setNumber(_ name: String, _ value: Double) {
        queue.async { [weak self] in
            guard let self, let context = self.context else { return }
            var number = value
            _ = mpv_set_property(context, name, MPV_FORMAT_DOUBLE, &number)
        }
    }
    func selectTrack(type: String, id: Int?) {
        queue.async { [weak self] in
            guard let self, let context = self.context else { return }
            let property = type == "sub" ? "sid" : type == "audio" ? "aid" : "vid"
            let value = id.map(String.init) ?? "no"
            _ = mpv_set_property_string(context, property, value)
        }
    }
    func addSubtitle(url: URL, title: String, language: String) {
        queue.async { [weak self] in
            guard let self, let context = self.context else { return }
            self.command(context, ["sub-add", url.path, "select", title, language])
        }
    }
    func configureSubtitles(scale: Double, background: Bool, delay: Double, language: String) {
        queue.async { [weak self] in
            guard let self, let context = self.context else { return }
            let fontSize = min(max(55 * scale, 20), 100)
            self.command(context, ["set", "sub-font-size", String(format: "%.1f", fontSize)])
            self.command(context, ["set", "sub-back-color", background ? "#80000000" : "#00000000"])
            self.command(context, ["set", "sub-delay", String(format: "%.3f", locale: Locale(identifier: "en_US_POSIX"), delay)])
            if !language.isEmpty { self.command(context, ["set", "slang", language]) }
        }
    }
    func shutdown() {
        queue.async { [self] in
            self.timer?.cancel()
            self.timer = nil
            if let context = self.context { mpv_terminate_destroy(context); self.context = nil }
        }
    }

    private func poll() {
        guard let context else { return }
        while let event = mpv_wait_event(context, 0), event.pointee.event_id != MPV_EVENT_NONE {
            switch event.pointee.event_id {
            case MPV_EVENT_START_FILE:
                isOpen = true
                terminalPhase = nil
                failureMessage = nil
            case MPV_EVENT_FILE_LOADED:
                isOpen = true
                terminalPhase = nil
                failureMessage = nil
                if let pendingStart { command(context, ["seek", String(format: "%.3f", locale: Locale(identifier: "en_US_POSIX"), pendingStart), "absolute+exact"]); self.pendingStart = nil }
                _ = mpv_set_property_string(context, "pause", wantsToPlay ? "no" : "yes")
            case MPV_EVENT_END_FILE:
                isOpen = false
                if let data = event.pointee.data {
                    let end = data.assumingMemoryBound(to: mpv_event_end_file.self).pointee
                    if end.reason == MPV_END_FILE_REASON_ERROR {
                        failureMessage = Self.message(end.error)
                        terminalPhase = .failed
                    } else if end.reason == MPV_END_FILE_REASON_STOP || end.reason == MPV_END_FILE_REASON_QUIT {
                        terminalPhase = .idle
                    } else {
                        terminalPhase = .ended
                    }
                }
            default: break
            }
        }

        var snapshot = MPVPlaybackSnapshot()
        snapshot.isOpen = isOpen
        snapshot.isMuted = bool(context, "mute")
        snapshot.volume = number(context, "volume") ?? 100
        if let duration = number(context, "duration"), duration.isFinite, duration > 0 {
            lastKnownDuration = duration
        }
        snapshot.duration = lastKnownDuration
        let reportedPosition = number(context, "time-pos")
        if let reportedPosition, reportedPosition.isFinite,
           terminalPhase != .ended || reportedPosition > 0 {
            lastKnownPosition = reportedPosition
        }
        snapshot.position = terminalPhase == .ended
            ? max(lastKnownPosition, lastKnownDuration)
            : reportedPosition ?? lastKnownPosition
        snapshot.seekable = bool(context, "seekable")
        let width = number(context, "video-params/w") ?? 0
        let height = number(context, "video-params/h") ?? 0
        snapshot.size = CGSize(width: max(0, width), height: max(0, height))
        snapshot.hasVideoOut = width > 0 && height > 0
        // Read codec identity from the selected source tracks first. These are
        // the same per-track values used in the track picker and remain tied
        // to the stream the user is actually watching.
        snapshot.videoCodec = selectedTrackText(context, type: "video", property: "codec")
            ?? text(context, "video-codec-name")
        snapshot.audioCodec = selectedTrackText(context, type: "audio", property: "codec")
            ?? text(context, "audio-codec-name")
        snapshot.audioChannels = integer(context, "audio-params/channel-count")
        snapshot.audioLayout = text(context, "audio-params/hr-channels")
        snapshot.frameRate = number(context, "container-fps")
        let gamma = text(context, "video-params/gamma")?.lowercased()
        if gamma == "pq" { snapshot.dynamicRange = "HDR" }
        else if gamma == "hlg" { snapshot.dynamicRange = "HLG" }
        snapshot.subtitleTracks = tracks(context, type: "sub")
        snapshot.audioTracks = tracks(context, type: "audio")
        snapshot.videoTracks = tracks(context, type: "video")
        snapshot.selectedSubtitleIndex = selectedTrack(context, type: "sub")
        snapshot.selectedAudioIndex = selectedTrack(context, type: "audio")
        snapshot.selectedVideoIndex = selectedTrack(context, type: "video")
        let paused = bool(context, "pause")
        let buffering = bool(context, "paused-for-cache")
        snapshot.isPlaying = isOpen && wantsToPlay && !paused
        snapshot.error = failureMessage
        if let terminalPhase { snapshot.phase = terminalPhase }
        else if !isOpen { snapshot.phase = .idle }
        else if number(context, "duration") == nil && !snapshot.hasVideoOut && text(context, "audio-codec-name") == nil { snapshot.phase = .loading }
        else if buffering { snapshot.phase = .buffering }
        else if paused { snapshot.phase = .paused }
        else { snapshot.phase = .playing }
        onSnapshot?(snapshot)
    }

    @discardableResult
    private func command(_ context: OpaquePointer, _ args: [String]) -> Int32 {
        var allocated: [UnsafeMutablePointer<CChar>] = []
        for arg in args {
            guard let value = strdup(arg) else {
                allocated.forEach { free($0) }
                return -1
            }
            allocated.append(value)
        }
        var cargs: [UnsafePointer<CChar>?] = allocated.map { UnsafePointer<CChar>($0) }
        cargs.append(nil)
        defer { allocated.forEach { free($0) } }
        return mpv_command(context, &cargs)
    }
    private func number(_ context: OpaquePointer, _ property: String) -> Double? {
        var value = Double.zero
        guard mpv_get_property(context, property, MPV_FORMAT_DOUBLE, &value) >= 0,
              value.isFinite, value >= 0 else { return nil }
        return value
    }
    private func integer(_ context: OpaquePointer, _ property: String) -> Int? {
        var value: Int64 = 0
        guard mpv_get_property(context, property, MPV_FORMAT_INT64, &value) >= 0 else { return nil }
        return Int(exactly: value)
    }
    private func bool(_ context: OpaquePointer, _ property: String) -> Bool {
        var value: Int32 = 0
        return mpv_get_property(context, property, MPV_FORMAT_FLAG, &value) >= 0 && value != 0
    }
    private func text(_ context: OpaquePointer, _ property: String) -> String? {
        guard let pointer = mpv_get_property_string(context, property) else { return nil }
        defer { mpv_free(pointer) }
        let value = String(cString: pointer).trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }
    private func tracks(_ context: OpaquePointer, type: String) -> [MPVPlaybackTrack] {
        guard let count = integer(context, "track-list/count") else { return [] }
        return (0..<min(count, 128)).compactMap { index in
            let prefix = "track-list/\(index)"
            guard text(context, "\(prefix)/type") == type,
                  let id = integer(context, "\(prefix)/id") else { return nil }
            let title = [text(context, "\(prefix)/title"), text(context, "\(prefix)/lang"), text(context, "\(prefix)/codec")]
                .compactMap { $0 }.joined(separator: " · ")
            return MPVPlaybackTrack(id: id, title: title.isEmpty ? "\(type.capitalized) \(id)" : title)
        }
    }
    private func selectedTrack(_ context: OpaquePointer, type: String) -> Int? {
        guard let count = integer(context, "track-list/count") else { return nil }
        for index in 0..<min(count, 128) {
            let prefix = "track-list/\(index)"
            if text(context, "\(prefix)/type") == type, bool(context, "\(prefix)/selected") {
                return integer(context, "\(prefix)/id")
            }
        }
        return nil
    }
    private func selectedTrackText(_ context: OpaquePointer, type: String, property: String) -> String? {
        guard let count = integer(context, "track-list/count") else { return nil }
        for index in 0..<min(count, 128) {
            let prefix = "track-list/\(index)"
            if text(context, "\(prefix)/type") == type, bool(context, "\(prefix)/selected") {
                return text(context, "\(prefix)/\(property)")
            }
        }
        return nil
    }
    private static func message(_ status: Int32) -> String {
        guard let value = mpv_error_string(status) else { return "MPV error \(status)." }
        return String(cString: value)
    }
}

private enum MPVPlaybackError: LocalizedError {
    case initialization(String)
    var errorDescription: String? {
        switch self { case .initialization(let message): "MPV could not initialize: \(message)" }
    }
}
