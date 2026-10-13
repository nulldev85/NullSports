import SwiftUI

/// One player's line of a tennis scoreboard: the games of each set, in
/// columns that line up with the opponent's line below.
///
/// A set the player took is in full white, one they lost in grey, and the
/// set being played in white too, since it is still anyone's. A tiebreak is
/// raised beside the set it settled, against the side that lost it, the way
/// a scoreboard prints 7-6⁵.
struct TennisSetColumns: View {
    let score: TennisScore
    /// The first player's line, or the second's.
    let isAway: Bool
    let size: CGFloat
    var primary: Color = LineupStyle.text
    var secondary: Color = LineupStyle.secondary

    var body: some View {
        HStack(spacing: size * 0.42) {
            ForEach(Array(score.sets.enumerated()), id: \.offset) { entry in
                column(entry.element)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(spoken)
    }

    private func column(_ set: TennisScore.SetGames) -> some View {
        let games = isAway ? set.away : set.home
        let won = set.awayWon.map { $0 == isAway }
        let tiebreak: Int? = won == false ? (isAway ? set.awayTiebreak : set.homeTiebreak) : nil
        let weight: Font.Weight = won == nil ? .heavy : (won == true ? .bold : .medium)
        return Text(verbatim: "\(games)")
            .font(.interDigits(size, weight))
            .foregroundStyle(won == false ? secondary : primary)
            .frame(minWidth: size * 0.62)
            .overlay(alignment: .topTrailing) {
                if let tiebreak {
                    Text(verbatim: "\(tiebreak)")
                        .font(.interDigits((size * 0.5).rounded(), .semibold))
                        .foregroundStyle(secondary)
                        .fixedSize()
                        .offset(x: size * 0.42, y: -size * 0.12)
                }
            }
    }

    private var spoken: String {
        score.sets.map { "\(isAway ? $0.away : $0.home)" }.joined(separator: ", ")
    }
}
