import Foundation

/// Full team names and codes matter here: India, India A and India Women can
/// all play on the same day. A broadcaster name alone never selects a game.
enum CricketChannelMatcher {
    private static let squadSuffixes: [(String, String)] = [
        ("women s", "women"), ("women", "women"), ("womens", "women"), ("w", "women"),
        ("under 19s", "u19"), ("under 19", "u19"), ("u 19", "u19"), ("u19s", "u19"), ("u19", "u19"),
        ("under 23", "u23"), ("u 23", "u23"), ("u23", "u23"), ("emerging", "emerging"), ("a", "a")
    ]
    private static let countryCodes: [String: [String]] = [
        "new zealand": ["nz", "nzl"], "south africa": ["sa", "rsa"],
        "sri lanka": ["sl", "sri"], "west indies": ["wi", "win"],
        "india": ["ind"], "australia": ["aus"], "england": ["eng"],
        "pakistan": ["pak"], "bangladesh": ["ban", "bang"], "afghanistan": ["afg"],
        "ireland": ["ire"], "zimbabwe": ["zim"], "scotland": ["sco"],
        "netherlands": ["ned", "neth"], "united arab emirates": ["uae"]
    ]

    private struct Team {
        let squad: String
        let bases: [String]
        let aliases: [String]

        init(_ name: String, _ code: String) {
            let originalCode = ProfessionalChannelMatcher.normalize(code)
            func split(_ raw: String) -> (String, String) {
                let value = ProfessionalChannelMatcher.normalize(raw)
                for (suffix, squad) in squadSuffixes where value.hasSuffix(" " + suffix) {
                    return (String(value.dropLast(suffix.count + 1)), squad)
                }
                return (value, "")
            }
            let (name, nameSquad) = split(name)
            var (code, codeSquad) = split(code)
            if codeSquad.isEmpty, !nameSquad.isEmpty {
                let compact = squadSuffixes.filter { $0.1 == nameSquad && !$0.0.contains(" ") }.map(\.0)
                    + (nameSquad == "u19" ? ["19", "19s"] : [])
                if let suffix = compact.first(where: { code.hasSuffix($0) && code.count > $0.count + 1 }) {
                    code = String(code.dropLast(suffix.count))
                    codeSquad = nameSquad
                }
            }
            let squad = nameSquad.isEmpty ? codeSquad : nameSquad
            self.squad = squad
            // Explicit country codes, never fuzzy prefixes: India A must not
            // acquire India's senior alias. Domestic sides retain feed codes.
            let bases = Array(Set(([name, code] + (countryCodes[name] ?? [])).filter { $0.count >= 2 })).sorted()
            self.bases = bases
            let suffixes = squadSuffixes.filter { $0.1 == squad }.map(\.0)
            var values = bases.flatMap { base in
                squad.isEmpty ? [base] : suffixes.map { base + " " + $0 }
            }
            // Provider guide codes also commonly omit the hyphen in IND-A,
            // NZ-A or AS-W. Keep that spelling qualified as the same squad.
            if !squad.isEmpty, !code.isEmpty {
                values += suffixes.filter { !$0.contains(" ") }.map { code + $0 }
                if originalCode != code { values.append(originalCode) }
            }
            // Competition titles can supply Women/U19 instead of repeating
            // the qualifier on each side. Bare aliases require that context.
            if ["women", "u19", "u23", "emerging"].contains(squad) { values += bases }
            aliases = Array(Set(values)).sorted().map(ProfessionalChannelMatcher.pad)
        }

        func conflicts(_ text: String) -> Bool {
            for base in bases {
                for (suffix, kind) in squadSuffixes where kind != squad {
                    if text.contains(" " + base + " " + suffix + " ") { return true }
                }
            }
            return false
        }
    }

    private static func teams(_ game: SportsGame) -> [Team] {
        [Team(game.awayTeam, game.awayAbbreviation), Team(game.homeTeam, game.homeAbbreviation)]
    }

    private static func womensContext(_ text: String) -> Bool {
        [" women ", " womens ", " women s ", " wbbl ", " wpl "].contains(where: text.contains)
    }

    /// A provider can label a feed "Sheffield Shield 02" and its guide "NSW v
    /// TAS", without ever writing "Cricket". Find possible team evidence across
    /// the live catalog before the full scorer decides whether it is this game.
    /// Only guide slots covering a requested match point are normalized, once
    /// per shared guide ID. This does not rescan entire days for every match.
    static func candidates(in streams: [XtreamStream], programs: [String: [CurrentProgram]],
                           games: [SportsGame], now: Date, deadline: TimeInterval? = nil) throws -> [XtreamStream] {
        let games = games.filter { $0.league == .cricket && ($0.isLive || $0.isUpcoming) }
        let aliases = games.flatMap { game -> [String] in
            let prepared = prepare(game)
            return prepared.away + prepared.home
        }
        let words = Set(aliases.compactMap { $0.split(separator: " ").first.map(String.init) })
        guard !words.isEmpty else { return [] }
        let points = Set(games.map { $0.isLive ? now : $0.start })
        func hasTeamWord(_ value: String) -> Bool {
            ProfessionalChannelMatcher.normalize(value).split(separator: " ").contains { words.contains(String($0)) }
        }
        var guideEvidence: [String: Bool] = [:]
        var result: [XtreamStream] = []
        for stream in streams {
            try Task.checkCancellation()
            if let deadline, ProcessInfo.processInfo.systemUptime >= deadline { throw CancellationError() }
            guard !["radio", "radio_streams", "movie", "series", "episode", "video", "vod"]
                .contains(stream.streamType?.lowercased() ?? "") else { continue }
            if hasTeamWord(stream.name) { result.append(stream); continue }
            let key = stream.epgChannelID ?? ""
            if guideEvidence[key] == nil {
                var found = false
                for entry in programs[key] ?? [] {
                    try Task.checkCancellation()
                    guard points.contains(where: { entry.start <= $0 && $0 < entry.end }) else { continue }
                    if hasTeamWord(entry.title + " " + entry.detail) { found = true; break }
                }
                guideEvidence[key] = found
            }
            if guideEvidence[key] == true { result.append(stream) }
        }
        return result
    }

    static func prepare(_ game: SportsGame) -> ProfessionalChannelMatcher.PreparedGame {
        let sides = teams(game)
        return .init(away: sides[0].aliases, home: sides[1].aliases, start: game.start, isLive: game.isLive)
    }

    static func allowsContext(_ text: String, game: SportsGame) -> Bool {
        allowsContext(text, game: game, sides: teams(game))
    }

    private static func allowsContext(_ text: String, game: SportsGame, sides: [Team]) -> Bool {
        let format = game.cricket?.format.lowercased() ?? ""
        for (tag, kind) in [("test", "test"), ("t20", "t20"), ("odi", "odi")] {
            if !format.isEmpty && text.contains(" " + tag + " ") && format != kind { return false }
        }
        if womensContext(text) && !sides.allSatisfy({ $0.squad == "women" }) { return false }
        if sides.allSatisfy({ $0.squad == "women" }) {
            if [" men ", " mens ", " men s "].contains(where: text.contains) { return false }
            if [" bbl ", " ipl "].contains(where: text.contains), !womensContext(text) { return false }
        }
        for side in sides where side.conflicts(text) { return false }
        // A match number or a score of 19 is not an age category. Only
        // explicit U19/Under-19 wording can qualify the whole programme.
        for (tag, squad) in squadSuffixes where squad == "u19" || squad == "u23" || squad == "emerging" {
            if text.contains(" " + tag + " ") && !sides.allSatisfy({ $0.squad == squad }) { return false }
        }
        return true
    }

    static func score(channel: ProfessionalChannelMatcher.PreparedChannel,
                      prepared: ProfessionalChannelMatcher.PreparedGame, game: SportsGame, now: Date) -> Int? {
        let sides = teams(game)
        guard channel.eligible, allowsContext(channel.padded, game: game, sides: sides) else { return nil }
        func identifies(_ text: String) -> Bool {
            func side(_ aliases: [String], _ team: Team) -> Bool {
                return aliases.contains { alias in
                    guard text.contains(alias) else { return false }
                    if !team.squad.isEmpty, team.bases.contains(alias.trimmingCharacters(in: .whitespaces)) {
                        let context = text + channel.padded
                        if team.squad == "women" { return womensContext(context) }
                        return squadSuffixes.contains { tag, squad in
                            squad == team.squad && context.contains(" " + tag + " ")
                        }
                    }
                    return true
                }
            }
            return allowsContext(text, game: game, sides: sides) && side(prepared.away, sides[0]) && side(prepared.home, sides[1])
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
