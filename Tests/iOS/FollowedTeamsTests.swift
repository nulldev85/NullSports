import XCTest
@testable import LineupiOS

/// Following a team, and what counts as one of your games.
final class FollowedTeamsTests: XCTestCase {
    private func key(_ league: String, _ abbreviation: String, _ name: String = "") -> TeamChannelKey {
        TeamChannelKey(league: league, abbreviation: abbreviation, name: name)
    }
    private func team(_ league: String, _ abbreviation: String, _ name: String) -> FollowedTeam {
        FollowedTeam(key: key(league, abbreviation, name), name: name,
                     abbreviation: abbreviation, logo: "")
    }
    private let chiefsAtBills = TeamChannelGame(
        league: "nfl", homeTeam: "Buffalo Bills", homeAbbreviation: "BUF",
        awayTeam: "Kansas City Chiefs", awayAbbreviation: "KC")

    func testAGameWithEitherSideFollowedIsYours() {
        var teams = FollowedTeams()
        teams.follow(team("nfl", "KC", "Chiefs"))
        XCTAssertTrue(FollowedSlate.follows(chiefsAtBills, in: teams))
        teams.unfollow(key("nfl", "KC"))
        teams.follow(team("nfl", "BUF", "Bills"))
        XCTAssertTrue(FollowedSlate.follows(chiefsAtBills, in: teams),
                      "The home side counts as much as the away side")
    }

    func testFollowingNobodyClaimsNothing() {
        XCTAssertFalse(FollowedSlate.follows(chiefsAtBills, in: FollowedTeams()))
    }

    // The same abbreviation belongs to different teams in different leagues,
    // which is exactly why the key carries the league.
    func testTheSameLettersInAnotherLeagueAreAnotherTeam() {
        var teams = FollowedTeams()
        teams.follow(team("nba", "BUF", "Buffalo"))
        XCTAssertFalse(FollowedSlate.follows(chiefsAtBills, in: teams))
    }

    func testFollowingTwiceIsStillOnce() {
        var teams = FollowedTeams()
        teams.follow(team("nfl", "KC", "Chiefs"))
        teams.follow(team("nfl", "KC", "Chiefs"))
        XCTAssertEqual(teams.count, 1)
    }

    func testToggleGoesBothWays() {
        var teams = FollowedTeams()
        let chiefs = team("nfl", "KC", "Chiefs")
        teams.toggle(chiefs); XCTAssertTrue(teams.contains(chiefs.key))
        teams.toggle(chiefs); XCTAssertFalse(teams.contains(chiefs.key))
    }

    // Order is when you followed, not form, standing or name. A list that
    // rearranges itself is one nobody can find anything in twice.
    func testOrderIsWhenYouFollowed() {
        let early = FollowedTeam(key: key("nfl", "KC"), name: "Chiefs", abbreviation: "KC",
                                 logo: "", followedAt: Date(timeIntervalSince1970: 100))
        let late = FollowedTeam(key: key("nfl", "BUF"), name: "Bills", abbreviation: "BUF",
                                logo: "", followedAt: Date(timeIntervalSince1970: 900))
        XCTAssertEqual(FollowedTeams([late, early]).teams.map(\.abbreviation), ["KC", "BUF"])
    }

    // A fight card has no two sides, so there is nothing to follow on it.
    func testAnEventOffersNoSidesToFollow() {
        let event = TeamChannelGame(league: "ufc", homeTeam: "", homeAbbreviation: "",
                                    awayTeam: "", awayAbbreviation: "")
        XCTAssertTrue(FollowedSlate.sides(of: event).isEmpty)
    }

    func testAGameOffersBothSides() {
        XCTAssertEqual(FollowedSlate.sides(of: chiefsAtBills).map(\.team), ["KC", "BUF"])
    }
}
