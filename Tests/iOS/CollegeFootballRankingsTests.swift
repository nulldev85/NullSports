import XCTest
@testable import LineupiOS

final class CollegeFootballRankingsTests: XCTestCase {
    // ESPN's scoreboard, cut to the parts the ranks come from. Unranked
    // teams carry 99.
    private let scoreboard = """
    {"events": [
      {"id": "401", "competitions": [{"competitors": [
        {"homeAway": "home", "team": {"abbreviation": "UGA", "displayName": "Georgia Bulldogs"}, "curatedRank": {"current": 5}},
        {"homeAway": "away", "team": {"abbreviation": "ALA", "displayName": "Alabama Crimson Tide"}, "curatedRank": {"current": 3}}
      ]}]},
      {"id": "402", "competitions": [{"competitors": [
        {"homeAway": "home", "team": {"abbreviation": "TEX", "displayName": "Texas Longhorns"}, "curatedRank": {"current": 99}},
        {"homeAway": "away", "team": {"abbreviation": "OKST", "displayName": "Oklahoma State Cowboys"}, "curatedRank": {"current": 12}}
      ]}]},
      {"id": "403", "competitions": [{"competitors": [
        {"homeAway": "home", "team": {"abbreviation": "APP", "displayName": "App State Mountaineers"}},
        {"homeAway": "away", "team": {"abbreviation": "MRSH", "displayName": "Marshall Thundering Herd"}}
      ]}]}
    ]}
    """

    private func ranks() throws -> CollegeFootballRankings.Ranks {
        try CollegeFootballRankings.Ranks.parse(Data(scoreboard.utf8))
    }

    private func game(id: String, league: SportsLeague = .ncaaf,
                      away: String, awayCode: String, home: String, homeCode: String) -> SportsGame {
        SportsGame(
            id: id, league: league, start: Date(),
            awayTeam: away, homeTeam: home,
            awayAbbreviation: awayCode, homeAbbreviation: homeCode,
            awayLogo: "", homeLogo: "", awayScore: "", homeScore: "",
            awayColor: nil, homeColor: nil, awayRecord: nil, homeRecord: nil,
            venue: nil, location: nil, status: "Scheduled", state: "pre",
            broadcast: "ABC", eventName: nil
        )
    }

    func testTheSameESPNGameGivesBothSidesTheirRanks() throws {
        let ranked = try ranks().applied(to: game(
            id: "ncaaf-401", away: "Alabama Crimson Tide", awayCode: "ALA",
            home: "Georgia Bulldogs", homeCode: "UGA"))
        XCTAssertEqual(ranked.awayRank, 3)
        XCTAssertEqual(ranked.homeRank, 5)
    }

    func testTeamsAreFoundByNameOrCodeWhenTheGameIDDiffers() throws {
        let ranks = try ranks()
        let byName = ranks.applied(to: game(
            id: "ncaaf-other", away: "Oklahoma State Cowboys", awayCode: "OSU",
            home: "Texas Longhorns", homeCode: "TEX"))
        XCTAssertEqual(byName.awayRank, 12)
        XCTAssertNil(byName.homeRank)

        let byCode = ranks.applied(to: game(
            id: "ncaaf-other", away: "Alabama", awayCode: "ala",
            home: "Georgia", homeCode: "UGA"))
        XCTAssertEqual(byCode.awayRank, 3)
        XCTAssertEqual(byCode.homeRank, 5)
    }

    func testUnrankedTeamsAndOtherLeaguesGetNoRank() throws {
        let ranks = try ranks()
        let unranked = ranks.applied(to: game(
            id: "ncaaf-403", away: "Marshall Thundering Herd", awayCode: "MRSH",
            home: "App State Mountaineers", homeCode: "APP"))
        XCTAssertNil(unranked.awayRank)
        XCTAssertNil(unranked.homeRank)

        let pro = ranks.applied(to: game(
            id: "nfl-401", league: .nfl, away: "Alabama Crimson Tide", awayCode: "ALA",
            home: "Georgia Bulldogs", homeCode: "UGA"))
        XCTAssertNil(pro.awayRank)
        XCTAssertNil(pro.homeRank)
    }

    // ESPN's rankings, cut down: the committee's, the AP poll, the coaches'.
    private let polls = """
    {"rankings": [
      {"type": "cfp", "ranks": [
        {"current": 3, "team": {"location": "Alabama", "name": "Crimson Tide", "nickname": "Alabama", "abbreviation": "ALA"}},
        {"current": 5, "team": {"location": "Notre Dame", "name": "Fighting Irish", "nickname": "Notre Dame", "abbreviation": "ND"}}
      ]},
      {"type": "ap", "ranks": [
        {"current": 3, "team": {"location": "Notre Dame", "name": "Fighting Irish", "nickname": "Notre Dame", "abbreviation": "ND"}},
        {"current": 7, "team": {"location": "Alabama", "name": "Crimson Tide", "nickname": "Alabama", "abbreviation": "ALA"}},
        {"current": 26, "team": {"location": "Nowhere", "name": "State", "abbreviation": "NOW"}}
      ]},
      {"type": "usa", "ranks": [
        {"current": 4, "team": {"location": "Notre Dame", "name": "Fighting Irish", "abbreviation": "ND"}}
      ]}
    ]}
    """

    func testThePollTheViewerFollowsGivesTheRanks() throws {
        let data = Data(polls.utf8)
        let matchup = game(id: "ncaaf-other", away: "Notre Dame Fighting Irish", awayCode: "ND",
                           home: "Alabama", homeCode: "ALA")
        let ap = try CollegeFootballRankings.Ranks.parse(polls: data, poll: .ap).applied(to: matchup)
        XCTAssertEqual(ap.awayRank, 3, "Found by the full name")
        XCTAssertEqual(ap.homeRank, 7, "Found by the school alone")
        let playoff = try CollegeFootballRankings.Ranks.parse(polls: data, poll: .playoff).applied(to: matchup)
        XCTAssertEqual(playoff.awayRank, 5)
        XCTAssertEqual(playoff.homeRank, 3)
        let coaches = try CollegeFootballRankings.Ranks.parse(polls: data, poll: .coaches).applied(to: matchup)
        XCTAssertEqual(coaches.awayRank, 4)
        XCTAssertNil(coaches.homeRank)
    }

    func testTheAPPollStandsInBeforeTheCommitteeRanks() throws {
        let early = Data(#"{"rankings": [{"type": "ap", "ranks": [{"current": 1, "team": {"location": "Georgia", "name": "Bulldogs", "abbreviation": "UGA"}}]}]}"#.utf8)
        let ranked = try CollegeFootballRankings.Ranks.parse(polls: early, poll: .playoff).applied(to: game(
            id: "ncaaf-1", away: "Georgia Bulldogs", awayCode: "UGA", home: "Somebody", homeCode: "SOME"))
        XCTAssertEqual(ranked.awayRank, 1)
        XCTAssertNil(ranked.homeRank)
    }

    func testAnOldSavedScheduleWithoutRanksStillLoads() throws {
        let saved = try JSONEncoder().encode(game(
            id: "ncaaf-1", away: "Alabama Crimson Tide", awayCode: "ALA",
            home: "Georgia Bulldogs", homeCode: "UGA"))
        var payload = try XCTUnwrap(JSONSerialization.jsonObject(with: saved) as? [String: Any])
        payload["awayRank"] = nil
        payload["homeRank"] = nil
        let loaded = try JSONDecoder().decode(SportsGame.self, from: JSONSerialization.data(withJSONObject: payload))
        XCTAssertNil(loaded.awayRank)
        XCTAssertEqual(loaded.awayTeam, "Alabama Crimson Tide")
    }
}
