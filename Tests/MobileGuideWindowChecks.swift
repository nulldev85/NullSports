import Foundation

@main
struct MobileGuideWindowChecks {
    static func main() {
        let now = Date(timeIntervalSince1970: 1_800_000_900)
        let window = MobileGuideWindow(now: now)
        let origin = window.start
        func date(_ seconds: Double) -> Date { origin.addingTimeInterval(seconds) }
        func check(_ condition: Bool, _ message: String) {
            precondition(condition, message)
        }
        let empty = window.segments([])
        check(empty.count == 1 && empty[0].programIndex == nil, "Empty channels remain watchable across the whole window")
        check(empty[0].start == origin && empty[0].end == window.end, "Empty guide covers the viewport")
        let long = window.segments([(date(-7200), date(40000))])
        check(long.count == 1 && long[0].start == origin && long[0].end == window.end, "Long events clip at both ends")
        let mixed = window.segments([
            (date(3600), date(7200)),
            (date(-600), date(1800)),
            (date(1200), date(2400)),
            (date(8000), date(7000)),
            (date(30000), date(31000))
        ])
        check(mixed.compactMap(\.programIndex) == [1, 2, 0], "Sorting preserves source indices and excludes invalid/offscreen entries")
        check(mixed[1].start == date(1800), "Overlaps must not double-book horizontal space")
        check(mixed[2].programIndex == nil && mixed[2].start == date(2400) && mixed[2].end == date(3600), "Missing listings leave explicit gaps")
        check(mixed.first?.start == origin && mixed.last?.end == window.end, "Segments span the viewport")
        for pair in zip(mixed, mixed.dropFirst()) {
            check(pair.0.end == pair.1.start, "All segments must meet without overlaps or unfilled gaps")
        }
        check(window.ticks.count == 16 && window.x(date(1800)) == 96, "Half-hour labels align with the program scale")
        check(window.width == 1536, "Eight hours use a stable horizontal extent")
        let midnight = MobileGuideWindow(now: Date(timeIntervalSince1970: 0))
        check(midnight.start < Date(timeIntervalSince1970: 0), "Viewport crosses midnight without losing prior programs")
        print("Mobile guide timeline checks passed")
    }
}
