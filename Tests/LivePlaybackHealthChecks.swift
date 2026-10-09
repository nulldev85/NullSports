import Foundation

@main
enum LivePlaybackHealthChecks {
    static func main() {
        var health = LivePlaybackHealth(now: 0)
        func sample(_ second: Int, frames: Int, time: Int32? = nil, bytes: Int? = nil, playing: Bool = true,
                    video: Bool = true, failed: Bool = false) -> Bool {
            health.observe(now: Double(second), playing: playing, video: video,
                time: time ?? Int32(second * 1000), frames: frames, bytes: bytes, failed: failed)
        }
        for second in 1...120 { precondition(!sample(second, frames: second * 30)) }
        precondition(health.isStable(now: 120), "Stable playback replenishes recovery budget")
        for second in 121...131 { precondition(!sample(second, frames: 3600)) }
        precondition(sample(132, frames: 3600), "Frozen frames must recover even if audio clock advances")
        health = LivePlaybackHealth(now: 0)
        precondition(!sample(1, frames: 30))
        precondition(sample(3, frames: 30, playing: false, video: false, failed: true), "Ended stream recovers")
        health = LivePlaybackHealth(now: 0)
        precondition(!sample(29, frames: 0, time: -1, playing: false, video: false))
        precondition(sample(30, frames: 0, time: -1, playing: false, video: false), "Opening cannot hang forever")
        health = LivePlaybackHealth(now: 0)
        precondition(!sample(1, frames: 30))
        precondition(!sample(2, frames: 30, video: false))
        precondition(sample(14, frames: 30, video: false), "Lost video output recovers")
        // Controllers reset health after intentional pause/background suspension.
        health = LivePlaybackHealth(now: 600)
        precondition(!sample(601, frames: 30), "Paused time must not count as a stall after resume")
        health = LivePlaybackHealth(now: 0)
        for second in 1...40 { precondition(!sample(second, frames: 0), "Clock fallback supports unavailable frame statistics") }
        health = LivePlaybackHealth(now: 0)
        for second in 1...40 { precondition(!sample(second, frames: second * 30, time: -1), "Video frames support an unavailable media clock") }
        // A film buffering on a slow link is given longer than a channel.
        health = LivePlaybackHealth(now: 0, stallLimit: 30)
        precondition(!sample(1, frames: 30))
        for second in 2...30 { precondition(!sample(second, frames: 30), "A film may buffer past a channel's limit") }
        precondition(sample(31, frames: 30), "A film that never resumes still recovers")
        // A picture standing still while the stream keeps arriving is VLC
        // rebuffering a late feed, not a lost one: it is given far longer.
        health = LivePlaybackHealth(now: 0)
        precondition(!health.hasShownPicture)
        for second in 1...10 { precondition(!sample(second, frames: second * 30, bytes: second * 100_000)) }
        precondition(health.hasShownPicture)
        for second in 11...54 {
            precondition(!sample(second, frames: 300, bytes: second * 100_000),
                         "A frozen picture with data still arriving is not reconnected at twelve seconds")
        }
        precondition(sample(55, frames: 300, bytes: 55 * 100_000), "A picture frozen for 45 seconds recovers anyway")
        precondition(health.stall == .frozenWhileArriving)
        // Frozen with nothing arriving is lost after twelve seconds, as before.
        health = LivePlaybackHealth(now: 0)
        for second in 1...10 { precondition(!sample(second, frames: second * 30, bytes: second * 100_000)) }
        for second in 11...21 { precondition(!sample(second, frames: 300, bytes: 1_000_000)) }
        precondition(sample(22, frames: 300, bytes: 1_000_000), "A feed that stops arriving recovers in twelve seconds")
        precondition(health.stall == .nothingArriving)
        // The retries are earned back after half a minute of good playback.
        health = LivePlaybackHealth(now: 0)
        for second in 1...29 { _ = sample(second, frames: second * 30) }
        precondition(!health.isStable(now: 29))
        _ = sample(31, frames: 31 * 30)
        precondition(health.isStable(now: 31), "Half a minute of playback earns the retries back")
        var retry = LivePlaybackRetry()
        for expected in [TimeInterval(1), 2, 4, 8, 15, 30] { precondition(retry.nextDelay() == expected) }
        precondition(retry.nextDelay() == nil, "Failed feeds must not reconnect forever")
        retry.reset()
        precondition(retry.nextDelay() == 1, "Stable playback or explicit Retry restores recovery budget")
        print("Live playback health regression checks passed")
    }
}
