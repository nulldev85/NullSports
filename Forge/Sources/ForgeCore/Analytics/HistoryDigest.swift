import Foundation

/// Everything the History and Progress screens derive from the workout list
/// — weekly and monthly totals, streaks, muscles trained, calendar dots,
/// search text — computed once each time history changes (off the main
/// thread) instead of on every redraw.
///
/// Answers match `Stats` exactly; periods are whole weeks, so a period's
/// totals are the sum of its weeks.
public struct HistoryDigest: Sendable {
    public let calendar: Calendar
    /// Totals per week, keyed by the week's first moment.
    public private(set) var weeks: [Date: PeriodTotals] = [:]
    /// Totals per month, keyed by the month's first moment.
    public private(set) var months: [Date: PeriodTotals] = [:]
    /// The first moment of every day with a workout.
    public private(set) var workoutDays: Set<Date> = []
    /// Which month each workout belongs to, for grouping lists.
    public private(set) var monthOfWorkout: [UUID: Date] = [:]
    public private(set) var allTime = PeriodTotals()
    public private(set) var firstWorkoutDate: Date?
    /// Working sets per muscle per week (primary 1, each secondary 0.5).
    private var muscleWeeks: [Date: [MuscleGroup: Double]] = [:]
    /// Normalized name, notes, exercises and timers per workout.
    private var searchText: [UUID: String] = [:]

    public init(calendar: Calendar = .current) {
        self.calendar = calendar
    }

    public init(summaries: [WorkoutSummary], records: [SetRecord], calendar: Calendar, exercises: [String: Exercise]) {
        self.calendar = calendar
        for summary in summaries {
            let week = Stats.weekStart(of: summary.startedAt, calendar: calendar)
            let month = calendar.dateInterval(of: .month, for: summary.startedAt)?.start ?? summary.startedAt
            weeks[week, default: PeriodTotals()].add(summary)
            months[month, default: PeriodTotals()].add(summary)
            allTime.add(summary)
            workoutDays.insert(calendar.startOfDay(for: summary.startedAt))
            monthOfWorkout[summary.id] = month
            searchText[summary.id] = Self.searchText(for: summary)
            if firstWorkoutDate.map({ summary.startedAt < $0 }) ?? true {
                firstWorkoutDate = summary.startedAt
            }
        }
        // Every set of a workout shares its start date, so look each week up
        // once per workout.
        var weekOfWorkout: [UUID: Date] = [:]
        for record in records where record.kind.isWorking {
            guard let exercise = exercises[record.exerciseID] else { continue }
            let week: Date
            if let known = weekOfWorkout[record.workoutID] {
                week = known
            } else {
                week = Stats.weekStart(of: record.date, calendar: calendar)
                weekOfWorkout[record.workoutID] = week
            }
            muscleWeeks[week, default: [:]][exercise.primaryMuscle, default: 0] += 1
            for secondary in exercise.secondaryMuscles where secondary != exercise.primaryMuscle {
                muscleWeeks[week, default: [:]][secondary, default: 0] += 0.5
            }
        }
    }

    // MARK: Totals

    /// Totals of workouts from `start` (a week start) on, or of everything.
    public func totals(since start: Date?) -> PeriodTotals {
        guard let start else { return allTime }
        var totals = PeriodTotals()
        for (week, value) in weeks where week >= start {
            totals.merge(value)
        }
        return totals
    }

    /// The last `count` weeks including the current one, oldest first.
    public func weekly(weeks count: Int, now: Date = Date()) -> [WeekBucket] {
        guard count > 0 else { return [] }
        let current = Stats.weekStart(of: now, calendar: calendar)
        var buckets: [WeekBucket] = []
        for offset in stride(from: count - 1, through: 0, by: -1) {
            guard let start = calendar.date(byAdding: .weekOfYear, value: -offset, to: current) else { continue }
            buckets.append(WeekBucket(start: start, totals: weeks[start] ?? PeriodTotals()))
        }
        return buckets
    }

    /// Consecutive weeks with a workout, counting back from this week (an
    /// empty current week doesn't break the streak yet).
    public func weekStreak(now: Date = Date()) -> Int {
        var cursor = Stats.weekStart(of: now, calendar: calendar)
        var streak = 0
        if weeks[cursor] == nil {
            guard let previous = calendar.date(byAdding: .weekOfYear, value: -1, to: cursor) else { return 0 }
            cursor = previous
        }
        while weeks[cursor] != nil {
            streak += 1
            guard let previous = calendar.date(byAdding: .weekOfYear, value: -1, to: cursor) else { break }
            cursor = previous
        }
        return streak
    }

    /// Working sets per muscle since `start` (a week start), most first.
    public func muscleShares(since start: Date?) -> [MuscleShare] {
        var totals: [MuscleGroup: Double] = [:]
        for (week, muscles) in muscleWeeks {
            if let start, week < start { continue }
            for (muscle, sets) in muscles {
                totals[muscle, default: 0] += sets
            }
        }
        return totals
            .map { MuscleShare(muscle: $0.key, sets: $0.value) }
            .sorted { $0.sets == $1.sets ? $0.muscle.rawValue < $1.muscle.rawValue : $0.sets > $1.sets }
    }

    // MARK: Search

    /// Whether a workout matches an already-normalized query (see
    /// `ExerciseSearchIndex.normalize`). Each field is matched on its own.
    public func workout(_ id: UUID, matches normalizedQuery: String) -> Bool {
        guard !normalizedQuery.isEmpty else { return true }
        return searchText[id]?.contains(normalizedQuery) ?? false
    }

    static func searchText(for summary: WorkoutSummary) -> String {
        // Fields are joined with a newline, which normalized queries never
        // contain, so a match can't straddle two fields.
        ([summary.name, summary.notes] + summary.exerciseNames + summary.timerSummaries)
            .map(ExerciseSearchIndex.normalize)
            .filter { !$0.isEmpty }
            .joined(separator: "\n")
    }
}

extension PeriodTotals {
    mutating func merge(_ other: PeriodTotals) {
        workouts += other.workouts
        duration += other.duration
        volume += other.volume
        sets += other.sets
        reps += other.reps
        distance += other.distance
    }
}
