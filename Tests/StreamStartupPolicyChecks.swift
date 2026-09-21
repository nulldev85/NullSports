import Foundation

@main
struct StreamStartupPolicyChecks {
    static func check(_ condition: Bool, _ message: String) {
        precondition(condition, message)
    }

    static func main() {
        let m3u8 = URL(string: "http://provider.example.com:8080/live/user/pass/451.m3u8")!
        let ts = URL(string: "http://provider.example.com:8080/live/user/pass/451.ts")!
        // Exactly what XtreamClient.playbackURLs hands back, in its order.
        let supplied = [m3u8, ts]

        // --- Candidate order -------------------------------------------------
        // Nothing learned yet must behave byte-for-byte like the old code, which
        // simply reversed the list to put the transport stream first.
        check(StreamStartupPolicy.orderedCandidates(supplied, preferring: nil) == [ts, m3u8],
              "With nothing remembered the transport stream is still tried first")
        check(StreamStartupPolicy.orderedCandidates(supplied, preferring: "m3u8") == [m3u8, ts],
              "A provider known to serve HLS leads with it instead of waiting out .ts")
        check(StreamStartupPolicy.orderedCandidates(supplied, preferring: "TS") == [ts, m3u8],
              "Remembered formats match case-insensitively")
        check(StreamStartupPolicy.orderedCandidates(supplied, preferring: "mkv") == [ts, m3u8],
              "A remembered format that isn't on offer falls back to the default order")
        check(StreamStartupPolicy.orderedCandidates([], preferring: "ts").isEmpty,
              "No candidates stays no candidates")
        check(Set(StreamStartupPolicy.orderedCandidates(supplied, preferring: "m3u8")) == Set(supplied),
              "Reordering never drops or duplicates a candidate")

        // --- Buffer ladder ---------------------------------------------------
        check(StreamStartupPolicy.bufferLadderMs.last == 5000,
              "The slowest rung is the flat five seconds every stream used to start with")
        check(StreamStartupPolicy.bufferMs(for: 0) < 5000, "The first rung opens sooner than that")
        check(StreamStartupPolicy.bufferMs(for: -3) == StreamStartupPolicy.bufferLadderMs[0],
              "Out-of-range rungs clamp low")
        check(StreamStartupPolicy.bufferMs(for: 99) == 5000, "Out-of-range rungs clamp high")
        check(StreamStartupPolicy.bufferLadderMs == StreamStartupPolicy.bufferLadderMs.sorted(),
              "Rungs only ever get deeper")
        var level = 0
        for _ in 0..<10 { level = StreamStartupPolicy.escalated(level) }
        check(level == StreamStartupPolicy.bufferLadderMs.count - 1,
              "Repeated stalls settle at the old five-second buffer and stop there")
        check(StreamStartupPolicy.bufferMs(for: level) == 5000,
              "A link that keeps starving ends up exactly where the app used to begin")
        for _ in 0..<10 { level = StreamStartupPolicy.decayed(level) }
        check(level == 0, "A link that stays clean can work its way back to the fastest rung")
        check(StreamStartupPolicy.heldPictureBeforeTrustingFormat > 0
              && StreamStartupPolicy.heldPictureBeforeTrustingFormat < StreamStartupPolicy.cleanPlaybackBeforeDecay,
              "A format is trusted well before a rung is relaxed, never the other way round")

        // --- Timeouts --------------------------------------------------------
        // On the last candidate there is nowhere better to go, so the waits are
        // the ones the app has always allowed. Impatience is only for when
        // switching is actually an option.
        check(StreamStartupPolicy.firstVideoTimeout(bufferLevel: 0, hasAlternative: false) == 30,
              "The last candidate still gets the full thirty seconds")
        check(StreamStartupPolicy.firstVideoTimeout(bufferLevel: 2, hasAlternative: false) == 30,
              "That holds at every rung")
        // Playing-but-no-picture is also where a healthy stream decodes its
        // first frame, so this window is not a few spare seconds to reclaim.
        check(StreamStartupPolicy.audioOnlyTimeout == 15,
              "A stream that is playing keeps every second it had to show a picture")
        check(StreamStartupPolicy.firstVideoTimeout(bufferLevel: 0, hasAlternative: true) == 12,
              "A hanging first URL costs twelve seconds, not thirty")
        for rung in 0..<StreamStartupPolicy.bufferLadderMs.count {
            let timeout = StreamStartupPolicy.firstVideoTimeout(bufferLevel: rung, hasAlternative: true)
            let buffer = Double(StreamStartupPolicy.bufferMs(for: rung)) / 1000
            check(timeout >= buffer + 6,
                  "Every rung is given time to resolve, handshake and fill its buffer")
            check(timeout >= StreamStartupPolicy.audioOnlyTimeout - 3,
                  "Reaching playback is never held to a tighter bar than showing a picture")
            check(timeout <= StreamStartupPolicy.lastCandidateTimeout,
                  "Switching candidates is never slower than waiting one out")
        }

        // --- Media options ---------------------------------------------------
        let fast = StreamStartupPolicy.mediaOptions(bufferLevel: 0, isHLS: false)
        let slow = StreamStartupPolicy.mediaOptions(bufferLevel: 99, isHLS: false)
        check(slow.contains(":network-caching=5000") && slow.contains(":live-caching=5000"),
              "The deepest rung reproduces the original buffer options exactly")
        check(fast.contains(":network-caching=\(StreamStartupPolicy.bufferLadderMs[0])"),
              "The first rung asks for its own, shorter buffer")
        for options in [fast, slow] {
            check(options.contains(":http-reconnect=true"), "Reconnect stays on at every rung")
            // These are what make a short buffer safe rather than a gamble: they
            // remove the jitter estimator that turned small buffers into stalls.
            check(options.contains(":clock-jitter=0") && options.contains(":clock-synchro=0"),
                  "Live clock handling is disabled so a short buffer doesn't read as drift")
            check(options.allSatisfy({ $0.hasPrefix(":") }), "VLC options are passed in its own syntax")
        }
        check(!fast.contains(where: { $0.hasPrefix(":adaptive-livedelay") }),
              "Transport streams don't carry an adaptive-demuxer setting")
        let hls = StreamStartupPolicy.mediaOptions(bufferLevel: 0, isHLS: true)
        check(hls.contains(":adaptive-livedelay=3000"),
              "HLS trims its own live delay but never below one segment's worth")
        check(StreamStartupPolicy.isHLS(m3u8) && !StreamStartupPolicy.isHLS(ts),
              "Only the .m3u8 candidate is treated as HLS")

        // --- Poll cadence ----------------------------------------------------
        check(StreamStartupPolicy.pollInterval(isStartingUp: true) < StreamStartupPolicy.pollInterval(isStartingUp: false),
              "Opening is watched more closely than steady playback")
        check(StreamStartupPolicy.pollInterval(isStartingUp: false) == 0.5,
              "Steady playback keeps the original half-second watchdog cadence")

        // --- Provider memory -------------------------------------------------
        // A suite of its own per run, so a previous run can never seed this one.
        let suite = "StreamStartupPolicyChecks.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite) ?? .standard
        let memory = StreamStartupMemory(defaults: defaults)
        let host = StreamStartupMemory.host(for: ts)
        check(host == "provider.example.com", "Memory is keyed by provider host, not by channel")
        check(StreamStartupMemory.host(for: nil) == nil, "A missing URL has no host")
        check(memory.preferredExtension(for: host) == nil && memory.bufferLevel(for: host) == 0,
              "An unknown provider starts at the default order and the fastest rung")
        check(memory.bufferLevel(for: nil) == 0, "A hostless stream falls back to defaults")

        memory.recordPlayed(host: host, format: "M3U8")
        check(memory.preferredExtension(for: host) == "m3u8", "The format that played is remembered, normalized")
        check(memory.preferredExtension(for: "other.example.com") == nil,
              "One provider's answer never leaks into another's")

        check(memory.recordStall(host: host) == 1, "A stall moves this provider one rung deeper")
        check(memory.bufferLevel(for: host) == 1, "And that rung is what the next connection opens at")
        check(!memory.recordSustainedPlayback(host: host),
              "A provider that has stalled this run never talks itself back down")
        check(memory.bufferLevel(for: host) == 1, "So its rung holds")

        let clean = StreamStartupMemory(defaults: defaults)
        check(clean.bufferLevel(for: host) == 1, "A fresh run inherits the rung the link needed")
        check(clean.preferredExtension(for: host) == "m3u8", "And the format that worked")
        check(clean.recordSustainedPlayback(host: host),
              "With no stall this run, a long clean stretch earns a faster rung")
        check(clean.bufferLevel(for: host) == 0, "Which is the one the next connection uses")
        check(!clean.recordSustainedPlayback(host: host), "The fastest rung has nowhere further to go")

        defaults.removePersistentDomain(forName: suite)
        print("Stream startup policy checks passed")
    }
}
