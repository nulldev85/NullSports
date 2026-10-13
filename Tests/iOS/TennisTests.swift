import XCTest
@testable import LineupiOS

/// Tennis from ESPN's scoreboard to a card: which matches are kept, how the
/// score reads, when one is on, and when a channel is carrying it.
final class TennisTests: XCTestCase {
    // The scoreboard's own shape, trimmed: one tournament, its draws, and the
    // kinds of match a day of it holds.
    private let feed = """
    {"events": [{
      "id": "713-2026", "name": "Rolex Shanghai Masters",
      "groupings": [
        {"grouping": {"slug": "mens-singles"}, "competitions": [
          {"id": "1001", "date": "2026-10-13T08:00Z", "timeValid": true,
           "type": {"slug": "mens-singles"}, "round": {"displayName": "Quarterfinal"},
           "venue": {"court": "Stadium Court"}, "format": {"regulation": {"periods": 3}},
           "status": {"type": {"state": "in", "description": "In Progress", "shortDetail": "3rd"}},
           "broadcasts": [{"names": ["Tennis Channel"]}, {"names": ["Tennis Channel"]}],
           "competitors": [
             {"order": 2, "curatedRank": {"current": 4}, "linescores": [{"value": 4, "winner": false}, {"value": 7, "tiebreak": 7, "winner": true}, {"value": 5}],
              "athlete": {"displayName": "Alex de Minaur", "shortName": "A. de Minaur", "flag": {"href": "https://flags/aus.png", "alt": "Australia"}}},
             {"order": 1, "curatedRank": {"current": 1}, "linescores": [{"value": 6, "winner": true}, {"value": 6, "tiebreak": 5, "winner": false}, {"value": 3}],
              "athlete": {"displayName": "Jannik Sinner", "shortName": "J. Sinner", "flag": {"href": "https://flags/ita.png", "alt": "Italy"}}}
           ]},
          {"id": "1002", "date": "2026-10-13T11:00Z", "timeValid": true,
           "type": {"slug": "mens-singles"}, "round": {"displayName": "Quarterfinal"},
           "status": {"type": {"state": "pre", "shortDetail": "10/13 - 7:00 AM EDT"}},
           "competitors": [
             {"order": 1, "athlete": {"displayName": "Carlos Alcaraz", "shortName": "C. Alcaraz"}},
             {"order": 2, "athlete": {"displayName": "Taylor Fritz", "shortName": "T. Fritz"}}
           ]},
          {"id": "1003", "date": "2026-10-12T09:00Z", "timeValid": true,
           "type": {"slug": "mens-singles"}, "round": {"displayName": "Round of 16"},
           "status": {"type": {"state": "post", "shortDetail": "Final"}},
           "competitors": [
             {"order": 1, "linescores": [{"value": 6, "winner": true}, {"value": 6, "winner": true}], "athlete": {"displayName": "Holger Rune"}},
             {"order": 2, "linescores": [{"value": 2, "winner": false}, {"value": 3, "winner": false}], "athlete": {"displayName": "Ben Shelton"}}
           ]},
          {"id": "1004", "date": "2026-10-15T04:00Z", "timeValid": false,
           "type": {"slug": "mens-singles"}, "round": {"displayName": "Semifinal"},
           "status": {"type": {"state": "pre", "shortDetail": "TBD"}},
           "competitors": [
             {"order": 1, "athlete": {"displayName": "TBD"}}, {"order": 2, "athlete": {"displayName": "TBD"}}
           ]},
          {"id": "1005", "date": "2026-10-13T06:00Z", "timeValid": true,
           "type": {"slug": "mens-singles"}, "round": {"displayName": "Qualifying Final"},
           "status": {"type": {"state": "pre"}},
           "competitors": [
             {"order": 1, "athlete": {"displayName": "Qualifier One"}}, {"order": 2, "athlete": {"displayName": "Qualifier Two"}}
           ]},
          {"id": "1006", "date": "2026-10-13T12:00Z", "timeValid": false,
           "type": {"slug": "mens-singles"}, "round": {"displayName": "Quarterfinal"},
           "status": {"type": {"state": "pre", "shortDetail": "TBD"}},
           "competitors": [
             {"order": 1, "athlete": {"displayName": "Casper Ruud"}}, {"order": 2, "athlete": {"displayName": "Tommy Paul"}}
           ]},
          {"id": "broken"}
        ]},
        {"grouping": {"slug": "mens-doubles"}, "competitions": [
          {"id": "2001", "date": "2026-10-13T09:00Z", "timeValid": true,
           "type": {"slug": "mens-doubles"}, "round": {"displayName": "Quarterfinal"},
           "status": {"type": {"state": "in"}},
           "competitors": [
             {"order": 1, "roster": {"displayName": "A / B"}}, {"order": 2, "roster": {"displayName": "C / D"}}
           ]}
        ]}
      ]
    }]}
    """

    private var day: Date { ISO8601DateFormatter().date(from: "2026-10-13T00:00:00Z")! }

    private func matches() throws -> [SportsGame] {
        let envelope = try JSONDecoder().decode(TennisEnvelope.self, from: Data(feed.utf8))
        return envelope.events.flatMap {
            SportsScheduleClient.tennisMatches(in: $0, tour: .atp, from: day,
                                               to: day.addingTimeInterval(86_400))
        }
    }

    func testOnlyMainDrawSinglesWithRealPlayersAndTimesAreKept() throws {
        let ids = Set(try matches().map(\.id))
        XCTAssertEqual(ids, ["tennis-1001", "tennis-1002"],
                       "doubles, qualifying, TBD rounds, unknown times and other days are left out")
    }

    // A major is on both scoreboards with both draws in it: the draw, not
    // the feed, says whose tour a match is.
    func testAMatchGoesUnderItsOwnTour() throws {
        let major = """
        {"events": [{"name": "US Open", "groupings": [
          {"grouping": {"slug": "womens-singles"}, "competitions": [
            {"id": "3001", "date": "2026-10-13T15:00Z", "timeValid": true, "type": {"slug": "womens-singles"},
             "round": {"displayName": "Final"}, "status": {"type": {"state": "pre"}},
             "competitors": [{"order": 1, "athlete": {"displayName": "Iga Swiatek"}},
                             {"order": 2, "athlete": {"displayName": "Coco Gauff"}}]}]},
          {"grouping": {"slug": "mens-singles"}, "competitions": [
            {"id": "3002", "date": "2026-10-13T19:00Z", "timeValid": true, "type": {"slug": "mens-singles"},
             "round": {"displayName": "Final"}, "status": {"type": {"state": "pre"}},
             "competitors": [{"order": 1, "athlete": {"displayName": "Jannik Sinner"}},
                             {"order": 2, "athlete": {"displayName": "Carlos Alcaraz"}}]}]}
        ]}]}
        """
        let envelope = try JSONDecoder().decode(TennisEnvelope.self, from: Data(major.utf8))
        let games = envelope.events.flatMap {
            SportsScheduleClient.tennisMatches(in: $0, tour: .atp, from: day, to: day.addingTimeInterval(86_400))
        }
        XCTAssertEqual(games.first { $0.id == "tennis-3001" }?.league, .wta)
        XCTAssertEqual(games.first { $0.id == "tennis-3002" }?.league, .atp)
    }

    func testALiveMatchReadsAsAScoreboardDoes() throws {
        let match = try XCTUnwrap(try matches().first { $0.id == "tennis-1001" })
        // The draw's order, not ESPN's home and away.
        XCTAssertEqual(match.awayTeam, "Jannik Sinner")
        XCTAssertEqual(match.homeTeam, "Alex de Minaur")
        XCTAssertEqual(match.awayAbbreviation, "SINNER")
        XCTAssertEqual(match.homeAbbreviation, "DE MINAUR")
        XCTAssertEqual(match.awayLogo, "https://flags/ita.png")
        XCTAssertEqual(match.awayRecord, "Italy")
        XCTAssertEqual(match.awayRank, 1)
        XCTAssertEqual(match.homeRank, 4)
        XCTAssertEqual(match.awayScore, "1")
        XCTAssertEqual(match.homeScore, "1")
        XCTAssertEqual(match.status, "Set 3 \u{00B7} 3-5")
        XCTAssertEqual(match.broadcast, "Tennis Channel")
        XCTAssertEqual(match.placeLine, "Rolex Shanghai Masters \u{00B7} Quarterfinal \u{00B7} Stadium Court")
        XCTAssertEqual(match.matchupLine, "Jannik Sinner vs Alex de Minaur")
        XCTAssertTrue(match.isLive)
        let score = try XCTUnwrap(match.tennis)
        XCTAssertEqual(score.line, "6-4 6-7(5) 3-5")
        XCTAssertTrue(score.isDecidingSet)
    }

    func testAFinishedMatchCarriesItsScoreLine() throws {
        let envelope = try JSONDecoder().decode(TennisEnvelope.self, from: Data(feed.utf8))
        let yesterday = day.addingTimeInterval(-86_400)
        let finished = envelope.events.flatMap {
            SportsScheduleClient.tennisMatches(in: $0, tour: .atp, from: yesterday, to: day)
        }
        let match = try XCTUnwrap(finished.first { $0.id == "tennis-1003" })
        XCTAssertEqual(match.status, "Final \u{00B7} 6-2 6-3")
        XCTAssertEqual(match.awayScore, "2")
        XCTAssertEqual(match.homeScore, "0")
        // The match in play is kept whatever day is asked for.
        XCTAssertTrue(finished.contains { $0.id == "tennis-1001" })
    }

    // A court's later matches are listed at its opening time. Past that time
    // a match not yet begun is still to come, not on.
    func testAMatchWaitingForItsCourtIsUpcomingNotLive() {
        let waiting = SportsGame(
            id: "t", league: .atp, start: Date().addingTimeInterval(-2 * 3600),
            awayTeam: "Carlos Alcaraz", homeTeam: "Taylor Fritz", awayAbbreviation: "ALCARAZ",
            homeAbbreviation: "FRITZ", awayLogo: "", homeLogo: "", awayScore: "", homeScore: "",
            awayColor: nil, homeColor: nil, awayRecord: nil, homeRecord: nil, venue: nil,
            location: nil, status: "", state: "pre", broadcast: "", eventName: nil)
        XCTAssertFalse(waiting.isLive)
        XCTAssertTrue(waiting.isUpcoming)
    }

    func testTheDecidingSetDependsOnTheLength() {
        typealias Set = TennisScore.SetGames
        let oneAll = [Set(away: 6, home: 4, awayWon: true), Set(away: 3, home: 6, awayWon: false), Set(away: 1, home: 1)]
        XCTAssertTrue(TennisScore(sets: oneAll, bestOf: 3).isDecidingSet)
        XCTAssertFalse(TennisScore(sets: oneAll, bestOf: 5).isDecidingSet)
        let twoAll = [Set(away: 6, home: 4, awayWon: true), Set(away: 3, home: 6, awayWon: false),
                      Set(away: 6, home: 4, awayWon: true), Set(away: 3, home: 6, awayWon: false), Set(away: 0, home: 0)]
        XCTAssertTrue(TennisScore(sets: twoAll, bestOf: 5).isDecidingSet)
        // Over is over.
        XCTAssertFalse(TennisScore(sets: Array(oneAll.prefix(2)) + [Set(away: 6, home: 2, awayWon: true)], bestOf: 3).isDecidingSet)
    }

    private func live(_ sets: [TennisScore.SetGames], bestOf: Int = 3) -> SportsGame {
        let score = TennisScore(sets: sets, bestOf: bestOf)
        return SportsGame(
            id: "t", league: .atp, start: Date().addingTimeInterval(-3600),
            awayTeam: "Jannik Sinner", homeTeam: "Carlos Alcaraz", awayAbbreviation: "SINNER",
            homeAbbreviation: "ALCARAZ", awayLogo: "", homeLogo: "",
            awayScore: String(score.awaySets), homeScore: String(score.homeSets),
            awayColor: nil, homeColor: nil, awayRecord: nil, homeRecord: nil, venue: nil,
            location: nil, status: "Set \(sets.count)", state: "in", broadcast: "", eventName: nil,
            tennis: score)
    }

    func testAlertsSpeakTennis() {
        typealias Set = TennisScore.SetGames
        let first = [Set(away: 6, home: 4, awayWon: true), Set(away: 3, home: 6, awayWon: false)]
        let secondSet = live([Set(away: 6, home: 4, awayWon: true), Set(away: 3, home: 2)])
        let decider = live(first + [Set(away: 2, home: 1)])
        let tiebreak = live(first + [Set(away: 6, home: 6)])
        XCTAssertFalse(GameAlertRules.isCloseLate(secondSet))
        XCTAssertEqual(GameAlertRules.alerts(from: secondSet, to: decider), [.closeLate])
        XCTAssertEqual(GameAlert(game: decider, kind: .closeLate).headline, "Deciding set")
        XCTAssertEqual(GameAlertRules.alerts(from: decider, to: tiebreak), [.overtime])
        XCTAssertEqual(GameAlert(game: tiebreak, kind: .overtime).headline, "Final-set tiebreak")
    }

    private func program(_ title: String, _ detail: String = "") -> CurrentProgram {
        CurrentProgram(channelID: "c", title: title, detail: detail,
                       start: Date().addingTimeInterval(-1800), end: Date().addingTimeInterval(1800))
    }

    func testAChannelCarriesAMatchOnlyWhenItNamesBothPlayers() {
        let match = live([TennisScore.SetGames(away: 2, home: 1)])
        let now = Date()
        // A provider's feed named for the match, with nothing in its guide.
        XCTAssertEqual(SportsLibrary.tennisScore(channel: "ESPN+ 07: Sinner vs. Alcaraz (Shanghai)",
                                                 listings: [], game: match, now: now), 400)
        // The listing on now names them.
        XCTAssertEqual(SportsLibrary.tennisScore(
            channel: "US| TENNIS CHANNEL HD",
            listings: [program("ATP Tennis", "Shanghai Masters quarterfinal: Jannik Sinner vs. Carlos Alcaraz")],
            game: match, now: now), 300)
        // The tournament alone is not this match: it is a dozen of them.
        XCTAssertNil(SportsLibrary.tennisScore(
            channel: "US| TENNIS CHANNEL HD",
            listings: [program("ATP Tennis", "Shanghai Masters quarterfinals")], game: match, now: now))
        // A replay of a match between the same two is not this one.
        XCTAssertNil(SportsLibrary.tennisScore(channel: "Tennis Replay: Sinner v Alcaraz",
                                               listings: [], game: match, now: now))
        // One surname is not a match.
        XCTAssertNil(SportsLibrary.tennisScore(channel: "Sinner Cam", listings: [], game: match, now: now))
    }

    func testATournamentIsLookedForByItsOwnWord() {
        XCTAssertEqual(SportsLibrary.tournamentWords("Rolex Shanghai Masters \u{00B7} Quarterfinal"), ["shanghai"])
        XCTAssertEqual(SportsLibrary.tournamentWords("US Open \u{00B7} Final"), ["us open"])
        XCTAssertEqual(SportsLibrary.tournamentWords(nil), [])
    }

    func testTheLeagueIsFoundOnTennisChannels() {
        for tour in [SportsLeague.atp, .wta] {
            XCTAssertTrue(tour.matches("US| TENNIS CHANNEL HD"))
            XCTAssertTrue(tour.matches("beIN 4 | WTA Wuhan Open"))
            XCTAssertTrue(tour.matches("Wimbledon 2026: Centre Court"))
            XCTAssertFalse(tour.matches("US| NFL NETWORK HD"))
        }
    }
}
