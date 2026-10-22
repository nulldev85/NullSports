import Foundation

/// One repeated strip's geometry and time, shared by the native layer animator
/// and its coverage checks. No SwiftUI state changes drive individual frames.
struct MobileWelcomeRowMotion {
    static let copyCount = 3
    static let pointsPerSecond: CGFloat = 24

    let period: CGFloat
    let startOffset: CGFloat
    let endOffset: CGFloat

    var duration: TimeInterval { Double(period / Self.pointsPerSecond) }

    init(rowIndex: Int, rowCount: Int, period: CGFloat) {
        self.period = max(0, period)
        guard rowCount > 0, period > 0 else {
            startOffset = 0
            endOffset = 0
            return
        }

        let index = ((rowIndex % rowCount) + rowCount) % rowCount
        let phase = period * CGFloat(index) / CGFloat(rowCount)
        let movesLeft = index.isMultiple(of: 2)
        // The right-moving row begins on the second of three identical strips.
        startOffset = movesLeft ? -phase : -period - phase
        endOffset = startOffset + (movesLeft ? -period : period)
    }

    func offset(atElapsed elapsed: TimeInterval) -> CGFloat {
        guard duration > 0 else { return startOffset }
        let progress = max(0, elapsed).truncatingRemainder(dividingBy: duration) / duration
        return startOffset + (endOffset - startOffset) * CGFloat(progress)
    }
}

/// Active elapsed time survives keyboard/layout changes and view detachment.
/// A repeated request to start is deliberately a no-op, so form edits cannot
/// reset an animation that is already running.
struct MobileWelcomeAnimationClock {
    private var accumulated: TimeInterval = 0
    private var startedAt: TimeInterval?

    var isRunning: Bool { startedAt != nil }

    mutating func setRunning(_ running: Bool, at now: TimeInterval) {
        if running {
            if startedAt == nil { startedAt = now }
        } else if let start = startedAt {
            accumulated += max(0, now - start)
            startedAt = nil
        }
    }

    func elapsed(at now: TimeInterval) -> TimeInterval {
        accumulated + (startedAt.map { max(0, now - $0) } ?? 0)
    }
}
