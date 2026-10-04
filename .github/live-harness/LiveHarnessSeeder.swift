// TEMPORARY design harness -- never part of the app.
//
// The live-design-snapshots workflow copies this file into the checkout it
// builds, calls `seed()` from that checkout's LineupApp.init, and throws the
// checkout away afterwards. It gives the Live tab a provider, a schedule and a
// guide to draw, entirely in-process: every request the app makes to the
// schedule service, ESPN's UFC scoreboard or the provider is answered here.
// Team artwork still comes from ESPN's CDN, which is not intercepted.
import Foundation

enum LiveHarnessSeeder {
    static let profileID = UUID(uuidString: "6F1B7C3A-2D4E-4F5A-9B8C-1A2B3C4D5E6F")!
    static let password = "harness"

    static var isActive: Bool { ProcessInfo.processInfo.arguments.contains("-LiveHarness") }

    static func seed() {
        guard isActive else { return }
        URLProtocol.registerClass(LiveHarnessProtocol.self)
        let defaults = UserDefaults.standard
        let profile = XtreamProfile(id: profileID, name: "Harness Provider",
                                    serverURL: "http://harness.lineup.test", username: "harness")
        if let data = try? JSONEncoder().encode([profile]) {
            defaults.set(data, forKey: "NullSports.profiles")
        }
        defaults.set(profileID.uuidString, forKey: "NullSports.activeProfile")
        let arguments = ProcessInfo.processInfo.arguments
        if let index = arguments.firstIndex(of: "-LiveHarnessTheme"), arguments.indices.contains(index + 1) {
            defaults.set(arguments[index + 1], forKey: LineupTheme.storageKey)
        }
        let follows = arguments.contains("-LiveHarnessNoFollows") ? FollowedTeams() : FollowedTeams(LiveHarnessData.followed)
        if let data = try? JSONEncoder().encode(follows) {
            defaults.set(data, forKey: "NullSports.followedTeams." + profileID.uuidString)
        }
    }

    /// Consulted by the checkout's patched KeychainStore, because an unsigned
    /// simulator build has no keychain to keep a password in.
    static func password(for profile: UUID) -> String? {
        isActive && profile == profileID ? password : nil
    }
}

final class LiveHarnessProtocol: URLProtocol {
    private static let hosts: Set<String> = ["sports.mateomedia.link", "site.api.espn.com", "harness.lineup.test"]

    override class func canInit(with request: URLRequest) -> Bool {
        guard let host = request.url?.host else { return false }
        return hosts.contains(host)
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let url = request.url else { return }
        let (body, type) = LiveHarnessData.response(for: url)
        let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1",
                                       headerFields: ["Content-Type": type])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: body)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

enum LiveHarnessData {
    struct Team {
        let name: String
        let abbreviation: String
        let logo: String
        let color: String
        let record: String
    }

    struct Fixture {
        let league: String
        let id: String
        let away: Team
        let home: Team
        /// Start, relative to launch.
        let hours: Double
        let state: String
        let status: String
        let awayScore: String
        let homeScore: String
        let venue: String
        let location: String
        let broadcast: String
        let tomorrow: Bool
        /// A provider event channel carrying it, or nil to leave it unmatched.
        let channel: Int?
    }

    static let anchor = Date()

    private static func logo(_ path: String, _ code: String) -> String {
        "https://a.espncdn.com/i/teamlogos/\(path)/500/\(code).png"
    }

    private static func nfl(_ name: String, _ abbreviation: String, _ color: String, _ record: String) -> Team {
        Team(name: name, abbreviation: abbreviation, logo: logo("nfl", abbreviation.lowercased()), color: color, record: record)
    }
    private static func nba(_ name: String, _ abbreviation: String, _ color: String, _ record: String) -> Team {
        Team(name: name, abbreviation: abbreviation, logo: logo("nba", abbreviation.lowercased()), color: color, record: record)
    }
    private static func mlb(_ name: String, _ abbreviation: String, _ color: String, _ record: String) -> Team {
        Team(name: name, abbreviation: abbreviation, logo: logo("mlb", abbreviation.lowercased()), color: color, record: record)
    }
    private static func nhl(_ name: String, _ abbreviation: String, _ color: String, _ record: String) -> Team {
        Team(name: name, abbreviation: abbreviation, logo: logo("nhl", abbreviation.lowercased()), color: color, record: record)
    }
    private static func ncaa(_ name: String, _ abbreviation: String, _ espnID: String, _ color: String, _ record: String) -> Team {
        Team(name: name, abbreviation: abbreviation, logo: logo("ncaa", espnID), color: color, record: record)
    }

    static let fixtures: [Fixture] = [
        Fixture(league: "nfl", id: "401", away: nfl("Buffalo Bills", "BUF", "00338D", "10-3"),
                home: nfl("Kansas City Chiefs", "KC", "E31837", "11-2"), hours: -2.1, state: "in",
                status: "4:12 - 3rd", awayScore: "17", homeScore: "24",
                venue: "GEHA Field at Arrowhead Stadium", location: "Kansas City, MO", broadcast: "CBS",
                tomorrow: false, channel: 1001),
        Fixture(league: "mlb", id: "402", away: mlb("New York Yankees", "NYY", "003087", "94-68"),
                home: mlb("Boston Red Sox", "BOS", "BD3039", "89-73"), hours: -2.6, state: "in",
                status: "Top 7th", awayScore: "3", homeScore: "5",
                venue: "Fenway Park", location: "Boston, MA", broadcast: "FOX",
                tomorrow: false, channel: 1002),
        Fixture(league: "nba", id: "403", away: nba("Golden State Warriors", "GS", "1D428A", "38-25"),
                home: nba("Los Angeles Lakers", "LAL", "552583", "40-22"), hours: -1.0, state: "in",
                status: "6:41 - 2nd", awayScore: "54", homeScore: "49",
                venue: "Crypto.com Arena", location: "Los Angeles, CA", broadcast: "ESPN",
                tomorrow: false, channel: 1003),
        Fixture(league: "nhl", id: "404", away: nhl("Toronto Maple Leafs", "TOR", "00205B", "31-18-6"),
                home: nhl("Montreal Canadiens", "MTL", "AF1E2D", "27-22-7"), hours: -1.3, state: "in",
                status: "12:03 - 2nd", awayScore: "2", homeScore: "1",
                venue: "Bell Centre", location: "Montreal, QC", broadcast: "ESPN+",
                tomorrow: false, channel: 1004),
        Fixture(league: "ncaaf", id: "405", away: ncaa("Ohio State Buckeyes", "OSU", "194", "BB0000", "9-0"),
                home: ncaa("Michigan Wolverines", "MICH", "130", "00274C", "8-1"), hours: -1.1, state: "in",
                status: "1:48 - 2nd", awayScore: "14", homeScore: "10",
                venue: "Michigan Stadium", location: "Ann Arbor, MI", broadcast: "FOX",
                tomorrow: false, channel: 1005),
        Fixture(league: "nba", id: "406", away: nba("Boston Celtics", "BOS", "007A33", "44-18"),
                home: nba("Milwaukee Bucks", "MIL", "00471B", "36-26"), hours: 0.75, state: "pre",
                status: "7:30 PM", awayScore: "", homeScore: "",
                venue: "Fiserv Forum", location: "Milwaukee, WI", broadcast: "NBC",
                tomorrow: false, channel: 1007),
        Fixture(league: "ncaaf", id: "407", away: ncaa("Alabama Crimson Tide", "ALA", "333", "9E1B32", "7-2"),
                home: ncaa("Georgia Bulldogs", "UGA", "61", "BA0C2F", "8-1"), hours: 1.0, state: "pre",
                status: "8:00 PM", awayScore: "", homeScore: "",
                venue: "Sanford Stadium", location: "Athens, GA", broadcast: "ABC",
                tomorrow: false, channel: nil),
        Fixture(league: "nfl", id: "408", away: nfl("Dallas Cowboys", "DAL", "003594", "7-6"),
                home: nfl("Philadelphia Eagles", "PHI", "004C54", "10-3"), hours: 1.5, state: "pre",
                status: "8:20 PM", awayScore: "", homeScore: "",
                venue: "Lincoln Financial Field", location: "Philadelphia, PA", broadcast: "NBC",
                tomorrow: false, channel: 1006),
        Fixture(league: "mlb", id: "409", away: mlb("Los Angeles Dodgers", "LAD", "005A9C", "98-64"),
                home: mlb("San Diego Padres", "SD", "2F241D", "90-72"), hours: 2.5, state: "pre",
                status: "9:40 PM", awayScore: "", homeScore: "",
                venue: "Petco Park", location: "San Diego, CA", broadcast: "TBS",
                tomorrow: false, channel: 1008),
        Fixture(league: "nhl", id: "410", away: nhl("Edmonton Oilers", "EDM", "041E42", "33-17-5"),
                home: nhl("Vegas Golden Knights", "VGK", "B4975A", "30-19-6"), hours: 3.0, state: "pre",
                status: "10:00 PM", awayScore: "", homeScore: "",
                venue: "T-Mobile Arena", location: "Las Vegas, NV", broadcast: "ESPN+",
                tomorrow: false, channel: nil),
        Fixture(league: "nfl", id: "411", away: nfl("San Francisco 49ers", "SF", "AA0000", "9-4"),
                home: nfl("Seattle Seahawks", "SEA", "002244", "8-5"), hours: 21.5, state: "pre",
                status: "4:25 PM", awayScore: "", homeScore: "",
                venue: "Lumen Field", location: "Seattle, WA", broadcast: "FOX",
                tomorrow: true, channel: nil),
        Fixture(league: "mlb", id: "412", away: mlb("Chicago Cubs", "CHC", "0E3386", "88-74"),
                home: mlb("Milwaukee Brewers", "MIL", "12284B", "93-69"), hours: 19.0, state: "pre",
                status: "2:10 PM", awayScore: "", homeScore: "",
                venue: "American Family Field", location: "Milwaukee, WI", broadcast: "ESPN",
                tomorrow: true, channel: nil),
        Fixture(league: "nba", id: "413", away: nba("Denver Nuggets", "DEN", "0E2240", "41-21"),
                home: nba("Phoenix Suns", "PHX", "1D1160", "33-29"), hours: 24.0, state: "pre",
                status: "9:00 PM", awayScore: "", homeScore: "",
                venue: "Footprint Center", location: "Phoenix, AZ", broadcast: "ESPN",
                tomorrow: true, channel: nil),
    ]

    static let followed: [FollowedTeam] = [
        followedTeam("nfl", fixtures[0].home, minutesAgo: 300),
        followedTeam("nba", fixtures[2].home, minutesAgo: 200),
        followedTeam("mlb", fixtures[1].home, minutesAgo: 100),
    ]

    private static func followedTeam(_ league: String, _ team: Team, minutesAgo: Double) -> FollowedTeam {
        FollowedTeam(key: TeamChannelKey(league: league, abbreviation: team.abbreviation, name: team.name),
                     name: team.name, abbreviation: team.abbreviation, logo: team.logo,
                     followedAt: anchor.addingTimeInterval(-minutesAgo * 60))
    }

    // MARK: Responses

    static func response(for url: URL) -> (Data, String) {
        let host = url.host ?? ""
        let query = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        func value(_ name: String) -> String? { query.first { $0.name == name }?.value }
        if host == "sports.mateomedia.link" { return (json(schedule(day: value("date") ?? "")), "application/json") }
        if host == "site.api.espn.com" { return (json(ufc(day: value("dates") ?? "")), "application/json") }
        if url.path.hasSuffix("xmltv.php") { return (Data(xmltv().utf8), "application/xml") }
        switch value("action") {
        case "get_live_categories": return (json(categories), "application/json")
        case "get_live_streams": return (json(streams), "application/json")
        default: return (json(authentication), "application/json")
        }
    }

    private static func json(_ object: Any) -> Data {
        (try? JSONSerialization.data(withJSONObject: object)) ?? Data("{}".utf8)
    }

    private static func dayString(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd"
        return formatter.string(from: date)
    }

    private static func iso(_ date: Date) -> String {
        ISO8601DateFormatter().string(from: date)
    }

    private static func start(_ fixture: Fixture) -> Date {
        anchor.addingTimeInterval(fixture.hours * 3600)
    }

    private static func schedule(day: String) -> [String: Any] {
        let today = dayString(anchor)
        let tomorrow = dayString(anchor.addingTimeInterval(24 * 3600))
        var leagues: [String: [[String: Any]]] = ["nfl": [], "nba": [], "nhl": [], "mlb": [], "ncaaf": []]
        for fixture in fixtures where (day == today && !fixture.tomorrow) || (day == tomorrow && fixture.tomorrow) {
            leagues[fixture.league, default: []].append([
                "id": fixture.id, "start": iso(start(fixture)),
                "awayTeam": fixture.away.name, "homeTeam": fixture.home.name,
                "awayAbbreviation": fixture.away.abbreviation, "homeAbbreviation": fixture.home.abbreviation,
                "awayLogo": fixture.away.logo, "homeLogo": fixture.home.logo,
                "awayScore": fixture.awayScore, "homeScore": fixture.homeScore,
                "awayColor": fixture.away.color, "homeColor": fixture.home.color,
                "awayRecord": fixture.away.record, "homeRecord": fixture.home.record,
                "venue": fixture.venue, "location": fixture.location,
                "status": fixture.status, "state": fixture.state, "broadcast": fixture.broadcast
            ])
        }
        return ["schema": 2, "date": day, "leagues": leagues, "failedLeagues": [String]()]
    }

    private static func ufc(day: String) -> [String: Any] {
        guard day == dayString(anchor) else { return ["events": [[String: Any]]()] }
        let start = iso(anchor.addingTimeInterval(1.25 * 3600))
        let status: [String: Any] = ["type": ["state": "pre", "description": "Scheduled", "shortDetail": "Tonight"]]
        func fighter(_ side: String, _ name: String, _ record: String) -> [String: Any] {
            ["homeAway": side, "athlete": ["displayName": name], "score": "", "records": [["summary": record]]]
        }
        let competition: [String: Any] = [
            "competitors": [fighter("away", "Brandon Royval", "17-8-0"), fighter("home", "Manel Kape", "20-7-0")],
            "status": status, "broadcasts": [["names": ["ESPN+"]]],
            "venue": ["fullName": "UFC APEX", "address": ["city": "Las Vegas", "state": "NV"]],
            "matchNumber": 1
        ]
        return ["events": [[
            "id": "600051", "name": "UFC Fight Night: Royval vs. Kape", "shortName": "Royval vs. Kape",
            "date": start, "status": status, "competitions": [competition]
        ]]]
    }

    private static let authentication: [String: Any] = [
        "user_info": ["auth": 1, "status": "Active", "exp_date": "1893456000", "max_connections": "2"],
        "server_info": ["url": "harness.lineup.test", "port": "80"]
    ]

    private static let categories: [[String: Any]] = [
        ["category_id": "10", "category_name": "USA | SPORTS EVENTS", "parent_id": 0],
        ["category_id": "11", "category_name": "USA | NETWORKS", "parent_id": 0]
    ]

    private static let networks: [(Int, String, String)] = [
        (2001, "US| CBS HD", "cbs.us"), (2002, "US| ESPN HD", "espn.us"), (2003, "US| FOX HD", "fox.us"),
        (2004, "US| NBC HD", "nbc.us"), (2005, "US| ABC HD", "abc.us"), (2006, "US| TBS HD", "tbs.us")
    ]

    private static func eventChannelName(_ fixture: Fixture) -> String {
        "US| \(fixture.league.uppercased()) \(fixture.channel.map { String($0 % 100) } ?? ""): \(fixture.away.name) vs \(fixture.home.name)"
    }

    private static var streams: [[String: Any]] {
        var rows: [[String: Any]] = []
        for fixture in fixtures {
            guard let channel = fixture.channel else { continue }
            rows.append(["num": channel, "name": eventChannelName(fixture), "stream_type": "live",
                         "stream_id": channel, "stream_icon": "", "epg_channel_id": "event\(channel).us",
                         "category_id": "10"])
        }
        for (id, name, epg) in networks {
            rows.append(["num": id, "name": name, "stream_type": "live", "stream_id": id,
                         "stream_icon": "", "epg_channel_id": epg, "category_id": "11"])
        }
        return rows
    }

    private static func stamp(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyyMMddHHmmss"
        return formatter.string(from: date) + " +0000"
    }

    private static func escape(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
    }

    private static func programme(_ channel: String, _ from: Date, _ to: Date, _ title: String, _ detail: String) -> String {
        "<programme start=\"\(stamp(from))\" stop=\"\(stamp(to))\" channel=\"\(channel)\"><title>\(escape(title))</title><desc>\(escape(detail))</desc></programme>"
    }

    private static func xmltv() -> String {
        var lines = ["<?xml version=\"1.0\" encoding=\"UTF-8\"?>", "<tv>"]
        let leagueNames = ["nfl": "NFL Football", "nba": "NBA Basketball", "mlb": "MLB Baseball",
                           "nhl": "NHL Hockey", "ncaaf": "College Football"]
        for fixture in fixtures {
            guard let channel = fixture.channel else { continue }
            let id = "event\(channel).us"
            let kickoff = start(fixture)
            let title = "\(leagueNames[fixture.league] ?? "Sports"): \(fixture.away.name) at \(fixture.home.name)"
            lines.append(programme(id, kickoff.addingTimeInterval(-5400), kickoff.addingTimeInterval(-1800),
                                   "Pregame", "Build-up to \(fixture.away.name) at \(fixture.home.name)."))
            lines.append(programme(id, kickoff.addingTimeInterval(-1800), kickoff.addingTimeInterval(4 * 3600),
                                   title, "Live from \(fixture.venue)."))
        }
        for (_, name, epg) in networks {
            var slot = anchor.addingTimeInterval(-3 * 3600)
            while slot < anchor.addingTimeInterval(30 * 3600) {
                lines.append(programme(epg, slot, slot.addingTimeInterval(7200), "\(name.dropFirst(4)) Sports Tonight",
                                       "Highlights and analysis."))
                slot = slot.addingTimeInterval(7200)
            }
        }
        lines.append("</tv>")
        return lines.joined(separator: "\n")
    }
}
