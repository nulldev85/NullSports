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
