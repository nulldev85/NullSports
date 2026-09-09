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
        print("Professional matchup regression checks passed")
    }
}
