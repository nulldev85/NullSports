import Foundation

/// Everything that decides *how fast* a live stream is allowed to open, kept
/// free of VLCKit and UIKit so it can be compiled and checked on its own.
///
/// Every stream used to open behind a flat five-second buffer and wait a flat
/// thirty seconds before a second URL was tried. Both numbers were sized for
/// the worst provider on the worst link, so every viewer paid them on every
/// channel. Nothing here lowers the ceiling: those same numbers are still
/// where a bad connection ends up. They just stopped being where a good one
/// starts.
enum StreamStartupPolicy {
    /// Input buffer rungs, in milliseconds. Rung 0 opens fast; the last rung is
    /// the flat five seconds every stream used to start with, so a provider
    /// that genuinely needs that much still settles there.
    static let bufferLadderMs = [1500, 3000, 5000]

    static func bufferMs(for level: Int) -> Int {
        bufferLadderMs[min(max(level, 0), bufferLadderMs.count - 1)]
    }

    /// A stall after playback was already underway is the one signal that means
    /// "this link cannot sustain the current buffer" — the exact complaint that
    /// pushed the buffer to five seconds originally. Nothing else moves the
    /// ladder up, because a dead URL says nothing about link speed.
    static func escalated(_ level: Int) -> Int { min(level + 1, bufferLadderMs.count - 1) }

    static func decayed(_ level: Int) -> Int { max(level - 1, 0) }

    /// How long a picture must hold before the format that produced it is worth
    /// remembering. A feed that dies after half a second teaches nothing, and a
    /// wrong lesson here costs the next channel a wasted first attempt.
    static let heldPictureBeforeTrustingFormat: TimeInterval = 3

    /// A link that has held a picture this long at the current rung has earned a
    /// try at the next one down. Only applied when the host has not stalled at
    /// all in this run, so a rung can never oscillate within a session.
    static let cleanPlaybackBeforeDecay: TimeInterval = 90

    /// The wait on a URL that has not reached playback at all — a connection
    /// that is hanging rather than one that is slow to show a picture. Short
    /// only while there is somewhere better to go: on the last candidate this
    /// is the same thirty seconds the app has always waited, because giving up
    /// early there fails sooner rather than playing sooner.
    ///
    /// Twelve seconds, not six. A connection that is merely slow still has to
    /// resolve, handshake and fill its buffer, and abandoning one that would
    /// have played to try a URL that might be dead trades a slow channel for a
    /// broken one. Two and a half times faster than before is worth having;
    /// shaving the last few seconds is not worth that risk.
    static func firstVideoTimeout(bufferLevel: Int, hasAlternative: Bool) -> TimeInterval {
        guard hasAlternative else { return lastCandidateTimeout }
        return max(12, Double(bufferMs(for: bufferLevel)) / 1000 + 6)
    }

    static let lastCandidateTimeout: TimeInterval = 30

    /// Playing, but no picture yet. This is deliberately unchanged at the
    /// fifteen seconds the app has always allowed, and it is not a spare few
    /// seconds to be reclaimed: VLC reports playing as soon as it starts, so
    /// this same window is what a healthy stream sits in while it decodes its
    /// first frame. Shortening it abandons streams that were about to play.
    /// The slow path worth fixing is the hanging connection above, which never
    /// reaches playback at all.
    static let audioOnlyTimeout: TimeInterval = 15

    /// Opening is the only phase worth watching closely. Polling twice a second
    /// throughout meant up to half a second of dead spinner after the picture
    /// was already decoding, and the same again before `play()` was called on a
    /// surface that had been ready the whole time.
    static let startupPollInterval: TimeInterval = 0.1
    static let steadyPollInterval: TimeInterval = 0.5

    static func pollInterval(isStartingUp: Bool) -> TimeInterval {
        isStartingUp ? startupPollInterval : steadyPollInterval
    }

    /// VLC options for one attempt. `isHLS` covers the `.m3u8` candidate, whose
    /// adaptive demuxer holds its own live delay on top of the input buffer.
    static func mediaOptions(bufferLevel: Int, isHLS: Bool) -> [String] {
        let ms = bufferMs(for: bufferLevel)
        var options = [
            ":network-caching=\(ms)",
            ":live-caching=\(ms)",
            ":http-reconnect=true",
            // A live feed carries no clock worth synchronising against, and
            // VLC's jitter estimator is what turned a small buffer into dropped
            // frames and apparent stalls on slower links — the reason the buffer
            // was raised to five seconds in the first place. Disabling both is
            // the standard pairing for live IPTV and is what makes starting from
            // a short buffer safe rather than a gamble.
            ":clock-jitter=0",
            ":clock-synchro=0"
        ]
        if isHLS {
            // Left at its default the adaptive demuxer banks several extra
            // seconds of segments before showing anything. Track the input
            // buffer instead, but never drop under one segment's worth.
            options.append(":adaptive-livedelay=\(max(ms, 3000))")
        }
        return options
    }

    static func isHLS(_ url: URL) -> Bool { url.pathExtension.lowercased() == "m3u8" }

    /// Today's order — the transport stream first, as on Apple TV — unless this
    /// provider has already shown which format actually plays. A provider whose
    /// `.ts` endpoint hangs costs every viewer the full first-candidate wait on
    /// every channel; one remembered answer removes it from the second channel
    /// on. With nothing remembered the order is byte-for-byte what it was.
    static func orderedCandidates(_ urls: [URL], preferring rememberedExtension: String?) -> [URL] {
        let defaultOrder = Array(urls.reversed())
        guard let wanted = rememberedExtension?.lowercased(),
              let index = defaultOrder.firstIndex(where: { $0.pathExtension.lowercased() == wanted })
        else { return defaultOrder }
        var ordered = defaultOrder
        ordered.insert(ordered.remove(at: index), at: 0)
        return ordered
    }
}

/// What previous connections to one provider taught us: which stream format
/// actually played, and how much buffer that link needed. Small enough for
/// `UserDefaults`; losing it only costs a return to the default order and the
/// fastest rung.
final class StreamStartupMemory {
    static let shared = StreamStartupMemory()

    private let defaults: UserDefaults
    private let key = "StreamStartupMemory.v1"
    /// Hosts that have stalled since launch never decay their rung again, so a
    /// link sitting on the boundary settles instead of flapping.
    private var stalledThisRun: Set<String> = []
    private var cache: [String: [String: Any]] = [:]

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        // Read entry by entry: one unreadable provider costs only its own
        // memory, and a stored shape we don't recognise costs a default start
        // rather than a crash.
        cache = (defaults.dictionary(forKey: key) ?? [:]).compactMapValues { $0 as? [String: Any] }
    }

    /// Streams for one provider share a host, and it is the link to that host
    /// — not the channel — that decides how much buffer is needed.
    static func host(for url: URL?) -> String? { url?.host?.lowercased() }

    func preferredExtension(for host: String?) -> String? {
        guard let host else { return nil }
        return cache[host]?["ext"] as? String
    }

    func bufferLevel(for host: String?) -> Int {
        guard let host else { return 0 }
        return cache[host]?["level"] as? Int ?? 0
    }

    func recordPlayed(host: String?, format: String) {
        guard let host, !format.isEmpty else { return }
        write(host: host) { $0["ext"] = format.lowercased() }
    }

    /// Returns the rung to reopen at.
    @discardableResult
    func recordStall(host: String?) -> Int {
        guard let host else { return 0 }
        stalledThisRun.insert(host)
        let level = StreamStartupPolicy.escalated(bufferLevel(for: host))
        write(host: host) { $0["level"] = level }
        return level
    }

    /// Returns true when the rung actually moved, so the caller only logs or
    /// reacts to a real change.
    @discardableResult
    func recordSustainedPlayback(host: String?) -> Bool {
        guard let host, !stalledThisRun.contains(host) else { return false }
        let current = bufferLevel(for: host)
        let decayed = StreamStartupPolicy.decayed(current)
        guard decayed != current else { return false }
        write(host: host) { $0["level"] = decayed }
        return true
    }

    private func write(host: String, _ mutate: (inout [String: Any]) -> Void) {
        var entry = cache[host] ?? [:]
        mutate(&entry)
        cache[host] = entry
        defaults.set(cache, forKey: key)
    }
}
