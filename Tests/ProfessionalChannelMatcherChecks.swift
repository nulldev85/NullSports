import Foundation

@main
enum ProfessionalChannelMatcherChecks {
    static func main() {
        typealias Matcher = ProfessionalChannelMatcher
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        let game = Matcher.Matchup(away: "New York Yankees", home: "Boston Red Sox",
            awayAbbreviation: "NYY", homeAbbreviation: "BOS", start: start, isLive: true)
        let now = start.addingTimeInterval(3600)
        func listing(_ title: String, from: TimeInterval = 0, to: TimeInterval = 10800) -> Matcher.Listing {
            .init(title: title, detail: "", start: start.addingTimeInterval(from), end: start.addingTimeInterval(to))
        }
        func score(_ channel: String = "US: ESPN FHD", _ listings: [Matcher.Listing] = []) -> Int? {
            Matcher.score(channel: channel, listings: listings, game: game, now: now)
        }
        precondition(score() == nil, "Network alone must not authorize a matchup")
        precondition(score("MLB Yankees") == nil, "One team alone must not choose an opponent")
        precondition(score("MLB Yankees vs Red Sox") != nil, "Explicit event feed works without EPG")
        precondition(score("MLB NYY @ BOS") != nil, "Whole team abbreviations are accepted")
        precondition(score("MLB NYYY @ BOSS") == nil, "Abbreviations must not match substrings")
        precondition(score("ESPN", [listing("Yankees vs Red Sox")]) != nil, "Current matchup can identify a generic network")
        precondition(score("ESPN", [listing("Yankees vs Red Sox", from: 14400, to: 25200)]) == nil,
                     "Tonight's game cannot authorize what is playing now")
        precondition(score("ESPN", [listing("Yankees vs Red Sox", from: -10800, to: 0)]) == nil,
                     "Earlier game cannot identify current coverage")
        precondition(score("ESPN", [listing("Yankees vs Dodgers"), listing("Red Sox vs Mets", from: 14400, to: 25200)]) == nil,
                     "Teams across different listings must not combine into one matchup")
        precondition(score("Yankees vs Red Sox", [listing("Dodgers vs Mets")]) == nil,
                     "Fresh contradictory EPG overrides an event channel name")
        precondition(score("ESPN", [listing("Yankees vs Red Sox Highlights")]) == nil,
                     "Highlights are not a live feed")
        precondition(score("Yankees vs Red Sox Replay") == nil, "Replay channels are rejected")
        precondition(score("ESPN", [listing("Yankees vs Red Sox", from: 3500)]) == nil,
                     "A later doubleheader listing must not match the first game's start")
        let listingNow = listing("Yankees vs Red Sox", to: 4000)
        precondition(score("ESPN", [listingNow]) != nil)
        precondition(Matcher.score(channel: "ESPN", listings: [listingNow], game: game,
            now: start.addingTimeInterval(4000)) == nil, "Selection revalidation expires at program end")

        // A national channel's guide schedules a game; it does not promise the
        // channel stays on it. MLB Network listed Rangers at Mariners while it
        // was cutting to another game's ninth inning, so a channel named for the
        // matchup has to outrank a channel the guide merely schedules it on.
        let dedicated = score("MLB 02 | New York Yankees at Boston Red Sox AWAY @ 9 Sep 01:10 PM ET")
        let national = score("US: MLB Network", [listing("Yankees vs Red Sox")])
        precondition(dedicated != nil && national != nil, "Both channels still match")
        precondition(dedicated! > national!, "A channel named for the game outranks a national guide listing")
        precondition(score("MLB 02 | Yankees at Red Sox", [listing("Yankees vs Red Sox")])! > national!,
                     "A named feed whose guide agrees still outranks the national channel")

        // Whip-around channels cut between games by design.
        precondition(score("US: MLB Network Strike Zone", [listing("Yankees vs Red Sox")]) == nil,
                     "Strike Zone is never carrying one game")
        precondition(score("US: MLB Big Inning", [listing("Yankees vs Red Sox")]) == nil,
                     "Big Inning is never carrying one game")
        precondition(score("US: NFL RedZone", [listing("Yankees vs Red Sox")]) == nil,
                     "RedZone is never carrying one game")

        // NHL feed quality --------------------------------------------------
        // Provider EPGs sometimes attach an NHL matchup to DAZN UK's linear
        // channels even though those services do not carry the game. NHL
        // policy filters that false destination only after matchup evidence is
        // established, then favors the broadcaster named by the schedule.
        precondition(NHLChannelPolicy.adjustedScore(400, channel: "UK: DAZN 1 FHD",
                                                    broadcast: "NHL NET") == nil,
                     "DAZN UK is not an automatic NHL game feed")
        precondition(NHLChannelPolicy.adjustedScore(400, channel: "DAZN UK 2",
                                                    broadcast: "Sportsnet") == nil,
                     "DAZN UK is rejected regardless of token order")
        precondition(NHLChannelPolicy.adjustedScore(nil, channel: "US: NHL Network",
                                                    broadcast: "NHL NET") == nil,
                     "A broadcaster name without matchup evidence is still insufficient")
        let nhlNetwork = NHLChannelPolicy.adjustedScore(300, channel: "US: NHL Network FHD",
                                                        broadcast: "NHL NET")
        let genericNHL = NHLChannelPolicy.adjustedScore(300, channel: "US: Sports Alternate 4",
                                                       broadcast: "NHL NET")
        precondition(nhlNetwork != nil && genericNHL != nil && nhlNetwork! > genericNHL!,
                     "The schedule's named NHL broadcaster wins an evidence tie")
        precondition(NHLChannelPolicy.adjustedScore(300, channel: "CA: DAZN 1",
                                                    broadcast: "") != nil,
                     "Only the specifically unsupported UK variant is excluded")

        precondition(NFLRedZoneChannelMatcher.score(channel: "US: NFL RedZone FHD") != nil,
                     "The dedicated RedZone event selects a RedZone channel")
        precondition(NFLRedZoneChannelMatcher.score(channel: "US: NFL Network") == nil,
                     "NFL Network is not RedZone")
        precondition(NFLRedZoneChannelMatcher.score(channel: "NFL RedZone Replay") == nil,
                     "A replay is not the live Sunday feed")
        // Event-only Channels vetoes otherwise matching EPG when a provider
        // assigns one game's listing to another team's or sport's feed.
        let prepared = Matcher.prepare(game)
        let participants = Set(prepared.away + prepared.home)
        let knownTeams = ["New York Yankees", "Boston Red Sox", "New York Mets"].map {
            EventChannelEvidence.Team(name: $0, abbreviation: "", nicknames: true)
        }
        func allows(_ channel: String, category: String = "", league: String = "mlb") -> Bool {
            EventChannelEvidence.allowsSource(league: league, channel: channel, category: category,
                date: start, participants: participants, teams: knownTeams)
        }
        precondition(allows("US: MLB Boston Red Sox FHD"), "A participant's feed remains eligible with proper EPG")
        precondition(!allows("US: MLB New York Mets 4K"), "Another team's feed cannot borrow the same EPG")
        precondition(!allows("US: NFL Network 4K"), "Another sport cannot borrow the same EPG")
        precondition(!allows("US: CNN International"), "A news channel cannot borrow the same EPG")
        precondition(!allows("US: ESPN", category: "Kids"), "A non-sports category is not event evidence")
        precondition(!allows("US: NBA Basketball", league: "wnba"), "Specific league evidence beats a broad sport token")
        precondition(!allows("US: ATP Tennis", league: "wta"), "The other tour's explicit label is contradictory")
        precondition(allows("US: ESPN", category: "MLB / NBA"), "A multi-sport category may include this league")
        precondition(allows("US: NASCAR", category: "NASCAR Cup Series", league: "nascar"), "Cup Series is not a TV-series category")
        precondition(!allows("MLB Yankees vs Red Sox 2016"), "Historical names do not identify this live game")
        for title in ["SportsCenter", "Sports Center: Yankees vs Red Sox", "Yankees vs Red Sox Highlights"] {
            precondition(!EventChannelEvidence.allowsProgram(title: title, detail: "Yankees vs Red Sox", league: "mlb", date: start))
        }
        precondition(!EventChannelEvidence.isGenericTitle("MLB Tonight", league: "mlb"), "A studio title requires title-only event proof")
        precondition(EventChannelEvidence.isGenericTitle("Live MLB Baseball", league: "mlb"))
        precondition(EventChannelEvidence.allowsProgram(title: "MLB Baseball", detail: "Yankees vs Red Sox", league: "mlb", date: start))
        precondition(!EventChannelEvidence.allowsProgram(title: "MLB Baseball", detail: "Highlights: Yankees vs Red Sox", league: "mlb", date: start))
        precondition(EventChannelEvidence.namesMatchup("NBA: Magic vs Heat"))
        precondition(EventChannelEvidence.namesMatchup("Soccer England at France"))
        precondition(!EventChannelEvidence.namesMatchup("US: AT&T SportsNet"))
        precondition(!EventChannelEvidence.namesMatchup("PT: V Sports"))
        precondition(!EventChannelEvidence.allowsSoccerContext("Soccer Womens", women: false))
        precondition(!EventChannelEvidence.allowsSoccerContext("Soccer U21", women: false))
        precondition(!EventChannelEvidence.allowsSoccerContext("Mens Soccer", women: true))
        precondition(EventChannelEvidence.allowsSoccerContext("Sky Sports Football", women: true))
        precondition(!EventChannelEvidence.allowsRacingSession("F1 Austin Qualifying", session: "Race"))
        precondition(!EventChannelEvidence.allowsRacingSession("F1 Austin Practice 1", session: "Practice 2"))
        precondition(!EventChannelEvidence.allowsRacingSession("F1 Austin Qualifying", session: "Sprint Qualifying"))
        precondition(EventChannelEvidence.allowsRacingSession("Sky Sports F1", session: "Race"))
        precondition(EventChannelEvidence.allowsRacingSession("F1 Austin Sprint Qualifying", session: "Sprint Qualifying"))
        print("Professional matchup and event evidence regression checks passed")
    }
}
