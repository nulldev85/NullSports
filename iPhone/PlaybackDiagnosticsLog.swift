import Foundation

/// A bounded, timestamped record of what playback did and in what order.
///
/// The ordering is the whole point. Whether the video surface exists when the
/// stream opens, whether the layer is installed before or after `play()`, and
/// whether the layer ever reports itself ready to display are questions a
/// snapshot cannot answer — only a sequence with timings can.
///
/// Pure Foundation so it can be checked without a simulator.
struct PlaybackDiagnosticsLog: Equatable {
    struct Entry: Equatable {
        /// Seconds since the session began, not wall clock: the interval is
        /// what matters and it stays stable across clock changes.
        let at: TimeInterval
        let text: String
    }

    /// Enough to cover opening a stream and a few minutes of running, without
    /// letting a long session grow without bound.
    static let limit = 250

    private(set) var entries: [Entry] = []
    private var origin: TimeInterval?
    private let limit: Int

    init(limit: Int = PlaybackDiagnosticsLog.limit) {
        self.limit = max(1, limit)
    }

    var isEmpty: Bool { entries.isEmpty }
    var count: Int { entries.count }

    /// The first entry sets the origin, so every later timestamp reads as
    /// "how long after this stream started".
    mutating func append(_ text: String, at now: TimeInterval) {
        if origin == nil { origin = now }
        entries.append(Entry(at: now - (origin ?? now), text: text))
        // Drop the oldest rather than the newest: the tail is where a failure
        // shows up, and the head is a fixed, well-understood opening sequence.
        if entries.count > limit { entries.removeFirst(entries.count - limit) }
    }

    mutating func reset() {
        entries.removeAll()
        origin = nil
    }

    /// Fixed-width seconds so the column lines up when pasted into a report.
    func transcript() -> String {
        entries.map { entry in
            String(format: "%8.3f  %@", entry.at, entry.text)
        }.joined(separator: "\n")
    }
}
