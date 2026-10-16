import Foundation

enum ExpandedSportsChannelMatcher {
    static func soccer(_ game: SportsGame) -> ProfessionalChannelMatcher.PreparedGame {
        func aliases(_ name: String, _ abbreviation: String) -> [String] {
            let normalized = ProfessionalChannelMatcher.normalize(name)
            let trim: Set<String> = ["fc", "afc", "cf", "sc", "ac", "fk"]
            var words = normalized.split(separator: " ").map(String.init)
            while let first = words.first, trim.contains(first) { words.removeFirst() }
            while let last = words.last, trim.contains(last) { words.removeLast() }
            let clean = words.joined(separator: " ")
            let special: [String: [String]] = [
                "manchester united": ["man utd", "man united"], "manchester city": ["man city"],
                "newcastle united": ["newcastle"], "tottenham hotspur": ["tottenham", "spurs"],
                "paris saint germain": ["psg"], "internazionale": ["inter milan"],
                "bayern munich": ["bayern munchen", "bayern"], "atletico madrid": ["atletico de madrid"],
                "united states": ["usa"], "south korea": ["korea republic"], "czechia": ["czech republic"]
            ]
            let unsafe: Set<String> = ["united", "city", "real", "sporting", "athletic", "national", "racing", "inter"]
            let code = ProfessionalChannelMatcher.normalize(abbreviation)
            return Array(Set(([normalized, clean, code.count >= 3 ? code : ""] + (special[clean] ?? []))
                .filter { !$0.isEmpty && !unsafe.contains($0) })).map(ProfessionalChannelMatcher.pad)
        }
        return .init(away: aliases(game.awayTeam, game.awayAbbreviation),
                     home: aliases(game.homeTeam, game.homeAbbreviation), start: game.start, isLive: game.isLive)
    }

    static func soccerScore(channel: ProfessionalChannelMatcher.PreparedChannel,
                            prepared: ProfessionalChannelMatcher.PreparedGame, game: SportsGame, now: Date) -> Int? {
        guard channel.eligible, !prepared.away.isEmpty, !prepared.home.isEmpty else { return nil }
        let shared = Set(prepared.away).intersection(prepared.home)
        let away = prepared.away.filter { !shared.contains($0) }, home = prepared.home.filter { !shared.contains($0) }
        func identifies(_ text: String) -> Bool {
            guard away.contains(where: text.contains), home.contains(where: text.contains) else { return false }
            if [" u17 ", " u19 ", " u20 ", " u21 ", " u23 ", " under 17 ", " under 19 ", " under 20 ", " under 21 ", " under 23 "]
                .contains(where: text.contains) { return false }
            // Identical national-team names need women's-competition evidence.
            let women = [" women ", " womens ", " wwc "].contains(where: text.contains)
            if game.competition?.id == "fifa.wwc" {
                return women
            }
            return game.competition?.id == "usa.nwsl" || !women
        }
        let point = game.isLive ? now : game.start
        let current = channel.listings.filter { $0.start <= point && point < $0.end }
        let confirms = current.contains {
            $0.start <= game.start.addingTimeInterval(1800) && $0.end > game.start
                && !archive($0.text, at: game.start) && identifies($0.text)
        }
        let generic: Set<String> = ["", "live", "soccer", "football", "live soccer", "live football", "mls", "nwsl",
            "premier league", "no program information", "no guide information", "tba"]
        let silent = current.allSatisfy { generic.contains($0.title) && $0.detail.isEmpty }
        if !archive(channel.padded, at: game.start), identifies(channel.padded) && (confirms || silent) { return 400 }
        return confirms ? 300 : nil
    }

    static func racingScore(channel: ProfessionalChannelMatcher.PreparedChannel, game: SportsGame, now: Date) -> Int? {
        guard channel.eligible, let race = game.race else { return nil }
        let name = ProfessionalChannelMatcher.normalize(game.eventName ?? "")
        let city = ProfessionalChannelMatcher.normalize(game.location?.components(separatedBy: ",").first ?? "")
        let circuit = ProfessionalChannelMatcher.normalize(race.circuit ?? "")
        var venues = [circuit, city].filter { $0.count >= 4 }
        // Names from the current event, never a broadcaster name or "GP" alone.
        for place in ["united states", "australian", "australia", "chinese", "china", "japanese", "japan", "miami",
                      "canadian", "canada", "monaco", "barcelona", "austrian", "austria", "british", "great britain",
                      "belgian", "belgium", "hungarian", "hungary", "dutch", "netherlands", "italian", "italy",
                      "madrid", "spanish", "azerbaijan", "bahrain", "singapore", "mexico", "brazil", "sao paulo",
                      "las vegas", "qatar", "abu dhabi", "saudi arabian", "saudi arabia"] {
            if ProfessionalChannelMatcher.pad(name).contains(ProfessionalChannelMatcher.pad(place)) { venues.append(place) }
        }
        if game.league == .nascar, let track = name.components(separatedBy: " at ").last, track != name {
            venues.append(track)
        }
        let venueAliases = Set(venues.map(ProfessionalChannelMatcher.pad))
        guard !venueAliases.isEmpty else { return nil }
        func identifies(_ text: String) -> Bool {
            let series = game.league == .f1
                ? [" f1 ", " formula 1 ", " formula one "].contains(where: text.contains)
                : text.contains(" nascar ") || text.contains(" cup series ")
            guard series, venueAliases.contains(where: text.contains), !archive(text, at: game.start) else { return false }
            if game.league == .nascar,
               [" xfinity ", " truck ", " trucks ", " arca ", " o reilly "].contains(where: text.contains) { return false }
            if [" pre race ", " prerace ", " countdown ", " post race ", " paddock ", " highlights "].contains(where: text.contains) { return false }
            let sprint = text.contains(" sprint ")
            let qualifying = text.contains(" qualifying ") || text.contains(" qualification ") || text.contains(" qual ")
            let practice = text.contains(" practice ") || [" fp1 ", " fp2 ", " fp3 "].contains(where: text.contains)
            switch race.title {
            case "Practice 1", "Practice 2", "Practice 3":
                let number = String(race.title.suffix(1))
                let word = ["1": "first", "2": "second", "3": "third"][number]!
                return !qualifying && !sprint && [" fp\(number) ", " practice \(number) ", " \(word) practice "].contains(where: text.contains)
            case "Qualifying": return qualifying && !sprint && !practice
            case "Sprint Qualifying": return sprint && qualifying && !practice
            case "Sprint": return sprint && !qualifying && !practice
            case "Race", "Cup Series Race": return !practice && !qualifying && !sprint
            default: return text.contains(ProfessionalChannelMatcher.pad(ProfessionalChannelMatcher.normalize(race.title)))
            }
        }
        let point = game.isLive ? now : game.start
        let current = channel.listings.filter { $0.start <= point && point < $0.end }
        let confirms = current.contains {
            $0.start <= game.start.addingTimeInterval(1800) && $0.end > game.start && identifies($0.text)
        }
        let generic: Set<String> = ["", "live", "f1", "formula 1", "formula one", "nascar", "motorsport", "motor racing", "no program information", "tba"]
        let silent = current.allSatisfy { generic.contains($0.title) && $0.detail.isEmpty }
        if identifies(channel.padded) && (confirms || silent) { return 400 }
        return confirms ? 300 : nil
    }

    private static func archive(_ text: String, at date: Date) -> Bool {
        if [" replay ", " classic ", " classics ", " highlights ", " preview ", " review ", " recap ", " documentary ", " encore "]
            .contains(where: text.contains) { return true }
        let year = Calendar.current.component(.year, from: date)
        return text.split(separator: " ").compactMap { Int($0) }.contains { (1968...2100).contains($0) && $0 != year }
    }
}
