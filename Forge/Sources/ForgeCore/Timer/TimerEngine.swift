import Foundation

// The interval engine is pure: a program is a list of phases, and the state
// of a run is derived from wall-clock time, pauses and skips. Nothing depends
// on a ticking timer, so the display is always correct after the app has
// been backgrounded, suspended, or even relaunched.

public struct TimerPhase: Hashable, Sendable {
    public enum Kind: String, Hashable, Sendable {
        case prepare
        case work
        case rest
        case setRest
    }

    public var kind: Kind
    /// nil for an open-ended phase (stopwatch, uncapped For Time).
    public var duration: Double?
    public var label: String
    /// 1-based round within the set; 0 for prepare/set rest.
    public var round: Int
    /// 0 when the number of rounds isn't fixed.
    public var totalRounds: Int
    public var set: Int
    public var totalSets: Int
    /// Show elapsed time instead of time remaining.
    public var countsUp: Bool
    /// Death By: reps required this interval.
    public var targetReps: Int?
    /// Index of the movement this interval is for when a block alternates
    /// movements (EMOM/Tabata with several exercises).
    public var workIndex: Int

    public init(
        kind: Kind,
        duration: Double?,
        label: String,
        round: Int = 0,
        totalRounds: Int = 0,
        set: Int = 0,
        totalSets: Int = 0,
        countsUp: Bool = false,
        targetReps: Int? = nil,
        workIndex: Int = 0
    ) {
        self.kind = kind
        self.duration = duration
        self.label = label
        self.round = round
        self.totalRounds = totalRounds
        self.set = set
        self.totalSets = totalSets
        self.countsUp = countsUp
        self.targetReps = targetReps
        self.workIndex = workIndex
    }

    public var isRest: Bool { kind == .rest || kind == .setRest }
}

public struct TimerProgram: Sendable {
    public let config: TimerConfig
    public let phases: [TimerPhase]
    /// Start offset of each phase from the beginning of the run.
    public let starts: [Double]
    public let leadIn: Double

    public init(config rawConfig: TimerConfig) {
        let config = rawConfig.sanitized()
        self.config = config
        var phases: [TimerPhase] = []

        if config.leadIn > 0 {
            phases.append(TimerPhase(kind: .prepare, duration: config.leadIn, label: "Get Ready"))
        }
        let leadIn = config.leadIn > 0 ? config.leadIn : 0
        var workCounter = 0

        func work(_ duration: Double?, label: String, round: Int, totalRounds: Int, set: Int = 1, totalSets: Int = 1, countsUp: Bool = false, targetReps: Int? = nil) -> TimerPhase {
            defer { workCounter += 1 }
            return TimerPhase(
                kind: .work,
                duration: duration,
                label: label,
                round: round,
                totalRounds: totalRounds,
                set: set,
                totalSets: totalSets,
                countsUp: countsUp,
                targetReps: targetReps,
                workIndex: workCounter
            )
        }

        switch config.kind {
        case .stopwatch:
            phases.append(work(nil, label: "Stopwatch", round: 1, totalRounds: 0, countsUp: true))
        case .countdown:
            phases.append(work(config.duration, label: "Countdown", round: 1, totalRounds: 1))
        case .forTime:
            let cap = config.duration > 0 ? config.duration : nil
            phases.append(work(cap, label: "For Time", round: 1, totalRounds: config.rounds, countsUp: true))
        case .amrap:
            phases.append(work(config.duration, label: "AMRAP", round: 1, totalRounds: 0))
        case .emom:
            for round in 1...config.rounds {
                phases.append(work(config.interval, label: "Round \(round)", round: round, totalRounds: config.rounds))
            }
        case .tabata, .intervals:
            for set in 1...config.sets {
                for round in 1...config.rounds {
                    phases.append(work(config.work, label: "Work", round: round, totalRounds: config.rounds, set: set, totalSets: config.sets))
                    let lastRoundOfSet = round == config.rounds
                    let lastSet = set == config.sets
                    if !lastRoundOfSet {
                        if config.rest > 0 {
                            phases.append(TimerPhase(kind: .rest, duration: config.rest, label: "Rest", round: round, totalRounds: config.rounds, set: set, totalSets: config.sets))
                        }
                    } else if !lastSet {
                        let setRest = config.restBetweenSets > 0 ? config.restBetweenSets : config.rest
                        if setRest > 0 {
                            phases.append(TimerPhase(kind: .setRest, duration: setRest, label: "Set Rest", round: round, totalRounds: config.rounds, set: set, totalSets: config.sets))
                        }
                    } else if !config.skipLastRest, config.rest > 0 {
                        phases.append(TimerPhase(kind: .rest, duration: config.rest, label: "Rest", round: round, totalRounds: config.rounds, set: set, totalSets: config.sets))
                    }
                }
            }
        case .custom:
            for set in 1...config.sets {
                for segment in config.segments {
                    let name = segment.name.trimmingCharacters(in: .whitespaces)
                    if segment.kind == .rest {
                        phases.append(TimerPhase(kind: .rest, duration: segment.duration, label: name.isEmpty ? "Rest" : name, round: set, totalRounds: config.sets, set: set, totalSets: config.sets))
                    } else {
                        phases.append(work(segment.duration, label: name.isEmpty ? "Work" : name, round: set, totalRounds: config.sets, set: set, totalSets: config.sets))
                    }
                }
                if set < config.sets, config.restBetweenSets > 0 {
                    phases.append(TimerPhase(kind: .setRest, duration: config.restBetweenSets, label: "Set Rest", round: set, totalRounds: config.sets, set: set, totalSets: config.sets))
                }
            }
            if config.skipLastRest, let last = phases.last, last.kind == .rest, phases.count > 1 {
                phases.removeLast()
            }
        case .deathBy:
            for round in 1...config.rounds {
                let reps = config.startReps + (round - 1) * config.repIncrement
                phases.append(work(config.interval, label: "\(reps) reps", round: round, totalRounds: config.rounds, targetReps: reps))
            }
        }

        if phases.isEmpty || phases.allSatisfy({ $0.kind == .prepare }) {
            phases.append(work(nil, label: config.kind.displayName, round: 1, totalRounds: 0, countsUp: true))
        }

        var starts: [Double] = []
        var cursor = 0.0
        for phase in phases {
            starts.append(cursor)
            cursor += phase.duration ?? 0
        }
        self.phases = phases
        self.starts = starts
        self.leadIn = leadIn
    }

    /// Total length, or nil when the program ends with an open-ended phase.
    public var totalDuration: Double? {
        guard let last = phases.last, let lastDuration = last.duration else { return nil }
        return (starts.last ?? 0) + lastDuration
    }

    /// Total length excluding the lead-in.
    public var workDuration: Double? {
        totalDuration.map { $0 - leadIn }
    }

    public var workPhaseCount: Int {
        phases.filter { $0.kind == .work }.count
    }

    public func end(ofPhase index: Int) -> Double? {
        guard phases.indices.contains(index), let duration = phases[index].duration else { return nil }
        return starts[index] + duration
    }

    public func phaseIndex(at elapsed: Double) -> Int {
        var low = 0
        var high = phases.count - 1
        while low < high {
            let mid = (low + high + 1) / 2
            if starts[mid] <= elapsed {
                low = mid
            } else {
                high = mid - 1
            }
        }
        return low
    }

    public func snapshot(for run: TimerRun, at now: Date) -> TimerSnapshot {
        let rawElapsed = run.elapsed(at: now)
        let total = totalDuration
        let naturalFinish = total.map { rawElapsed >= $0 } ?? false
        let elapsed = total.map { min(rawElapsed, $0) } ?? rawElapsed
        let index = phaseIndex(at: naturalFinish ? max(0, elapsed - 0.000_001) : elapsed)
        let phase = phases[index]
        let phaseElapsed = max(0, elapsed - starts[index])
        let phaseRemaining = phase.duration.map { max(0, $0 - phaseElapsed) }
        let progress: Double
        if let duration = phase.duration, duration > 0 {
            progress = min(1, phaseElapsed / duration)
        } else {
            progress = 0
        }
        let finished = run.isFinished || naturalFinish
        return TimerSnapshot(
            elapsed: elapsed,
            workElapsed: max(0, elapsed - leadIn),
            phaseIndex: index,
            phase: phase,
            phaseElapsed: phaseElapsed,
            phaseRemaining: phaseRemaining,
            phaseProgress: finished ? 1 : progress,
            totalRemaining: total.map { max(0, $0 - elapsed) },
            isFinished: finished,
            isPaused: run.isPaused,
            nextPhase: index + 1 < phases.count ? phases[index + 1] : nil,
            roundsCompleted: run.roundSplits.count
        )
    }

    /// Summarizes a finished (or stopped) run.
    public func result(for run: TimerRun, at now: Date, extraReps: Int = 0) -> BlockResult {
        let snapshot = self.snapshot(for: run, at: now)
        let rounds: Int
        switch config.kind {
        case .amrap, .forTime:
            rounds = run.roundSplits.count
        case .stopwatch, .countdown:
            rounds = run.roundSplits.count
        case .emom, .tabata, .intervals, .custom, .deathBy:
            rounds = completedWorkPhases(atElapsed: snapshot.elapsed)
        }
        let reachedEnd = totalDuration.map { snapshot.elapsed >= $0 - 0.01 } ?? false
        let finished: Bool
        switch config.kind {
        case .forTime:
            // Beating the cap is a finish; hitting it means the athlete was capped.
            finished = !(totalDuration != nil && reachedEnd)
        case .stopwatch:
            finished = true
        default:
            finished = reachedEnd
        }
        return BlockResult(
            rounds: rounds,
            extraReps: max(0, extraReps),
            elapsed: snapshot.workElapsed,
            finished: finished,
            roundSplits: run.roundSplits
        )
    }

    /// Work intervals that ran their full length by `elapsed`.
    public func completedWorkPhases(atElapsed elapsed: Double) -> Int {
        var count = 0
        for (index, phase) in phases.enumerated() where phase.kind == .work {
            if let end = end(ofPhase: index), elapsed >= end - 0.01 {
                count += 1
            }
        }
        return count
    }
}

public struct TimerSnapshot: Hashable, Sendable {
    /// Seconds since start including the lead-in.
    public var elapsed: Double
    /// Seconds since the lead-in ended.
    public var workElapsed: Double
    public var phaseIndex: Int
    public var phase: TimerPhase
    public var phaseElapsed: Double
    public var phaseRemaining: Double?
    public var phaseProgress: Double
    public var totalRemaining: Double?
    public var isFinished: Bool
    public var isPaused: Bool
    public var nextPhase: TimerPhase?
    public var roundsCompleted: Int

    /// The number to show in big type.
    public var clockValue: Double {
        if phase.countsUp || phaseRemaining == nil {
            return phaseElapsed
        }
        return phaseRemaining ?? 0
    }

    public var clockText: String {
        if phase.countsUp || phaseRemaining == nil {
            return DurationFormat.clock(phaseElapsed)
        }
        return DurationFormat.countdownClock(phaseRemaining ?? 0)
    }
}

/// Persistable state of one timer run.
public struct TimerRun: Hashable, Codable, Sendable {
    public var config: TimerConfig
    public var startedAt: Date
    public var pausedAt: Date?
    public var pausedTotal: Double
    /// Seconds added by skipping forward (negative after going back).
    public var offset: Double
    public var finishedAt: Date?
    public var finishedElapsed: Double?
    /// Work-elapsed seconds at each round (or lap) tap.
    public var roundSplits: [Double]

    public init(config: TimerConfig, startedAt: Date) {
        self.config = config
        self.startedAt = startedAt
        self.pausedAt = nil
        self.pausedTotal = 0
        self.offset = 0
        self.finishedAt = nil
        self.finishedElapsed = nil
        self.roundSplits = []
    }

    enum CodingKeys: String, CodingKey {
        case config, startedAt, pausedAt, pausedTotal, offset, finishedAt, finishedElapsed, roundSplits
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        config = c.value(.config, default: TimerConfig.standard(.stopwatch))
        startedAt = c.value(.startedAt, default: Date())
        pausedAt = c.optionalValue(.pausedAt)
        pausedTotal = c.value(.pausedTotal, default: 0)
        offset = c.value(.offset, default: 0)
        finishedAt = c.optionalValue(.finishedAt)
        finishedElapsed = c.optionalValue(.finishedElapsed)
        roundSplits = c.value(.roundSplits, default: [])
    }

    public var isPaused: Bool { pausedAt != nil && finishedElapsed == nil }
    public var isFinished: Bool { finishedElapsed != nil }

    public func elapsed(at now: Date) -> Double {
        if let finishedElapsed { return finishedElapsed }
        let reference = pausedAt ?? now
        return max(0, reference.timeIntervalSince(startedAt) - pausedTotal + offset)
    }

    public mutating func pause(at now: Date) {
        guard pausedAt == nil, !isFinished else { return }
        pausedAt = now
    }

    public mutating func resume(at now: Date) {
        guard let pausedAt, !isFinished else { return }
        pausedTotal += max(0, now.timeIntervalSince(pausedAt))
        self.pausedAt = nil
    }

    public mutating func finish(at now: Date, program: TimerProgram) {
        guard !isFinished else { return }
        var value = elapsed(at: now)
        if let total = program.totalDuration { value = min(value, total) }
        finishedElapsed = value
        finishedAt = now
        pausedAt = nil
    }

    /// Jumps to the start of the next phase (or finishes on the last one).
    public mutating func skipPhase(at now: Date, program: TimerProgram) {
        guard !isFinished else { return }
        let current = elapsed(at: now)
        let index = program.phaseIndex(at: current)
        if index + 1 < program.phases.count {
            offset += program.starts[index + 1] - current
        } else {
            finish(at: now, program: program)
        }
    }

    /// Restarts the current phase, or goes to the previous one when the
    /// current phase has only just begun.
    public mutating func previousPhase(at now: Date, program: TimerProgram) {
        guard !isFinished else { return }
        let current = elapsed(at: now)
        let index = program.phaseIndex(at: current)
        let intoPhase = current - program.starts[index]
        let target: Double
        if intoPhase > 2 || index == 0 {
            target = program.starts[index]
        } else {
            target = program.starts[index - 1]
        }
        offset -= current - target
    }

    public mutating func markRound(at now: Date, program: TimerProgram) {
        guard !isFinished else { return }
        let work = max(0, elapsed(at: now) - program.leadIn)
        roundSplits.append(work)
    }

    public mutating func undoRound() {
        if !roundSplits.isEmpty { roundSplits.removeLast() }
    }
}

public enum TimerCue: Hashable, Sendable {
    /// 3, 2, 1 before a phase ends.
    case countdown(Int)
    case phaseStart(TimerPhase)
    case halfway
    /// Seconds left in a long phase (60, 30, 10).
    case remaining(Int)
    /// Whole minutes elapsed in a count-up phase.
    case minuteMark(Int)
    case finished
}

public enum TimerCueDetector {
    /// Cues to fire when the display moves from `old` to `new`. Crossing
    /// several phases at once (after the app was suspended) only announces
    /// where the run is now.
    public static func cues(from old: TimerSnapshot?, to new: TimerSnapshot) -> [TimerCue] {
        if new.isFinished {
            if let old, old.isFinished { return [] }
            return [.finished]
        }
        guard let old, !old.isFinished else {
            return [.phaseStart(new.phase)]
        }
        if new.phaseIndex != old.phaseIndex {
            return [.phaseStart(new.phase)]
        }

        var cues: [TimerCue] = []
        let phase = new.phase
        if let duration = phase.duration, let before = old.phaseRemaining, let after = new.phaseRemaining {
            if duration >= 120 {
                for mark in [60, 30] where Double(mark) < duration {
                    if before > Double(mark), after <= Double(mark) {
                        cues.append(.remaining(mark))
                    }
                }
            }
            if duration >= 45, before > 10, after <= 10 {
                cues.append(.remaining(10))
            }
            if duration >= 240, phase.kind == .work, !phase.countsUp {
                let half = duration / 2
                if before > half, after <= half {
                    cues.append(.halfway)
                }
            }
            if duration >= 4 {
                for tick in [3, 2, 1] where before > Double(tick) && after <= Double(tick) {
                    cues.append(.countdown(tick))
                }
            }
        }
        if phase.countsUp || phase.duration == nil, cues.isEmpty {
            let beforeMinutes = Int(old.phaseElapsed / 60)
            let afterMinutes = Int(new.phaseElapsed / 60)
            if afterMinutes > beforeMinutes, afterMinutes > 0 {
                cues.append(.minuteMark(afterMinutes))
            }
        }
        return cues
    }
}
