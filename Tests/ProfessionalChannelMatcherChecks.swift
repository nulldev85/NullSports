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
        print("Professional matchup regression checks passed")
    }
}
