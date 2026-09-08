import Foundation

// Pure matching policy, shared with the standalone regression checks.
enum CollegeChannelMatcher {
    struct Listing: Sendable {
        let title: String
        let detail: String
        let start: Date
        let end: Date
        let text: String

        init(title: String, detail: String, start: Date, end: Date) {
            self.title = title
            self.detail = detail
            self.start = start
            self.end = end
            text = CollegeChannelMatcher.normalized(title + " " + detail)
        }
    }

    struct Matchup: Sendable {
        let broadcast: String
        let away: String
        let home: String
        let awayAbbreviation: String
        let homeAbbreviation: String
        let kickoff: Date
        let isLive: Bool
        let expectedNetworks: Set<String>
        let awayAliases: [String]
        let homeAliases: [String]

        init(broadcast: String, away: String, home: String, awayAbbreviation: String,
             homeAbbreviation: String, kickoff: Date, isLive: Bool) {
            self.broadcast = broadcast
            self.away = away
            self.home = home
            self.awayAbbreviation = awayAbbreviation
            self.homeAbbreviation = homeAbbreviation
            self.kickoff = kickoff
            self.isLive = isLive
            expectedNetworks = CollegeChannelMatcher.networks(broadcast)
            awayAliases = CollegeChannelMatcher.teamAliases(away, abbreviation: awayAbbreviation)
            homeAliases = CollegeChannelMatcher.teamAliases(home, abbreviation: homeAbbreviation)
        }
    }

    static func allowsNetworkFallback(for game: Matchup, slate: [Matchup]) -> Bool {
        let expected = game.expectedNetworks
        return !slate.contains { other in
            guard other.away != game.away || other.home != game.home || other.kickoff != game.kickoff else { return false }
            let overlaps = (game.isLive && other.isLive)
                || abs(other.kickoff.timeIntervalSince(game.kickoff)) < 3 * 60 * 60
            return overlaps && !other.expectedNetworks.isDisjoint(with: expected)
        }
    }

    struct Candidate: Sendable {
        let id: Int
        let name: String
        let listings: [Listing]
        let normalizedName: String
        let networkIDs: Set<String>

        init(id: Int, name: String, listings: [Listing]) {
            self.id = id
            self.name = name
            self.listings = listings
            normalizedName = CollegeChannelMatcher.normalized(name)
            networkIDs = CollegeChannelMatcher.networks(name)
        }
    }

    // Evidence outranks provider ordering. Multiple valid feeds are alternatives,
    // even when the provider gives each quality or affiliate a different EPG ID.
    static func select(_ candidates: [Candidate], game: Matchup, now: Date, allowNetworkFallback: Bool = true) -> Int? {
        candidates.compactMap { candidate -> (id: Int, score: Int)? in
            score(candidate: candidate, game: game, now: now, allowNetworkFallback: allowNetworkFallback)
                .map { (candidate.id, $0) }
        }.sorted { $0.score == $1.score ? $0.id < $1.id : $0.score > $1.score }.first?.id
    }

    static func score(channel: String, listings: [Listing], game: Matchup, now: Date, allowNetworkFallback: Bool = true) -> Int? {
        score(candidate: Candidate(id: 0, name: channel, listings: listings), game: game, now: now, allowNetworkFallback: allowNetworkFallback)
    }

    private static func score(candidate: Candidate, game: Matchup, now: Date, allowNetworkFallback: Bool) -> Int? {
        let name = candidate.normalizedName
        let listings = candidate.listings
        let blocked = ["radio", "audio", "sirius", "podcast", "music", "nfhs", "news", "business", "high school", "basketball", "baseball", "soccer", "volleyball", "softball", "lacrosse", "hockey", "tennis", "replay", "classic"]
        guard !blocked.contains(where: { contains(name, phrase: $0) }) else { return nil }
        let expected = game.expectedNetworks
        let actual = candidate.networkIDs
        let networkMatch = actual.count == 1 && actual.isSubset(of: expected)
        if !actual.isEmpty && !expected.isEmpty && !networkMatch { return nil }
        func teams(_ text: String) -> Bool {
            titleMatches(text, awayNames: game.awayAliases, homeNames: game.homeAliases)
        }
        let relevant = listings.filter {
            $0.end > $0.start && $0.start <= game.kickoff.addingTimeInterval(1800)
                && $0.end > game.kickoff
                && (!game.isLive || ($0.start <= now && now < $0.end.addingTimeInterval(90 * 60)))
        }
        if relevant.contains(where: {
            let text = $0.text
            return !["replay", "classic", "highlights", "sportscenter", "gameday", "preview", "basketball", "baseball", "soccer", "volleyball", "softball", "lacrosse", "hockey", "tennis"].contains(where: { contains(text, phrase: $0) })
                && teams(text)
        }) { return networkMatch ? 400 : 300 }

        let point = game.isLive ? now : game.kickoff
        let current = listings.filter { $0.start <= point && point < $0.end }
        // Generic or absent listings are common. An explicit different program
        // must not be overridden by the channel's event name or network label.
        let generic: Set<String> = ["", "college football", "ncaa football", "ncaaf", "cfb", "football", "live", "no information", "no program information", "to be announced", "tba"]
        guard current.allSatisfy({
            let detail = normalized($0.detail)
            return generic.contains(normalized($0.title)) &&
                !["vs", "versus", "at", "replay", "highlights", "basketball"].contains(where: { contains(detail, phrase: $0) })
        }) else { return nil }

        // A specifically named event feed can work without XMLTV metadata.
        if teams(name) { return networkMatch ? 250 : 200 }

        // Only linear national sports networks are safe without team evidence.
        // Affiliates, regional feeds and multiplex services still need a matchup.
        let national: Set<String> = ["espn", "espn2", "espnu", "fs1", "fs2", "cbssn", "accn", "secn"]
        guard allowNetworkFallback, networkMatch, actual.isSubset(of: national),
              !["uk", "au", "australia", "ca", "can", "canada", "caribbean", "deportes", "extra", "alternate", "alt", "ncaa", "ncaaf", "cfb", "vs", "versus", "at", "event"].contains(where: { contains(name, phrase: $0) }),
              !candidate.name.contains("@") else { return nil }
        // Numbered event slots (ESPN 01, SEC Network 3, etc.) are not the
        // main linear channel. Only ESPN 2 / Fox Sports 1 / Fox Sports 2 use digits.
        let networkName = name.replacingOccurrences(of: "espn 2", with: "espn2")
            .replacingOccurrences(of: "fox sports 1", with: "fs1")
            .replacingOccurrences(of: "fox sports 2", with: "fs2")
        guard !networkName.split(separator: " ").contains(where: { Int($0) != nil }) else { return nil }
        return current.isEmpty ? 100 : 120
    }

    static func normalized(_ value: String) -> String {
        value.folding(options: [.diacriticInsensitive, .widthInsensitive], locale: Locale(identifier: "en_US_POSIX"))
            .lowercased().replacingOccurrences(of: "+", with: " plus ")
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }.joined(separator: " ")
    }

    static func contains(_ text: String, phrase: String) -> Bool {
        (" " + text + " ").contains(" " + phrase + " ")
    }

    static func networks(_ value: String) -> Set<String> {
        let text = normalized(value).replacingOccurrences(
            of: "\\b(espn2|espnu|espn|fs1|fs2|cbssn|accn|secn)(uhd|fhd|hd|sd)\\b",
            with: "$1", options: .regularExpression)
        guard !contains(text, phrase: "news"), !contains(text, phrase: "business") else { return [] }
        let aliases: [(String, [String])] = [
            ("espnplus", ["espn plus", "espnplus"]), ("espnnews", ["espnews", "espn news"]),
            ("espn2", ["espn2", "espn 2"]),
            ("espnu", ["espnu", "espn u"]), ("espn", ["espn"]),
            ("fs1", ["fs1", "fox sports 1"]), ("fs2", ["fs2", "fox sports 2"]),
            ("fox", ["fox"]), ("cbssn", ["cbssn", "cbs sports network"]),
            ("cbs", ["cbs"]), ("nbc", ["nbc"]), ("abc", ["abc"]),
            ("btn", ["btn", "big ten network"]), ("accplus", ["acc network extra", "accnx", "accn plus"]),
            ("accn", ["accn", "acc network"]), ("secplus", ["sec network plus", "secn plus"]),
            ("secn", ["secn", "sec network"]), ("cw", ["cw"]),
            ("peacock", ["peacock"])
        ]
        // Consume specific names first so ESPN2/ESPN+ cannot also become ESPN.
        var remaining = " " + text + " "
        var result: Set<String> = []
        for (network, names) in aliases {
            for name in names where remaining.contains(" " + name + " ") {
                result.insert(network)
                remaining = remaining.replacingOccurrences(of: " " + name + " ", with: " ")
            }
        }
        return result
    }

    static func teamAliases(_ team: String, abbreviation: String) -> [String] {
        let full = normalized(team)
        // Strip known mascot suffixes, never arbitrary words from school names.
        let mascots = ["crimson tide", "fighting irish", "yellow jackets", "golden bears", "golden gophers", "red raiders", "blue devils", "tar heels", "nittany lions", "sun devils", "horned frogs", "demon deacons", "fighting illini", "mountaineers", "seminoles", "mustangs", "cougars", "huskies", "bulldogs", "tigers", "wildcats", "cardinals", "owls", "longhorns", "sooners", "buckeyes", "wolverines", "ducks", "beavers", "gators", "volunteers", "razorbacks", "rebels", "aggies", "spartans", "trojans", "bruins", "badgers", "hawkeyes", "cyclones", "jayhawks", "cowboys", "bears", "buffaloes", "utes", "hoosiers", "boilermakers", "terrapins", "scarlet knights", "panthers", "eagles", "hokies", "cavaliers", "orange", "wolfpack", "commodores", "gamecocks"]
        let additionalMascots = ["hurricanes", "knights", "golden knights", "black knights", "midshipmen", "green wave", "golden eagles", "golden flashes", "golden hurricane", "thundering herd", "mean green", "blue raiders", "red wolves", "redhawks", "red hawks", "bobcats", "rockets", "falcons", "zips", "bulls", "broncos", "chippewas", "minutemen", "monarchs", "flames", "hilltoppers", "bearkats", "bearcats", "roadrunners", "miners", "lobos", "wolf pack", "aztecs", "rainbow warriors", "warriors", "rams", "ragin cajuns", "warhawks", "jaguars", "chanticleers", "dukes", "pirates", "blazers", "49ers", "owls", "leopards", "bison", "jackrabbits"]
        let suffix = (mascots + additionalMascots).sorted { $0.count > $1.count }.first { full.hasSuffix(" " + $0) }
        let school = suffix.map { String(full.dropLast($0.count + 1)) } ?? full
        let synonyms = [["smu", "southern methodist"], ["florida state", "fsu"],
                        ["ole miss", "mississippi"], ["uconn", "connecticut"],
                        ["umass", "massachusetts"], ["ucf", "central florida"],
                        ["usf", "south florida"], ["lsu", "louisiana state"],
                        ["tcu", "texas christian"], ["byu", "brigham young"],
                        ["utsa", "texas san antonio"], ["utep", "texas el paso"],
                        ["miami oh", "miami ohio"], ["miami", "miami fl", "miami florida"],
                        ["southern miss", "southern mississippi"], ["pitt", "pittsburgh"],
                        ["app state", "appalachian state"], ["hawai i", "hawaii"]]
        var result: Set<String> = [full, school]
        for group in synonyms where group.contains(school) { result.formUnion(group) }
        for name in Array(result) {
            if name.contains(" state") { result.insert(name.replacingOccurrences(of: " state", with: " st")) }
            if name.contains(" a m") { result.insert(name.replacingOccurrences(of: " a m", with: " am")) }
        }
        let short = normalized(abbreviation)
        if short.count >= 2 { result.insert(short) }
        return result.filter { !$0.isEmpty }.sorted { $0.count > $1.count }
    }

    static func titleMatches(_ title: String, away: String, home: String,
                             awayAbbreviation: String = "", homeAbbreviation: String = "") -> Bool {
        let text = normalized(title)
        let awayNames = teamAliases(away, abbreviation: awayAbbreviation)
        let homeNames = teamAliases(home, abbreviation: homeAbbreviation)
        return titleMatches(text, awayNames: awayNames, homeNames: homeNames)
    }

    private static func titleMatches(_ title: String, awayNames: [String], homeNames: [String]) -> Bool {
        let text = title // Callers supply normalized channel/guide text.
        guard awayNames.contains(where: { contains(text, phrase: $0) }),
              homeNames.contains(where: { contains(text, phrase: $0) }) else { return false }
        // Consume the longer occurrence first so Washington State cannot also
        // supply Washington, and no shared mascot can establish a match.
        for first in awayNames {
            for second in homeNames where first != second {
                let ordered = [first, second].sorted { $0.count > $1.count }
                var remaining = " " + text + " "
                var matched = true
                for phrase in ordered {
                    guard let range = remaining.range(of: " " + phrase + " ") else { matched = false; break }
                    let following = String(remaining[range.upperBound...])
                    let preceding = String(remaining[..<range.lowerBound])
                    // Florida is not Florida State; Virginia is not Virginia Tech.
                    if ["state", "st", "tech", "a m", "atlantic", "international", "oh", "ohio"].contains(where: { following == $0 || following.hasPrefix($0 + " ") })
                        || ["west", "east", "north", "south", "western", "eastern", "northern", "southern", "central"].contains(where: { preceding.hasSuffix(" " + $0) }) {
                        matched = false
                        break
                    }
                    remaining.replaceSubrange(range, with: " ")
                }
                if matched { return true }
            }
        }
        return false
    }

}
