import Foundation
import SwiftUI

struct XtreamProfile: Codable, Identifiable, Equatable {
    let id: UUID
    var name: String
    var serverURL: String
    var username: String

    init(id: UUID = UUID(), name: String, serverURL: String, username: String) {
        self.id = id
        self.name = name
        self.serverURL = serverURL
        self.username = username
    }
}

struct XtreamCategory: Codable, Identifiable, Hashable {
    let categoryID: String
    let categoryName: String

    var id: String { categoryID }

    enum CodingKeys: String, CodingKey {
        case categoryID = "category_id"
        case categoryName = "category_name"
    }
}

struct XtreamStream: Codable, Identifiable, Hashable {
    let num: Int?
    let name: String
    let streamType: String?
    let streamID: Int
    let streamIcon: String?
    let epgChannelID: String?
    let categoryID: String?

    var id: Int { streamID }

    enum CodingKeys: String, CodingKey {
        case num, name
        case streamType = "stream_type"
        case streamID = "stream_id"
        case streamIcon = "stream_icon"
        case epgChannelID = "epg_channel_id"
        case categoryID = "category_id"
    }
}

struct CurrentProgram: Hashable, Sendable {
    let channelID: String
    let title: String
    let detail: String
    let start: Date
    let end: Date

    var isLive: Bool {
        let now = Date()
        return start <= now && now < end
    }
}

struct ScheduledStream: Identifiable, Hashable {
    let stream: XtreamStream
    let program: CurrentProgram

    var id: String { "\(stream.id)-\(program.start.timeIntervalSince1970)" }
}

struct SportsGame: Identifiable, Hashable, Sendable {
    let id: String
    let league: SportsLeague
    let start: Date
    let awayTeam: String
    let homeTeam: String
    let awayAbbreviation: String
    let homeAbbreviation: String
    let awayLogo: String
    let homeLogo: String
    let awayScore: String
    let homeScore: String
    let status: String
    let state: String
    let broadcast: String

    var isLive: Bool { state == "in" }
    var isUpcoming: Bool { state == "pre" }
}

struct XtreamEnvelope: Codable {
    struct UserInfo: Codable {
        let auth: Int?
        let status: String?
        let expDate: String?
        let maxConnections: String?

        enum CodingKeys: String, CodingKey {
            case auth, status
            case expDate = "exp_date"
            case maxConnections = "max_connections"
        }

        init(from decoder: Decoder) throws {
            let values = try decoder.container(keyedBy: CodingKeys.self)
            if let number = try? values.decode(Int.self, forKey: .auth) {
                auth = number
            } else if let text = try? values.decode(String.self, forKey: .auth) {
                auth = Int(text)
            } else {
                auth = nil
            }
            status = try? values.decode(String.self, forKey: .status)
            expDate = try? values.decode(String.self, forKey: .expDate)
            maxConnections = try? values.decode(String.self, forKey: .maxConnections)
        }
    }

    let userInfo: UserInfo?

    enum CodingKeys: String, CodingKey {
        case userInfo = "user_info"
    }
}

enum SportsLeague: String, CaseIterable, Identifiable, Sendable {
    case nfl, nba, nhl, mlb

    var id: String { rawValue }
    var shortName: String { rawValue.uppercased() }
    var fullName: String {
        switch self {
        case .nfl: "Football"
        case .nba: "Basketball"
        case .nhl: "Hockey"
        case .mlb: "Baseball"
        }
    }
    var color: Color {
        switch self {
        case .nfl: Color(red: 0.61, green: 0.43, blue: 0.31)
        case .nba: Color(red: 0.70, green: 0.39, blue: 0.28)
        case .nhl: Color(red: 0.45, green: 0.55, blue: 0.59)
        case .mlb: Color(red: 0.42, green: 0.49, blue: 0.66)
        }
    }

    func matches(_ text: String) -> Bool {
        let value = text.lowercased()
        return containsLeagueToken(value) || containsAny(value, teamTerms)
    }

    func matchesProfessionalGame(_ text: String) -> Bool {
        let value = text.lowercased()
        if containsLeagueToken(value) { return true }
        return teamTerms.reduce(0) { $0 + (value.contains($1) ? 1 : 0) } >= 2
    }

    private var teamTerms: [String] {
        switch self {
        case .nfl: ["49ers", "bears", "bengals", "bills", "broncos", "browns", "buccaneers", "cardinals", "chargers", "chiefs", "colts", "commanders", "cowboys", "dolphins", "eagles", "falcons", "giants", "jaguars", "jets", "lions", "packers", "panthers", "patriots", "raiders", "rams", "ravens", "saints", "seahawks", "steelers", "texans", "titans", "vikings"]
        case .nba: ["76ers", "bucks", "bulls", "cavaliers", "celtics", "clippers", "grizzlies", "hawks", "heat", "hornets", "jazz", "kings", "knicks", "lakers", "magic", "mavericks", "nets", "nuggets", "pacers", "pelicans", "pistons", "raptors", "rockets", "spurs", "suns", "thunder", "timberwolves", "trail blazers", "warriors", "wizards"]
        case .nhl: ["avalanche", "blackhawks", "blue jackets", "blues", "bruins", "canadiens", "canucks", "capitals", "devils", "ducks", "flames", "flyers", "golden knights", "hurricanes", "islanders", "jets", "kings", "kraken", "lightning", "maple leafs", "mammoth", "oilers", "panthers", "penguins", "predators", "rangers", "red wings", "sabres", "senators", "sharks", "stars"]
        case .mlb: ["angels", "astros", "athletics", "blue jays", "braves", "brewers", "cardinals", "cubs", "diamondbacks", "dodgers", "giants", "guardians", "mariners", "marlins", "mets", "nationals", "orioles", "padres", "phillies", "pirates", "rangers", "rays", "red sox", "reds", "rockies", "royals", "tigers", "twins", "white sox", "yankees"]
        }
    }

    private func containsAny(_ text: String, _ terms: [String]) -> Bool {
        terms.contains { text.contains($0) }
    }

    private func containsLeagueToken(_ text: String) -> Bool {
        text.components(separatedBy: CharacterSet.alphanumerics.inverted).contains(rawValue)
    }
}
