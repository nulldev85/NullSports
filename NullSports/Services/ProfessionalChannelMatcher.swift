import Foundation

// A network or a mention elsewhere in the day's guide is not game evidence.
enum ProfessionalChannelMatcher {
    struct Listing: Sendable {
        let title: String
        let detail: String
        let start: Date
        let end: Date
    }

    struct Matchup: Sendable {
        let away: String
        let home: String
        let awayAbbreviation: String
        let homeAbbreviation: String
        let start: Date
        let isLive: Bool
    }

    static func score(channel: String, listings: [Listing], game: Matchup, now: Date) -> Int? {
        func normalized(_ text: String) -> String {
            text.folding(options: [.diacriticInsensitive, .widthInsensitive], locale: Locale(identifier: "en_US_POSIX"))
                .lowercased().components(separatedBy: CharacterSet.alphanumerics.inverted)
                .filter { !$0.isEmpty }.joined(separator: " ")
        }
        func contains(_ text: String, _ phrase: String) -> Bool {
            !phrase.isEmpty && (" " + text + " ").contains(" " + phrase + " ")
        }
        func aliases(_ name: String, _ abbreviation: String) -> [String] {
            let full = normalized(name)
            let nickname = full.split(separator: " ").last.map(String.init) ?? ""
            let lastTwo = full.split(separator: " ").suffix(2).joined(separator: " ")
            let short = normalized(abbreviation)
            return [full, lastTwo, nickname.count >= 4 ? nickname : "", short.count >= 2 ? short : ""].filter { !$0.isEmpty }
        }
        let away = aliases(game.away, game.awayAbbreviation)
        let home = aliases(game.home, game.homeAbbreviation)
        func matchup(_ text: String) -> Bool {
            away.contains { contains(text, $0) } && home.contains { contains(text, $0) }
        }
        func blocked(_ text: String) -> Bool {
            ["replay", "classic", "highlights", "radio", "audio", "preview"].contains { contains(text, $0) }
        }
        let name = normalized(channel)
        guard !blocked(name), !away.isEmpty, !home.isEmpty else { return nil }
        let point = game.isLive ? now : game.start
        let current = listings.filter { $0.start <= point && point < $0.end }
        // Inspect each program independently: two unrelated listings cannot
        // combine into evidence for the requested matchup.
        if current.contains(where: { listing in
            let text = normalized(listing.title + " " + listing.detail)
            return listing.start <= game.start.addingTimeInterval(1800)
                && listing.end > game.start && !blocked(text) && matchup(text)
        }) { return 300 }

        // A named event feed is usable without guide data, but never overrides
        // a current listing identifying different coverage.
        let generic: Set<String> = ["", "live", "tba", "to be announced", "no information", "no guide information",
            "no program information", "baseball", "mlb baseball", "basketball", "nba basketball",
            "football", "nfl football", "hockey", "nhl hockey"]
        guard current.allSatisfy({ generic.contains(normalized($0.title)) && normalized($0.detail).isEmpty }),
              matchup(name) else { return nil }
        return 200
    }
}
