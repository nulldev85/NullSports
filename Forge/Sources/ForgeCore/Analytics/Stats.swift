import Foundation

public struct PeriodTotals: Hashable, Sendable {
    public var workouts = 0
    public var duration = 0.0
    public var volume = 0.0
    public var sets = 0
    public var reps = 0
    public var distance = 0.0

    public init() {}

    mutating func add(_ summary: WorkoutSummary) {
        workouts += 1
        duration += summary.duration
        volume += summary.volume
        sets += summary.setCount
        reps += summary.totalReps
        distance += summary.totalDistance
    }
}

public struct WeekBucket: Identifiable, Hashable, Sendable {
    public var start: Date
    public var totals: PeriodTotals
    public var id: Date { start }
}

public struct MuscleShare: Identifiable, Hashable, Sendable {
    public var muscle: MuscleGroup
    public var sets: Double
    public var id: MuscleGroup { muscle }
}

public struct ProgressPoint: Identifiable, Hashable, Sendable {
    public var date: Date
    public var value: Double
    public var workoutID: UUID
    public var id: UUID { workoutID }
}

public enum ExerciseMetric: String, CaseIterable, Identifiable, Hashable, Sendable {
    case estimatedOneRepMax
    case maxWeight
    case sessionVolume
    case maxReps
    case totalReps
    case totalDuration
    case totalDistance
    case pace

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .estimatedOneRepMax: return "Est. 1RM"
        case .maxWeight: return "Heaviest"
        case .sessionVolume: return "Volume"
        case .maxReps: return "Best Set"
        case .totalReps: return "Total Reps"
        case .totalDuration: return "Time"
        case .totalDistance: return "Distance"
        case .pace: return "Pace"
        }
    }

    public static func metrics(for tracking: TrackingType) -> [ExerciseMetric] {
        switch tracking {
        case .weightReps: return [.estimatedOneRepMax, .maxWeight, .sessionVolume, .maxReps]
        case .weightedBodyweight: return [.maxWeight, .maxReps, .sessionVolume]
        case .assistedBodyweight, .reps: return [.maxReps, .totalReps]
        case .duration: return [.totalDuration]
        case .weightDuration: return [.maxWeight, .totalDuration]
        case .distanceDuration: return [.totalDistance, .totalDuration, .pace]
        case .weightDistance: return [.maxWeight, .totalDistance]
        case .shortDistance: return [.totalDistance, .pace]
        }
    }
}

public enum Stats {
    public static func totals(_ summaries: [WorkoutSummary], from start: Date? = nil, to end: Date? = nil) -> PeriodTotals {
        var totals = PeriodTotals()
        for summary in summaries {
            if let start, summary.startedAt < start { continue }
            if let end, summary.startedAt >= end { continue }
            totals.add(summary)
        }
        return totals
    }

    public static func weekStart(of date: Date, calendar: Calendar) -> Date {
        calendar.dateInterval(of: .weekOfYear, for: date)?.start ?? calendar.startOfDay(for: date)
    }

    /// The last `weeks` weeks including the current one, oldest first.
    public static func weekly(_ summaries: [WorkoutSummary], weeks: Int, calendar: Calendar, now: Date = Date()) -> [WeekBucket] {
        guard weeks > 0 else { return [] }
        let currentStart = weekStart(of: now, calendar: calendar)
        var starts: [Date] = []
        for offset in stride(from: weeks - 1, through: 0, by: -1) {
            if let start = calendar.date(byAdding: .weekOfYear, value: -offset, to: currentStart) {
                starts.append(start)
            }
        }
        var buckets = starts.map { WeekBucket(start: $0, totals: PeriodTotals()) }
        guard let first = starts.first else { return buckets }
        for summary in summaries where summary.startedAt >= first {
            let start = weekStart(of: summary.startedAt, calendar: calendar)
            if let index = starts.firstIndex(of: start) {
                buckets[index].totals.add(summary)
            }
        }
        return buckets
    }

    /// Consecutive weeks with at least one workout, counting back from this
    /// week (an empty current week doesn't break the streak yet).
    public static func weekStreak(_ summaries: [WorkoutSummary], calendar: Calendar, now: Date = Date()) -> Int {
        let activeWeeks = Set(summaries.map { weekStart(of: $0.startedAt, calendar: calendar) })
        var cursor = weekStart(of: now, calendar: calendar)
        var streak = 0
        if !activeWeeks.contains(cursor) {
            guard let previous = calendar.date(byAdding: .weekOfYear, value: -1, to: cursor) else { return 0 }
            cursor = previous
        }
        while activeWeeks.contains(cursor) {
            streak += 1
            guard let previous = calendar.date(byAdding: .weekOfYear, value: -1, to: cursor) else { break }
            cursor = previous
        }
        return streak
    }

    public static func workoutDays(_ summaries: [WorkoutSummary], calendar: Calendar) -> Set<Date> {
        Set(summaries.map { calendar.startOfDay(for: $0.startedAt) })
    }

    /// Working sets per muscle: primary muscle counts 1, each secondary 0.5.
    public static func muscleShares(_ records: [SetRecord], since start: Date? = nil, lookup: (String) -> Exercise?) -> [MuscleShare] {
        var totals: [MuscleGroup: Double] = [:]
        for record in records where record.kind.isWorking {
            if let start, record.date < start { continue }
            guard let exercise = lookup(record.exerciseID) else { continue }
            totals[exercise.primaryMuscle, default: 0] += 1
            for secondary in exercise.secondaryMuscles where secondary != exercise.primaryMuscle {
                totals[secondary, default: 0] += 0.5
            }
        }
        return totals
            .map { MuscleShare(muscle: $0.key, sets: $0.value) }
            .sorted { $0.sets == $1.sets ? $0.muscle.rawValue < $1.muscle.rawValue : $0.sets > $1.sets }
    }

    /// One point per session, oldest first.
    public static func series(_ sessions: [ExerciseSession], metric: ExerciseMetric) -> [ProgressPoint] {
        sessions.compactMap { session -> ProgressPoint? in
            let value: Double?
            switch metric {
            case .estimatedOneRepMax: value = session.bestOneRepMax
            case .maxWeight: value = session.maxWeight
            case .sessionVolume: value = session.volume > 0 ? session.volume : nil
            case .maxReps: value = session.maxReps.map(Double.init)
            case .totalReps: value = session.totalReps > 0 ? Double(session.totalReps) : nil
            case .totalDuration: value = session.totalDuration > 0 ? session.totalDuration : nil
            case .totalDistance: value = session.totalDistance > 0 ? session.totalDistance : nil
            case .pace:
                value = session.totalDistance >= 100 && session.totalDuration > 0
                    ? session.totalDuration / (session.totalDistance / 1000)
                    : nil
            }
            guard let value, value.isFinite else { return nil }
            return ProgressPoint(date: session.date, value: value, workoutID: session.workoutID)
        }
        .sorted { $0.date < $1.date }
    }
}
