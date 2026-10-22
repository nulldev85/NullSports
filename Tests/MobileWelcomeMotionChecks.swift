import Foundation

@main
struct MobileWelcomeMotionChecks {
    static func main() {
        let viewportWidths: [CGFloat] = [320, 393, 430, 852, 1_366]
        for viewportWidth in viewportWidths {
            let step: CGFloat = 116
            let tileCount = max(12, Int(ceil(viewportWidth / step)) + 2)
            let stripPeriod = CGFloat(tileCount) * step
            for row in 0..<6 {
                let motion = MobileWelcomeRowMotion(rowIndex: row, rowCount: 6, period: stripPeriod)
                let travel = motion.endOffset - motion.startOffset
                precondition(abs(abs(travel) - stripPeriod) < 0.01)
                precondition(row.isMultiple(of: 2) ? travel < 0 : travel > 0)
                // Several complete loops, including their reset, rather than
                // only the first frame of a row that later runs out of content.
                for tick in 0...600 {
                    let elapsed = motion.duration * Double(tick) / 200
                    let offset = motion.offset(atElapsed: elapsed)
                    let end = offset + stripPeriod * CGFloat(MobileWelcomeRowMotion.copyCount) - 8
                    precondition(offset <= 0 && end >= viewportWidth,
                                 "Row \(row) must cover width \(viewportWidth) throughout every loop")
                }
                let change = motion.offset(atElapsed: 0.25) - motion.offset(atElapsed: 0)
                precondition(abs(abs(change) - 6) < 0.01, "Rows move at 24pt/s immediately")
            }
        }

        var clock = MobileWelcomeAnimationClock()
        precondition(clock.elapsed(at: 100) == 0)
        clock.setRunning(true, at: 100)
        clock.setRunning(true, at: 102) // repeated SwiftUI updates must not reset it
        precondition(clock.elapsed(at: 104) == 4)
        clock.setRunning(false, at: 104)
        precondition(clock.elapsed(at: 200) == 4)
        clock.setRunning(true, at: 200)
        precondition(clock.elapsed(at: 202) == 6)
        clock.setRunning(false, at: 202)
        clock.setRunning(false, at: 300)
        precondition(clock.elapsed(at: 400) == 6)
        print("Welcome rows cover three complete loops; the animation clock survives updates and pause/resume")
    }
}
