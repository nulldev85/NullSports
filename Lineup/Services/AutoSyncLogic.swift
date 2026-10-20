import Foundation

/// A line of text read off the picture, where it was: Vision's box, in
/// fractions of the frame, origin at the bottom left.
struct ScoreboardText: Sendable {
    let text: String
    let x: Double
    let y: Double
    let width: Double
    let height: Double
}

/// A part of the frame to read, in Vision's fractions of the frame (origin at
/// the bottom left). A scoreboard is a small box at the top or the bottom;
/// reading only that part gives the reader its text at several times the
/// size, which is what a corner bug's digits need to be read at all.
struct ScoreboardArea: Equatable, Sendable {
    let x: Double
    let y: Double
    let width: Double
    let height: Double

    static let whole = ScoreboardArea(x: 0, y: 0, width: 1, height: 1)
    static let top = ScoreboardArea(x: 0, y: 0.66, width: 1, height: 0.34)
    static let bottom = ScoreboardArea(x: 0, y: 0, width: 1, height: 0.34)
    /// Where to look, in turn, while the scoreboard is not yet found.
    static let search: [ScoreboardArea] = [.top, .bottom, .whole]

    /// A line read inside this area, placed in the whole frame.
    func placing(_ line: ScoreboardText) -> ScoreboardText {
        ScoreboardText(text: line.text, x: x + line.x * width, y: y + line.y * height,
                       width: line.width * width, height: line.height * height)
    }

    /// The band across the frame around a line the clock was read in: wide,
    /// for a bar that spreads the score across the screen, and tall enough
    /// for a box that stacks the teams.
    static func around(_ line: ScoreboardText) -> ScoreboardArea {
        let low = max(0, line.y - 0.08)
        let high = min(1, line.y + line.height + 0.08)
        return ScoreboardArea(x: 0, y: low, width: 1, height: high - low)
    }
}

/// What a frame's scoreboard says, read from its text.
enum ScoreboardReader {
    /// Every game clock on screen, in seconds: "4:52", "12:00", "67:13".
    /// A time of day ("8:15 PM") is not a clock, and neither is a reading
    /// longer than the sport's longest period.
    static func clocks(in texts: [ScoreboardText], maxMinutes: Int) -> Set<Int> {
        Set(clockLines(in: texts, maxMinutes: maxMinutes).map(\.seconds))
    }

    /// Each clock with the line it was read in, so the scoreboard can be found.
    static func clockLines(in texts: [ScoreboardText], maxMinutes: Int) -> [(seconds: Int, line: ScoreboardText)] {
        var found: [(seconds: Int, line: ScoreboardText)] = []
        for line in texts {
            let text = line.text.uppercased() as NSString
            for match in clockPattern.matches(in: text as String, range: NSRange(location: 0, length: text.length)) {
                let after = text.substring(from: match.range.location + match.range.length)
                    .trimmingCharacters(in: .whitespaces)
                guard !["AM", "PM", "ET", "PT", "CT", "MT"].contains(where: after.hasPrefix),
                      let minutes = Int(text.substring(with: match.range(at: 1))),
                      let seconds = Int(text.substring(with: match.range(at: 2))),
                      minutes <= maxMinutes else { continue }
                found.append((seconds: minutes * 60 + seconds, line: line))
            }
        }
        return found
    }

    /// Minutes and seconds standing on their own: not part of a longer
    /// number, a decimal or a time with seconds.
    private static let clockPattern = try! NSRegularExpression(pattern: #"(?<![\d:.])(\d{1,3}):([0-5]\d)(?![\d:])"#)

    /// Each side's score, read beside its code: in the same line ("KC 22",
    /// "22 KC"), or in the line just beside it on the same row.
    static func score(in texts: [ScoreboardText], away: [String], home: [String]) -> (away: Int, home: Int)? {
        guard let awayScore = number(beside: away, in: texts), let homeScore = number(beside: home, in: texts) else {
            return nil
        }
        return (awayScore, homeScore)
    }

    /// The first line naming either side: where a scoreboard without a clock
    /// (baseball's) is.
    static func line(in texts: [ScoreboardText], naming codes: [String]) -> ScoreboardText? {
        let codes = Set(codes.map { $0.uppercased() }.filter { !$0.isEmpty })
        return texts.first { !Set(words($0.text)).isDisjoint(with: codes) }
    }

    private static func words(_ text: String) -> [String] {
        text.uppercased().components(separatedBy: CharacterSet.alphanumerics.inverted).filter { !$0.isEmpty }
    }

    private static func number(beside codes: [String], in texts: [ScoreboardText]) -> Int? {
        let codes = Set(codes.map { $0.uppercased() }.filter { !$0.isEmpty })
        guard !codes.isEmpty else { return nil }
        for line in texts {
            let tokens = words(line.text)
            guard let at = tokens.firstIndex(where: codes.contains) else { continue }
            // A score is one to three digits; anything longer is a clock
            // read without its colon, a year, a phone number.
            func score(_ token: String) -> Int? {
                guard token.count <= 3, let value = Int(token), value <= 200 else { return nil }
                return value
            }
            if let next = tokens.dropFirst(at + 1).first.flatMap(score) { return next }
            if at > 0, let previous = score(tokens[at - 1]) { return previous }
            // Otherwise the nearest line beside it on the same row, holding
            // one number and nothing else.
            let middle = line.y + line.height / 2
            let beside = texts.filter { other in
                guard other.text != line.text else { return false }
                let sameRow = abs((other.y + other.height / 2) - middle) < max(line.height, 0.02)
                let gap = min(abs(other.x - (line.x + line.width)), abs((other.x + other.width) - line.x))
                return sameRow && gap < 0.12
            }
            .sorted { abs($0.x - line.x) < abs($1.x - line.x) }
            for other in beside {
                let numbers = words(other.text).compactMap(score)
                if numbers.count == 1 { return numbers[0] }
            }
        }
        return nil
    }
}

/// A play as Auto Sync reads it: when it happened, the clock and the score.
struct AutoSyncPlay: Sendable {
    let wallclock: Date
    /// The play's clock in seconds: time left in the period, or for soccer
    /// and hockey time gone.
    let clockSeconds: Double?
    let period: String
    let awayScore: Int
    let homeScore: Int
}

/// How a sport's clock on screen relates to ESPN's.
enum AutoSyncClock: Sendable {
    /// Counting down, as ESPN counts: basketball, football.
    case remaining
    /// Counting down on screen; ESPN counts up within the period: hockey.
    case remainingOfPeriods
    /// Counting up without stopping, as ESPN counts: soccer. Every reading
    /// is a moment, not just the ones a play lands on.
    case continuous
    /// No clock to read: baseball. The score alone.
    case none

    static func forSport(_ sport: String) -> AutoSyncClock {
        switch sport {
        case "basketball", "football": .remaining
        case "hockey": .remainingOfPeriods
        case "soccer": .continuous
        default: .none
        }
    }

    var maxMinutes: Int {
        switch self {
        case .remaining, .remainingOfPeriods: 20
        case .continuous: 130
        case .none: 0
        }
    }
}

/// Estimates how far the picture is behind ESPN from what its scoreboard
/// shows, frame by frame.
///
/// Two kinds of moment give an estimate. A clock that reaches the time a
/// play happened at: the play was on screen then. And a score changing on
/// screen to a score a play made: that play was just on screen. Each gives
/// "seen at, happened at"; the difference, less the viewer's own pauses, is
/// one estimate of the delay.
///
/// ESPN can post a play minutes after it happened -- in hockey, three and
/// more -- often after a stream only a little behind live has shown it. So
/// every moment the scoreboard showed is kept for ten minutes, and matched
/// to plays as they arrive, not only to those there when it was seen.
///
/// Single estimates mislead -- a clock stopped on a play's time before the
/// play, a misread digit -- so the delay is the one most estimates agree
/// on, and nothing is said until enough do. Every way an estimate goes wrong
/// that is not random makes it short (the stats early), so a margin is
/// added for the sport, and a tie goes to the longer delay.
struct AutoSyncTracker {
    let clock: AutoSyncClock
    /// Added to what the estimates agree on: the moment a feed calls a play
    /// is a little after the moment a clock shows its time.
    let margin: TimeInterval

    /// What the scoreboard showed, when, and the viewer's own pauses then.
    private struct Moment {
        let value: Int
        let at: Date
        let lag: TimeInterval
    }

    /// A score the scoreboard changed to, timed from its first sighting.
    private struct ScoreChange {
        let away: Int
        let home: Int
        let at: Date
        let lag: TimeInterval
    }

    private var lastSeen: [Int: Date] = [:]
    private var lastRunning: (value: Int, at: Date)?
    private var moments: [Moment] = []
    private var shownScore: (away: Int, home: Int)?
    private var pendingScore: (away: Int, home: Int, since: Date)?
    private var scoreChanges: [ScoreChange] = []
    private(set) var estimates: [(at: Date, delay: TimeInterval)] = []

    init(clock: AutoSyncClock, margin: TimeInterval) {
        self.clock = clock
        self.margin = margin
    }

    static let range: ClosedRange<TimeInterval> = 0...600
    /// How long a moment waits for its play: also how long an estimate
    /// counts, since a reconnected stream is a new delay.
    static let memory: TimeInterval = 600

    /// One frame: what it showed, the moment it was on screen, and how far
    /// the viewer's own pauses had put the picture behind by then.
    mutating func observe(clocks: Set<Int>, score: (away: Int, home: Int)?, at time: Date,
                          playerLag: TimeInterval, plays: [AutoSyncPlay]) {
        let lag = max(0, playerLag)
        switch clock {
        case .remaining, .remainingOfPeriods:
            for value in clocks {
                // A clock is new when it was not on screen a minute ago:
                // only then is this the moment it reached that time.
                defer { lastSeen[value] = time }
                if let seen = lastSeen[value], time.timeIntervalSince(seen) < 60 { continue }
                moments.append(Moment(value: value, at: time, lag: lag))
            }
        case .continuous:
            // Only a clock seen running: one held at 45:00 through stoppage
            // time, or through half time, is not the time on the field.
            let previous = lastRunning
            lastRunning = clocks.count == 1 ? clocks.first.map { (value: $0, at: time) } : nil
            if let value = clocks.first, clocks.count == 1, let previous, value != previous.value,
               abs(Double(value - previous.value) - time.timeIntervalSince(previous.at)) <= 2 {
                moments.append(Moment(value: value, at: time, lag: lag))
            }
        case .none:
            break
        }
        noteScore(score, at: time, lag: lag)
        moments.removeAll { time.timeIntervalSince($0.at) > Self.memory }
        if moments.count > 400 { moments.removeFirst(moments.count - 400) }
        scoreChanges.removeAll { time.timeIntervalSince($0.at) > Self.memory }
        lastSeen = lastSeen.filter { time.timeIntervalSince($0.value) < 60 }
        estimates = matched(plays)
    }

    /// Every moment kept, matched to the plays ESPN has posted so far.
    private func matched(_ plays: [AutoSyncPlay]) -> [(at: Date, delay: TimeInterval)] {
        func measure(_ moment: Date, lag: TimeInterval, since happened: Date) -> TimeInterval? {
            let delay = moment.timeIntervalSince(happened) - lag
            return Self.range.contains(delay) ? delay : nil
        }
        var found: [(at: Date, delay: TimeInterval)] = []
        switch clock {
        case .remaining, .remainingOfPeriods:
            // Each play under the time its scoreboard showed for it.
            var byClock: [Int: [Date]] = [:]
            for play in plays {
                guard let seconds = play.clockSeconds else { continue }
                let onScreen = clock == .remaining ? seconds : Double(play.period == "OT" ? 300 : 1200) - seconds
                byClock[Int(onScreen.rounded()), default: []].append(play.wallclock)
            }
            for moment in moments {
                let matching = (byClock[moment.value] ?? []).compactMap { measure(moment.at, lag: moment.lag, since: $0) }
                // Plays at one clock a minute or two apart -- a foul and its
                // free throws -- stand on one stopped clock, which reached
                // that time with the first of them. Plays farther apart are
                // the same time in different periods: no telling which.
                if let shortest = matching.min(), let longest = matching.max(), longest - shortest <= 120 {
                    found.append((at: moment.at, delay: longest))
                }
            }
        case .continuous:
            // Soccer's clock never stops, so any reading lands between
            // two plays: time from the nearest is time on the field.
            let timed = plays.compactMap { play in play.clockSeconds.map { (seconds: $0, at: play.wallclock) } }
            for moment in moments {
                let value = Double(moment.value)
                let near = timed.compactMap { play -> TimeInterval? in
                    guard abs(play.seconds - value) <= 180 else { return nil }
                    return measure(moment.at, lag: moment.lag, since: play.at.addingTimeInterval(value - play.seconds))
                }.sorted()
                if !near.isEmpty { found.append((at: moment.at, delay: near[near.count / 2])) }
            }
        case .none:
            break
        }
        // The play that made each score: the first to have it, after one
        // that did not.
        for change in scoreChanges {
            var before: (away: Int, home: Int)?
            for play in plays {
                defer { before = (play.awayScore, play.homeScore) }
                guard play.awayScore == change.away, play.homeScore == change.home,
                      let made = before, made != (change.away, change.home) else { continue }
                if let estimate = measure(change.at, lag: change.lag, since: play.wallclock) {
                    found.append((at: change.at, delay: estimate))
                }
                break
            }
        }
        return found.sorted { $0.at < $1.at }
    }

    /// A score on screen changing: read twice in a row before it counts, so
    /// one misread digit is not a goal; timed from the first of the two.
    private mutating func noteScore(_ score: (away: Int, home: Int)?, at time: Date, lag: TimeInterval) {
        guard let score else { return }
        if let shown = shownScore, shown == score { pendingScore = nil; return }
        guard let pending = pendingScore, pending.away == score.away, pending.home == score.home else {
            pendingScore = (score.away, score.home, time)
            return
        }
        let previous = shownScore
        shownScore = score
        pendingScore = nil
        // The first reading only says where the game stands; a score that
        // went down or leapt was misread.
        guard let previous, score.away >= previous.away, score.home >= previous.home,
              score.away + score.home - previous.away - previous.home <= 8 else { return }
        scoreChanges.append(ScoreChange(away: score.away, home: score.home, at: pending.since, lag: lag))
    }

    /// How many estimates have to agree before the delay is the scoreboard's.
    var needed: Int { clock == .none ? 2 : 3 }

    /// How many agree so far: the largest group within a couple of seconds.
    var agreeing: Int { bestGroup?.count ?? 0 }

    /// The delay most estimates agree on -- within a couple of seconds of
    /// one another -- once enough do, with the sport's margin added.
    var delay: TimeInterval? {
        guard let best = bestGroup, best.count >= needed else { return nil }
        return min(Self.range.upperBound, (best.median + margin).rounded())
    }

    private var bestGroup: (count: Int, median: TimeInterval)? {
        let sorted = estimates.map(\.delay).sorted()
        var best: (count: Int, median: TimeInterval)?
        var start = 0
        for end in sorted.indices {
            while sorted[end] - sorted[start] > 2.5 { start += 1 }
            let count = end - start + 1
            let median = sorted[(start + end) / 2]
            if best == nil || count > best!.count || (count == best!.count && median > best!.median) {
                best = (count, median)
            }
        }
        return best
    }
}
