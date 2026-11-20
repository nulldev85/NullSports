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

    private let started: TimeInterval
    private var lastProgress: TimeInterval
    /// When media last arrived or was presented.
    private var lastData: TimeInterval
    private var healthySince: TimeInterval?
    private var lastTime: Int32?
    private var lastFrames: Int?
    private var lastBytes: Int?
    private var lastBuffer: Double?
    private var hadVideo = false
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

    /// How long a stream may be open without a picture before it counts as
    /// lost. Thirty seconds where reconnecting is all there is to do; a
    /// game, with another verified channel to move to, waits less.
    private let neverPlayedLimit: TimeInterval

    init(now: TimeInterval, stallLimit: TimeInterval = 12, neverPlayedLimit: TimeInterval = 30) {
        started = now
        lastProgress = now
        lastData = now
        self.stallLimit = stallLimit
        self.neverPlayedLimit = neverPlayedLimit
        frozenLimit = max(45, stallLimit * 2)
    }

    /// Whether a picture has been shown since the stream was opened.
    var hasShownPicture: Bool { hadVideo }

    /// How long since the stream was opened.
    func age(now: TimeInterval) -> TimeInterval { now - started }

    /// Byte counters can wrap. Engines without a counter can report how much
    /// playable data they are adding to their forward buffer.
    mutating func observe(now: TimeInterval, playing: Bool, video: Bool,
                          time: Int32, frames: Int?, bytes: Int? = nil, bufferedAhead: Double? = nil,
                          failed: Bool) -> Bool {
        if failed && now - started >= 2 {
            stall = .failed
            return true
        }
        let frameProgress = frames.map { $0 > 0 && $0 != lastFrames } ?? false
        let usesFrames = (frames ?? 0) > 0 || (lastFrames ?? 0) > 0
        let clockProgress = playing && time >= 0 && lastTime != nil && time != lastTime
        let progress = usesFrames ? frameProgress : clockProgress
        if let bytes, bytes != 0 {
            if bytes != lastBytes { lastData = now }
            lastBytes = bytes
        }
        if let bufferedAhead, bufferedAhead.isFinite, bufferedAhead >= 0 {
            let baseline = lastBuffer ?? 0
            if bufferedAhead > baseline + 0.05 {
                lastData = now
                lastBuffer = bufferedAhead
            } else if bufferedAhead < baseline {
                lastBuffer = bufferedAhead
            }
        }
        lastTime = time
        lastFrames = frames
        if video && progress {
            hadVideo = true
            lastProgress = now
            lastData = now
            if healthySince == nil { healthySince = now }
        } else if now - lastProgress > 3 {
            healthySince = nil
        }
        // Still arriving, the picture is given longer to come back.
        let arriving = now - lastData < stallLimit
        let limit = arriving ? frozenLimit : stallLimit
        let lost: Bool
        if hadVideo {
            lost = now - lastProgress >= limit
        } else {
            let openingLimit = max(neverPlayedLimit, stallLimit)
            // Give a source making progress time to produce a frame, with a
            // hard ceiling in case it sends data that can never be rendered.
            lost = now - started >= openingLimit + (arriving ? 15 : 0)
        }
        if lost { stall = !hadVideo ? .neverPlayed : arriving ? .frozenWhileArriving : .nothingArriving }
        return lost
    }

    static func milliseconds(_ seconds: TimeInterval) -> Int32 {
        guard seconds.isFinite, seconds >= 0 else { return -1 }
        return Int32(min(seconds * 1_000, Double(Int32.max)))
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
