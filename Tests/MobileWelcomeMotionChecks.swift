import Foundation

let stripPeriod: CGFloat = 1_856
let viewportWidth: CGFloat = 393
let rowCount = 6

for row in 0..<rowCount {
    let motion = MobileWelcomeRowMotion(rowIndex: row, rowCount: rowCount, period: stripPeriod)
    let duplicatedContentEnd = motion.startOffset + stripPeriod * 2
    precondition(motion.startOffset <= 0 && duplicatedContentEnd >= viewportWidth,
                 "Welcome row \(row) must cover the viewport with artwork on its first frame")
    let travel = motion.endOffset - motion.startOffset
    precondition(abs(abs(travel) - stripPeriod) < 0.01,
                 "Welcome row \(row) must travel exactly one repeated strip per loop")
    precondition(row.isMultiple(of: 2) ? travel < 0 : travel > 0,
                 "Welcome row \(row) must alternate direction, with the first row moving left")
}

print("Welcome poster rows start visible and alternate direction seamlessly")
