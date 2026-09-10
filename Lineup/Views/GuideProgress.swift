import Foundation

enum GuideProgress {
    // Real dates determine playback state. The viewport only clips the rendered fill.
    static func playedWidth(start: Date, end: Date, now: Date, visibleStart: Date,
                            pointsPerSecond: Double, cellWidth: Double) -> Double {
        guard end > start, cellWidth > 0, now > start else { return 0 }
        if now >= end { return cellWidth }
        let elapsed = now.timeIntervalSince(max(start, visibleStart))
        return min(cellWidth, max(0, elapsed * pointsPerSecond))
    }
}
