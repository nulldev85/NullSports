import Foundation

/// Available even offline and between seasons. Following uses the same league
/// and team code as schedule menus, so there is only one My Teams store.
struct SportsTeamDirectory: Decodable, Sendable {
    struct Team: Decodable, Identifiable, Sendable {
        let league: SportsLeague
        let espnID: String
        let name: String
        let abbreviation: String
        let logo: String
        let division: String?
        var competitions: [String]? = nil

        var key: TeamChannelKey {
            league == .soccer
                ? TeamChannelKey(league: league.rawValue, identity: "ESPN:" + espnID)
                : TeamChannelKey(league: league.rawValue, abbreviation: abbreviation, name: name)
        }
        var id: String { key.storageKey }
        var followedTeam: FollowedTeam {
            FollowedTeam(key: key, name: name, abbreviation: abbreviation, logo: logo)
        }
    }

    let teams: [Team]
    static let leagues: [SportsLeague] = [.nfl, .nba, .nhl, .mlb, .ncaaf, .soccer]
    static let bundled: SportsTeamDirectory = {
        guard let url = Bundle.main.url(forResource: "SportsTeams", withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let directory = try? JSONDecoder().decode(SportsTeamDirectory.self, from: data) else {
            return SportsTeamDirectory(teams: [])
        }
        return directory
    }()
    static let soccerByIdentity = Dictionary(uniqueKeysWithValues: bundled.teams
        .filter { $0.league == .soccer }.map { ($0.key.team, $0) })
    static let soccerCompetitionNames = Dictionary(uniqueKeysWithValues: SportsCompetitionCatalog.bundled.competitions.map { ($0.id, $0.shortName) })

    func teams(in league: SportsLeague? = nil, matching query: String = "") -> [Team] {
        let words = Self.normalized(query).split(whereSeparator: \.isWhitespace)
        return teams.filter { team in
            guard league == nil || team.league == league else { return false }
            let text = Self.normalized([team.name, team.abbreviation, team.league.shortName,
                                       team.league.fullName, team.division ?? "",
                                       (team.competitions ?? []).compactMap { id in
                                           SportsCompetitionCatalog.bundled.competitions.first { $0.id == id }?.name
                                       }.joined(separator: " ")].joined(separator: " "))
            return words.allSatisfy { text.contains($0) }
        }
    }

    static func title(_ league: SportsLeague) -> String {
        league == .ncaaf ? "College Football" : league.shortName
    }

    private static func normalized(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en_US_POSIX"))
    }
}
