import Foundation

@main
enum GuideProgressChecks {
    static func main() {
        func fill(_ now: Double, viewport: Double = 0, end: Double = 100, width: Double = 94) -> Double {
            GuideProgress.playedWidth(start: Date(timeIntervalSince1970: 0),
                end: Date(timeIntervalSince1970: end), now: Date(timeIntervalSince1970: now),
                visibleStart: Date(timeIntervalSince1970: viewport), pointsPerSecond: 1, cellWidth: width)
        }
        precondition(fill(-1) == 0)
        precondition(fill(0) == 0)
        precondition(fill(50) == 50)
        precondition(fill(100) == 94)
        precondition(fill(150) == 94)
        precondition(fill(50, viewport: 20, width: 74) == 30)
        precondition(fill(50, viewport: 60, width: 34) == 0)
        precondition(fill(50, width: 24) == 24) // Now beyond the displayed part.
        precondition(fill(150, viewport: 20, width: 74) == 74)
        precondition(fill(50, end: 0) == 0)
        print("10 Guide progress checks passed")
    }
}
