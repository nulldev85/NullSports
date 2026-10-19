import Foundation

/// The team page's parsing, against small copies of what ESPN sends
/// (October 2026): a team, its schedule, a grouped and a flat roster, a
/// standings tree, and news.
@main
struct MobileTeamPageChecks {
    static func data(_ json: String) -> Data { Data(json.utf8) }

    static func main() {
        let path = TeamPagePath(sport: "football", league: "nfl", teamID: "12")
        precondition(path.team?.absoluteString == "https://site.api.espn.com/apis/site/v2/sports/football/nfl/teams/12")
        precondition(path.schedules.count == 1)
        precondition(TeamPagePath(sport: "soccer", league: "eng.1", teamID: "359").schedules.last?.query == "fixture=true",
                     "Soccer's fixtures to come are a list of their own")
        precondition(path.standings?.absoluteString == "https://site.api.espn.com/apis/v2/sports/football/nfl/standings")

        let info = TeamPageParser.info(data("""
        {"team":{"id":"2","displayName":"Boston Celtics","abbreviation":"BOS","color":"008348",
         "logos":[{"href":"https://a.espncdn.com/i/teamlogos/nba/500/bos.png"}],
         "record":{"items":[{"description":"Overall Record","type":"total","summary":"4-0"},
                            {"description":"Home Record","type":"home","summary":"2-0"}]},
         "standingSummary":"1st in Atlantic Division"}}
        """))
        precondition(info == TeamPageInfo(name: "Boston Celtics", abbreviation: "BOS",
                                          logo: "https://a.espncdn.com/i/teamlogos/nba/500/bos.png", color: "008348",
                                          record: "4-0", standing: "1st in Atlantic Division"))

        let schedule = TeamPageParser.schedule([data("""
        {"events":[
         {"id":"2","date":"2026-10-26T17:00Z","week":{"text":"Week 8"},"competitions":[{"date":"2026-10-26T17:00Z",
          "status":{"type":{"state":"pre","completed":false,"shortDetail":"10/26 - 1:00 PM EDT"}},
          "broadcasts":[{"media":{"shortName":"CBS"}}],
          "competitors":[{"id":"12","homeAway":"away","team":{"id":"12","abbreviation":"KC"}},
                         {"id":"7","homeAway":"home","team":{"id":"7","displayName":"Denver Broncos","abbreviation":"DEN",
                          "logos":[{"href":"den.png"}]}}]}]},
         {"id":"1","date":"2026-10-12T20:25Z","week":{"text":"Week 6"},"competitions":[{"date":"2026-10-12T20:25Z",
          "status":{"type":{"state":"post","completed":true,"shortDetail":"Final"}},
          "competitors":[{"id":"12","homeAway":"home","winner":true,"score":{"value":22.0,"displayValue":"22"},
                          "team":{"id":"12","abbreviation":"KC"}},
                         {"id":"24","homeAway":"away","winner":false,"score":{"value":6.0,"displayValue":"6"},
                          "team":{"id":"24","displayName":"Los Angeles Chargers","abbreviation":"LAC"}}]}]}
        ]}
        """)], teamID: "12")
        precondition(schedule.map(\.id) == ["1", "2"], "Oldest first")
        let final = schedule[0], next = schedule[1]
        precondition(final.isFinished && final.outcome == .win && final.teamScore == "22" && final.opponentScore == "6")
        precondition(final.isHome && final.opponent == "Los Angeles Chargers" && final.label == "Week 6")
        precondition(!next.isFinished && !next.isHome && next.broadcast == "CBS" && next.opponentLogo == "den.png")
        // A game in two lists -- results and fixtures -- is listed once.
        let twice = TeamPageParser.schedule([data("{\"events\":[]}"), data("""
        {"events":[{"id":"9","date":"2026-08-21T19:00Z","league":{"abbreviation":"Premier League"},
         "competitions":[{"status":{"type":{"state":"post"}},
          "competitors":[{"id":"359","homeAway":"home","score":"3","team":{"id":"359"}},
                         {"id":"388","homeAway":"away","score":"0","team":{"id":"388","displayName":"Coventry City"}}]}]}]}
        """), data("""
        {"events":[{"id":"9","date":"2026-08-21T19:00Z","competitions":[{"status":{"type":{"state":"post"}},
          "competitors":[{"id":"359","homeAway":"home","score":"3"},{"id":"388","homeAway":"away","score":"0"}]}]}]}
        """)], teamID: "359")
        precondition(twice.count == 1 && twice[0].outcome == .win && twice[0].label == "Premier League",
                     "Scores as strings decide the result when no winner is marked")

        let standings = TeamPageParser.standings(data("""
        {"name":"National Basketball Association","children":[
         {"name":"Eastern Conference","standings":{"entries":[
          {"team":{"id":"18","displayName":"New York Knicks","abbreviation":"NY"},
           "stats":[{"name":"wins","displayValue":"1"},{"name":"losses","displayValue":"4"},
                    {"name":"winPercent","value":0.2,"displayValue":".200"},{"name":"gamesBehind","displayValue":"3.5"},
                    {"name":"playoffSeed","value":15,"displayValue":"15"}]},
          {"team":{"id":"2","displayName":"Boston Celtics","abbreviation":"BOS"},
           "stats":[{"name":"wins","displayValue":"4"},{"name":"losses","displayValue":"0"},
                    {"name":"winPercent","value":1.0,"displayValue":"1.000"},{"name":"gamesBehind","displayValue":"-"},
                    {"name":"playoffSeed","value":1,"displayValue":"1"}]}]}},
         {"name":"Western Conference","standings":{"entries":[{"team":{"id":"25"},"stats":[]}]}}]}
        """), teamID: "2", columns: TeamPageParser.columns(sport: "basketball", league: "nba"))
        precondition(standings?.group == "Eastern Conference", "The table the team is in")
        precondition(standings?.rows.map(\.id) == ["2", "18"], "In seed order")
        precondition(standings?.columns == ["W", "L", "PCT", "GB"])
        precondition(standings?.rows.first?.values == ["4", "0", "1.000", "-"])
        // College football names one record among several by its type.
        let college = TeamPageParser.standings(data("""
        {"name":"FBS","children":[{"name":"Southeastern Conference","standings":{"entries":[
         {"team":{"id":"61","abbreviation":"UGA"},"stats":[
          {"name":"overall","type":"total","displayValue":"6-1"},{"name":"Home","type":"homerecord","displayValue":"4-1"},
          {"name":"vs. Conf.","type":"vsconf","displayValue":"4-1"},
          {"name":"playoffSeed","type":"playoffseed","value":1},{"name":"playoffSeed","type":"homerecord_playoffseed","value":3}]}]}}]}
        """), teamID: "61", columns: TeamPageParser.columns(sport: "football", league: "college-football"))
        precondition(college?.rows.first?.values == ["4-1", "6-1"])
        precondition(TeamPageParser.standings(data("{\"children\":[]}"), teamID: "2", columns: []) == nil)

        let grouped = TeamPageParser.roster(data("""
        {"coach":[{"firstName":"Andy","lastName":"Reid"}],"athletes":[
         {"position":"offense","items":[
          {"id":"3","displayName":"Patrick Mahomes","jersey":"15","position":{"abbreviation":"QB"}},
          {"id":"4","displayName":"Jaylon Moore","jersey":"77","position":{"abbreviation":"OT"},
           "injuries":[{"status":"Questionable","date":"2026-10-18T22:41Z"}]}]},
         {"position":"injuredReserveOrOut","items":[
          {"id":"5","displayName":"Jeff Caldwell","jersey":"8","position":{"abbreviation":"WR"},
           "injuries":[{"status":"Injured Reserve","date":"2026-08-25T23:12Z"}]}]},
         {"position":"suspended","items":[]}]}
        """))
        precondition(grouped?.coach == "Andy Reid")
        precondition(grouped?.groups.map(\.title) == ["Offense", "Injured Reserve / Out"], "Empty groups are left out")
        precondition(grouped?.groups.first?.players.map(\.jersey) == ["15", "77"])
        precondition(grouped?.injured.map(\.name) == ["Jaylon Moore", "Jeff Caldwell"], "Latest report first")
        let flat = TeamPageParser.roster(data("""
        {"athletes":[
         {"id":"1","displayName":"Devin Carter","jersey":"99","position":{"displayName":"Guard","abbreviation":"G"}},
         {"id":"2","displayName":"Neemias Queta","jersey":"88","position":{"displayName":"Center","abbreviation":"C"}},
         {"id":"3","displayName":"Derrick White","jersey":"9","position":{"displayName":"Guard","abbreviation":"G"}}]}
        """))
        precondition(flat?.groups.map(\.title) == ["Guards", "Centers"])
        precondition(flat?.groups.first?.players.map(\.name) == ["Derrick White", "Devin Carter"], "By number")
        precondition(flat?.injured.isEmpty == true)

        let news = TeamPageParser.news(data("""
        {"articles":[{"id":48957095,"headline":"Grades for offseason signings","description":"We're grading them.",
          "published":"2026-10-19T13:31:46Z","images":[{"url":"https://a.espncdn.com/photo/x.jpg"}],
          "links":{"web":{"href":"https://www.espn.com/nba/story/_/id/48957095"}}},{"headline":""}]}
        """))
        precondition(news.count == 1 && news[0].id == "48957095" && news[0].image == "https://a.espncdn.com/photo/x.jpg")
        precondition(news[0].link?.host == "www.espn.com" && news[0].published != nil)
        precondition(TeamPageParser.date("2026-10-20T19:00Z") != nil && TeamPageParser.date("2026-10-19T13:31:46Z") != nil)
        print("Team page checks passed")
    }
}
