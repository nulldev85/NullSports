import Foundation

@main
struct MobileWelcomeMotionChecks {
    static func main() {
        let stripPeriod: CGFloat = 1_856
        let viewportWidth: CGFloat = 393
        let copyCount = 3
        let gapBetweenCopies: CGFloat = 8
        let rowCount = 6

        for row in 0..<rowCount {
            let motion = MobileWelcomeRowMotion(rowIndex: row, rowCount: rowCount, period: stripPeriod)
            let travel = motion.endOffset - motion.startOffset
            precondition(abs(abs(travel) - stripPeriod) < 0.01,
                         "Welcome row \(row) must travel exactly one repeated strip per loop")
            precondition(row.isMultiple(of: 2) ? travel < 0 : travel > 0,
                         "Welcome row \(row) must alternate direction, with the first row moving left")

            for offset in [motion.startOffset, motion.endOffset] {
                let duplicatedContentEnd = offset + stripPeriod * CGFloat(copyCount) - gapBetweenCopies
                precondition(offset <= 0 && duplicatedContentEnd >= viewportWidth,
                             "Welcome row \(row) must cover the viewport at both ends of its loop")
            }
        }

        print("Welcome poster rows start visible and alternate direction seamlessly")
    }
}
