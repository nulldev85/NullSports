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
        let isDelayed: Bool
        let expectedNetworks: Set<String>
        let awayAliases: [String]
        let homeAliases: [String]

        init(broadcast: String, away: String, home: String, awayAbbreviation: String,
             homeAbbreviation: String, kickoff: Date, isLive: Bool, status: String = "") {
            self.broadcast = broadcast
            self.away = away
            self.home = home
            self.awayAbbreviation = awayAbbreviation
            self.homeAbbreviation = homeAbbreviation
            self.kickoff = kickoff
            self.isLive = isLive
            let normalizedStatus = CollegeChannelMatcher.normalized(status)
            isDelayed = ["delay", "delayed", "suspended", "suspension", "power outage"].contains {
                CollegeChannelMatcher.contains(normalizedStatus, phrase: $0)
            } && !["postponed", "canceled", "cancelled", "final"].contains {
                CollegeChannelMatcher.contains(normalizedStatus, phrase: $0)
            }
            expectedNetworks = CollegeChannelMatcher.networks(broadcast)
            awayAliases = CollegeChannelMatcher.teamAliases(away, abbreviation: awayAbbreviation)
            homeAliases = CollegeChannelMatcher.teamAliases(home, abbreviation: homeAbbreviation)
        }
    }

    static func allowsNetworkFallback(for game: Matchup, slate: [Matchup]) -> Bool {
        let expected = game.expectedNetworks
        return !slate.contains { other in
            guard other.away != game.away || other.home != game.home || other.kickoff != game.kickoff else { return false }
            let overlaps = ((game.isLive || game.isDelayed) && (other.isLive || other.isDelayed))
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
        // Delayed games can remain pregame or live. The guide still follows its
        // original clock; an explicit delay keeps same-day game evidence usable.
        let delayActive = game.isDelayed && game.kickoff <= now
            && now.timeIntervalSince(game.kickoff) < 12 * 60 * 60
        if game.isDelayed && now.timeIntervalSince(game.kickoff) >= 12 * 60 * 60 { return nil }
        func teams(_ text: String) -> Bool {
            titleMatches(text, awayNames: game.awayAliases, homeNames: game.homeAliases)
        }
        let point = (game.isLive || delayActive) ? now : game.kickoff
        let current = listings.filter { $0.start <= point && point < $0.end }
        if delayActive && current.contains(where: { listing in
            !teams(listing.text) && ["vs", "versus", "at"].contains(where: { contains(listing.text, phrase: $0) })
        }) { return nil }
        let relevant = listings.filter {
            $0.end > $0.start && $0.start <= game.kickoff.addingTimeInterval(1800)
                && $0.end > game.kickoff
                && (!(game.isLive || delayActive) || ($0.start <= now &&
                    (now < $0.end.addingTimeInterval(90 * 60) || (delayActive && networkMatch))))
        }
        if relevant.contains(where: {
            let text = $0.text
            return !nonGameMarkers.contains(where: { contains(text, phrase: $0) }) && teams(text)
        }) { return networkMatch ? 400 : 300 }

        // Generic or absent listings are common. An explicit different program
        // must not be overridden by the channel's event name or network label.
        let generic: Set<String> = ["", "college football", "ncaa football", "ncaaf", "cfb", "football", "live", "no information", "no program information", "to be announced", "tba"]
        let genericGuide = current.allSatisfy({
            let detail = normalized($0.detail)
            return generic.contains(normalized($0.title)) &&
                !["vs", "versus", "at", "replay", "highlights", "basketball"].contains(where: { contains(detail, phrase: $0) })
        })
        // Only known interruption/studio coverage may stand in for a delayed
        // game. Another named game still requires manual selection.
        let delayCoverage = delayActive && current.allSatisfy {
            let title = normalized($0.title)
            let placeholder = ["sportscenter", "game delay", "weather delay", "rain delay", "power outage", "coverage will resume"].contains {
                contains(title, phrase: $0)
            }
            return (generic.contains(title) || placeholder)
                && !["vs", "versus", "at", "replay", "classic"].contains(where: { contains(title, phrase: $0) })
        }
        // A guide title we cannot fully parse must not veto the advertised network.
        // One confirmed school is decisive because a team plays one game at a time,
        // and the exact advertised network keeps an unrelated feed from qualifying.
        let partialGuide = networkMatch && !current.isEmpty && current.allSatisfy { listing in
            let text = listing.text
            guard !nonGameMarkers.contains(where: { contains(text, phrase: $0) }) else { return false }
            return sideMatches(text, names: game.awayAliases) != sideMatches(text, names: game.homeAliases)
        }
        guard genericGuide || delayCoverage || partialGuide else { return nil }

        // A specifically named event feed can work without XMLTV metadata.
        if genericGuide && teams(name) { return networkMatch ? 250 : 200 }

        // One identified school outranks a blind network match but never a feed
        // that names the matchup outright.
        if partialGuide { return 150 }

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

    // Programming that is about a game without being the game itself, or that is
    // plainly another sport. Shared by the evidence and partial-evidence checks.
    static let nonGameMarkers: [String] = ["replay", "classic", "highlights", "sportscenter", "gameday", "preview", "basketball", "baseball", "soccer", "volleyball", "softball", "lacrosse", "hockey", "tennis"]

    static let mascots: [String] = ["crimson tide", "fighting irish", "yellow jackets", "golden bears", "golden gophers", "red raiders", "blue devils", "tar heels", "nittany lions", "sun devils", "horned frogs", "demon deacons", "fighting illini", "mountaineers", "seminoles", "mustangs", "cougars", "huskies", "bulldogs", "tigers", "wildcats", "cardinals", "owls", "longhorns", "sooners", "buckeyes", "wolverines", "ducks", "beavers", "gators", "volunteers", "razorbacks", "rebels", "aggies", "spartans", "trojans", "bruins", "badgers", "hawkeyes", "cyclones", "jayhawks", "cowboys", "bears", "buffaloes", "utes", "hoosiers", "boilermakers", "terrapins", "scarlet knights", "panthers", "eagles", "hokies", "cavaliers", "orange", "wolfpack", "commodores", "gamecocks", "hurricanes", "knights", "golden knights", "black knights", "midshipmen", "green wave", "golden eagles", "golden flashes", "golden hurricane", "thundering herd", "mean green", "blue raiders", "red wolves", "redhawks", "red hawks", "bobcats", "rockets", "falcons", "zips", "bulls", "broncos", "chippewas", "minutemen", "monarchs", "flames", "hilltoppers", "bearkats", "bearcats", "roadrunners", "miners", "lobos", "wolf pack", "aztecs", "rainbow warriors", "warriors", "rams", "ragin cajuns", "warhawks", "jaguars", "chanticleers", "dukes", "pirates", "blazers", "49ers", "leopards", "bison", "jackrabbits"].sorted { $0.count > $1.count }

    // Tokens that carry school identity. Trimming one turns a school into a
    // different school: Ohio State into Ohio, New Mexico into New.
    static let identityTokens: Set<String> = ["state", "st", "tech", "a", "m", "am", "oh", "ohio", "fl", "florida", "southern", "northern", "eastern", "western", "central", "north", "south", "east", "west", "new", "atlantic", "international", "christian", "college", "university", "poly", "valley", "sam", "saint", "holy", "old", "bay", "carolina", "dakota", "michigan", "illinois", "kentucky"]
    // A school name that is only a direction or qualifier cannot stand alone;
    // "southern" appears inside Southern Miss, Georgia Southern and USC alike.
    static let genericSchools: Set<String> = ["southern", "northern", "eastern", "western", "central", "north", "south", "east", "west", "new", "state", "saint", "holy", "old", "big", "the"]
    // First word of a two-word mascot: Blue Hens, Big Red, Golden Lions.
    static let mascotModifiers: Set<String> = ["blue", "big", "black", "red", "golden", "fighting", "green", "mountain", "runnin", "rainbow", "scarlet", "crimson", "thundering", "demon", "horned", "nittany", "sun", "tar", "yellow", "wolf", "ragin", "delta", "white", "purple", "flying", "screaming", "mean", "war", "great", "sea", "night", "fightin"]
    static let synonyms: [[String]] = [
        ["smu", "southern methodist"], ["florida state", "fsu"],
        ["ole miss", "mississippi"], ["uconn", "connecticut"],
        ["umass", "massachusetts"], ["ucf", "central florida"],
        ["usf", "south florida"], ["lsu", "louisiana state"],
        ["tcu", "texas christian"], ["byu", "brigham young"],
        ["utsa", "texas san antonio"], ["utep", "texas el paso"],
        ["miami oh", "miami ohio"], ["miami", "miami fl", "miami florida"],
        ["southern miss", "southern mississippi"], ["pitt", "pittsburgh"],
        ["app state", "appalachian state"], ["hawai i", "hawaii"]]
    // A following token that continues a longer school name, or a preceding token
    // that starts one: Florida is not Florida State, Virginia is not West Virginia.
    static let trailingQualifiers: [String] = ["state", "st", "tech", "a m", "atlantic", "international", "oh", "ohio", "southern", "valley", "monroe", "peay", "pine", "christian", "poly", "dominion", "cross", "brook", "force", "wesleyan", "central", "illinois", "utah", "carolina", "methodist", "miss", "mississippi", "houston", "jaguars"]
    static let leadingQualifiers: [String] = ["west", "east", "north", "south", "western", "eastern", "northern", "southern", "central", "southeastern", "northeastern", "southwestern", "northwestern", "middle", "sam", "prairie", "abilene", "stephen", "f", "houston", "texas", "charleston", "gardner", "holy", "saint", "old"]

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
        // A mascot list can never cover every program, and an unknown mascot used
        // to leave the school name unrecoverable, which rejected the one channel
        // carrying the game. Trim a known mascot when there is one, then also offer
        // the name minus a one- or two-word trailing mascot, never trimming a token
        // that carries school identity.
        let suffix = mascots.first { full.hasSuffix(" " + $0) }
        let school = suffix.map { String(full.dropLast($0.count + 1)) } ?? full
        var result: Set<String> = [full]
        func offer(_ name: String) {
            guard !name.isEmpty, !genericSchools.contains(name),
                  !synonyms.contains(where: { $0.contains(name) && !$0.contains(school) }) else { return }
            result.insert(name)
        }
        offer(school)
        let tokens = full.split(separator: " ").map(String.init)
        if tokens.count > 1, let last = tokens.last, !identityTokens.contains(last) {
            offer(tokens.dropLast().joined(separator: " "))
            let modifier = tokens[tokens.count - 2]
            if tokens.count > 2, mascotModifiers.contains(modifier), !identityTokens.contains(modifier) {
                offer(tokens.dropLast(2).joined(separator: " "))
            }
        }
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

    // The first occurrence of `phrase` that names the school itself rather than
    // part of a longer school name. Later occurrences still count, so "Washington"
    // is found in "Washington State at Washington".
    private static func schoolRange(_ padded: String, phrase: String) -> Range<String.Index>? {
        let needle = " " + phrase + " "
        var searchStart = padded.startIndex
        while let range = padded.range(of: needle, range: searchStart..<padded.endIndex) {
            let following = String(padded[range.upperBound...])
            let preceding = String(padded[..<range.lowerBound])
            if !trailingQualifiers.contains(where: { following == $0 || following.hasPrefix($0 + " ") })
                && !leadingQualifiers.contains(where: { preceding.hasSuffix(" " + $0) }) {
                return range
            }
            searchStart = padded.index(after: range.lowerBound)
        }
        return nil
    }

    // One side of a matchup, for guide text that names a school we can identify
    // alongside one we cannot. Callers supply normalized text.
    static func sideMatches(_ text: String, names: [String]) -> Bool {
        let padded = " " + text + " "
        return names.contains { schoolRange(padded, phrase: $0) != nil }
    }

    private static func titleMatches(_ title: String, awayNames: [String], homeNames: [String]) -> Bool {
        let text = title // Callers supply normalized channel/guide text.
        guard sideMatches(text, names: awayNames), sideMatches(text, names: homeNames) else { return false }
        // Consume the longer occurrence first so Washington State cannot also
        // supply Washington, and no shared mascot can establish a match.
        for first in awayNames {
            for second in homeNames where first != second {
                let ordered = [first, second].sorted { $0.count > $1.count }
                var remaining = " " + text + " "
                var matched = true
                for phrase in ordered {
                    guard let range = schoolRange(remaining, phrase: phrase) else { matched = false; break }
                    remaining.replaceSubrange(range, with: " ")
                }
                if matched { return true }
            }
        }
        return false
    }

}
