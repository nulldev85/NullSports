import Foundation

@main
enum CollegeChannelMatcherChecks {
    static func main() {
        typealias Matcher = CollegeChannelMatcher
        let kickoff = Date(timeIntervalSince1970: 1_000_000)
        let now = kickoff.addingTimeInterval(3600)
        var checks = 0
        func check(_ result: Bool, _ name: String) {
            precondition(result, name)
            checks += 1
        }
        func game(_ broadcast: String = "ESPN", away: String = "SMU Mustangs",
                  home: String = "Florida State Seminoles", awayShort: String = "SMU",
                  homeShort: String = "FSU", offset: Double = 0, live: Bool = true, status: String = "") -> Matcher.Matchup {
            .init(broadcast: broadcast, away: away, home: home, awayAbbreviation: awayShort,
                  homeAbbreviation: homeShort, kickoff: kickoff.addingTimeInterval(offset), isLive: live, status: status)
        }
        func listing(_ title: String, detail: String = "", offset: Double = 0, duration: Double = 10800) -> Matcher.Listing {
            .init(title: title, detail: detail, start: kickoff.addingTimeInterval(offset),
                  end: kickoff.addingTimeInterval(offset + duration))
        }
        func score(_ channel: String, _ listings: [Matcher.Listing] = [], broadcast: String = "ESPN",
                   time: Date? = nil, fallback: Bool = true) -> Int? {
            Matcher.score(channel: channel, listings: listings, game: game(broadcast), now: time ?? now, allowNetworkFallback: fallback)
        }
        let matchup = listing("SMU vs. Florida State")
        check(score("US: ESPN HD") != nil, "Reported ESPN case without EPG")
        check(score("US: ESPNHD") != nil, "Attached quality suffix")
        check(score("ESPN2HD") == nil, "Attached quality does not conflate networks")
        check(score("ESPN FHD", [matchup]) == 400, "Reported ESPN case with school names")
        check(score("ESPN", [listing("Southern Methodist at FSU")]) == 400, "School alias and abbreviation")
        check(score("ESPN", [listing("#12 SMU Mustangs @ #4 Florida State Seminoles")]) == 400, "Ranked full team names")
        check(score("ESPN", [listing("College Football", detail: "SMU faces Florida State in conference play")]) == 400, "Teams in description")
        check(score("ESPN", [listing("College Football")]) != nil, "Generic guide")
        check(score("ESPN", [listing("College Football", detail: "Live NCAA college football coverage")]) != nil, "Generic guide description")
        check(score("ESPN", [listing("No program information")]) != nil, "Guide placeholder")
        check(score("ESPN", [listing("SportsCenter")]) == nil, "Different active program")
        check(score("ESPN", [listing("Alabama vs Georgia")]) == nil, "Different active game")
        check(score("ESPN", [listing("College Football", detail: "Alabama vs Georgia")]) == nil, "Different game in description")
        check(score("ESPN", [listing("SMU vs Florida State", offset: 86400)]) == 100, "Tomorrow's guide cannot confirm today")
        check(score("ESPN", [listing("SMU vs Florida State", offset: -86400)]) == 100, "Yesterday's guide cannot confirm today")
        check(score("ESPN", [listing("SMU vs Florida State", duration: -1)]) == 100, "Invalid listing duration")
        check(score("ESPN", [matchup], time: kickoff.addingTimeInterval(4 * 3600)) == 400, "Live game running past guide end")
        check(score("ESPN", [matchup], time: kickoff.addingTimeInterval(5 * 3600)) == 100, "Overrun grace is bounded")
        for channel in ["ESPN2 HD", "ESPN 2", "ESPN+", "ESPN Plus", "ESPNU", "ESPNEWS", "FOX News", "ESPN Radio", "ESPN Deportes", "UK ESPN", "CA ESPN", "ESPN 01", "ESPN Alternate"] {
            check(score(channel) == nil, "No main ESPN fallback to " + channel)
        }
        check(score("ESPN2", [matchup]) == nil, "Team evidence cannot override a different advertised network")
        check(score("ESPN 2 HD", broadcast: "ESPN2") != nil, "Spaced ESPN2")
        check(score("FOX SPORTS 1 UHD", broadcast: "FS1") != nil, "FS1 alias")
        check(Matcher.networks("SEC Network+") == ["secplus"], "SEC multiplex distinct")
        check(Matcher.networks("ACC Network Extra") == ["accplus"], "ACC multiplex distinct")
        check(Matcher.networks("ESPN / ABC") == ["espn", "abc"], "Multiple advertised networks")
        check(score("ABC", [matchup], broadcast: "ESPN / ABC") == 400, "Simulcast verified affiliate")
        for network in ["ABC", "NBC", "FOX", "CBS", "BTN", "ESPN+", "Peacock", "CW"] {
            check(score(network, broadcast: network) == nil, network + " requires event evidence")
            check(score(network, [matchup], broadcast: network) == 400, network + " with guide evidence")
        }
        check(score("NCAAF 04: SMU vs FSU") == 200, "Dedicated event feed without guide")
        check(score("ESPN: SMU vs Virginia") == nil, "Other named event is not main ESPN")
        check(score("NCAAF SMU vs FSU", [listing("Alabama vs Georgia")]) == nil, "Stale event label cannot override active guide")
        check(score("Event 04", [matchup]) == 300, "Guide identifies unnamed event feed")
        check(score("ESPN", [listing("SMU vs Florida State Replay")]) == nil, "Replay rejected")
        check(score("College Basketball SMU vs FSU") == nil, "Basketball rejected")
        check(score("ESPN", [listing("Women's Soccer: SMU vs Florida State")]) == nil, "Same schools in another sport rejected")
        check(score("ESPN", [listing("SportsCenter", detail: "SMU vs Florida State preview")]) == nil, "Studio discussion is not the game")
        check(score("ESPN", [matchup], broadcast: "") == 300, "Guide match without broadcast metadata")
        check(score("ESPN", broadcast: "") == nil, "No blind match without metadata")

        check(Matcher.titleMatches("Washington State at Washington", away: "Washington State Cougars", home: "Washington Huskies"), "Similar schools")
        check(!Matcher.titleMatches("Washington State Cougars", away: "Washington State Cougars", home: "Washington Huskies"), "One school cannot supply both teams")
        check(!Matcher.titleMatches("Florida State vs Georgia", away: "Florida Gators", home: "Georgia Bulldogs"), "Florida is not Florida State")
        check(!Matcher.titleMatches("Virginia Tech vs SMU", away: "Virginia Cavaliers", home: "SMU Mustangs"), "Virginia is not Virginia Tech")
        check(!Matcher.titleMatches("West Virginia vs SMU", away: "Virginia Cavaliers", home: "SMU Mustangs"), "Virginia is not West Virginia")
        check(Matcher.titleMatches("Florida St. vs SMU", away: "Florida State Seminoles", home: "SMU Mustangs"), "State abbreviation")
        check(!Matcher.titleMatches("Tigers vs Bulldogs", away: "Clemson Tigers", home: "Georgia Bulldogs"), "Shared mascots are not school evidence")
        check(Matcher.titleMatches("Ohio State at Michigan", away: "Ohio State Buckeyes", home: "Michigan Wolverines"), "School names without mascots")
        check(Matcher.titleMatches("Central Florida vs Brigham Young", away: "UCF Knights", home: "BYU Cougars", awayAbbreviation: "UCF", homeAbbreviation: "BYU"), "Expanded abbreviations")
        check(!Matcher.titleMatches("Charity ball army deployment rice prices", away: "Ball State Cardinals", home: "Rice Owls"), "Unrelated prose")

        let main = Matcher.Candidate(id: 5, name: "ESPN HD", listings: [])
        let confirmed = Matcher.Candidate(id: 20, name: "ESPN FHD", listings: [matchup])
        let duplicate = Matcher.Candidate(id: 30, name: "ESPN UHD", listings: [matchup])
        let wrong = Matcher.Candidate(id: 1, name: "ESPN2", listings: [matchup])
        let unrelated = Matcher.Candidate(id: 2, name: "ESPN", listings: [listing("Alabama vs Georgia")])
        check(Matcher.select([main, confirmed, duplicate, wrong, unrelated], game: game(), now: now) == 20, "Best evidence wins; duplicate feeds allowed")
        check(Matcher.select([duplicate, confirmed, main], game: game(), now: now) == 20, "Provider ordering cannot change selection")
        check(Matcher.select([wrong, unrelated], game: game(), now: now) == nil, "All candidates invalid")
        check(Matcher.select([], game: game(), now: now) == nil, "Empty library")
        let rival = game("ESPN", away: "Alabama Crimson Tide", home: "Georgia Bulldogs", awayShort: "ALA", homeShort: "UGA")
        check(Matcher.allowsNetworkFallback(for: game(), slate: [game()]), "Only game safely uses network")
        check(!Matcher.allowsNetworkFallback(for: game(), slate: [game(), rival]), "Simultaneous same-network games require evidence")
        check(Matcher.allowsNetworkFallback(for: game(), slate: [game(), game("ESPN2", away: "Alabama", home: "Georgia")]), "Other network does not block ESPN")
        check(score("ESPN", fallback: false) == nil, "Ambiguous schedule disables fallback")
        check(score("ESPN", [matchup], fallback: false) == 400, "Explicit matchup survives schedule ambiguity")
        check(Matcher.select([confirmed, unrelated], game: rival, now: now, allowNetworkFallback: false) == 2, "Busy slate selects the other game")
        let tomorrow = game(offset: 86400, live: false)
        check(Matcher.allowsNetworkFallback(for: game(), slate: [game(), tomorrow]), "Next day does not conflict")
        let delayed = game(status: "Delayed - power outage")
        let longDelay = kickoff.addingTimeInterval(6 * 3600)
        let filler = listing("SportsCenter", offset: 5 * 3600)
        check(Matcher.score(channel: "ESPN", listings: [filler], game: delayed, now: longDelay) != nil, "Power outage allows announced ESPN despite filler guide")
        check(Matcher.score(channel: "ESPN", listings: [filler], game: game(), now: longDelay) == nil, "Filler exception requires reported delay")
        check(Matcher.score(channel: "ESPN", listings: [matchup, filler], game: delayed, now: longDelay) == 400, "Confirmed game remains matched through long delay")
        check(Matcher.score(channel: "ESPN", listings: [filler], game: game(live: false, status: "Delayed"), now: longDelay) != nil, "Pregame delay uses current guide")
        check(Matcher.score(channel: "ESPN2", listings: [filler], game: delayed, now: longDelay) == nil, "Delay cannot substitute ESPN2")
        check(Matcher.score(channel: "ESPN", listings: [filler], game: delayed, now: longDelay, allowNetworkFallback: false) == nil, "Delay does not override conflicting broadcast schedules")
        let otherGame = listing("Alabama vs Georgia", offset: 5 * 3600)
        check(Matcher.score(channel: "ESPN", listings: [matchup, otherGame], game: delayed, now: longDelay) == nil, "Current different game outranks old delayed listing")
        check(Matcher.score(channel: "ESPN", listings: [matchup], game: delayed, now: kickoff.addingTimeInterval(86400)) == nil, "Delay cannot preserve yesterday's match")
        check(!game(status: "Postponed after delay").isDelayed, "Postponement is not an active delay")
        check(!game(status: "Final after delay").isDelayed, "Final is not an active delay")
        print("\(checks) college channel matching checks passed")
    }
}
