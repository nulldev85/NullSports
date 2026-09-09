import Foundation

@main
enum LivePlaybackHealthChecks {
    static func main() {
        var health = LivePlaybackHealth(now: 0)
        func sample(_ second: Int, frames: Int, time: Int32? = nil, playing: Bool = true,
                    video: Bool = true, failed: Bool = false) -> Bool {
            health.observe(now: Double(second), playing: playing, video: video,
                time: time ?? Int32(second * 1000), frames: frames, failed: failed)
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
        var retry = LivePlaybackRetry()
        for expected in [TimeInterval(1), 2, 4, 8, 15, 30] { precondition(retry.nextDelay() == expected) }
        precondition(retry.nextDelay() == nil, "Failed feeds must not reconnect forever")
        retry.reset()
        precondition(retry.nextDelay() == 1, "Stable playback or explicit Retry restores recovery budget")
        print("Live playback health regression checks passed")
    }
}
