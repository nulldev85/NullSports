import Foundation

/// A team whose page can be opened: where ESPN keeps it, and what to call
/// and draw it while the page loads.
struct MobileTeamPageTarget: Identifiable, Hashable {
    let league: SportsLeague
    let path: TeamPagePath
    let name: String
    let abbreviation: String
    let logo: String
    let followKey: TeamChannelKey

    var id: String { "\(path.sport)/\(path.league)/\(path.teamID)" }

    /// A followed team or one side of a game, as `SportsLibrary` keys it: by
    /// its code in the team directory, or a soccer club by its ESPN id. A
    /// soccer club's competition is the game's, else its own league's.
    init?(side: FollowedTeam, competition: String? = nil) {
        guard let league = SportsLeague(rawValue: side.league.lowercased()) else { return nil }
        let teamID: String
        var competition = competition
        if league == .soccer {
            guard side.team.hasPrefix("ESPN:") else { return nil }
            teamID = String(side.team.dropFirst("ESPN:".count))
            if competition == nil { competition = SportsTeamDirectory.soccerByIdentity[side.team]?.competitions?.first }
        } else {
            guard let entry = SportsTeamDirectory.bundled.teams.first(where: {
                $0.league == league && $0.abbreviation.uppercased() == side.team
            }) else { return nil }
            teamID = entry.espnID
        }
        guard !teamID.isEmpty, let espn = Self.espnPath(league, competition: competition) else { return nil }
        self.league = league
        self.path = TeamPagePath(sport: espn.sport, league: espn.league, teamID: teamID)
        self.name = side.name
        self.abbreviation = side.abbreviation
        self.logo = side.logo
        self.followKey = side.key
    }

    private static func espnPath(_ league: SportsLeague, competition: String?) -> (sport: String, league: String)? {
        switch league {
        case .nfl: return ("football", "nfl")
        case .ncaaf: return ("football", "college-football")
        case .nba: return ("basketball", "nba")
        case .nhl: return ("hockey", "nhl")
        case .mlb: return ("baseball", "mlb")
        case .soccer: return competition.map { ("soccer", $0) }
        default: return nil
        }
    }
}
