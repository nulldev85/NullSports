import Foundation

@main
struct MobileAutoSyncChecks {
    static func line(_ text: String, x: Double = 0.1, y: Double = 0.05, width: Double = 0.1) -> ScoreboardText {
        ScoreboardText(text: text, x: x, y: y, width: width, height: 0.03)
    }

    static func main() {
        // The clock, and nothing that only looks like one.
        precondition(ScoreboardReader.clocks(in: [line("2ND 4:52"), line("8:15 PM ET"), line("3RD & 7")], maxMinutes: 20) == [292])
        precondition(ScoreboardReader.clocks(in: [line("67:13")], maxMinutes: 130) == [4033])
        precondition(ScoreboardReader.clocks(in: [line("67:13")], maxMinutes: 20).isEmpty, "Longer than a period")
        precondition(ScoreboardReader.clocks(in: [line("12:34:56")], maxMinutes: 130).isEmpty, "A time with seconds")

        // A line read in the top of the frame is placed in the whole frame,
        // and the band read after is drawn round it, clear of the edge.
        let inTop = ScoreboardArea.top.placing(line("SJ 0 TOR 0 9:12", x: 0.1, y: 0.5, width: 0.2))
        precondition(abs(inTop.y - 0.83) < 0.0001 && abs(inTop.height - 0.0102) < 0.0001
                     && abs(inTop.x - 0.1) < 0.0001 && abs(inTop.width - 0.2) < 0.0001)
        let band = ScoreboardArea.around(inTop)
        precondition(abs(band.y - 0.75) < 0.0001 && abs(band.y + band.height - (0.83 + 0.0102 + 0.08)) < 0.0001
                     && band.x == 0 && band.width == 1)
        let edge = ScoreboardArea.around(line("4:52", y: 0.95))
        precondition(edge.y + edge.height < 1.0001, "Kept inside the frame")
        let found = ScoreboardReader.clockLines(in: [line("SN"), inTop], maxMinutes: 20)
        precondition(found.count == 1 && found[0].seconds == 552 && found[0].line.text == "SJ 0 TOR 0 9:12")
        // Without a clock, the scoreboard is the line naming a side.
        precondition(ScoreboardReader.line(in: [line("MLB NETWORK"), line("SF 3 LAD 1 · TOP 7")],
                                           naming: ["SF", "LAD"])?.text == "SF 3 LAD 1 · TOP 7")
        precondition(ScoreboardReader.line(in: [line("SFO 3")], naming: ["SF"]) == nil, "A whole word, not a part")

        // Each side's score beside its code, in its line or the next one along.
        let bug = [line("LAC 6", x: 0.05), line("KC", x: 0.30, width: 0.04), line("22", x: 0.35, width: 0.03),
                   line("2ND 4:52", x: 0.5)]
        let score = ScoreboardReader.score(in: bug, away: ["LAC"], home: ["KC"])
        precondition(score?.away == 6 && score?.home == 22)
        precondition(ScoreboardReader.score(in: [line("22 KC")], away: ["LAC"], home: ["KC"]) == nil,
                     "Both sides or neither")

        let kickoff = Date(timeIntervalSince1970: 1_800_000_000)
        func at(_ seconds: Double) -> Date { kickoff.addingTimeInterval(seconds) }

        // A counting-down clock, timed by watching it run: two readings with
        // as many seconds gone on it as on the wall saw every second between
        // reached at its own moment. Each play's time, reached on screen 30s
        // after it happened, is one estimate. Three agree.
        let basketball = [AutoSyncPlay(wallclock: at(0), clockSeconds: 292, period: "Q2", awayScore: 0, homeScore: 0),
                          AutoSyncPlay(wallclock: at(12), clockSeconds: 280, period: "Q2", awayScore: 2, homeScore: 0),
                          AutoSyncPlay(wallclock: at(22), clockSeconds: 270, period: "Q2", awayScore: 2, homeScore: 0)]
        var tracker = AutoSyncTracker(clock: .remaining, margin: 1)
        tracker.observe(clocks: [293], score: nil, at: at(29), playerLag: 0, plays: basketball)
        tracker.observe(clocks: [292], score: nil, at: at(30), playerLag: 0, plays: basketball)
        tracker.observe(clocks: [292], score: nil, at: at(31), playerLag: 0, plays: basketball)
        precondition(tracker.estimates.map(\.delay) == [30], "A clock still on screen has not just reached its time")
        precondition(tracker.delay == nil, "One estimate is not enough")
        precondition(tracker.agreeing == 1 && tracker.needed == 3, "What the panel says while it waits")
        tracker.observe(clocks: [280], score: nil, at: at(42), playerLag: 0, plays: basketball)
        tracker.observe(clocks: [270], score: nil, at: at(52), playerLag: 0, plays: basketball)
        precondition(tracker.estimates.map(\.delay) == [30, 31, 30], "Every second the clock ran past is a moment")
        precondition(tracker.delay == 31, "Thirty seconds behind, and the margin")
        // Read only every four seconds, a running clock's plays are still each
        // timed: not just those whose second a frame happened to land on.
        let sparse = [AutoSyncPlay(wallclock: at(2), clockSeconds: 290, period: "Q2", awayScore: 0, homeScore: 0),
                      AutoSyncPlay(wallclock: at(5), clockSeconds: 287, period: "Q2", awayScore: 0, homeScore: 0)]
        var every4 = AutoSyncTracker(clock: .remaining, margin: 0)
        for (clock, seen) in [(292, 30.0), (288, 34.0), (284, 38.0)] {
            every4.observe(clocks: [clock], score: nil, at: at(seen), playerLag: 0, plays: sparse)
        }
        precondition(every4.estimates.map(\.delay) == [30, 30], "Both plays timed between frames")
        // The viewer's own pause is theirs, not the stream's.
        var paused = AutoSyncTracker(clock: .remaining, margin: 0)
        for (clock, seen) in [(293, 39.0), (292, 40.0), (280, 52.0), (270, 62.0)] {
            paused.observe(clocks: [clock], score: nil, at: at(seen), playerLag: 10, plays: basketball)
        }
        precondition(paused.delay == 30)
        // A clock back from an ad break, still stopped where it was, has not
        // just reached its time; once it runs again, it says so.
        let stopped = [AutoSyncPlay(wallclock: at(0), clockSeconds: 610, period: "Q3", awayScore: 0, homeScore: 0),
                       AutoSyncPlay(wallclock: at(200), clockSeconds: 609, period: "Q3", awayScore: 0, homeScore: 0)]
        var ads = AutoSyncTracker(clock: .remaining, margin: 0)
        ads.observe(clocks: [611], score: nil, at: at(29), playerLag: 0, plays: stopped)
        ads.observe(clocks: [610], score: nil, at: at(30), playerLag: 0, plays: stopped)
        ads.observe(clocks: [], score: nil, at: at(100), playerLag: 0, plays: stopped)
        ads.observe(clocks: [610], score: nil, at: at(229), playerLag: 0, plays: stopped)
        precondition(ads.estimates.map(\.delay) == [30], "Back from the break says nothing")
        ads.observe(clocks: [609], score: nil, at: at(230), playerLag: 0, plays: stopped)
        precondition(ads.estimates.map(\.delay) == [30, 30], "Running again, it does")
        // Two clocks at once is no telling which is the game's.
        var two = AutoSyncTracker(clock: .remaining, margin: 0)
        two.observe(clocks: [293], score: nil, at: at(29), playerLag: 0, plays: basketball)
        two.observe(clocks: [292, 24], score: nil, at: at(30), playerLag: 0, plays: basketball)
        two.observe(clocks: [291], score: nil, at: at(31), playerLag: 0, plays: basketball)
        precondition(two.estimates.isEmpty)

        // Hockey's feed counts up; its scoreboard counts down.
        let hockey = [AutoSyncPlay(wallclock: at(0), clockSeconds: 52, period: "1st", awayScore: 0, homeScore: 0)]
        var rink = AutoSyncTracker(clock: .remainingOfPeriods, margin: 0)
        rink.observe(clocks: [1149], score: nil, at: at(19), playerLag: 0, plays: hockey)
        rink.observe(clocks: [1148], score: nil, at: at(20), playerLag: 0, plays: hockey)
        precondition(rink.estimates.map(\.delay) == [20])

        // ESPN posts plays minutes late: the moments the clock showed are
        // kept, and matched when their plays come, for ten minutes.
        let posted = [AutoSyncPlay(wallclock: at(0), clockSeconds: 52, period: "1st", awayScore: 0, homeScore: 0),
                      AutoSyncPlay(wallclock: at(1), clockSeconds: 53, period: "1st", awayScore: 0, homeScore: 0),
                      AutoSyncPlay(wallclock: at(8), clockSeconds: 60, period: "1st", awayScore: 0, homeScore: 0)]
        var late = AutoSyncTracker(clock: .remainingOfPeriods, margin: 0)
        late.observe(clocks: [1149], score: nil, at: at(19), playerLag: 0, plays: [])
        late.observe(clocks: [1148], score: nil, at: at(20), playerLag: 0, plays: [])
        late.observe(clocks: [1147], score: nil, at: at(21), playerLag: 0, plays: [])
        precondition(late.estimates.isEmpty, "Nothing to match yet")
        late.observe(clocks: [1140], score: nil, at: at(28), playerLag: 0, plays: posted)
        precondition(late.estimates.map(\.delay) == [20, 20, 20] && late.delay == 20, "Matched once posted")
        late.observe(clocks: [], score: nil, at: at(700), playerLag: 0, plays: posted)
        precondition(late.estimates.isEmpty, "Ten minutes on, a reconnected stream may be a new delay")

        // ESPN stamps every play in a stoppage with the moment it began: a
        // free throw with its foul, though it went in half a minute later.
        // Its score changing on screen is no measure; a basket's is.
        let stoppage = [AutoSyncPlay(wallclock: at(90), clockSeconds: 390, period: "Q3", awayScore: 77, homeScore: 61),
                        AutoSyncPlay(wallclock: at(100), clockSeconds: 381, period: "Q3", awayScore: 77, homeScore: 61),
                        AutoSyncPlay(wallclock: at(100), clockSeconds: 381, period: "Q3", awayScore: 77, homeScore: 62),
                        AutoSyncPlay(wallclock: at(140), clockSeconds: 365, period: "Q3", awayScore: 77, homeScore: 64)]
        var line = AutoSyncTracker(clock: .remaining, margin: 0)
        let readings: [(score: (away: Int, home: Int), seen: Double)] =
            [((77, 61), 150), ((77, 61), 151), ((77, 62), 165), ((77, 62), 166)]
        for reading in readings {
            line.observe(clocks: [], score: reading.score, at: at(reading.seen), playerLag: 0, plays: stoppage)
        }
        precondition(line.estimates.isEmpty, "A free throw's score says nothing of when it changed")
        line.observe(clocks: [], score: (77, 64), at: at(170), playerLag: 0, plays: stoppage)
        line.observe(clocks: [], score: (77, 64), at: at(171), playerLag: 0, plays: stoppage)
        precondition(line.estimates.map(\.delay) == [30], "A basket's does")

        // Soccer's clock never stops: every running reading is a moment.
        let soccer = [AutoSyncPlay(wallclock: at(0), clockSeconds: 1400, period: "1H", awayScore: 0, homeScore: 0)]
        var pitch = AutoSyncTracker(clock: .continuous, margin: 1)
        for step in 0..<5 {
            pitch.observe(clocks: [1460 + step], score: nil, at: at(85 + Double(step)), playerLag: 0, plays: soccer)
        }
        precondition(pitch.delay == 26, "Twenty-five seconds behind, and the margin")
        // Held at 45:00 through stoppage time: not the time on the field.
        var held = AutoSyncTracker(clock: .continuous, margin: 1)
        for step in 0..<6 {
            held.observe(clocks: [2700], score: nil, at: at(2800 + Double(step)), playerLag: 0, plays: soccer)
        }
        precondition(held.estimates.isEmpty)

        // Baseball has no clock: a score changing on screen to one a play
        // made, seen twice, is timed from the first sighting.
        let baseball = [AutoSyncPlay(wallclock: at(0), clockSeconds: nil, period: "Top 1st", awayScore: 0, homeScore: 0),
                        AutoSyncPlay(wallclock: at(100), clockSeconds: nil, period: "Top 1st", awayScore: 1, homeScore: 0),
                        AutoSyncPlay(wallclock: at(400), clockSeconds: nil, period: "Bot 1st", awayScore: 1, homeScore: 2)]
        var diamond = AutoSyncTracker(clock: .none, margin: 0)
        diamond.observe(clocks: [], score: (0, 0), at: at(50), playerLag: 0, plays: baseball)
        diamond.observe(clocks: [], score: (0, 0), at: at(51), playerLag: 0, plays: baseball)
        precondition(diamond.estimates.isEmpty, "The first reading says where the game stands")
        diamond.observe(clocks: [], score: (1, 0), at: at(140), playerLag: 0, plays: baseball)
        diamond.observe(clocks: [], score: (7, 0), at: at(141), playerLag: 0, plays: baseball)
        diamond.observe(clocks: [], score: (1, 0), at: at(142), playerLag: 0, plays: baseball)
        diamond.observe(clocks: [], score: (1, 0), at: at(143), playerLag: 0, plays: baseball)
        precondition(diamond.estimates.map(\.delay) == [42], "A misread is not the change; timed from its first sighting")
        diamond.observe(clocks: [], score: (1, 2), at: at(442), playerLag: 0, plays: baseball)
        diamond.observe(clocks: [], score: (1, 2), at: at(443), playerLag: 0, plays: baseball)
        precondition(diamond.delay == 42, "Two agreeing are enough without a clock")

        // Estimates that disagree: the most that agree win, and nothing
        // outside ten minutes counts.
        var mixed = AutoSyncTracker(clock: .remaining, margin: 0)
        let scattered = [(301, 0.0, 10.0), (311, 100.0, 30.0), (321, 200.0, 30.5), (331, 300.0, 31.0), (341, 400.0, 55.0)]
        let plays = scattered.map { AutoSyncPlay(wallclock: at($0.1), clockSeconds: Double($0.0), period: "Q1",
                                                 awayScore: 0, homeScore: 0) }
        for (clock, happened, delay) in scattered {
            mixed.observe(clocks: [clock + 1], score: nil, at: at(happened + delay - 1), playerLag: 0, plays: plays)
            mixed.observe(clocks: [clock], score: nil, at: at(happened + delay), playerLag: 0, plays: plays)
        }
        precondition(mixed.delay == 31, "30.5 agreed by three, not 10 or 55")
        precondition(mixed.agreeing == 3)
        precondition(AutoSyncTracker(clock: .none, margin: 0).needed == 2)
        print("Auto Sync checks passed")
    }
}
