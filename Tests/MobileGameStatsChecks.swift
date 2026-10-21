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
        // ESPN's header at the same clock and score as the latest play: the
        // fetch stands for that play.
        let first = basketball(away: 50, home: 48, clock: "4:21",
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

        // Holding back: everything waits for the moment it happened, plus
        // how far the picture is behind live.
        var timeline = GameStatsTimeline()
        timeline.ingest(first)
        let delay: TimeInterval = 40
        // The box score in a fetch stands for its latest play, 20 s ago:
        // ahead of a picture 40 s behind, so it waits.
        let opening = timeline.reveal(at: t0.addingTimeInterval(-delay))!
        check(opening.catchingUp && opening.lines.isEmpty, "Totals the picture hasn't reached are held")
        check(opening.plays.map(\.id) == ["p1"], "An old play shows at once; one from 20 s ago is held")
        check(opening.awayScore == 48 && opening.homeScore == 48, "The score is the last shown play's, not the feed's")
        check(opening.homeWinProbability == nil, "Win probability waits for its play")
        check(timeline.reveal(at: t0.addingTimeInterval(-21))!.plays.count == 1,
              "A play is held to the second it happened")
        // The picture reaches the second play: it, and the totals that came
        // with it, show together.
        let reached = timeline.reveal(at: t0.addingTimeInterval(-20))!
        check(!reached.catchingUp && reached.lines.count == 2, "Totals show with the play they came with")
        check(reached.plays.map(\.id) == ["p2", "p1"], "Plays show newest first")
        check(reached.awayScore == 50 && reached.homeWinProbability == 0.62, "Score and odds follow")

        // A score, five seconds after the first fetch, in the next one.
        let second = basketball(away: 53, home: 48, clock: "4:21",
                                plays: [("p1", 1, t0.addingTimeInterval(-600), 48, 48, false),
                                        ("p2", 2, t0.addingTimeInterval(-20), 50, 48, true),
                                        ("p3", 3, t0.addingTimeInterval(5), 53, 48, true)],
                                received: t0.addingTimeInterval(10))!
        timeline.ingest(second)
        let before = timeline.reveal(at: t0.addingTimeInterval(4))!
        check(before.awayScore == 50 && !before.plays.contains { $0.id == "p3" },
              "A score is not shown a moment before the picture reaches it")
        let after = timeline.reveal(at: t0.addingTimeInterval(5))!
        check(after.awayScore == 53 && after.plays.first?.id == "p3", "It shows the moment the picture does")

        // Syncing steps through the plays by the moment they happened.
        check(timeline.timedPlays.map(\.id) == ["p1", "p2", "p3"], "Plays to sync by, oldest first")
        check(timeline.latestTimedPlay(at: t0)?.id == "p2", "The play to ask about is the latest one shown")
        check(timeline.timedPlay(after: timeline.timedPlays[1])?.id == "p3", "Already seen steps to the next")
        check(timeline.timedPlay(after: timeline.timedPlays[2]) == nil, "No play after the latest")
        check(GameStatsTimeline.delay(syncingTo: timeline.timedPlays[1], now: t0.addingTimeInterval(40)) == 60,
              "Seen now, a play from a minute ago means a stream a minute behind")
        let synced = timeline.reveal(at: t0.addingTimeInterval(40 - 60))!
        check(synced.plays.first?.id == "p2", "Synced to a play, that play is the latest shown")

        // A late, out-of-order reply is not taken as newer.
        let stale = basketball(away: 50, home: 48, clock: "4:52", plays: [], received: t0.addingTimeInterval(5))!
        timeline.ingest(stale)
        check(timeline.snapshots.count == 2, "An overtaken reply is dropped")
        // A reply without plays stands for when it came, never earlier.
        let bare = basketball(away: 53, home: 48, clock: "4:12", plays: [], received: t0.addingTimeInterval(20))!
        timeline.ingest(bare)
        check(timeline.snapshots.last?.moment == t0.addingTimeInterval(20), "Totals without plays wait for their fetch")

        // ESPN's score and clock run ahead of its plays. A fetch past its
        // latest play is held to when it came, not to that play: shown at
        // the play's moment, it put a basket on screen before the picture.
        let ahead = basketball(away: 56, home: 48, clock: "4:02",
                               plays: [("p1", 1, t0.addingTimeInterval(-600), 48, 48, false),
                                       ("p2", 2, t0.addingTimeInterval(-20), 50, 48, true),
                                       ("p3", 3, t0.addingTimeInterval(5), 53, 48, true)],
                               received: t0.addingTimeInterval(30))!
        var leading = GameStatsTimeline()
        leading.countsDown = true
        leading.ingest(second)
        leading.ingest(ahead)
        check(leading.snapshots.last?.moment == t0.addingTimeInterval(30) && leading.snapshots.last?.timedByFetch == true,
              "A fetch ahead of its plays waits for its own moment")
        let early = leading.reveal(at: t0.addingTimeInterval(10))!
        check(early.awayScore == 53 && early.status == "4:21 - 3rd",
              "Until then, the score and clock are the latest play's, not the feed's")
        let caughtUp = leading.reveal(at: t0.addingTimeInterval(30))!
        check(caughtUp.awayScore == 56 && caughtUp.status == "4:02 - 3rd", "Then the fetch's own")
        // A fetch held to when it came is behind the picture: a play shown
        // since, later in the game, gives the clock.
        let behind = basketball(away: 50, home: 48, clock: "4:52",
                                plays: [("p2", 2, t0.addingTimeInterval(-30), 50, 48, true)], received: t0)!
        var trailing = GameStatsTimeline()
        trailing.countsDown = true
        trailing.ingest(behind)
        check(trailing.snapshots.last?.timedByFetch == true, "Another clock than its play's")
        check(trailing.reveal(at: t0)!.status == "4:21 - 3rd", "The later clock of the two, never one still to come")
        check(GameStatsTimeline.gameSeconds("35.5") == 35.5 && GameStatsTimeline.gameSeconds("4:21") == 261,
              "A clock under a minute reads with its tenths")

        // The delay a viewer sets is kept for the channel.
        let defaults = UserDefaults(suiteName: "MobileGameStatsChecks")!
        defaults.removePersistentDomain(forName: "MobileGameStatsChecks")
        let store = GameStatsDelayStore(defaults: defaults)
        check(store.delay(forChannel: 7) == (GameStatsDelayStore.Kind.plays.defaultDelay, false), "Unset uses the default")
        store.set(32.4, forChannel: 7)
        check(store.delay(forChannel: 7) == (32, true), "A set delay is kept for its channel")
        check(store.delay(forChannel: 8) == (32, false), "Another channel starts from the last one set")
        store.set(900, forChannel: 7)
        check(store.delay(forChannel: 7).seconds == 600, "Delays are kept in range")
        // Tennis is held by a delay of its own, unset at nothing: a game
        // reaches ESPN only after its last point.
        let tennis = GameStatsDelayStore(defaults: defaults, kind: .tennis)
        check(tennis.delay(forChannel: 7) == (0, false), "Tennis shows as ESPN has it until synced")
        tennis.set(14, forChannel: 7)
        check(tennis.delay(forChannel: 7) == (14, true), "A tennis delay is kept for its channel")
        check(store.delay(forChannel: 7).seconds == 600, "Tennis syncing leaves the channel's play delay alone")
        check(GameStatsDelayStore(defaults: defaults, kind: .fights).delay(forChannel: 7) == (60, false),
              "A fight card keeps its own default")
        print("MobileGameStatsChecks passed")
    }
}
