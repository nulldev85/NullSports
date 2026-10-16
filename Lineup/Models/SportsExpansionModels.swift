import Foundation

struct SportsCompetition: Codable, Hashable, Sendable, Identifiable {
    let id: String
    let feedID: String
    let name: String
    let shortName: String
    let logo: String
}

struct SportsCompetitionCatalog: Decodable, Sendable {
    let competitions: [SportsCompetition]
    static let bundled: Self = {
        guard let url = Bundle.main.url(forResource: "SportsCompetitions", withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let catalog = try? JSONDecoder().decode(Self.self, from: data) else {
            return Self(competitions: [])
        }
        return catalog
    }()
}

struct SoccerScore: Codable, Hashable, Sendable {
    let awayPenalties: String?
    let homePenalties: String?
    let awayAggregate: String?
    let homeAggregate: String?
    var period: Int? = nil
    var clockSeconds: Double? = nil
    var detail: String? {
        if let awayPenalties, let homePenalties, let away = Int(awayPenalties), let home = Int(homePenalties), away + home > 0 {
            return "Penalties \(awayPenalties)–\(homePenalties)"
        }
        if let awayAggregate, let homeAggregate { return "Aggregate \(awayAggregate)–\(homeAggregate)" }
        return nil
    }
}

struct RacingSession: Codable, Hashable, Sendable {
    struct Entrant: Codable, Hashable, Sendable, Identifiable {
        let id: String
        let name: String
        let flag: String?
        let position: Int?
    }
    let eventID: String
    let kind: String
    let title: String
    let circuit: String?
    let entrants: [Entrant]
}

extension SportsGame {
    var competitionLabel: String { competition?.name ?? league.shortName }
    var detailLine: String? {
        if let detail = soccer?.detail { return detail }
        return race?.title
    }
    var racingFollow: FollowedTeam? {
        league.seriesFollow
    }
}

extension SportsLeague {
    var seriesFollow: FollowedTeam? {
        guard isRacing else { return nil }
        return FollowedTeam(key: TeamChannelKey(league: rawValue, abbreviation: "SERIES", name: fullName),
            name: fullName, abbreviation: "SERIES", logo: officialLogoURL ?? "")
    }
    var officialLogoURL: String? {
        switch self {
        case .f1: "https://a.espncdn.com/i/teamlogos/leagues/500/f1.png"
        case .nascar: "https://rf.nascar.com/static/images/NASCAR-logo-300.png"
        default: nil
        }
    }
}
