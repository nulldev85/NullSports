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

        // Each side's score beside its code, in its line or the next one along.
        let bug = [line("LAC 6", x: 0.05), line("KC", x: 0.30, width: 0.04), line("22", x: 0.35, width: 0.03),
                   line("2ND 4:52", x: 0.5)]
        let score = ScoreboardReader.score(in: bug, away: ["LAC"], home: ["KC"])
        precondition(score?.away == 6 && score?.home == 22)
        precondition(ScoreboardReader.score(in: [line("22 KC")], away: ["LAC"], home: ["KC"]) == nil,
                     "Both sides or neither")

        let kickoff = Date(timeIntervalSince1970: 1_800_000_000)
        func at(_ seconds: Double) -> Date { kickoff.addingTimeInterval(seconds) }

        // A counting-down clock: each play's time, reached on screen 30s
        // after it happened, is one estimate. Three agree.
        let basketball = [AutoSyncPlay(wallclock: at(0), clockSeconds: 292, period: "Q2", awayScore: 0, homeScore: 0),
                          AutoSyncPlay(wallclock: at(12), clockSeconds: 280, period: "Q2", awayScore: 2, homeScore: 0),
                          AutoSyncPlay(wallclock: at(22), clockSeconds: 270, period: "Q2", awayScore: 2, homeScore: 0)]
        var tracker = AutoSyncTracker(clock: .remaining, margin: 1)
        tracker.observe(clocks: [292], score: nil, at: at(30), playerLag: 0, plays: basketball)
        tracker.observe(clocks: [292], score: nil, at: at(31), playerLag: 0, plays: basketball)
        precondition(tracker.estimates.count == 1, "A clock still on screen is not new")
        precondition(tracker.delay == nil, "One estimate is not enough")
        tracker.observe(clocks: [280], score: nil, at: at(42), playerLag: 0, plays: basketball)
        tracker.observe(clocks: [270], score: nil, at: at(52), playerLag: 0, plays: basketball)
        precondition(tracker.delay == 31, "Thirty seconds behind, and the margin")
        // The viewer's own pause is theirs, not the stream's.
        var paused = AutoSyncTracker(clock: .remaining, margin: 0)
        for (clock, seen) in [(292, 40.0), (280, 52.0), (270, 62.0)] {
            paused.observe(clocks: [clock], score: nil, at: at(seen), playerLag: 10, plays: basketball)
        }
        precondition(paused.delay == 30)

        // Hockey's feed counts up; its scoreboard counts down.
        let hockey = [AutoSyncPlay(wallclock: at(0), clockSeconds: 52, period: "1st", awayScore: 0, homeScore: 0)]
        var rink = AutoSyncTracker(clock: .remainingOfPeriods, margin: 0)
        rink.observe(clocks: [1148], score: nil, at: at(20), playerLag: 0, plays: hockey)
        precondition(rink.estimates.map(\.delay) == [20])

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
        let scattered = [(301, 10.0), (302, 30.0), (303, 30.5), (304, 31.0), (305, 55.0)]
        let plays = scattered.map { AutoSyncPlay(wallclock: at(0), clockSeconds: Double($0.0), period: "Q1",
                                                 awayScore: 0, homeScore: 0) }
        for (clock, delay) in scattered {
            mixed.observe(clocks: [clock], score: nil, at: at(delay), playerLag: 0, plays: plays)
        }
        precondition(mixed.delay == 31, "30.5 agreed by three, not 10 or 55")
        print("Auto Sync checks passed")
    }
}
