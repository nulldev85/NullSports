import SwiftUI

/// Keep runs/wickets legible; overs and targets belong on their own line.
struct CricketScoreView: View {
    let score: String
    let size: CGFloat

    var body: some View {
        VStack(alignment: .trailing, spacing: 2) {
            Text(score.isEmpty ? "—" : CricketMatch.runs(score))
                .font(.interDigits(size, .bold)).lineLimit(1).minimumScaleFactor(0.6)
            if let overs = CricketMatch.overs(score) {
                Text(overs).font(.interDigits(max(10, size * 0.45), .medium))
                    .lineLimit(1).minimumScaleFactor(0.6).opacity(0.7)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(score.isEmpty ? "Yet to bat" : score)
    }
}
