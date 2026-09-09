import Foundation

/// An eight-hour viewport starting at the current half-hour.
struct MobileGuideWindow {
    let start: Date
    let end: Date
    static let pointsPerSecond = 96.0 / 1800.0

    init(now: Date) {
        start = Date(timeIntervalSince1970: floor(now.timeIntervalSince1970 / 1800) * 1800)
        end = start.addingTimeInterval(8 * 3600)
    }

    var width: Double { x(end) }
    var ticks: [Date] { (0..<16).map { start.addingTimeInterval(Double($0) * 1800) } }
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
