import Foundation
import XCTest
@testable import ForgeCore

final class HistoryDigestTests: XCTestCase {
    private let calendar = Fixtures.utcCalendar
    private let now = Fixtures.date(15, hour: 12, month: 9, year: 2026)

    /// A deterministic mix of workouts over two years, with streaks and gaps.
    private func makeHistory() -> (summaries: [WorkoutSummary], records: [SetRecord]) {
        var generator = SeededGenerator(seed: 42)
        var summaries: [WorkoutSummary] = []
        var records: [SetRecord] = []
        let names = ["Upper A", "Lower B", "Cindy", "Easy Run", "Push Day"]
        let exercises = Fixtures.all
        for index in 0..<260 {
            // Mostly every 2–3 days, with a few long breaks.
            let daysAgo = Double(index) * 2.6 + (index > 200 ? 40 : 0) + Double(generator.next() % 20) / 10
            let start = now.addingTimeInterval(-daysAgo * 86_400 - Double(generator.next() % 36_000))
            let id = UUID()
            let chosen = (0..<3).map { _ in exercises[Int(generator.next() % UInt64(exercises.count))] }
            summaries.append(WorkoutSummary(
                id: id,
                kind: index % 9 == 0 ? .timer : .strength,
                name: names[index % names.count],
                notes: index % 4 == 0 ? "Felt strong — new belt" : "",
                startedAt: start,
                duration: Double(1_200 + generator.next() % 3_000),
                exerciseNames: chosen.map(\.name),
                exerciseCount: chosen.count,
                setCount: Int(generator.next() % 20),
                volume: Double(generator.next() % 9_000) + 0.25,
                totalReps: Int(generator.next() % 150),
                totalDistance: Double(generator.next() % 5_000),
                timerSummaries: index % 9 == 0 ? ["AMRAP 12:00 · 7 rounds"] : []
            ))
            for exercise in chosen {
                for set in 0..<4 {
                    records.append(SetRecord(
                        workoutID: id,
                        date: start,
                        exerciseID: exercise.id,
                        tracking: exercise.tracking,
                        kind: set == 0 && index % 2 == 0 ? .warmup : .normal,
                        weight: 60,
                        reps: 5
                    ))
                }
            }
        }
        return (summaries.sorted { $0.startedAt > $1.startedAt }, records.sorted { $0.date < $1.date })
    }

    private func digest(_ history: (summaries: [WorkoutSummary], records: [SetRecord])) -> HistoryDigest {
        let exercises = Dictionary(uniqueKeysWithValues: Fixtures.all.map { ($0.id, $0) })
        return HistoryDigest(summaries: history.summaries, records: history.records, calendar: calendar, exercises: exercises)
    }

    private func assertEqual(_ lhs: PeriodTotals, _ rhs: PeriodTotals, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(lhs.workouts, rhs.workouts, file: file, line: line)
        XCTAssertEqual(lhs.sets, rhs.sets, file: file, line: line)
        XCTAssertEqual(lhs.reps, rhs.reps, file: file, line: line)
        XCTAssertEqual(lhs.duration, rhs.duration, accuracy: 0.001, file: file, line: line)
        XCTAssertEqual(lhs.volume, rhs.volume, accuracy: 0.001, file: file, line: line)
        XCTAssertEqual(lhs.distance, rhs.distance, accuracy: 0.001, file: file, line: line)
    }

    func testTotalsMatchStatsForEveryPeriod() {
        let history = makeHistory()
        let digest = digest(history)
        let thisWeek = Stats.weekStart(of: now, calendar: calendar)
        for weeks in [1, 4, 12, 26, 52, 200] {
            let start = calendar.date(byAdding: .weekOfYear, value: -(weeks - 1), to: thisWeek)
            assertEqual(digest.totals(since: start), Stats.totals(history.summaries, from: start))
        }
        assertEqual(digest.totals(since: nil), Stats.totals(history.summaries))
        XCTAssertEqual(digest.firstWorkoutDate, history.summaries.last?.startedAt)
    }

    func testWeeklyBucketsMatchStats() {
        let history = makeHistory()
        let digest = digest(history)
        for count in [4, 12, 26] {
            let expected = Stats.weekly(history.summaries, weeks: count, calendar: calendar, now: now)
            let actual = digest.weekly(weeks: count, now: now)
            XCTAssertEqual(actual.map(\.start), expected.map(\.start))
            for (lhs, rhs) in zip(actual, expected) {
                assertEqual(lhs.totals, rhs.totals)
            }
        }
    }

    func testStreakMatchesStats() {
        let history = makeHistory()
        let digest = digest(history)
        XCTAssertEqual(digest.weekStreak(now: now), Stats.weekStreak(history.summaries, calendar: calendar, now: now))
        XCTAssertGreaterThan(digest.weekStreak(now: now), 10)

        // An empty current week doesn't break the streak; an empty last week does.
        let later = now.addingTimeInterval(7 * 86_400)
        XCTAssertEqual(digest.weekStreak(now: later), Stats.weekStreak(history.summaries, calendar: calendar, now: later))
        let muchLater = now.addingTimeInterval(21 * 86_400)
        XCTAssertEqual(digest.weekStreak(now: muchLater), 0)
    }

    func testMuscleSharesMatchStats() {
        let history = makeHistory()
        let digest = digest(history)
        let thisWeek = Stats.weekStart(of: now, calendar: calendar)
        for weeks in [nil, 4, 12, 52] as [Int?] {
            let start = weeks.flatMap { calendar.date(byAdding: .weekOfYear, value: -($0 - 1), to: thisWeek) }
            let expected = Stats.muscleShares(history.records, since: start, lookup: Fixtures.lookup)
            let actual = digest.muscleShares(since: start)
            XCTAssertEqual(actual.map(\.muscle), expected.map(\.muscle))
            XCTAssertEqual(actual.map(\.sets), expected.map(\.sets))
        }
    }

    func testCalendarDaysAndMonths() {
        let history = makeHistory()
        let digest = digest(history)
        XCTAssertEqual(digest.workoutDays, Stats.workoutDays(history.summaries, calendar: calendar))
        for summary in history.summaries.prefix(40) {
            let month = calendar.dateInterval(of: .month, for: summary.startedAt)!
            XCTAssertEqual(digest.monthOfWorkout[summary.id], month.start)
            assertEqual(digest.months[month.start]!, Stats.totals(history.summaries, from: month.start, to: month.end))
        }
    }

    func testSearchMatchesFieldByField() {
        let history = makeHistory()
        let digest = digest(history)
        for query in ["upper", "BENCH press", "belt", "amrap 12", "squat barbell", "zzz", "run", "felt strong new"] {
            let key = ExerciseSearchIndex.normalize(query)
            let expected = history.summaries.filter { summary in
                ExerciseSearchIndex.normalize(summary.name).contains(key)
                    || ExerciseSearchIndex.normalize(summary.notes).contains(key)
                    || summary.exerciseNames.contains { ExerciseSearchIndex.normalize($0).contains(key) }
                    || summary.timerSummaries.contains { ExerciseSearchIndex.normalize($0).contains(key) }
            }.map(\.id)
            let actual = history.summaries.filter { digest.workout($0.id, matches: key) }.map(\.id)
            XCTAssertEqual(actual, expected, "query \(query)")
        }
        // A match can't join the end of one field to the start of the next.
        let summary = WorkoutSummary(id: UUID(), kind: .strength, name: "Leg", startedAt: now, duration: 60, exerciseNames: ["Day Press"])
        let single = HistoryDigest(summaries: [summary], records: [], calendar: calendar, exercises: [:])
        XCTAssertFalse(single.workout(summary.id, matches: ExerciseSearchIndex.normalize("leg day")))
        XCTAssertTrue(single.workout(summary.id, matches: ExerciseSearchIndex.normalize("day press")))
    }

    func testSnapshotLoadsEverythingFromTheDatabase() throws {
        let directory = TemporaryDirectory()
        let database = try AppDatabase.open(at: directory.location)
        let first = Fixtures.workout(on: Fixtures.date(2), [(Fixtures.bench, [(100, 5), (100, 5)])])
        let second = Fixtures.workout(on: Fixtures.date(9), [(Fixtures.bench, [(110, 5)])])
        try database.workouts.save(first)
        try database.workouts.save(second)

        let snapshot = try HistorySnapshot.load(from: database, calendar: calendar, exercises: [Fixtures.bench.id: Fixtures.bench])
        XCTAssertEqual(snapshot.summaries.map(\.id), [second.id, first.id], "newest first")
        XCTAssertTrue(snapshot.deleted.isEmpty)
        XCTAssertEqual(snapshot.setRecords.count, 3)
        XCTAssertEqual(snapshot.digest.totals(since: nil).workouts, 2)
        XCTAssertEqual(snapshot.digest.muscleShares(since: nil).first?.muscle, .chest)
        XCTAssertEqual(snapshot.recentRecords.first?.workoutID, second.id, "the heavier session set the newest record")
    }

    func testLastDoneFollowsTheWorkoutsInHistory() throws {
        let directory = TemporaryDirectory()
        let database = try AppDatabase.open(at: directory.location)
        let routineID = UUID()
        let otherRoutineID = UUID()
        var older = Fixtures.workout(on: Fixtures.date(2), [(Fixtures.bench, [(100, 5)])])
        older.routineID = routineID
        var newer = Fixtures.workout(on: Fixtures.date(9), [(Fixtures.bench, [(105, 5)])])
        newer.routineID = routineID
        var other = Fixtures.workout(on: Fixtures.date(12), [(Fixtures.squat, [(140, 5)])])
        other.routineID = otherRoutineID
        let unplanned = Fixtures.workout(on: Fixtures.date(14), [(Fixtures.pushUp, [(nil, 20)])])
        for workout in [older, newer, other, unplanned] {
            try database.workouts.save(workout)
        }
        func lastDone(_ id: UUID) throws -> Date? {
            try HistorySnapshot.load(from: database, calendar: calendar, exercises: [:]).digest.lastDone(routineID: id)
        }

        XCTAssertEqual(try lastDone(routineID), newer.startedAt)
        XCTAssertEqual(try lastDone(otherRoutineID), other.startedAt)
        XCTAssertNil(try lastDone(UUID()), "a routine that was never done has no date")

        // Deleting the newest session falls back to the one before it, and
        // with none left the routine counts as never done.
        try database.workouts.softDelete(workoutID: newer.id)
        XCTAssertEqual(try lastDone(routineID), older.startedAt)
        try database.workouts.softDelete(workoutID: older.id)
        XCTAssertNil(try lastDone(routineID))

        // Restoring brings it back; moving a workout to another day moves
        // "last done" with it.
        try database.workouts.restore(workoutID: newer.id)
        XCTAssertEqual(try lastDone(routineID), newer.startedAt)
        var redated = newer
        redated.startedAt = Fixtures.date(5)
        try database.workouts.save(redated)
        XCTAssertEqual(try lastDone(routineID), Fixtures.date(5))
    }

    func testEmptyHistory() {
        let digest = HistoryDigest(summaries: [], records: [], calendar: calendar, exercises: [:])
        XCTAssertEqual(digest.weekStreak(now: now), 0)
        XCTAssertEqual(digest.totals(since: nil).workouts, 0)
        XCTAssertEqual(digest.weekly(weeks: 4, now: now).count, 4)
        XCTAssertTrue(digest.muscleShares(since: nil).isEmpty)
        XCTAssertNil(digest.firstWorkoutDate)
    }
}

/// Reproducible pseudo-random numbers (SplitMix64).
struct SeededGenerator: RandomNumberGenerator {
    private var state: UInt64

    init(seed: UInt64) {
        state = seed
    }

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}
