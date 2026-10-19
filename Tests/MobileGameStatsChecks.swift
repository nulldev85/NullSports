import Foundation

@main
struct MobileGameStatsChecks {
    static func main() throws {
        func check(_ condition: Bool, _ message: String) { precondition(condition, message) }
        let t0 = Date(timeIntervalSince1970: 1_800_000_000)
        func iso(_ date: Date) -> String { ISO8601DateFormatter().string(from: date) }

        // A basketball reply as ESPN shapes it, trimmed to what is read.
        func basketball(away: Int, home: Int, clock: String, plays: [(id: String, seq: Int, at: Date, away: Int, home: Int, scoring: Bool)],
                        received: Date, extra: String = "") -> GameStatsReport? {
            let playJSON = plays.map { play in
                #"{"id":"\#(play.id)","sequenceNumber":"\#(play.seq)","text":"Play \#(play.id)","period":{"number":3,"displayValue":"3rd Quarter"},"clock":{"displayValue":"4:21"},"wallclock":"\#(iso(play.at))","scoringPlay":\#(play.scoring),"awayScore":\#(play.away),"homeScore":\#(play.home),"team":{"id":"2"}}"#
            }.joined(separator: ",")
            let body = #"""
            {"header":{"competitions":[{"competitors":[
              {"homeAway":"home","score":"\#(home)","team":{"id":"1","abbreviation":"BOS","displayName":"Boston Celtics","color":"008348","logos":[{"href":"https://a.espncdn.com/bos.png"}]}},
              {"homeAway":"away","score":"\#(away)","team":{"id":"2","abbreviation":"NY","displayName":"New York Knicks","color":"1d428a"}}],
              "status":{"displayClock":"\#(clock)","period":3,"type":{"state":"in","shortDetail":"\#(clock) - 3rd"}}}]},
             "boxscore":{"teams":[
               {"team":{"id":"2"},"statistics":[{"label":"FG","displayValue":"30-60"},{"label":"Rebounds","displayValue":"40"}]},
               {"team":{"id":"1"},"statistics":[{"label":"FG","displayValue":"28-61"},{"label":"Rebounds","displayValue":"38"},{"label":"Only Home","displayValue":"1"}]}]},
             "leaders":[{"team":{"id":"1"},"leaders":[{"displayName":"Points","leaders":[{"displayValue":"29","athlete":{"shortName":"J. Tatum"}}]}]}],
             "winprobability":[{"playId":"p2","homeWinPercentage":0.62}],
             "plays":[\#(playJSON)]\#(extra)}
            """#
            return GameStatsParser.parse(Data(body.utf8), sport: "basketball", receivedAt: received)
        }

        // Reading.
        let first = basketball(away: 50, home: 48, clock: "4:52",
                               plays: [("p1", 1, t0.addingTimeInterval(-600), 48, 48, false),
                                       ("p2", 2, t0.addingTimeInterval(-20), 50, 48, true)],
                               received: t0)!
        check(first.away.abbreviation == "NY" && first.home.abbreviation == "BOS", "Sides come from homeAway")
        check(first.home.logo == "https://a.espncdn.com/bos.png", "A team's logo is read from its logos")
        check(first.snapshot.awayScore == 50 && first.snapshot.homeScore == 48, "Scores are read")
        check(first.snapshot.lines == [GameStatsLine(label: "FG", away: "30-60", home: "28-61"),
                                       GameStatsLine(label: "Rebounds", away: "40", home: "38")],
              "Totals pair the two sides by team, and only shared ones are kept")
        check(first.snapshot.leaders.first?.athlete == "J. Tatum", "Leaders are read")
        check(first.plays.map(\.id) == ["p1", "p2"] && first.plays[1].scoring, "Plays are read oldest first")
        check(first.plays[0].period == "Q3", "Basketball periods read as quarters")
        check(first.winProbability["p2"] == 0.62, "Win probability is read by play")
        check(GameStatsParser.parse(Data("{}".utf8), sport: "basketball", receivedAt: t0) == nil,
              "A reply with no teams says nothing")
        check(GameStatsParser.periodLabel(sport: "baseball", number: 7, half: "Bottom") == "Bot 7th", "Innings")
        check(GameStatsParser.periodLabel(sport: "hockey", number: 4, half: nil) == "OT", "Hockey overtime")
        check(GameStatsParser.periodLabel(sport: "football", number: 5, half: nil) == "OT", "Football overtime")

        // Holding back.
        var timeline = GameStatsTimeline()
        timeline.ingest(first)
        let delay: TimeInterval = 40
        // Opened just now: the totals are as of now, ahead of a picture 40 s
        // behind, so none can be shown yet.
        let opening = timeline.reveal(at: t0.addingTimeInterval(-delay))!
        check(opening.catchingUp && opening.lines.isEmpty, "Totals newer than the picture are held")
        check(opening.plays.map(\.id) == ["p1"], "An old play shows at once; one from 20 s ago is held")
        check(opening.awayScore == 48 && opening.homeScore == 48, "The score is the last shown play's, not the feed's")
        check(opening.homeWinProbability == nil, "Win probability waits for its play")

        // Twenty seconds on: the second play happened 40 s before the
        // picture's moment now, plus ESPN's allowance of 30 s -- still held.
        check(timeline.reveal(at: t0.addingTimeInterval(20 - delay))!.plays.count == 1,
              "A play stays held for ESPN's lag on top of the picture's")
        // Once the picture has reached the fetch, all of it shows.
        let reached = timeline.reveal(at: t0)!
        check(!reached.catchingUp && reached.lines.count == 2, "Totals show once the picture reaches their fetch")
        check(reached.plays.map(\.id) == ["p2", "p1"], "Plays show newest first")
        check(reached.awayScore == 50 && reached.homeWinProbability == 0.62, "Score and odds follow")

        // A score arrives ten seconds later in the next fetch.
        let second = basketball(away: 53, home: 48, clock: "4:32",
                                plays: [("p1", 1, t0.addingTimeInterval(-600), 48, 48, false),
                                        ("p2", 2, t0.addingTimeInterval(-20), 50, 48, true),
                                        ("p3", 3, t0.addingTimeInterval(5), 53, 48, true)],
                                received: t0.addingTimeInterval(10))!
        timeline.ingest(second)
        let before = timeline.reveal(at: t0.addingTimeInterval(9))!
        check(before.awayScore == 50 && !before.plays.contains { $0.id == "p3" },
              "A score is not shown a moment before the picture reaches it")
        let after = timeline.reveal(at: t0.addingTimeInterval(10))!
        check(after.awayScore == 53 && after.plays.first?.id == "p3", "It shows the moment the picture does")

        // The clock runs between fetches, for matching by eye.
        check(timeline.clock(at: t0) == "4:52", "The clock at a fetch is the fetch's")
        check(timeline.clock(at: t0.addingTimeInterval(5)) == "4:42", "Between fetches it runs on")
        check(timeline.clock(at: t0.addingTimeInterval(-1)) == nil, "Before any fetch there is none")

        // Calibrating from a score the viewer has just seen.
        let change = timeline.lastScoreChange(within: 300, now: t0.addingTimeInterval(50))
        check(change == t0, "A seen score sets the delay from the fetch before it, never short")
        check(timeline.lastScoreChange(within: 30, now: t0.addingTimeInterval(50)) == nil,
              "An old score is no guide")

        // A late, out-of-order reply is not taken as newer.
        let stale = basketball(away: 50, home: 48, clock: "4:52", plays: [], received: t0.addingTimeInterval(5))!
        timeline.ingest(stale)
        check(timeline.snapshots.count == 2, "An overtaken reply is dropped")

        // The delay a viewer sets is kept for the channel.
        let defaults = UserDefaults(suiteName: "MobileGameStatsChecks")!
        defaults.removePersistentDomain(forName: "MobileGameStatsChecks")
        let store = GameStatsDelayStore(defaults: defaults)
        check(store.delay(forChannel: 7) == (GameStatsDelayStore.defaultDelay, false), "Unset uses the default")
        store.set(32.4, forChannel: 7)
        check(store.delay(forChannel: 7) == (32, true), "A set delay is kept for its channel")
        check(store.delay(forChannel: 8) == (32, false), "Another channel starts from the last one set")
        store.set(900, forChannel: 7)
        check(store.delay(forChannel: 7).seconds == 300, "Delays are kept in range")
        print("MobileGameStatsChecks passed")
    }
}
