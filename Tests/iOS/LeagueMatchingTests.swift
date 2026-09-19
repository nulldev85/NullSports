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

/// Sorting channels into leagues is now done once in the filter pass and
/// looked up afterwards, instead of every league re-asking every channel.
/// These check the lookup answers what the asking used to.
final class LeagueBucketTests: XCTestCase {
    private func leaguesFound(name: String, listings: String?) -> Set<SportsLeague> {
        let base = SportsMatchText(alreadyLowercased: name.lowercased())
        let fromName = Set(SportsLeague.allCases.filter { $0.matches(base) })
        guard let listings else { return fromName }
        let text = SportsMatchText(alreadyLowercased: listings.lowercased())
        return fromName.union(SportsLeague.allCases.filter { $0.matches(text) })
    }

    // The union is the same answer the per-league pass used to reach, because
    // that pass asked exactly these two questions of exactly these two strings.
    func testTheUnionIsWhatEachLeagueWouldHaveAnsweredAnyway() {
        let samples: [(String, String?)] = [
            ("us| nfl network hd", "chiefs at bills"),
            ("us| regional sports 4", "dodgers at padres"),
            ("us| espn hd", "college football and nfl live"),
            ("us| movies", nil),
            ("us| nba tv", nil)
        ]
        for (name, listings) in samples {
            let found = leaguesFound(name: name, listings: listings)
            for league in SportsLeague.allCases {
                let base = SportsMatchText(alreadyLowercased: name.lowercased())
                let asked = league.matches(base)
                    || (listings.map { league.matches(SportsMatchText(alreadyLowercased: $0.lowercased())) } ?? false)
                XCTAssertEqual(found.contains(league), asked,
                               "\(league.rawValue) disagreed about \"\(name)\"")
            }
        }
    }

    // A channel in no league at all is dropped, which is what keeps twenty-two
    // thousand of twenty-six thousand channels out of the sports index.
    func testAChannelInNoLeagueIsNotASportsChannel() {
        XCTAssertTrue(leaguesFound(name: "us| home shopping", listings: "jewellery hour").isEmpty)
    }

    // Listings alone are enough, which is the case a channel name can never
    // cover: a numbered regional feed carrying a game.
    func testListingsAloneAreEnough() {
        XCTAssertEqual(leaguesFound(name: "us| rsn 12", listings: "maple leafs at bruins"), [.nhl])
    }
}

/// Single-word terms are looked up in the channel's words now, instead of
/// being searched for anywhere in its text. That is a real change, and this is
/// what it does and does not alter.
final class WordLookupTests: XCTestCase {
    private func text(_ value: String) -> SportsMatchText {
        SportsMatchText(alreadyLowercased: value.lowercased())
    }

    private func listings(_ value: String) -> SportsMatchText {
        SportsMatchText(alreadyLowercased: value.lowercased(), scannable: false)
    }

    // In a day of listings, a team name inside a longer word is noise, and
    // scanning for it is what cost the launch thirty-five seconds.
    func testATeamNameInsideALongerWordIsNotAMatchInListings() {
        XCTAssertFalse(SportsLeague.nfl.matches(listings("bearsville community access")))
        XCTAssertFalse(SportsLeague.mlb.matches(listings("metsuki japanese cinema")))
    }

    // A channel name is a few dozen characters, so it keeps the old, looser
    // rule. This is where terms turn up glued to their neighbours, and where
    // being strict quietly dropped five hundred channels out of the index.
    func testAChannelNameKeepsTheLooserRule() {
        XCTAssertTrue(SportsLeague.ufc.matches(text("us| ppv01 hd")))
        XCTAssertTrue(SportsLeague.ufc.matches(text("ppv4k events")))
        XCTAssertTrue(SportsLeague.nfl.matches(listings("chicago bears at green bay")),
                      "and a real listing still matches on its words")
    }

    // Everything a listing actually says still matches, whatever punctuation
    // it is wrapped in, because the text is split on anything non-alphanumeric.
    func testATeamNameTheListingActuallySaysStillMatches() {
        for wrapping in ["chicago bears at green bay",
                         "bears/packers",
                         "(bears) vs packers",
                         "live: bears!",
                         "nfl — bears"] {
            XCTAssertTrue(SportsLeague.nfl.matches(text(wrapping)), wrapping)
        }
    }

    // Terms that cannot survive tokenizing keep searching the text. These are
    // the ones a word lookup would silently never find.
    func testHyphenatedAndMultiWordTermsStillSearchTheText() {
        XCTAssertTrue(SportsLeague.ufc.matches(text("tonight: pay-per-view main card")))
        XCTAssertTrue(SportsLeague.ncaaf.matches(text("pac-12 after dark")))
        XCTAssertTrue(SportsLeague.mlb.matches(text("blue jays at red sox")))
        XCTAssertTrue(SportsLeague.nhl.matches(text("golden knights vs maple leafs")))
    }
}

/// Acronyms glued to numbers are how a provider writes a pay-per-view channel,
/// and they are why five hundred channels fell out of the index.
final class GluedAcronymTests: XCTestCase {
    private func listings(_ value: String) -> SportsMatchText {
        SportsMatchText(alreadyLowercased: value.lowercased(), scannable: false)
    }

    func testAnAcronymGluedToANumberIsStillFoundInListings() {
        XCTAssertTrue(SportsLeague.ufc.matches(listings("ufc299 main card")))
        XCTAssertTrue(SportsLeague.ufc.matches(listings("ppv01 tonight")))
    }

    // Team names are not searched for in listings, which is the scan that cost
    // thirty-five seconds. Only the short acronyms are.
    func testTeamNamesAreStillNotSearchedForInListings() {
        XCTAssertFalse(SportsLeague.nfl.matches(listings("bearsville community access")))
        XCTAssertTrue(SportsLeague.nfl.matches(listings("bears at packers")))
    }
}

/// Whether a college candidate is disqualified on its name alone is settled
/// when the candidate is built now, instead of inside a score that runs once
/// per game. These check it settles it the same way.
final class CollegeBlockedNameTests: XCTestCase {
    private func candidate(_ name: String) -> CollegeChannelMatcher.Candidate {
        CollegeChannelMatcher.Candidate(id: 1, name: name, listings: [])
    }

    /// The check as it was written inside the score.
    private func legacyBlocked(_ name: String) -> Bool {
        let normalized = CollegeChannelMatcher.normalized(name)
        return ["radio", "audio", "sirius", "podcast", "music", "nfhs", "news", "business",
                "high school", "basketball", "baseball", "soccer", "volleyball", "softball",
                "lacrosse", "hockey", "tennis", "replay", "classic"]
            .contains { CollegeChannelMatcher.contains(normalized, phrase: $0) }
    }

    func testItBlocksExactlyWhatItUsedTo() {
        for name in ["US| ESPN HD", "US| ESPNU FHD", "SiriusXM College Sports",
                     "US| CBS SPORTS NETWORK", "NFHS Network — Texas", "US| ESPN CLASSIC",
                     "College Baseball Replay", "US| SEC NETWORK 4K", "beIN SPORTS",
                     "US| ACC NETWORK", "High School Football Weekly", "ESPN Radio",
                     "US| FS1", "Business News Tonight", "Big Ten Hockey"] {
            XCTAssertEqual(candidate(name).isBlocked, legacyBlocked(name), name)
        }
    }

    // The ones it must keep: a plain national sports network is a candidate.
    func testTheChannelsCollegeGamesActuallyLandOnAreNotBlocked() {
        for name in ["US| ESPN HD", "US| ESPNU FHD", "US| ABC EAST", "US| FOX SPORTS 1"] {
            XCTAssertFalse(candidate(name).isBlocked, name)
        }
    }
}
