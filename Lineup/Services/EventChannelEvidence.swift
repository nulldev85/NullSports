import Foundation

/// Additional precision for the event-only Channels list. These checks can
/// reject a candidate, but never establish that it carries the requested event.
enum EventChannelEvidence {
    struct Team: Sendable {
        let aliases: Set<String>

        init(name: String, abbreviation: String, nicknames: Bool) {
            let full = ProfessionalChannelMatcher.normalize(name)
            var names = [full]
            if nicknames {
                let words = full.split(separator: " ")
                if let last = words.last, last.count >= 4 { names.append(String(last)) }
                if words.count > 2 { names.append(words.suffix(2).joined(separator: " ")) }
                let code = ProfessionalChannelMatcher.normalize(abbreviation)
                if code.count >= 3 { names.append(code) }
            }
            aliases = Set(names.filter { !$0.isEmpty }.map(ProfessionalChannelMatcher.pad))
        }
    }

    private static let nonGame = ["replay", "classic", "classics", "highlights", "recap", "roundup",
        "round up", "preview", "review", "documentary", "encore", "pregame", "pre game", "postgame",
        "post game", "sportscenter", "sports center", "sports centre", "sports news", "studio", "countdown",
        "press conference", "magazine", "talk show"].map(ProfessionalChannelMatcher.pad)
    private static let unrelatedChannels = ["cnn", "msnbc", "cnbc", "bloomberg", "fox news", "sky news",
        "bbc news", "cartoon network", "disney junior", "nick jr", "animal planet"].map(ProfessionalChannelMatcher.pad)
    private static let unrelatedCategories = ["movies", "movie", "vod", "tv series", "kids", "children",
        "music", "radio", "audio", "news", "adult", "high school", "nfhs"].map(ProfessionalChannelMatcher.pad)
    private static let leagueLabels: [(String, Set<String>)] = [
        ("nba", ["nba"]), ("wnba", ["wnba"]), ("nfl", ["nfl"]), ("nhl", ["nhl"]), ("mlb", ["mlb"]),
        ("ncaaf", ["ncaaf"]), ("cfb", ["ncaaf"]), ("college football", ["ncaaf"]), ("ncaa football", ["ncaaf"]),
        ("ncaab", ["ncaab"]), ("college basketball", ["ncaab"]), ("ncaa basketball", ["ncaab"]),
        ("soccer", ["soccer"]),
        ("premier league", ["soccer"]), ("epl", ["soccer"]), ("la liga", ["soccer"]),
        ("bundesliga", ["soccer"]), ("serie a", ["soccer"]), ("mls", ["soccer"]), ("nwsl", ["soccer"]),
        ("f1", ["f1"]), ("formula 1", ["f1"]), ("formula one", ["f1"]), ("nascar", ["nascar"]),
        ("ufc", ["ufc"]), ("mma", ["ufc"]), ("atp", ["atp"]), ("wta", ["wta"])
    ]
    private static let sportLabels: [(String, Set<String>)] = [
        ("basketball", ["nba", "wnba", "ncaab"]), ("baseball", ["mlb"]), ("hockey", ["nhl"]),
        ("football", ["nfl", "ncaaf", "soccer"]), ("tennis", ["atp", "wta"]),
        ("softball", ["softball"]), ("volleyball", ["volleyball"]), ("lacrosse", ["lacrosse"])
    ]
    private static let placeholders: Set<String> = ["", "live", "tba", "to be announced", "no information",
        "no guide information", "no program information", "live sports", "sports"]
    private static let genericTitles: [String: Set<String>] = [
        "nba": ["nba", "basketball", "nba basketball", "nba preseason", "nba preseason basketball", "nba basketball preseason", "nba playoffs", "nba finals", "national basketball association"],
        "nfl": ["nfl", "football", "nfl football", "nfl preseason", "nfl playoffs", "super bowl", "national football league"],
        "ncaaf": ["ncaaf", "cfb", "football", "college football", "ncaa football", "ncaa college football"],
        "nhl": ["nhl", "hockey", "nhl hockey", "nhl preseason", "stanley cup playoffs", "national hockey league"],
        "mlb": ["mlb", "baseball", "mlb baseball", "mlb playoffs", "world series", "major league baseball"],
        "soccer": ["soccer", "football", "mls", "nwsl", "premier league", "la liga", "bundesliga", "serie a", "champions league", "uefa champions league", "uefa europa league", "uefa conference league", "fifa world cup"],
        "ufc": ["ufc", "mma", "ufc fight night", "pay per view", "ppv", "main card", "prelims", "early prelims"],
        "atp": ["tennis", "atp", "atp tennis", "atp tour tennis", "center court live", "centre court live"],
        "wta": ["tennis", "wta", "wta tennis", "wta tour tennis", "center court live", "centre court live"],
        "f1": ["f1", "formula 1", "formula one", "formula 1 racing", "motorsport", "motor racing", "auto racing"],
        "nascar": ["nascar", "nascar cup series", "cup series", "motorsport", "motor racing", "auto racing"]
    ]

    static func isGenericTitle(_ title: String, league: String) -> Bool {
        var value = ProfessionalChannelMatcher.normalize(title)
        if value.hasPrefix("live ") { value.removeFirst(5) }
        if value.hasSuffix(" live") { value.removeLast(5) }
        return placeholders.contains(value) || genericTitles[league, default: []].contains(value)
    }

    static func allowsProgram(title: String, detail: String, league: String, date: Date) -> Bool {
        let normalized = ProfessionalChannelMatcher.normalize(title)
        let padded = ProfessionalChannelMatcher.pad(normalized)
        guard !nonGame.contains(where: padded.contains), !historical(normalized, date: date) else { return false }
        if isGenericTitle(title, league: league) {
            let description = ProfessionalChannelMatcher.pad(ProfessionalChannelMatcher.normalize(detail))
            if nonGame.contains(where: description.contains) { return false }
        }
        return true
    }

    static func hasOtherTeam(in padded: String, participants: Set<String>, teams: [Team]) -> Bool {
        teams.contains { team in
            team.aliases.isDisjoint(with: participants) && team.aliases.contains(where: padded.contains)
        }
    }

    static func namesMatchup(_ name: String) -> Bool {
        let words = ProfessionalChannelMatcher.normalize(name).split(separator: " ").map(String.init)
        guard words.count >= 3 else { return false }
        for index in 1..<(words.count - 1) where ["vs", "versus", "v", "at"].contains(words[index]) {
            // AT&T SportsNet and Portugal's V Sports are broadcaster names.
            if words[index] == "at" && words[index + 1] == "t" { continue }
            if words[index] == "v" && words[index + 1] == "sports" { continue }
            return true
        }
        return false
    }

    static func allowsSoccerContext(_ context: String, women: Bool) -> Bool {
        let text = ProfessionalChannelMatcher.pad(ProfessionalChannelMatcher.normalize(context))
        if ["u17", "u19", "u20", "u21", "u23", "under 17", "under 19", "under 20", "under 21", "under 23"]
            .map(ProfessionalChannelMatcher.pad).contains(where: text.contains) { return false }
        let female = ["women", "womens", "wwc", "nwsl"].map(ProfessionalChannelMatcher.pad).contains(where: text.contains)
        let male = ["men", "mens"].map(ProfessionalChannelMatcher.pad).contains(where: text.contains)
        return women ? !male : !female
    }

    static func allowsRacingSession(_ channel: String, session: String) -> Bool {
        let text = ProfessionalChannelMatcher.pad(ProfessionalChannelMatcher.normalize(channel))
        let practiceNumbers = (1...3).filter { number in
            let word = ["first", "second", "third"][number - 1]
            return ["fp\(number)", "practice \(number)", "\(word) practice"].map(ProfessionalChannelMatcher.pad).contains(where: text.contains)
        }
        let practice = text.contains(" practice ") || !practiceNumbers.isEmpty
        let qualifying = ["qualifying", "qualification", "qual"].map(ProfessionalChannelMatcher.pad).contains(where: text.contains)
        let sprint = text.contains(" sprint ")
        let race = text.contains(" race ")
        switch session {
        case "Practice 1", "Practice 2", "Practice 3":
            let number = Int(session.suffix(1)) ?? 0
            return !qualifying && !sprint && !race && practiceNumbers.allSatisfy { $0 == number }
        case "Qualifying": return !practice && !sprint && !race
        case "Sprint Qualifying": return !practice && !race && sprint == qualifying
        case "Sprint": return !practice && !qualifying && !race
        case "Race", "Cup Series Race": return !practice && !qualifying && !sprint
        default: return true
        }
    }

    static func allowsSource(league: String, channel: String, category: String, date: Date,
                             participants: Set<String>, teams: [Team]) -> Bool {
        let name = ProfessionalChannelMatcher.normalize(channel)
        let padded = ProfessionalChannelMatcher.pad(name)
        let group = ProfessionalChannelMatcher.pad(ProfessionalChannelMatcher.normalize(category))
        guard !historical(name, date: date), !nonGame.contains(where: padded.contains),
              !unrelatedChannels.contains(where: padded.contains),
              !unrelatedCategories.contains(where: group.contains),
              !hasOtherTeam(in: padded, participants: participants, teams: teams) else { return false }
        // Check the most specific league labels first: "NBA basketball" must
        // not admit another basketball league merely because the sport agrees.
        for text in [padded, group] {
            let explicit = leagueLabels.filter { text.contains(ProfessionalChannelMatcher.pad($0.0)) }
            let found = explicit.isEmpty ? sportLabels.filter { text.contains(ProfessionalChannelMatcher.pad($0.0)) } : explicit
            if !found.isEmpty && !found.contains(where: { $0.1.contains(league) }) { return false }
        }
        return true
    }

    private static func historical(_ normalized: String, date: Date) -> Bool {
        let year = Calendar(identifier: .gregorian).component(.year, from: date)
        return normalized.split(separator: " ").compactMap { Int($0) }.contains { (1968...2100).contains($0) && $0 != year }
    }
}
