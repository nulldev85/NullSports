import XCTest
import UIKit
#if os(tvOS)
@testable import Lineup
#else
@testable import LineupiOS
#endif

final class SportsTeamDirectoryTests: XCTestCase {
    private let directory = SportsTeamDirectory.bundled

    func testBundledDirectoryContainsEveryTeamLeagueWithoutDuplicateFollowKeys() {
        XCTAssertEqual(Set(directory.teams.map(\.league)), Set(SportsTeamDirectory.leagues))
        XCTAssertEqual(directory.teams(in: .nfl).count, 32)
        XCTAssertEqual(directory.teams(in: .nba).count, 30)
        XCTAssertEqual(directory.teams(in: .nhl).count, 32)
        XCTAssertEqual(directory.teams(in: .mlb).count, 30)
        let college = directory.teams(in: .ncaaf)
        XCTAssertGreaterThan(college.count, 250)
        XCTAssertEqual(Set(college.compactMap(\.division)), ["FBS", "FCS"])
        XCTAssertEqual(Set(directory.teams.map(\.id)).count, directory.teams.count)
        XCTAssertGreaterThan(directory.teams(in: .soccer).count, 300)
        XCTAssertTrue(directory.teams.allSatisfy { !$0.name.isEmpty && !$0.abbreviation.isEmpty && URL(string: $0.logo)?.scheme == "https" })
        for league in SportsTeamDirectory.leagues {
            if league == .soccer {
                XCTAssertEqual(SportsCompetitionCatalog.bundled.competitions.count, 18)
                XCTAssertTrue(SportsCompetitionCatalog.bundled.competitions.allSatisfy { URL(string: $0.logo)?.scheme == "https" })
                continue // Soccer is a category; each actual competition supplies its own official logo.
            }
            XCTAssertNotNil(UIImage(named: "League-\(league.rawValue)"), "Bundle the league logo on both platforms")
        }
    }

    func testSearchAcceptsNamesCodesLeagueWordsAndAccents() {
        XCTAssertEqual(directory.teams(matching: "nfl bills").map(\.name), ["Buffalo Bills"])
        XCTAssertEqual(directory.teams(in: .nba, matching: "bos").map(\.name), ["Boston Celtics"])
        XCTAssertEqual(directory.teams(in: .ncaaf, matching: "san jose").map(\.name), ["San José State Spartans"])
        XCTAssertEqual(directory.teams(in: .nfl, matching: "   ").count, 32)
        XCTAssertTrue(directory.teams(matching: "there is no such team").isEmpty)
        XCTAssertTrue(directory.teams(in: .soccer, matching: "premier league").contains { $0.name == "Arsenal" })
    }

    @MainActor
    private func makeLibrary() throws -> (SportsLibrary, UserDefaults, String, XtreamProfile, XtreamProfile) {
        let suite = "SportsTeamDirectoryTests.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        let first = XtreamProfile(name: "First", serverURL: "https://example.invalid", username: "one")
        let second = XtreamProfile(name: "Second", serverURL: "https://example.invalid", username: "two")
        defaults.set(try JSONEncoder().encode([first, second]), forKey: "NullSports.profiles")
        defaults.set(first.id.uuidString, forKey: "NullSports.activeProfile")
        return (SportsLibrary(profileDefaults: defaults), defaults, suite, first, second)
    }

    @MainActor
    func testSettingsFollowIsImmediatelyTheSameTeamAsGameMenusAndSurvivesRelaunch() throws {
        let (library, defaults, suite, _, _) = try makeLibrary()
        defer { defaults.removePersistentDomain(forName: suite) }
        let bills = try XCTUnwrap(directory.teams(in: .nfl, matching: "Bills").first)
        let game = SportsGame(id: "nfl-test", league: .nfl, start: .now,
            awayTeam: "Kansas City Chiefs", homeTeam: "Buffalo Bills",
            awayAbbreviation: "KC", homeAbbreviation: "BUF", awayLogo: "", homeLogo: "",
            awayScore: "", homeScore: "", awayColor: nil, homeColor: nil,
            awayRecord: nil, homeRecord: nil, venue: nil, location: nil,
            status: "Scheduled", state: "pre", broadcast: "", eventName: nil)
        library.toggleFollow(bills.followedTeam)
        XCTAssertTrue(library.isFollowing(game), "The Sports tab must react without a schedule refresh")
        XCTAssertTrue(library.isFollowing(bills.key))
        let restored = SportsLibrary(profileDefaults: defaults)
        XCTAssertTrue(restored.isFollowing(game))
        XCTAssertEqual(restored.followedTeams.count, 1)
        let menuTeam = try XCTUnwrap(restored.followableSides(of: game).first { $0.key == bills.key })
        restored.toggleFollow(menuTeam)
        XCTAssertFalse(restored.isFollowing(bills.key), "Removing from a game menu also updates Settings")
        XCTAssertTrue(SportsLibrary(profileDefaults: defaults).followedTeams.isEmpty)
    }

    @MainActor
    func testExistingFollowsRemainSelectedAndProvidersKeepIndependentLists() throws {
        let (library, defaults, suite, first, second) = try makeLibrary()
        defer { defaults.removePersistentDomain(forName: suite) }
        let bills = try XCTUnwrap(directory.teams(in: .nfl, matching: "Bills").first)
        let celtics = try XCTUnwrap(directory.teams(in: .nba, matching: "Celtics").first)
        let legacy = FollowedTeam(key: bills.key, name: "Bills", abbreviation: "BUF", logo: "")
        library.toggleFollow(legacy)
        XCTAssertTrue(library.isFollowing(bills.key), "A different display name must not create a new favorite")
        defaults.set(second.id.uuidString, forKey: "NullSports.activeProfile")
        let other = SportsLibrary(profileDefaults: defaults)
        XCTAssertTrue(other.followedTeams.isEmpty)
        other.toggleFollow(celtics.followedTeam)
        XCTAssertTrue(other.isFollowing(celtics.key))
        XCTAssertFalse(other.isFollowing(bills.key))
        defaults.set(first.id.uuidString, forKey: "NullSports.activeProfile")
        let restored = SportsLibrary(profileDefaults: defaults)
        XCTAssertTrue(restored.isFollowing(bills.key))
        XCTAssertFalse(restored.isFollowing(celtics.key))
        restored.toggleFollow(bills.followedTeam)
        XCTAssertTrue(SportsLibrary(profileDefaults: defaults).followedTeams.isEmpty)
    }

    @MainActor
    func testNoProviderDoesNotPretendToSaveAnUnpersistedFollow() throws {
        let suite = "SportsTeamDirectoryTests.Empty.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let library = SportsLibrary(profileDefaults: defaults)
        let team = try XCTUnwrap(directory.teams.first)
        library.toggleFollow(team.followedTeam)
        XCTAssertTrue(library.followedTeams.isEmpty)
    }

    @MainActor
    func testSoccerFollowUsesTheSameClubAcrossCompetitionsAndAfterRelaunch() throws {
        let (library, defaults, suite, _, _) = try makeLibrary()
        defer { defaults.removePersistentDomain(forName: suite) }
        let club = try XCTUnwrap(directory.teams(in: .soccer).first { $0.espnID == "363" })
        let file = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "soccer-schedule", withExtension: "json", subdirectory: "Fixtures"))
        var game = try XCTUnwrap(ExpandedSportsScheduleClient.soccerGames(data: Data(contentsOf: file),
            competitions: SportsCompetitionCatalog.bundled.competitions).first)
        library.toggleFollow(club.followedTeam)
        XCTAssertTrue(library.isFollowing(game))
        game.competition = SportsCompetitionCatalog.bundled.competitions.first { $0.id == "uefa.champions" }
        XCTAssertTrue(library.isFollowing(game))
        let changedDisplay = FollowedTeam(key: club.key, name: "Chelsea FC", abbreviation: "CFC", logo: club.logo)
        let restored = try JSONDecoder().decode(FollowedTeam.self, from: JSONEncoder().encode(changedDisplay))
        XCTAssertEqual(restored.key, club.key, "Saved identity must not be reconstructed from a changed display abbreviation")
        let relaunched = SportsLibrary(profileDefaults: defaults)
        XCTAssertTrue(relaunched.isFollowing(game))
        relaunched.toggleFollow(restored)
        XCTAssertFalse(SportsLibrary(profileDefaults: defaults).isFollowing(game))
    }

    @MainActor
    func testFollowingARacingSeriesIncludesEverySessionAndIsProviderScoped() throws {
        let (library, defaults, suite, _, second) = try makeLibrary()
        defer { defaults.removePersistentDomain(forName: suite) }
        let file = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "f1-weekend", withExtension: "json", subdirectory: "Fixtures"))
        let games = try ExpandedSportsScheduleClient.racingGames(data: Data(contentsOf: file), league: .f1)
        library.toggleFollow(try XCTUnwrap(SportsLeague.f1.seriesFollow))
        XCTAssertTrue(games.allSatisfy { library.isFollowing($0) })
        XCTAssertEqual(library.followableSides(of: games[0]).map(\.name), ["Formula 1"])
        XCTAssertTrue(SportsLibrary(profileDefaults: defaults).isFollowing(games[0]))
        defaults.set(second.id.uuidString, forKey: "NullSports.activeProfile")
        XCTAssertFalse(SportsLibrary(profileDefaults: defaults).isFollowing(games[0]))
    }
}
