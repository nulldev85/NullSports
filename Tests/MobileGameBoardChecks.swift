import Foundation

@main
struct MobileGameBoardChecks {
    static func main() throws {
        func check(_ condition: Bool, _ message: String) { precondition(condition, message) }
        let t0 = Date(timeIntervalSince1970: 1_800_000_000)
        func iso(_ date: Date) -> String { ISO8601DateFormatter().string(from: date) }

        // MARK: Soccer

        // A match as ESPN's summary shapes it: commentary for every moment,
        // key events for the goals, team totals by name.
        let soccer = #"""
        {"header":{"competitions":[{"competitors":[
          {"homeAway":"home","score":"1","team":{"id":"357","abbreviation":"LEE","displayName":"Leeds United","color":"ffffff"}},
          {"homeAway":"away","score":"2","team":{"id":"360","abbreviation":"MAN","displayName":"Manchester United","color":"da020e"}}],
          "status":{"period":2,"displayClock":"78'","type":{"state":"in","shortDetail":"78'"}}}]},
         "boxscore":{"teams":[
           {"team":{"id":"357"},"statistics":[{"name":"possessionPct","label":"Possession","displayValue":"61.3"},{"name":"totalShots","label":"SHOTS","displayValue":"12"},{"name":"passPct","label":"Pass Completion %","displayValue":"0.8"},{"name":"crossPct","label":"Cross %","displayValue":"0.1"}]},
           {"team":{"id":"360"},"statistics":[{"name":"possessionPct","label":"Possession","displayValue":"38.7"},{"name":"totalShots","label":"SHOTS","displayValue":"13"},{"name":"passPct","label":"Pass Completion %","displayValue":"0.74"},{"name":"crossPct","label":"Cross %","displayValue":"0.2"}]}]},
         "keyEvents":[
           {"id":"k1","type":{"type":"goal"},"text":"Goal! Leeds United 0, Manchester United 1. Mbeumo scores.","period":{"number":1},"clock":{"displayValue":"35'"},"scoringPlay":true,"team":{"id":"360"},"wallclock":"\#(iso(t0.addingTimeInterval(-3000)))"},
           {"id":"k3","type":{"type":"own-goal"},"text":"Own goal by Maguire.","period":{"number":2},"clock":{"displayValue":"70'"},"scoringPlay":true,"team":{"id":"360"},"wallclock":"\#(iso(t0.addingTimeInterval(-500)))"}],
         "commentary":[
           {"sequence":0,"text":"Lineups are announced."},
           {"sequence":1,"text":"First Half begins.","play":{"id":"k0","type":{"type":"kickoff"},"period":{"number":1},"clock":{"displayValue":""},"wallclock":"\#(iso(t0.addingTimeInterval(-5100)))"}},
           {"sequence":2,"text":"Goal! Leeds United 0, Manchester United 1. Bryan Mbeumo (Manchester United) left footed shot.","play":{"id":"k1","type":{"type":"goal"},"period":{"number":1},"clock":{"displayValue":"35'"},"team":{"displayName":"Manchester United"},"wallclock":"\#(iso(t0.addingTimeInterval(-3000)))"}},
           {"sequence":3,"text":"Corner, Leeds United. Conceded by Harry Maguire.","play":{"id":"k2","type":{"type":"corner-awarded"},"period":{"number":2},"clock":{"displayValue":"51'"},"team":{"displayName":"Leeds United"},"wallclock":"\#(iso(t0.addingTimeInterval(-1600)))"}},
           {"sequence":4,"text":"Goal! Leeds United 0, Manchester United 2. Mount scores.","play":{"id":"k4","type":{"type":"goal"},"period":{"number":2},"clock":{"displayValue":"77'"},"scoringPlay":true,"team":{"displayName":"Manchester United"},"wallclock":"\#(iso(t0.addingTimeInterval(-60)))"}}]}
        """#
        let match = GameStatsParser.parse(Data(soccer.utf8), sport: "soccer", receivedAt: t0)!
        check(match.away.name == "Manchester United" && match.home.name == "Leeds United", "Sides come from homeAway")
        check(match.plays.map(\.id) == ["k0", "k1", "k2", "k3", "k4"],
              "Commentary and the key events it missed, in the order they happened")
        check(match.plays[0].period == "1H" && match.plays[0].clock == nil, "Halves; kick-off has no minute")
        check(match.plays[2].teamID == "357", "A team named only by name is still placed")
        check(match.plays[1].scoring && match.plays[1].awayScore == 1 && match.plays[1].homeScore == 0,
              "A goal's score is read from what the commentary says")
        check(match.plays[3].scoring && match.plays[3].awayScore == 1 && match.plays[3].homeScore == 1,
              "An own goal with no stated score counts for the other side")
        check(match.plays[4].awayScore == 2 && match.plays[4].homeScore == 0,
              "A stated score settles the count")
        check(!match.plays[2].scoring, "A corner is not a goal")
        check(match.snapshot.lines == [GameStatsLine(label: "Possession", away: "39%", home: "61%"),
                                       GameStatsLine(label: "Shots", away: "13", home: "12"),
                                       GameStatsLine(label: "Pass Accuracy", away: "74%", home: "80%")],
              "Soccer's totals, named plainly, its fractions as percentages, the rest left out")
        check(GameStatsParser.statedScore("Goal! Mainz 05 1, Schalke 04 0.", away: "Schalke 04", home: "Mainz 05")! == (0, 1),
              "Numbers in a club's name are not its score")
        check(GameStatsParser.statedScore("Goal! Chelsea 2, Arsenal 1.", away: "Chelsea", home: "Arsenal")! == (2, 1),
              "Either side may be named first")

        // MARK: Tennis

        func tennisJSON(_ live: [(String, [(Int, Int)], String?, String)], extra: String = "") -> Data {
            // (id, sets as (first, second), serving side, state)
            let matches = live.map { match in
                let (id, sets, serving, state) = match
                func lines(_ first: Bool) -> String {
                    sets.enumerated().map { index, games in
                        let mine = first ? games.0 : games.1, theirs = first ? games.1 : games.0
                        let over = GameStatsBoardParser.settled(games.0, games.1) != nil || index < sets.count - 1
                        return #"{"value":\#(mine)\#(over ? #","winner":\#(mine > theirs)"# : "")}"#
                    }.joined(separator: ",")
                }
                let winnerOrder1 = state == "post" ? #","winner":true"# : ""
                let winnerOrder2 = state == "post" ? #","winner":false"# : ""
                return #"""
                {"id":"\#(id)","date":"2026-10-19T02:35Z","status":{"period":\#(sets.count),"type":{"state":"\#(state)","shortDetail":"\#(state == "post" ? "Final" : "2nd")"}},
                 "venue":{"court":"Court \#(id.suffix(1))"},"round":{"displayName":"Round 1"},"format":{"regulation":{"periods":3}},"type":{"slug":"womens-singles"},
                 "competitors":[
                  {"id":"b\#(id)","order":2,"possession":\#(serving == "home"),"linescores":[\#(lines(false))]\#(winnerOrder2),"athlete":{"displayName":"Kaitlin Quevedo","shortName":"K. Quevedo","flag":{"href":"esp.png"}}},
                  {"id":"a\#(id)","order":1,"possession":\#(serving == "away"),"linescores":[\#(lines(true))]\#(winnerOrder1),"athlete":{"displayName":"Lanlana Tararudee","shortName":"L. Tararudee","flag":{"href":"tha.png"}}}]}
                """#
            }.joined(separator: ",")
            return Data(#"""
            {"events":[{"id":"345-2026","name":"Japan Open","groupings":[
              {"grouping":{"slug":"womens-singles"},"competitions":[\#(matches)\#(extra)]},
              {"grouping":{"slug":"womens-doubles"},"competitions":[{"id":"d1","type":{"slug":"womens-doubles"},"competitors":[]}]}]}]}
            """#.utf8)
        }

        let opening = GameStatsBoardParser.tennis(tennisJSON([("m1", [(7, 5), (3, 2)], "away", "in")]),
                                                  tour: "wta", match: "m1", tournament: nil, receivedAt: t0)!
        guard case .tennis(let draw) = opening, let first = draw.focused else { preconditionFailure("A match is read") }
        check(first.away.name == "Lanlana Tararudee" && first.home.name == "Kaitlin Quevedo",
              "Players are in ESPN's order, as the schedule lists them")
        check(first.away.abbreviation == "Tararudee", "A player's surname stands for them")
        check(first.sets.count == 2 && first.sets[0].winner == .away && first.sets[1].winner == nil,
              "A finished set has its winner; the one in play has none")
        check(first.serving == .away && first.status == "Set 2 \u{00B7} 3-2" && first.line == "7-5 3-2",
              "Server, status and score line")
        check(first.start != nil, "A scoreboard's time to the minute is read")
        check(draw.matches.count == 1, "Doubles are left out")
        check(GameStatsBoardParser.tennis(tennisJSON([("m1", [(7, 5)], nil, "in")]), tour: "atp", match: "m1",
                                          tournament: nil, receivedAt: t0)
                .flatMap { if case .tennis(let other) = $0 { return other.focused } else { return nil } } != nil,
              "The match opened is found whatever its draw")
        check(GameStatsBoardParser.settled(6, 4) == .away && GameStatsBoardParser.settled(6, 5) == nil
                && GameStatsBoardParser.settled(6, 7) == .home, "A set settled on its games alone")

        func tennisChanges(_ before: [(Int, Int)], _ beforeServer: String?, _ after: [(Int, Int)],
                           state: String = "in") -> [GameStatsBoardChanges.Change] {
            let old = GameStatsBoardParser.tennis(tennisJSON([("m1", before, beforeServer, "in")]), tour: "wta",
                                                  match: "m1", tournament: nil, receivedAt: t0)
            let new = GameStatsBoardParser.tennis(tennisJSON([("m1", after, "home", state)]), tour: "wta",
                                                  match: "m1", tournament: nil, receivedAt: t0)!
            return GameStatsBoardChanges.changes(from: old, to: new)
        }
        let hold = tennisChanges([(7, 5), (3, 2)], "away", [(7, 5), (4, 2)])
        check(hold.map(\.text) == ["Tararudee holds serve"] && hold[0].badge == "4\u{2013}2" && hold[0].period == "Set 2",
              "One game, won by its server, is a hold")
        let broken = tennisChanges([(7, 5), (3, 2)], "home", [(7, 5), (4, 2)])
        check(broken.map(\.text) == ["Break of serve \u{2014} Tararudee"], "Won against serve, it is a break")
        let two = tennisChanges([(7, 5), (3, 2)], "away", [(7, 5), (4, 3)])
        check(two.map(\.text) == ["Game, Tararudee", "Game, Quevedo"], "Two games at once can't be told hold or break")
        let tiebreak = tennisChanges([(6, 5)], "away", [(6, 6)])
        check(tiebreak.map(\.text) == ["Game, Quevedo", "Tiebreak"] || tiebreak.map(\.text) == ["Break of serve \u{2014} Quevedo", "Tiebreak"],
              "Six all is a tiebreak")
        let tiebreakWon = tennisChanges([(6, 6)], "away", [(7, 6), (0, 0)])
        check(tiebreakWon.map(\.text) == ["Set 1 to Tararudee"], "A tiebreak won is the set, not a hold or break")
        let set = tennisChanges([(5, 4)], "away", [(6, 4), (0, 0)])
        check(set.map(\.text) == ["Tararudee holds serve", "Set 1 to Tararudee"] && set[1].scoring && set[1].badge == "6\u{2013}4",
              "A set won is told, and highlighted")
        let won = tennisChanges([(7, 5), (5, 3)], "away", [(7, 5), (6, 3)], state: "post")
        check(won.last?.text == "Game, set and match Tararudee" && won.last?.badge == "7-5 6-3",
              "The match won is told with its score")
        check(!won.contains { $0.text.hasPrefix("Set 2 to") }, "The last set isn't told twice")
        check(won.allSatisfy { $0.group == "m1" && $0.context == nil }, "A match's own plays need not say which match")

        // ESPN drops the server now and then; the serve alternates, so the
        // last one known says who serves.
        let known = GameStatsBoardParser.tennis(tennisJSON([("m1", [(0, 0)], "away", "in")]), tour: "wta",
                                                match: "m1", tournament: nil, receivedAt: t0)
        let unsaid = GameStatsBoardParser.tennis(tennisJSON([("m1", [(0, 1)], nil, "in")]), tour: "wta",
                                                 match: "m1", tournament: nil, receivedAt: t0)!
        guard case .tennis(let carried) = GameStatsBoardChanges.carryingServe(from: known, into: unsaid) else {
            preconditionFailure("A draw stays a draw")
        }
        check(carried.focused?.serving == .home, "After one game the serve has changed hands")
        let unsaid2 = GameStatsBoardParser.tennis(tennisJSON([("m1", [(1, 1)], nil, "in")]), tour: "wta",
                                                  match: "m1", tournament: nil, receivedAt: t0)!
        guard case .tennis(let carried2) = GameStatsBoardChanges.carryingServe(from: known, into: unsaid2) else {
            preconditionFailure("A draw stays a draw")
        }
        check(carried2.focused?.serving == .away, "After two, it is back")

        // MARK: A tennis tournament, held behind the picture

        // Two fetches ten seconds apart; a game is won between them.
        var timeline = GameStatsTimeline()
        let fetch1 = t0, fetch2 = t0.addingTimeInterval(10)
        let draw1 = GameStatsBoardParser.tennis(tennisJSON([("m1", [(7, 5), (3, 2)], "away", "in"), ("m2", [(1, 0)], "away", "in")]),
                                                tour: "wta", match: nil, tournament: "345-2026", receivedAt: fetch1)!
        let draw2 = GameStatsBoardParser.tennis(tennisJSON([("m1", [(7, 5), (4, 2)], "home", "in"), ("m2", [(1, 0)], "away", "in")]),
                                                tour: "wta", match: nil, tournament: "345-2026", receivedAt: fetch2)!
        timeline.ingest(GameStatsReport(board: draw1, receivedAt: fetch1))
        let early = timeline.reveal(at: fetch1.addingTimeInterval(-30))!
        check(early.catchingUp && early.board == nil && early.catchingUpFor == 30,
              "Nothing of a board shows before the picture reaches it, and it says how long until")
        check(timeline.timedPlays.isEmpty, "The first fetch says how things stand, not what happened")
        timeline.ingest(GameStatsReport(board: draw2, receivedAt: fetch2))
        let found = timeline.timedPlays
        check(found.count == 1 && found[0].text == "Tararudee holds serve" && found[0].seen == fetch1...fetch2,
              "A change is placed between the fetches that show it")
        check(found[0].drive == "Tararudee vs Quevedo \u{00B7} Court 1", "On a tournament, a play says which match")
        check(timeline.reveal(at: fetch2.addingTimeInterval(-1))!.plays.isEmpty,
              "A change is never shown before the fetch that found it")
        let reached = timeline.reveal(at: fetch2)!
        check(reached.plays.count == 1 && reached.status == "2 matches live", "Shown once the picture reaches it")
        guard case .tennis(let shownDraw)? = reached.board else { preconditionFailure("The board shows") }
        check(shownDraw.matches.first { $0.id == "m1" }?.line == "7-5 4-2", "The board is the one the picture has reached")
        // Syncing to it reckons from the earliest it could have happened, so
        // the next change can't come before the picture shows it.
        let now = fetch2.addingTimeInterval(45)
        check(GameStatsTimeline.delay(syncingTo: found[0], now: now) == 55, "Synced from the start of its window")
        check(timeline.latestTimedPlay(at: fetch2, in: "m2") == nil && timeline.latestTimedPlay(at: fetch2, in: "m1") != nil,
              "Syncing keeps to the match on screen")

        // MARK: A fight card

        func card(_ bouts: [(id: String, state: String, round: Int, clock: String, winner: Int?, details: [String])]) -> Data {
            let competitions = bouts.map { bout in
                let details = bout.details.enumerated().map { #"{"id":"\#(bout.id)\#($0.offset)","type":{"text":"\#($0.element)"}}"# }
                    .joined(separator: ",")
                let winner = { (index: Int) in bout.winner.map { #","winner":\#($0 == index)"# } ?? "" }
                return #"""
                {"id":"\#(bout.id)","date":"2026-10-17T21:00Z","type":{"abbreviation":"Welterweight"},"format":{"regulation":{"periods":3}},
                 "status":{"period":\#(bout.round),"displayClock":"\#(bout.clock)","type":{"state":"\#(bout.state)","shortDetail":"x"}},
                 "details":[\#(details)],
                 "competitors":[
                  {"id":"f\#(bout.id)a","order":2\#(winner(0)),"records":[{"summary":"15-2-1"}],"athlete":{"displayName":"Mike Malott","shortName":"M. Malott","flag":{"href":"can.png"}}},
                  {"id":"f\#(bout.id)b","order":1\#(winner(1)),"records":[{"summary":"21-7-0"}],"athlete":{"displayName":"Joaquin Buckley","shortName":"J. Buckley","flag":{"href":"usa.png"}}}]}
                """#
            }.joined(separator: ",")
            return Data(#"{"events":[{"id":"e1","name":"UFC Fight Night","competitions":[\#(competitions)]}]}"#.utf8)
        }
        let night1 = GameStatsBoardParser.card(card([
            ("p1", "post", 1, "4:52", 0, ["Round Start", "Fight Over", "Unofficial Winner Kotko", "Results"]),
            ("p2", "in", 1, "2:10", nil, ["Walkout", "Round Start"]),
            ("p3", "pre", 0, "0:00", nil, [])]), event: "e1")!
        guard case .card(let fights) = night1 else { preconditionFailure("A card is read") }
        check(fights.bouts.map(\.id) == ["p1", "p2", "p3"] && fights.mainEvent?.id == "p3", "The card runs to its main event")
        check(fights.bouts[0].method == "KO/TKO" && fights.bouts[0].result == "KO/TKO \u{00B7} R1 4:52"
                && fights.bouts[0].winnerName == "Mike Malott", "A finished fight's result")
        check(fights.live?.id == "p2" && fights.headline?.id == "p2" && fights.status == "Fight 2 of 3 \u{00B7} R1",
              "The fight on now leads")
        check(fights.bouts[2].clock == nil && fights.bouts[2].winner == nil, "A fight to come has no clock or result")
        check(GameStatsBoardParser.method([.init(id: "1", kind: "Unofficial Winner Submission")]) == "Submission", "Methods")
        let night2 = GameStatsBoardParser.card(card([
            ("p1", "post", 1, "4:52", 0, ["Round Start", "Fight Over", "Unofficial Winner Kotko", "Results"]),
            ("p2", "post", 2, "1:03", 1, ["Walkout", "Round Start", "Takedown Attempt", "Takedown", "Round End",
                                          "Round Start", "Knockdown", "Fight Over", "Unofficial Winner Kotko"]),
            ("p3", "pre", 0, "0:00", nil, [])]), event: "e1")!
        let fightChanges = GameStatsBoardChanges.changes(from: night1, to: night2)
        check(fightChanges.map(\.text) == ["Takedown", "End of round 2", "Knockdown", "The fight is over",
                                           "Joaquin Buckley defeats Mike Malott"],
              "What happened in a fight since the last look, its attempts left out")
        check(fightChanges.last?.badge == "KO/TKO" && fightChanges.last?.scoring == true
                && fightChanges.last?.context == "Malott vs. Buckley \u{00B7} Welterweight", "A result says how, and which fight")
        let night0 = GameStatsBoardParser.card(card([
            ("p1", "post", 1, "4:52", 0, ["Round Start", "Fight Over", "Unofficial Winner Kotko", "Results"]),
            ("p2", "pre", 0, "0:00", nil, ["Walkout"]),
            ("p3", "pre", 0, "0:00", nil, [])]), event: "e1")!
        check(GameStatsBoardChanges.changes(from: night0, to: night1).map(\.text) == ["Malott vs. Buckley is under way"],
              "A fight starting is told once")

        // MARK: A race

        func race(state: String, lap: Int, order: [String]) -> Data {
            let entrants = order.enumerated().map { index, name in
                #"{"id":"\#(name)","order":\#(index + 1),"athlete":{"displayName":"\#(name) Driver","shortName":"\#(name.prefix(1)). Driver","flag":{"href":"\#(name).png"}}}"#
            }.joined(separator: ",")
            return Data(#"""
            {"events":[{"id":"w1","name":"Grand Prix","competitions":[
              {"id":"s1","type":{"abbreviation":"Race"},"status":{"period":\#(lap),"type":{"state":"\#(state)","shortDetail":"\#(state == "post" ? "Final" : "Lap")"}},"competitors":[\#(entrants)]}]}]}
            """#.utf8)
        }
        let grid = GameStatsBoardParser.race(race(state: "pre", lap: 0, order: ["Ver", "Lec", "Ham", "Nor"]),
                                             event: "w1", session: "s1", league: "f1")!
        guard case .race(let before) = grid else { preconditionFailure("A race is read") }
        check(before.entrants.isEmpty && before.lap == nil && before.isRace, "Before the start, no order")
        let lap1 = GameStatsBoardParser.race(race(state: "in", lap: 1, order: ["Ver", "Lec", "Ham", "Nor"]),
                                             event: "w1", session: "s1", league: "f1")!
        check(GameStatsBoardChanges.changes(from: grid, to: lap1).map(\.text) == ["The race is under way"], "The start")
        let lap9 = GameStatsBoardParser.race(race(state: "in", lap: 9, order: ["Lec", "Nor", "Ver", "Ham"]),
                                             event: "w1", session: "s1", league: "f1")!
        guard case .race(let running) = lap9 else { preconditionFailure("A race is read") }
        check(running.status == "Lap 9" && running.leader?.name == "Lec Driver", "The lap and the leader")
        let passes = GameStatsBoardChanges.changes(from: lap1, to: lap9, sequence: 4)
        check(passes.map(\.text) == ["Lec Driver takes the lead", "Nor Driver up to P2"] && passes[0].period == "Lap 9",
              "A new leader, and a driver up into the podium places; a driver falling is not a play")
        let flag = GameStatsBoardParser.race(race(state: "post", lap: 57, order: ["Lec", "Nor", "Ver", "Ham"]),
                                             event: "w1", session: "s1", league: "f1")!
        let finish = GameStatsBoardChanges.changes(from: lap9, to: flag)
        check(finish.map(\.text) == ["Lec Driver wins"] && finish[0].context == "Podium: L. Driver, N. Driver, V. Driver",
              "The finish, with the podium")
        // Positions moved are shown against the order half a minute before.
        var raceline = GameStatsTimeline()
        raceline.ingest(GameStatsReport(board: lap1, receivedAt: t0))
        raceline.ingest(GameStatsReport(board: lap9, receivedAt: t0.addingTimeInterval(40)))
        let seen = raceline.reveal(at: t0.addingTimeInterval(40))!
        guard case .race(let earlier)? = seen.earlierBoard else { preconditionFailure("The earlier order is kept") }
        check(earlier.lap == 1, "The order the race has moved from")
        check(GameStatsBoardParser.sessionTitle("SR", league: "f1") == "Sprint"
                && GameStatsBoardParser.sessionTitle("", league: "nascar") == "Cup Series Race", "Session names")

        print("MobileGameBoardChecks passed")
    }
}
