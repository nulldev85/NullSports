import Foundation

@main
struct PlaybackDiagnosticsLogChecks {
    static func main() {
        func check(_ condition: Bool, _ message: String) { precondition(condition, message) }

        var log = PlaybackDiagnosticsLog()
        check(log.isEmpty, "A new log has nothing in it")
        check(log.transcript().isEmpty, "…and an empty transcript")

        // Timestamps are relative to the first entry, so a log reads as elapsed
        // time from the moment the stream opened.
        log.append("start", at: 1000)
        log.append("layer installed", at: 1000.25)
        log.append("play", at: 1000.5)
        check(log.count == 3, "Every entry is kept")
        check(log.entries[0].at == 0, "The first entry is the origin")
        check(abs(log.entries[1].at - 0.25) < 0.0001, "Later entries are offsets from it")
        check(abs(log.entries[2].at - 0.5) < 0.0001, "…in order")

        let lines = log.transcript().components(separatedBy: "\n")
        check(lines.count == 3, "One line per entry")
        check(lines[0].hasSuffix("start"), "The text survives formatting")
        check(lines[1].contains("0.250"), "Timings are printed to milliseconds")
        check(lines[0].count == lines[1].count - "layer installed".count + "start".count,
              "The time column is fixed width so it lines up")

        // A monotonic clock that jumps backwards must not produce nonsense that
        // crashes formatting.
        var backwards = PlaybackDiagnosticsLog()
        backwards.append("a", at: 50)
        backwards.append("b", at: 10)
        check(backwards.count == 2, "Out-of-order timestamps are still recorded")
        check(backwards.entries[1].at == -40, "…and reported as they are, not clamped away")

        // The cap drops the oldest: a failure shows up at the tail.
        var bounded = PlaybackDiagnosticsLog(limit: 3)
        for i in 0..<10 { bounded.append("entry \(i)", at: Double(i)) }
        check(bounded.count == 3, "The log is bounded")
        check(bounded.entries.map(\.text) == ["entry 7", "entry 8", "entry 9"],
              "The newest entries are the ones kept")

        var degenerate = PlaybackDiagnosticsLog(limit: 0)
        degenerate.append("only", at: 0)
        check(degenerate.count == 1, "A zero limit still keeps one entry rather than dividing by nothing")

        log.reset()
        check(log.isEmpty, "Reset clears the log")
        log.append("fresh", at: 9999)
        check(log.entries[0].at == 0, "…and the next entry becomes a new origin")

        print("Playback diagnostics log checks passed")
    }
}
