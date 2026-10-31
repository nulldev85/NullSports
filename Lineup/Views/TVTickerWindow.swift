import Foundation

/// The crawl renders a viewport, not two copies of the day's entire slate.
enum TVTickerWindow {
    static let cardWidth = 766.0
    static let spacing = 38.0
    static let loopSpacing = 72.0
    static let speed = 67.0

    static func indices(count: Int, start: Int, viewportWidth: Double) -> [Int] {
        guard count > 0 else { return [] }
        let width = viewportWidth.isFinite ? max(0, viewportWidth) : 0
        let capacity = max(2, Int(ceil(min(width, 16_384) / (cardWidth + spacing))) + 1)
        let first = ((start % count) + count) % count
        return (0..<capacity).map { (first + $0) % count }
    }

    static func stride(at index: Int, count: Int) -> Double {
        cardWidth + (index == count - 1 ? loopSpacing : spacing)
    }
}
