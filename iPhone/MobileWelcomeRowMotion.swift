import Foundation

/// Offsets for the duplicated poster strip used by the first-run backdrop.
/// Every row starts with artwork already crossing the viewport, then moves a
/// single strip length so the duplicate makes the loop seamless.
struct MobileWelcomeRowMotion {
    let startOffset: CGFloat
    let endOffset: CGFloat

    init(rowIndex: Int, rowCount: Int, period: CGFloat) {
        guard rowCount > 0, period > 0 else {
            startOffset = 0
            endOffset = 0
            return
        }

        let index = ((rowIndex % rowCount) + rowCount) % rowCount
        let phase = period * CGFloat(index) / CGFloat(rowCount)
        let movesLeft = index.isMultiple(of: 2)
        // The track contains two copies laid out left-to-right. A left-moving
        // row starts on the first copy; a right-moving row must start on the
        // second copy so that it never runs out of posters at the right edge.
        startOffset = movesLeft ? -phase : -period - phase
        endOffset = startOffset + (movesLeft ? -period : period)
    }
}
