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
        check(window.ticks.count == 18 && window.x(date(1800)) == 96, "Half-hour labels align with the program scale")
        check(window.width == 1728, "An hour of history plus eight hours of listings")
        let midnight = MobileGuideWindow(now: Date(timeIntervalSince1970: 0))
        check(midnight.anchor == Date(timeIntervalSince1970: 0), "The window anchors on the current half-hour at midnight")
        check(midnight.start == Date(timeIntervalSince1970: -3600), "History extends an hour before the anchor")
        // The elapsed shading is only legible when the program that is on now
        // has room in front of it, so `now` must sit an hour into the window.
        check(window.start < now && window.x(now) >= 96 * 2, "Now sits an hour into the window, not at its edge")
        check(now >= window.anchor && now < window.anchor.addingTimeInterval(1800), "The anchor tracks the current half-hour")
        check(!window.isStale(at: now), "A freshly built window is current")
        check(!window.isStale(at: window.anchor.addingTimeInterval(1799)), "The window holds until the half-hour turns")
        check(window.isStale(at: window.anchor.addingTimeInterval(1800)), "The window rebases once the half-hour turns")
        let nextWindow = MobileGuideWindow(now: window.anchor.addingTimeInterval(1800))
        check(nextWindow.anchor == window.anchor.addingTimeInterval(1800), "Following live advances at each half-hour boundary")
        check(nextWindow.start == origin.addingTimeInterval(1800), "History advances with the window")
        print("Mobile guide timeline checks passed")
    }
}
