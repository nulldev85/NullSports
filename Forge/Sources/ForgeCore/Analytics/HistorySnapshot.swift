import Foundation

/// History as the screens show it — the workout list, records and every
/// derived number — loaded in one pass so it can be built off the main
/// thread and swapped in all at once.
public struct HistorySnapshot: Sendable {
    public var summaries: [WorkoutSummary]
    public var deleted: [WorkoutSummary]
    public var setRecords: [SetRecord]
    public var records: RecordBook
    /// The newest personal records, newest first.
    public var recentRecords: [PersonalRecord]
    public var digest: HistoryDigest

    public init(
        summaries: [WorkoutSummary] = [],
        deleted: [WorkoutSummary] = [],
        setRecords: [SetRecord] = [],
        records: RecordBook = RecordBook(),
        recentRecords: [PersonalRecord] = [],
        digest: HistoryDigest = HistoryDigest()
    ) {
        self.summaries = summaries
        self.deleted = deleted
        self.setRecords = setRecords
        self.records = records
        self.recentRecords = recentRecords
        self.digest = digest
    }

    /// `exercises` maps exercise IDs (built-in and custom) to exercises, for
    /// the muscles-trained numbers.
    public static func load(from database: AppDatabase, calendar: Calendar, exercises: [String: Exercise]) throws -> HistorySnapshot {
        let summaries = try database.workouts.summaries()
        let deleted = try database.workouts.summaries(deleted: true)
        let setRecords = try database.workouts.setRecords()
        let records = RecordBook(records: setRecords)
        let all: [PersonalRecord] = records.prsByWorkout.values.flatMap { $0 }
        let recent = all.sorted(by: Self.newerFirst).prefix(20)
        return HistorySnapshot(
            summaries: summaries,
            deleted: deleted,
            setRecords: setRecords,
            records: records,
            recentRecords: Array(recent),
            digest: HistoryDigest(summaries: summaries, records: setRecords, calendar: calendar, exercises: exercises)
        )
    }

    private static func newerFirst(_ lhs: PersonalRecord, _ rhs: PersonalRecord) -> Bool {
        if lhs.date != rhs.date { return lhs.date > rhs.date }
        return lhs.id < rhs.id
    }
}
