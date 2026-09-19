import XCTest
@testable import LineupiOS

/// Matching was made much faster by preparing a channel's text once instead of
/// six times. Faster is only worth having if it decides the same things, so
/// these are about the answers, not the speed.
final class LeagueMatchingTests: XCTestCase {
    /// The old path: lowercase the text, split it on non-alphanumerics, and
    /// ask each league. Written out here so the new one can be held against it.
    private func legacyMatches(_ league: SportsLeague, _ text: String) -> Bool {
        let value = text.lowercased()
        let words = Set(value.components(separatedBy: CharacterSet.alphanumerics.inverted))
        switch league {
        case .ncaaf:
            return words.contains("ncaaf")
                || ["college football", "ncaa football", "cfb", "sec network", "acc network",
                    "big ten", "big 12", "pac-12"].contains { value.contains($0) }
                || !words.isDisjoint(with: ["espn", "espn2", "espnu", "abc", "fox", "fs1", "fs2",
                                            "cbs", "cbssn", "nbc", "btn", "cw"])
        case .ufc:
            return ["ufc", "ultimate fighting", "fight night", "mma", "pay per view",
                    "pay-per-view", "ppv", "prelims", "early prelims", "contender series",
                    "road to ufc", "fight pass"].contains { value.contains($0) }
        case .nfl:
            return words.contains("nfl") || ["49ers", "bears", "bengals", "bills", "broncos", "browns", "buccaneers", "cardinals", "chargers", "chiefs", "colts", "commanders", "cowboys", "dolphins", "eagles", "falcons", "giants", "jaguars", "jets", "lions", "packers", "panthers", "patriots", "raiders", "rams", "ravens", "saints", "seahawks", "steelers", "texans", "titans", "vikings"].contains { value.contains($0) }
        case .nba:
            return words.contains("nba") || ["76ers", "bucks", "bulls", "cavaliers", "celtics", "clippers", "grizzlies", "hawks", "heat", "hornets", "jazz", "kings", "knicks", "lakers", "magic", "mavericks", "nets", "nuggets", "pacers", "pelicans", "pistons", "raptors", "rockets", "spurs", "suns", "thunder", "timberwolves", "trail blazers", "warriors", "wizards"].contains { value.contains($0) }
        case .nhl:
            return words.contains("nhl") || ["avalanche", "blackhawks", "blue jackets", "blues", "bruins", "canadiens", "canucks", "capitals", "devils", "ducks", "flames", "flyers", "golden knights", "hurricanes", "islanders", "jets", "kings", "kraken", "lightning", "maple leafs", "mammoth", "oilers", "panthers", "penguins", "predators", "rangers", "red wings", "sabres", "senators", "sharks", "stars"].contains { value.contains($0) }
        case .mlb:
            return words.contains("mlb") || ["angels", "astros", "athletics", "blue jays", "braves", "brewers", "cardinals", "cubs", "diamondbacks", "dodgers", "giants", "guardians", "mariners", "marlins", "mets", "nationals", "orioles", "padres", "phillies", "pirates", "rangers", "rays", "red sox", "reds", "rockies", "royals", "tigers", "twins", "white sox", "yankees"].contains { value.contains($0) }
        }
    }

    /// Channel names in the shapes providers actually use, plus the listing
    /// text that gets appended to them.
    private let samples = [
        "US| NFL NETWORK HD",
        "us| espn 2 fhd sportscenter college football week 4",
        "USA - NBA TV",
        "uk: sky sports main event — ufc 320 prelims",
        "CA| SPORTSNET ONE hd  toronto blue jays at boston red sox",
        "us| mlb network",
        "US| NHL NETWORK FHD maple leafs vs golden knights",
        "vip - nba: lakers vs warriors",
        "radio | siriusxm nfl radio",
        "us| cbs sports network ncaaf big 12 saturday",
        "24/7 | trail blazers classics",
        "us| fox sports 1 fhd",
        "nothing sporting here at all",
        "",
        "us| espnu",
        "us| tnt hd  white sox at guardians",
        "beIN SPORTS — road to ufc",
        "US| ABC EAST hd"
    ]

    func testEveryLeagueDecidesExactlyWhatItUsedTo() {
        for sample in samples {
            let prepared = SportsMatchText(alreadyLowercased: sample.lowercased())
            for league in SportsLeague.allCases {
                XCTAssertEqual(league.matches(prepared), legacyMatches(league, sample),
                               "\(league.rawValue) disagreed about \"\(sample)\"")
            }
        }
    }

    // The string entry point has to keep working for callers that have not
    // prepared anything, and has to agree with the prepared one.
    func testThePlainStringEntryPointStillLowercases() {
        for sample in samples {
            let prepared = SportsMatchText(alreadyLowercased: sample.lowercased())
            for league in SportsLeague.allCases {
                XCTAssertEqual(league.matches(sample), league.matches(prepared),
                               "\(league.rawValue) disagreed about \"\(sample)\"")
            }
        }
        // Mixed case in, same answer out.
        XCTAssertTrue(SportsLeague.nfl.matches("US| NFL NETWORK"))
        XCTAssertTrue(SportsLeague.nhl.matches("Maple Leafs At Bruins"))
    }

    // A league token is a word, not a substring: that was true before and has
    // to stay true, or "nflx" and "wnba" start matching.
    func testALeagueTokenIsAWholeWord() {
        XCTAssertFalse(SportsLeague.nfl.matches("us| nflx movies hd"))
        XCTAssertTrue(SportsLeague.nfl.matches("us| nfl network hd"))
        XCTAssertTrue(SportsLeague.nfl.matches("us|nfl-network"), "Separators still split words")
    }
}

/// A channel's own words and the listings it points at are asked about
/// separately now, rather than glued into one string per stream. These check
/// that splitting them decides the same things.
final class SplitMatchTextTests: XCTestCase {
    private func asksSeparately(_ league: SportsLeague, name: String, listings: String) -> Bool {
        let base = SportsMatchText(alreadyLowercased: name.lowercased())
        let text = SportsMatchText(alreadyLowercased: listings.lowercased())
        return league.matches(base) || league.matches(text)
    }

    private func asksJoined(_ league: SportsLeague, name: String, listings: String) -> Bool {
        league.matches(SportsMatchText(alreadyLowercased: "\(name) \(listings)".lowercased()))
    }

    private let cases: [(name: String, listings: String)] = [
        ("us| espn hd", "college football alabama at auburn  nfl live  sportscenter"),
        ("us| regional sports network", "toronto blue jays at boston red sox pregame"),
        ("CA| SN1 FHD", "maple leafs vs golden knights  post game"),
        ("us| generic entertainment", "reruns and movies all day"),
        ("us| nba tv", ""),
        ("", "ufc 320 prelims early prelims"),
        ("us| fs1", "nascar cup series"),
        ("us| tnt", "white sox at guardians")
    ]

    func testAskingTheTwoHalvesSeparatelyAgreesWithAskingTheJoin() {
        for sample in cases {
            for league in SportsLeague.allCases {
                XCTAssertEqual(asksSeparately(league, name: sample.name, listings: sample.listings),
                               asksJoined(league, name: sample.name, listings: sample.listings),
                               "\(league.rawValue) disagreed about \"\(sample.name)\" + listings")
            }
        }
    }

    // A channel with no listings is matched on its name alone, which is what
    // happens for every stream whose EPG id the guide does not carry.
    func testAChannelWithNoListingsIsStillMatchedOnItsName() {
        let base = SportsMatchText(alreadyLowercased: "us| nfl network hd")
        XCTAssertTrue(SportsLeague.nfl.matches(base))
        XCTAssertFalse(SportsLeague.mlb.matches(base))
    }

    // Listings carry a match the name never could: a generic regional channel
    // showing a game is exactly the case the guide text exists for.
    func testListingsCanCarryAMatchTheNameCannot() {
        let base = SportsMatchText(alreadyLowercased: "us| regional sports 4")
        let listings = SportsMatchText(alreadyLowercased: "dodgers at padres  first pitch")
        XCTAssertFalse(SportsLeague.mlb.matches(base))
        XCTAssertTrue(SportsLeague.mlb.matches(listings))
    }
}
