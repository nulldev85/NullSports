import Foundation

/// An hour of history followed by eight hours of listings.
///
/// The history is what makes a program's elapsed shading readable. When the
/// window began at the current half-hour, a program already in progress was
/// clipped to the left edge, so its shading measured from that edge and
/// restarted every time the window rebased. With an hour in front of it, the
/// shading starts where the program actually started and stays between one and
/// one and a half hours wide instead of collapsing to nothing on the half-hour.
struct MobileGuideWindow {
    /// The current half-hour. The window follows this, not `start`.
    let anchor: Date
    let start: Date
    let end: Date
    static let pointsPerSecond = 96.0 / 1800.0
    static let lookback: TimeInterval = 3600
    static let span: TimeInterval = lookback + 8 * 3600

    init(now: Date) {
        anchor = Date(timeIntervalSince1970: floor(now.timeIntervalSince1970 / 1800) * 1800)
        start = anchor.addingTimeInterval(-Self.lookback)
        end = start.addingTimeInterval(Self.span)
    }

    /// True once `now` has crossed into the next half-hour and the window
    /// should be rebuilt. `start` sits in the past, so it cannot answer this.
    func isStale(at now: Date) -> Bool { now >= anchor.addingTimeInterval(1800) }

    var width: Double { x(end) }
    var ticks: [Date] { (0..<Int(Self.span / 1800)).map { start.addingTimeInterval(Double($0) * 1800) } }
    func x(_ date: Date) -> Double { date.timeIntervalSince(start) * Self.pointsPerSecond }

    struct Segment: Identifiable {
        var id: Date { start }
        let start: Date
        let end: Date
        let programIndex: Int?
    }

    // Clip long programs, skip malformed entries, and explicitly fill guide gaps.
    // Keep original indices so the UI can retrieve the program without guessing.
    func segments(_ programs: [(start: Date, end: Date)]) -> [Segment] {
        var result: [Segment] = []
        var cursor = start
        for (index, program) in programs.enumerated().sorted(by: {
            $0.element.start == $1.element.start ? $0.offset < $1.offset : $0.element.start < $1.element.start
        }) {
            guard program.end > program.start, program.end > cursor, program.start < end else { continue }
            let clippedStart = max(cursor, program.start)
            let clippedEnd = min(end, program.end)
            if clippedStart > cursor {
                result.append(Segment(start: cursor, end: clippedStart, programIndex: nil))
            }
            result.append(Segment(start: clippedStart, end: clippedEnd, programIndex: index))
            cursor = clippedEnd
            if cursor == end { break }
        }
        if cursor < end { result.append(Segment(start: cursor, end: end, programIndex: nil)) }
        return result
    }
}
