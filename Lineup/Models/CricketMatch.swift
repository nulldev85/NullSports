import Foundation

/// A Test keeps its original start across several days of play.
struct CricketMatch: Codable, Hashable, Sendable {
    let end: Date
    let format: String

    static func runs(_ score: String) -> String {
        score.components(separatedBy: " (").first ?? score
    }

    static func overs(_ score: String) -> String? {
        guard let opening = score.firstIndex(of: "("), let closing = score.lastIndex(of: ")"),
              opening < closing else { return nil }
        return String(score[score.index(after: opening)..<closing])
    }
}
