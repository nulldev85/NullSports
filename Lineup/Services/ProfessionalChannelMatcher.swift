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

    /// A channel's listings with the normalizing already done.
    ///
    /// Normalizing is folding, lowercasing, splitting on every non-alphanumeric
    /// and rejoining -- five allocations and a full pass over the text. It used
    /// to happen inside the score, which is asked once per candidate channel
    /// per game: sixty-six games against five and a half thousand channels is
    /// three hundred thousand times, renormalizing the same channel name and
    /// the same team names over and over.
    struct PreparedListing: Sendable {
        let title: String
        let detail: String
        let text: String
        let start: Date
        let end: Date
    }

    /// A game's team names worked out once, rather than once per candidate.
    struct PreparedGame: Sendable {
        let away: [String]
        let home: [String]
        let start: Date
        let isLive: Bool
    }

    static func normalize(_ text: String) -> String {
        text.folding(options: [.diacriticInsensitive, .widthInsensitive], locale: Locale(identifier: "en_US_POSIX"))
            .lowercased().components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }.joined(separator: " ")
    }

    static func prepare(_ listings: [Listing]) -> [PreparedListing] {
        listings.map { listing in
            let title = normalize(listing.title)
            let detail = normalize(listing.detail)
            return PreparedListing(
                title: title, detail: detail,
                text: [title, detail].filter { !$0.isEmpty }.joined(separator: " "),
                start: listing.start, end: listing.end)
        }
    }

    static func prepare(_ game: Matchup) -> PreparedGame {
        func aliases(_ name: String, _ abbreviation: String) -> [String] {
            let full = normalize(name)
            let nickname = full.split(separator: " ").last.map(String.init) ?? ""
            let lastTwo = full.split(separator: " ").suffix(2).joined(separator: " ")
            let short = normalize(abbreviation)
            return [full, lastTwo, nickname.count >= 4 ? nickname : "", short.count >= 2 ? short : ""].filter { !$0.isEmpty }
        }
        return PreparedGame(away: aliases(game.away, game.awayAbbreviation),
                            home: aliases(game.home, game.homeAbbreviation),
                            start: game.start, isLive: game.isLive)
    }

    /// Kept for callers scoring a single channel, where preparing costs nothing.
    static func score(channel: String, listings: [Listing], game: Matchup, now: Date) -> Int? {
        score(channel: normalize(channel), listings: prepare(listings), game: prepare(game), now: now)
    }

    static func score(channel: String, listings: [PreparedListing],
                      game: PreparedGame, now: Date) -> Int? {
        func contains(_ text: String, _ phrase: String) -> Bool {
            !phrase.isEmpty && (" " + text + " ").contains(" " + phrase + " ")
        }
        let away = game.away
        let home = game.home
        func matchup(_ text: String) -> Bool {
            away.contains { contains(text, $0) } && home.contains { contains(text, $0) }
        }
        func blocked(_ text: String) -> Bool {
            ["replay", "classic", "highlights", "radio", "audio", "preview"].contains { contains(text, $0) }
        }
        // Whip-around channels cut between games by design, so a guide entry
        // naming one game never describes what they are carrying minute to minute.
        func whipAround(_ text: String) -> Bool {
            ["red zone", "redzone", "strike zone", "big inning", "whip around", "mix"].contains { contains(text, $0) }
        }
        let name = channel
        guard !blocked(name), !whipAround(name), !away.isEmpty, !home.isEmpty else { return nil }
        let point = game.isLive ? now : game.start
        let current = listings.filter { $0.start <= point && point < $0.end }
        // Inspect each program independently: two unrelated listings cannot
        // combine into evidence for the requested matchup.
        let listingConfirms = current.contains { listing in
            listing.start <= game.start.addingTimeInterval(1800)
                && listing.end > game.start && !blocked(listing.text) && matchup(listing.text)
        }
        // A named event feed is usable without guide data, but never overrides
        // a current listing identifying different coverage.
        let generic: Set<String> = ["", "live", "tba", "to be announced", "no information", "no guide information",
            "no program information", "baseball", "mlb baseball", "basketball", "nba basketball",
            "football", "nfl football", "hockey", "nhl hockey"]
        let guideSilent = current.allSatisfy { generic.contains($0.title) && $0.detail.isEmpty }

        // A channel named for this matchup exists to carry this one game, so it
        // outranks a national channel whose guide merely schedules it: the
        // national feed can cut away to another game without the guide changing.
        if matchup(name) && (listingConfirms || guideSilent) { return 400 }
        return listingConfirms ? 300 : nil
    }
}
