import Foundation

public enum TimerKind: String, ResilientStringEnum, Identifiable, Hashable, Sendable {
    case stopwatch
    case countdown
    case forTime = "for_time"
    case amrap
    case emom
    case tabata
    case intervals
    case custom
    case deathBy = "death_by"

    public static var fallback: TimerKind { .stopwatch }
    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .stopwatch: return "Stopwatch"
        case .countdown: return "Countdown"
        case .forTime: return "For Time"
        case .amrap: return "AMRAP"
        case .emom: return "EMOM"
        case .tabata: return "Tabata"
        case .intervals: return "Intervals"
        case .custom: return "Custom"
        case .deathBy: return "Death By"
        }
    }

    public var tagline: String {
        switch self {
        case .stopwatch: return "Count up with laps"
        case .countdown: return "Simple countdown"
        case .forTime: return "Finish the work as fast as possible"
        case .amrap: return "As many rounds as possible"
        case .emom: return "Every minute on the minute"
        case .tabata: return "20s on, 10s off, 8 rounds"
        case .intervals: return "Work and rest intervals (HIIT)"
        case .custom: return "Build your own sequence"
        case .deathBy: return "Add a rep every minute until you can't"
        }
    }

    public var symbolName: String {
        switch self {
        case .stopwatch: return "stopwatch"
        case .countdown: return "timer"
        case .forTime: return "flag.checkered"
        case .amrap: return "arrow.triangle.2.circlepath"
        case .emom: return "clock.arrow.circlepath"
        case .tabata: return "bolt.heart"
        case .intervals: return "waveform.path.ecg"
        case .custom: return "slider.horizontal.3"
        case .deathBy: return "flame"
        }
    }

    /// Formats that make sense as a block inside a routine.
    public static var blockKinds: [TimerKind] {
        [.amrap, .emom, .forTime, .tabata, .intervals, .deathBy, .custom]
    }

    /// Whether the athlete taps to count rounds while it runs.
    public var countsRounds: Bool {
        self == .amrap || self == .forTime
    }
}

public enum SegmentKind: String, ResilientStringEnum, Hashable, Sendable {
    case work
    case rest

    public static var fallback: SegmentKind { .work }
}

public struct IntervalSegment: Identifiable, Hashable, Codable, Sendable {
    public var id: UUID
    public var name: String
    public var duration: Double
    public var kind: SegmentKind

    public init(id: UUID = UUID(), name: String, duration: Double, kind: SegmentKind) {
        self.id = id
        self.name = name
        self.duration = duration
        self.kind = kind
    }

    enum CodingKeys: String, CodingKey { case id, name, duration, kind }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = c.value(.id, default: UUID())
        name = c.value(.name, default: "")
        duration = max(0, c.value(.duration, default: 30.0))
        kind = c.value(.kind, default: .work)
    }
}

/// Every interval format is described by one flat, forward-compatible
/// configuration. Fields that don't apply to a kind are ignored.
public struct TimerConfig: Hashable, Codable, Sendable {
    public var kind: TimerKind
    /// Countdown and AMRAP length; For Time cap (0 = no cap).
    public var duration: Double
    /// EMOM / Death By interval length.
    public var interval: Double
    /// Rounds per set (EMOM, Tabata, Intervals); target rounds for For Time
    /// (0 = not tracked); maximum rounds for Death By.
    public var rounds: Int
    public var work: Double
    public var rest: Double
    /// Number of sets (Tabata/Intervals) or repeats (Custom).
    public var sets: Int
    public var restBetweenSets: Double
    public var segments: [IntervalSegment]
    /// Get-ready countdown before the first interval.
    public var leadIn: Double
    /// Drop the rest that would follow the very last work interval.
    public var skipLastRest: Bool
    public var startReps: Int
    public var repIncrement: Int
    /// With several movements in a timed block: true = one movement per
    /// interval in rotation ("odd minutes / even minutes"), false = every
    /// movement in every interval.
    public var alternateMovements: Bool

    public init(
        kind: TimerKind,
        duration: Double = 0,
        interval: Double = 60,
        rounds: Int = 1,
        work: Double = 20,
        rest: Double = 10,
        sets: Int = 1,
        restBetweenSets: Double = 60,
        segments: [IntervalSegment] = [],
        leadIn: Double = 10,
        skipLastRest: Bool = true,
        startReps: Int = 1,
        repIncrement: Int = 1,
        alternateMovements: Bool = false
    ) {
        self.kind = kind
        self.duration = duration
        self.interval = interval
        self.rounds = rounds
        self.work = work
        self.rest = rest
        self.sets = sets
        self.restBetweenSets = restBetweenSets
        self.segments = segments
        self.leadIn = leadIn
        self.skipLastRest = skipLastRest
        self.startReps = startReps
        self.repIncrement = repIncrement
        self.alternateMovements = alternateMovements
    }

    enum CodingKeys: String, CodingKey {
        case kind, duration, interval, rounds, work, rest, sets, restBetweenSets
        case segments, leadIn, skipLastRest, startReps, repIncrement, alternateMovements
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        kind = c.value(.kind, default: .stopwatch)
        duration = c.value(.duration, default: 0)
        interval = c.value(.interval, default: 60)
        rounds = c.value(.rounds, default: 1)
        work = c.value(.work, default: 20)
        rest = c.value(.rest, default: 10)
        sets = c.value(.sets, default: 1)
        restBetweenSets = c.value(.restBetweenSets, default: 60)
        segments = c.value(.segments, default: [])
        leadIn = c.value(.leadIn, default: 10)
        skipLastRest = c.value(.skipLastRest, default: true)
        startReps = c.value(.startReps, default: 1)
        repIncrement = c.value(.repIncrement, default: 1)
        alternateMovements = c.value(.alternateMovements, default: false)
    }

    // MARK: Presets

    public static func standard(_ kind: TimerKind) -> TimerConfig {
        switch kind {
        case .stopwatch:
            return TimerConfig(kind: .stopwatch, leadIn: 3)
        case .countdown:
            return TimerConfig(kind: .countdown, duration: 5 * 60, leadIn: 3)
        case .forTime:
            return TimerConfig(kind: .forTime, duration: 20 * 60, rounds: 0)
        case .amrap:
            return TimerConfig(kind: .amrap, duration: 12 * 60)
        case .emom:
            return TimerConfig(kind: .emom, interval: 60, rounds: 10)
        case .tabata:
            return TimerConfig(kind: .tabata, rounds: 8, work: 20, rest: 10, sets: 1, restBetweenSets: 60)
        case .intervals:
            return TimerConfig(kind: .intervals, rounds: 10, work: 40, rest: 20, sets: 1, restBetweenSets: 60)
        case .custom:
            return TimerConfig(
                kind: .custom,
                sets: 3,
                restBetweenSets: 60,
                segments: [
                    IntervalSegment(name: "Work", duration: 45, kind: .work),
                    IntervalSegment(name: "Rest", duration: 15, kind: .rest),
                ]
            )
        case .deathBy:
            return TimerConfig(kind: .deathBy, interval: 60, rounds: 30, startReps: 1, repIncrement: 1)
        }
    }

    /// Clamps values into sane ranges so a bad input can never produce an
    /// empty or endless program.
    public func sanitized() -> TimerConfig {
        var copy = self
        copy.duration = min(max(copy.duration, 0), 24 * 3600)
        copy.interval = min(max(copy.interval, 5), 3600)
        copy.rounds = min(max(copy.rounds, 0), 500)
        copy.work = min(max(copy.work, 1), 3600)
        copy.rest = min(max(copy.rest, 0), 3600)
        copy.sets = min(max(copy.sets, 1), 50)
        copy.restBetweenSets = min(max(copy.restBetweenSets, 0), 3600)
        copy.leadIn = min(max(copy.leadIn, 0), 60)
        copy.startReps = min(max(copy.startReps, 1), 1000)
        copy.repIncrement = min(max(copy.repIncrement, 1), 100)
        copy.segments = copy.segments.map { segment in
            var s = segment
            s.duration = min(max(s.duration, 1), 3600)
            return s
        }
        switch copy.kind {
        case .countdown, .amrap:
            if copy.duration < 1 { copy.duration = 60 }
        case .emom, .tabata, .intervals, .deathBy:
            if copy.rounds < 1 { copy.rounds = 1 }
        case .custom:
            if copy.segments.isEmpty {
                copy.segments = [IntervalSegment(name: "Work", duration: 30, kind: .work)]
            }
        case .stopwatch, .forTime:
            break
        }
        return copy
    }

    /// Short human description, e.g. "EMOM 1:00 × 10" or "Tabata 20/10 × 8".
    public var summary: String {
        switch kind {
        case .stopwatch:
            return "Stopwatch"
        case .countdown:
            return "Countdown \(DurationFormat.clock(duration))"
        case .forTime:
            var text = "For Time"
            if rounds > 0 { text += " · \(rounds) rounds" }
            if duration > 0 { text += " · cap \(DurationFormat.clock(duration))" }
            return text
        case .amrap:
            return "AMRAP \(DurationFormat.clock(duration))"
        case .emom:
            if interval == 60 {
                return "EMOM \(rounds) min"
            }
            return "Every \(DurationFormat.clock(interval)) × \(rounds)"
        case .tabata, .intervals:
            var text = "\(kind.displayName) \(Int(work))s/\(Int(rest))s × \(rounds)"
            if sets > 1 { text += " × \(sets) sets" }
            return text
        case .custom:
            let segmentText = segments.map { "\($0.name) \(DurationFormat.compact($0.duration))" }.joined(separator: ", ")
            return sets > 1 ? "\(segmentText) × \(sets)" : segmentText
        case .deathBy:
            return "Death By · every \(DurationFormat.clock(interval))"
        }
    }
}

public enum DurationFormat {
    /// "0:45", "12:00", "1:02:03".
    public static func clock(_ seconds: Double, showHours: Bool = false) -> String {
        let total = max(0, Int(seconds.rounded(.down)))
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        let secs = total % 60
        if hours > 0 || showHours {
            return String(format: "%d:%02d:%02d", hours, minutes, secs)
        }
        return String(format: "%d:%02d", minutes, secs)
    }

    /// Clock format that rounds up, for countdowns ("0:03" until it's done).
    public static func countdownClock(_ seconds: Double) -> String {
        clock(max(0, seconds).rounded(.up))
    }

    /// "45s", "2m", "1m 30s", "1h 5m".
    public static func compact(_ seconds: Double) -> String {
        let total = max(0, Int(seconds.rounded()))
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        let secs = total % 60
        if hours > 0 {
            return minutes > 0 ? "\(hours)h \(minutes)m" : "\(hours)h"
        }
        if minutes > 0 {
            return secs > 0 ? "\(minutes)m \(secs)s" : "\(minutes)m"
        }
        return "\(secs)s"
    }

    /// Parses "90", "1:30", "1:02:03" into seconds.
    public static func parse(_ text: String) -> Double? {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return nil }
        let parts = trimmed.split(separator: ":", omittingEmptySubsequences: false).map(String.init)
        guard parts.count <= 3 else { return nil }
        var total = 0.0
        for part in parts {
            let normalized = part.replacingOccurrences(of: ",", with: ".")
            guard let value = Double(normalized.isEmpty ? "0" : normalized), value >= 0 else { return nil }
            total = total * 60 + value
        }
        return total
    }
}
