import Foundation

// Monotonic timestamps make recovery independent of clock/time-zone changes.
struct LivePlaybackHealth {
    /// Why a stream was judged lost, for the playback log.
    enum Stall {
        /// The player reported an error, or the stream ended or stopped.
        case failed
        /// The picture stood still and nothing more was arriving.
        case nothingArriving
        /// The picture stood still for a long while although data kept
        /// arriving.
        case frozenWhileArriving
        /// No picture came at all after the stream was opened.
        case neverPlayed
    }

    private var started: TimeInterval
    private var lastProgress: TimeInterval
    /// When the last bytes came in from the server.
    private var lastData: TimeInterval
    private var healthySince: TimeInterval?
    private var lastTime: Int32?
    private var lastFrames: Int?
    private var lastBytes: Int?
    private var hadVideo = false
    private var missingVideoSince: TimeInterval?
    /// How long a picture may stand still with nothing arriving before the
    /// stream counts as lost. Twelve seconds for a channel, where the remedy
    /// is to reconnect; a film on a slow link can buffer longer than that and
    /// still recover by itself.
    private let stallLimit: TimeInterval
    /// How long a picture may stand still while data keeps arriving.
    ///
    /// VLC rebuffers a live stream that falls behind from scratch -- its whole
    /// buffer, then a keyframe -- and the picture can hold for longer than a
    /// stall's twelve seconds while every byte is still coming in. Judged on
    /// the picture alone, that was a lost stream: the app reconnected in the
    /// middle of it, threw away a connection that was working, and started
    /// the same wait over. It was the "Reconnecting" over a game that other
    /// apps played without a pause.
    private let frozenLimit: TimeInterval
    /// Why the last stream judged lost was.
    private(set) var stall: Stall?

    init(now: TimeInterval, stallLimit: TimeInterval = 12) {
        started = now
        lastProgress = now
        lastData = now
        self.stallLimit = stallLimit
        frozenLimit = max(45, stallLimit * 2)
    }

    /// Whether a picture has been shown since the stream was opened.
    var hasShownPicture: Bool { hadVideo }

    /// How long since the stream was opened.
    func age(now: TimeInterval) -> TimeInterval { now - started }

    /// `bytes` is how much the player has read from the server, when it can
    /// say. The count can wrap, so any change at all is data arriving.
    mutating func observe(now: TimeInterval, playing: Bool, video: Bool,
                          time: Int32, frames: Int?, bytes: Int? = nil, failed: Bool) -> Bool {
        if failed && now - started >= 2 {
            stall = .failed
            return true
        }
        let frameProgress = frames.map { $0 > 0 && $0 != lastFrames } ?? false
        let usesFrames = (frames ?? 0) > 0 || (lastFrames ?? 0) > 0
        let progress = usesFrames ? frameProgress : (time >= 0 && lastTime != nil && time != lastTime)
        if let bytes, bytes > 0, let lastBytes, bytes != lastBytes { lastData = now }
        lastTime = time
        lastFrames = frames
        lastBytes = bytes
        if playing && video && progress {
            hadVideo = true
            lastProgress = now
            lastData = now
            missingVideoSince = nil
            if healthySince == nil { healthySince = now }
        } else {
            if now - lastProgress > 3 { healthySince = nil }
            if !video && hadVideo && missingVideoSince == nil { missingVideoSince = now }
        }
        // Still arriving, the picture is given longer to come back.
        let arriving = now - lastData < stallLimit
        let limit = arriving ? frozenLimit : stallLimit
        let lost: Bool
        if let missingVideoSince, now - missingVideoSince >= limit {
            lost = true
        } else if hadVideo {
            lost = now - lastProgress >= limit
        } else {
            lost = now - started >= max(30, stallLimit)
        }
        if lost { stall = !hadVideo ? .neverPlayed : arriving ? .frozenWhileArriving : .nothingArriving }
        return lost
    }

    /// Long enough playing well that the retries are earned back.
    func isStable(now: TimeInterval) -> Bool {
        healthySince.map { now - $0 >= 30 && now - lastProgress < 3 } ?? false
    }
}

struct LivePlaybackRetry {
    private(set) var attempts = 0
    mutating func nextDelay() -> TimeInterval? {
        let delays: [TimeInterval] = [1, 2, 4, 8, 15, 30]
        guard attempts < delays.count else { return nil }
        let delay = delays[attempts]
        attempts += 1
        return delay
    }
    mutating func reset() { attempts = 0 }
}
