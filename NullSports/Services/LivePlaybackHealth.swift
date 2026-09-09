import Foundation

// Monotonic timestamps make recovery independent of clock/time-zone changes.
struct LivePlaybackHealth {
    private var started: TimeInterval
    private var lastProgress: TimeInterval
    private var healthySince: TimeInterval?
    private var lastTime: Int32?
    private var lastFrames: Int?
    private var hadVideo = false
    private var missingVideoSince: TimeInterval?

    init(now: TimeInterval) {
        started = now
        lastProgress = now
    }

    mutating func observe(now: TimeInterval, playing: Bool, video: Bool,
                          time: Int32, frames: Int?, failed: Bool) -> Bool {
        if failed && now - started >= 2 { return true }
        let frameProgress = frames.map { $0 > 0 && $0 != lastFrames } ?? false
        let usesFrames = (frames ?? 0) > 0 || (lastFrames ?? 0) > 0
        let progress = usesFrames ? frameProgress : (time >= 0 && lastTime != nil && time != lastTime)
        lastTime = time
        lastFrames = frames
        if playing && video && progress {
            hadVideo = true
            lastProgress = now
            missingVideoSince = nil
            if healthySince == nil { healthySince = now }
        } else {
            if now - lastProgress > 3 { healthySince = nil }
            if !video && hadVideo && missingVideoSince == nil { missingVideoSince = now }
        }
        if let missingVideoSince, now - missingVideoSince >= 12 { return true }
        return hadVideo ? now - lastProgress >= 12 : now - started >= 30
    }

    func isStable(now: TimeInterval) -> Bool {
        healthySince.map { now - $0 >= 60 && now - lastProgress < 3 } ?? false
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
