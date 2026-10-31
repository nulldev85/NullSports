import Foundation

/// Full team names and codes matter here: India, India A and India Women can
/// all play on the same day. A broadcaster name alone never selects a game.
enum CricketChannelMatcher {
    private static let qualifiers = ["a", "women", "womens", "w", "u19", "u19s", "u 19", "under 19", "under 19s", "19", "19s", "u23", "under 23", "emerging"]
    static func prepare(_ game: SportsGame) -> ProfessionalChannelMatcher.PreparedGame {
        func aliases(_ name: String, _ code: String) -> [String] {
            Array(Set([name, code].map(ProfessionalChannelMatcher.normalize).filter { $0.count >= 2 }))
                .map(ProfessionalChannelMatcher.pad)
        }
        return .init(away: aliases(game.awayTeam, game.awayAbbreviation),
                     home: aliases(game.homeTeam, game.homeAbbreviation), start: game.start, isLive: game.isLive)
    }

    static func allowsContext(_ text: String, game: SportsGame) -> Bool {
        let format = game.cricket?.format.lowercased() ?? ""
        for (tag, kind) in [("test", "test"), ("t20", "t20"), ("odi", "odi")] {
            if !format.isEmpty && text.contains(" " + tag + " ") && format != kind { return false }
        }
        let expected = ProfessionalChannelMatcher.pad(ProfessionalChannelMatcher.normalize(game.awayTeam + " " + game.homeTeam))
        let women = [" women ", " womens "].contains(where: expected.contains)
        if [" women ", " womens "].contains(where: text.contains) && !women { return false }
        let aliases = prepare(game)
        for alias in aliases.away + aliases.home {
            if qualifiers.contains(where: { text.contains(alias + $0 + " ") }) { return false }
        }
        return true
    }

    static func score(channel: ProfessionalChannelMatcher.PreparedChannel,
                      prepared: ProfessionalChannelMatcher.PreparedGame, game: SportsGame, now: Date) -> Int? {
        guard channel.eligible, allowsContext(channel.padded, game: game) else { return nil }
        let expected = ProfessionalChannelMatcher.pad(ProfessionalChannelMatcher.normalize(game.awayTeam + " " + game.homeTeam))
        func identifies(_ text: String) -> Bool {
            let women = [" women ", " womens "].contains(where: expected.contains)
            if [" women ", " womens "].contains(where: text.contains) && !women { return false }
            for tag in qualifiers where !["a", "w", "women", "womens"].contains(tag) {
                let token = ProfessionalChannelMatcher.pad(tag)
                if text.contains(token) && !expected.contains(token) { return false }
            }
            func side(_ aliases: [String]) -> Bool {
                aliases.contains { alias in
                    guard text.contains(alias) else { return false }
                    // "India" inside "India A" is a different side. Codes
                    // such as IND-A and ST-W normalize to the same suffixes.
                    return !qualifiers.contains { tag in text.contains(alias + tag + " ") }
                }
            }
            return allowsContext(text, game: game) && side(prepared.away) && side(prepared.home)
        }
        func archive(_ text: String) -> Bool {
            [" replay ", " highlights ", " classic ", " recap ", " preview ", " review ", " pre match ", " post match "]
                .contains(where: text.contains)
        }
        let point = game.isLive ? now : game.start
        let current = channel.listings.filter { $0.start <= point && point < $0.end }
        // A later day's Test listing starts days after the match's original
        // date. Its current slot and exact sides establish today's coverage.
        let confirms = current.contains { !archive($0.text) && identifies($0.text) }
        let silent = current.allSatisfy {
            EventChannelEvidence.isGenericTitle($0.title, league: "cricket") && $0.detail.isEmpty
        }
        if !archive(channel.padded), identifies(channel.padded), confirms || silent { return 400 }
        return confirms ? 300 : nil
    }
}
