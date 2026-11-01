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
    /// Both sides must occur in the same name or current programme. First
    /// words such as "new" (New Zealand) and "as" (AS-W) otherwise admit most
    /// of an unrelated guide into the much larger prepared-listing cache.
    static func candidates(in streams: [XtreamStream], programs: [String: [CurrentProgram]],
                           games: [SportsGame], now: Date, deadline: TimeInterval? = nil) throws -> [XtreamStream] {
        let games = games.filter { $0.league == .cricket && ($0.isLive || $0.isUpcoming) }
        let targets = games.map { (sides: prepare($0), point: $0.isLive ? now : $0.start) }
        guard !targets.isEmpty else { return [] }
        func hasBothSides(_ text: String, _ sides: ProfessionalChannelMatcher.PreparedGame) -> Bool {
            sides.away.contains(where: text.contains) && sides.home.contains(where: text.contains)
        }
        // Dedicated cricket channels and cricket programmes are few; scoring
        // decides which game, if any, each one is showing.
        func cricket(_ text: String) -> Bool { dedicatedTags.contains(where: text.contains) }
        var guideEvidence: [String: Bool] = [:]
        var result: [XtreamStream] = []
        for stream in streams {
            try Task.checkCancellation()
            if let deadline, ProcessInfo.processInfo.systemUptime >= deadline { throw CancellationError() }
            guard !["radio", "radio_streams", "movie", "series", "episode", "video", "vod"]
                .contains(stream.streamType?.lowercased() ?? "") else { continue }
            let name = ProfessionalChannelMatcher.pad(ProfessionalChannelMatcher.normalize(stream.name))
            if cricket(name) || targets.contains(where: { hasBothSides(name, $0.sides) }) { result.append(stream); continue }
            let key = stream.epgChannelID ?? ""
            if guideEvidence[key] == nil {
                var found = false
                for entry in programs[key] ?? [] {
                    try Task.checkCancellation()
                    let relevant = targets.filter { entry.start <= $0.point && $0.point < entry.end }
                    guard !relevant.isEmpty else { continue }
                    let text = ProfessionalChannelMatcher.pad(ProfessionalChannelMatcher.normalize(entry.title + " " + entry.detail))
                    if cricket(text) || relevant.contains(where: { hasBothSides(text, $0.sides) }) { found = true; break }
                }
                guideEvidence[key] = found
            }
            if guideEvidence[key] == true { result.append(stream) }
        }
        return result
    }

    /// Words that make a channel, or a programme, cricket coverage.
    private static let dedicatedTags = [" cricket ", " willow "]

    /// "India v Pakistan" names a matchup; "Live Cricket" does not.
    private static func namesMatchup(_ text: String) -> Bool {
        [" v ", " vs ", " versus "].contains(where: text.contains)
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
        func side(_ text: String, _ aliases: [String], _ team: Team) -> Bool {
            aliases.contains { alias in
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
        func identifies(_ text: String) -> Bool {
            allowsContext(text, game: game, sides: sides) && side(text, prepared.away, sides[0]) && side(text, prepared.home, sides[1])
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
        if confirms { return 300 }
        // Providers' guides seldom name both sides. On a cricket channel, or
        // under a cricket programme, accept a current slot that names one of
        // this game's sides, or only the sport or this game's competition,
        // as long as it names no other matchup. Weaker than a named match.
        guard !archive(channel.padded) else { return nil }
        let dedicated = dedicatedTags.contains(where: channel.padded.contains)
        let competitions = [game.competition?.name, game.competition?.shortName].compactMap { $0 }
            .map { ProfessionalChannelMatcher.pad(ProfessionalChannelMatcher.normalize($0)) }
            .filter { $0.count > 4 }
        let usable = current.filter { !archive($0.text) && allowsContext($0.text, game: game, sides: sides) && !namesMatchup($0.text) }
        guard usable.count == current.count else { return nil }
        let oneSide = usable.contains { entry in
            (dedicated || dedicatedTags.contains(where: entry.text.contains))
                && (side(entry.text, prepared.away, sides[0]) || side(entry.text, prepared.home, sides[1]))
        }
        if oneSide { return 250 }
        guard dedicated else { return nil }
        let general = usable.allSatisfy { entry in
            EventChannelEvidence.isGenericTitle(entry.title, league: "cricket")
                || dedicatedTags.contains(where: entry.text.contains)
                || competitions.contains(where: entry.text.contains)
        }
        return general ? 150 : nil
    }
}
