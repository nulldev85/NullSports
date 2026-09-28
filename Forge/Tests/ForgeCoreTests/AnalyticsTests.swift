import Foundation
import XCTest
@testable import ForgeCore

final class RecordBookTests: XCTestCase {
    private func records(_ workout: Workout) -> [SetRecord] {
        workout.allExercises.flatMap { exercise in
            exercise.sets.filter(\.isCompleted).map {
                SetRecord(workoutID: workout.id, date: workout.startedAt, exerciseID: exercise.exerciseID, tracking: exercise.tracking, kind: $0.kind, weight: $0.weight, reps: $0.reps, duration: $0.duration, distance: $0.distance)
            }
        }
    }

    func testFirstPerformanceIsBaselineAndImprovementsArePRs() {
        let w1 = Fixtures.workout(on: Fixtures.date(1), [(Fixtures.bench, [(100, 5), (100, 5)])])
        let w2 = Fixtures.workout(on: Fixtures.date(8), [(Fixtures.bench, [(105, 3), (90, 8)])])
        let w3 = Fixtures.workout(on: Fixtures.date(15), [(Fixtures.bench, [(100, 5)])])
        let book = RecordBook(records: records(w3) + records(w1) + records(w2))

        XCTAssertTrue(book.prs(in: w1.id).isEmpty)
        let prs = Dictionary(uniqueKeysWithValues: book.prs(in: w2.id).map { ($0.kind, $0) })
        XCTAssertEqual(prs[.heaviestWeight]?.value, 105)
        XCTAssertEqual(prs[.heaviestWeight]?.previousValue, 100)
        XCTAssertEqual(prs[.mostReps]?.value, 8)
        XCTAssertEqual(prs[.bestSessionVolume]?.value ?? 0, 105 * 3 + 90 * 8, accuracy: 0.001)
        XCTAssertNil(prs[.bestOneRepMax], "115.5 (105×3) doesn't beat 116.7 (100×5)")
        XCTAssertTrue(book.prs(in: w3.id).isEmpty)
    }

    func testOneRepMaxRecord() {
        let w1 = Fixtures.workout(on: Fixtures.date(1), [(Fixtures.bench, [(100, 5)])])
        let w2 = Fixtures.workout(on: Fixtures.date(8), [(Fixtures.bench, [(100, 8)])])
        let book = RecordBook(records: records(w1) + records(w2))
        let pr = book.prs(in: w2.id).first { $0.kind == .bestOneRepMax }
        XCTAssertEqual(pr?.value ?? 0, 100 * (1 + 8.0 / 30), accuracy: 0.001)
        XCTAssertEqual(pr?.reps, 8)
    }

    func testWarmupsNeverCount() {
        var w1 = Fixtures.workout(on: Fixtures.date(1), [(Fixtures.bench, [(100, 5)])])
        var w2 = Fixtures.workout(on: Fixtures.date(8), [(Fixtures.bench, [(140, 1), (100, 5)])])
        w2.blocks[0].exercises[0].sets[0].kind = .warmup
        w1.blocks[0].exercises[0].sets[0].kind = .normal
        let book = RecordBook(records: records(w1) + records(w2))
        XCTAssertNil(book.prs(in: w2.id).first { $0.kind == .heaviestWeight })
    }

    func testPaceLowerIsBetter() {
        func run(_ day: Int, meters: Double, seconds: Double) -> Workout {
            var workout = Fixtures.workout(on: Fixtures.date(day), [])
            workout.blocks = [WorkoutBlock(exercises: [WorkoutExercise(exerciseID: Fixtures.run.id, name: "Run", tracking: .distanceDuration, sets: [WorkoutSet(duration: seconds, distance: meters, isCompleted: true)])])]
            return workout
        }
        let slow = run(1, meters: 5000, seconds: 1500)
        let fast = run(8, meters: 5000, seconds: 1400)
        let book = RecordBook(records: records(slow) + records(fast))
        let pace = book.prs(in: fast.id).first { $0.kind == .bestPace }
        XCTAssertEqual(pace?.value ?? 0, 280, accuracy: 0.001)
        XCTAssertNil(book.prs(in: fast.id).first { $0.kind == .longestDistance }, "equal distance is not a record")
    }
}

final class StatsTests: XCTestCase {
    private func summary(_ date: Date, volume: Double = 1000, sets: Int = 10) -> WorkoutSummary {
        WorkoutSummary(id: UUID(), kind: .strength, name: "W", startedAt: date, duration: 3600, setCount: sets, volume: volume)
    }

    func testWeeklyBucketsAndTotals() {
        let calendar = Fixtures.utcCalendar
        let now = Fixtures.date(18) // Wednesday 18 March 2026
        let summaries = [summary(Fixtures.date(16)), summary(Fixtures.date(18)), summary(Fixtures.date(10)), summary(Fixtures.date(1))]
        let weeks = Stats.weekly(summaries, weeks: 3, calendar: calendar, now: now)
        XCTAssertEqual(weeks.count, 3)
        XCTAssertEqual(weeks.map(\.totals.workouts), [0, 1, 2])
        XCTAssertEqual(weeks.last?.start, Fixtures.date(16, hour: 0))
        XCTAssertEqual(Stats.totals(summaries, from: Fixtures.date(9)).volume, 3000)
    }

    func testWeekStreak() {
        let calendar = Fixtures.utcCalendar
        let now = Fixtures.date(18)
        // Current week empty so far, but the three previous weeks were active.
        let summaries = [summary(Fixtures.date(10)), summary(Fixtures.date(3)), summary(Fixtures.date(24, month: 2))]
        XCTAssertEqual(Stats.weekStreak(summaries, calendar: calendar, now: now), 3)
        XCTAssertEqual(Stats.weekStreak(summaries + [summary(Fixtures.date(17))], calendar: calendar, now: now), 4)
        XCTAssertEqual(Stats.weekStreak([summary(Fixtures.date(1, month: 1))], calendar: calendar, now: now), 0)
    }

    func testMuscleShares() {
        let workout = Fixtures.workout(on: Fixtures.date(1), [(Fixtures.bench, [(100, 5), (100, 5)]), (Fixtures.squat, [(100, 5)])])
        let records = workout.allExercises.flatMap { exercise in
            exercise.sets.map { SetRecord(workoutID: workout.id, date: workout.startedAt, exerciseID: exercise.exerciseID, tracking: exercise.tracking, weight: $0.weight, reps: $0.reps) }
        }
        let shares = Stats.muscleShares(records, lookup: Fixtures.lookup)
        let byMuscle = Dictionary(uniqueKeysWithValues: shares.map { ($0.muscle, $0.sets) })
        XCTAssertEqual(byMuscle[.chest], 2)
        XCTAssertEqual(byMuscle[.triceps], 1)
        XCTAssertEqual(byMuscle[.quadriceps], 1)
        XCTAssertEqual(byMuscle[.glutes], 0.5)
        XCTAssertEqual(shares.first?.muscle, .chest)
    }

    func testExerciseSeries() {
        let sessions = [
            ExerciseSession(id: UUID(), workoutID: UUID(), workoutName: "B", date: Fixtures.date(8), tracking: .weightReps, sets: [WorkoutSet(weight: 100, reps: 5, isCompleted: true)]),
            ExerciseSession(id: UUID(), workoutID: UUID(), workoutName: "A", date: Fixtures.date(1), tracking: .weightReps, sets: [WorkoutSet(weight: 90, reps: 5, isCompleted: true), WorkoutSet(kind: .warmup, weight: 200, reps: 1, isCompleted: true)]),
        ]
        let points = Stats.series(sessions, metric: .maxWeight)
        XCTAssertEqual(points.map(\.value), [90, 100], "sorted oldest first, warm-ups ignored")
        let volume = Stats.series(sessions, metric: .sessionVolume)
        XCTAssertEqual(volume.map(\.value), [450, 500])
    }
}

final class CalculatorTests: XCTestCase {
    func testPlateCalculatorExactLoads() {
        let load = PlateCalculator.load(target: 142.5, bar: 20, inventory: PlateStock.standardKilograms)
        XCTAssertTrue(load.isExact)
        XCTAssertEqual(load.perSide, [25, 25, 10, 1.25])
        XCTAssertEqual(load.achieved, 142.5, accuracy: 0.0001)

        let pounds = PlateCalculator.load(target: 315, bar: 45, inventory: PlateStock.standardPounds)
        XCTAssertEqual(pounds.perSide, [45, 45, 45])
    }

    func testPlateCalculatorRespectsInventoryAndRoundsDown() {
        let limited = [PlateStock(weight: 20, pairs: 1), PlateStock(weight: 10, pairs: 3), PlateStock(weight: 2.5, pairs: 1)]
        let load = PlateCalculator.load(target: 130, bar: 20, inventory: limited)
        // 55 per side wanted; 20 + 10 + 10 + 10 + 2.5 = 52.5 is the best available.
        XCTAssertEqual(load.perSide, [20, 10, 10, 10, 2.5])
        XCTAssertEqual(load.remainder, 5, accuracy: 0.0001)
        XCTAssertFalse(load.isExact)

        let belowBar = PlateCalculator.load(target: 15, bar: 20, inventory: PlateStock.standardKilograms)
        XCTAssertTrue(belowBar.perSide.isEmpty)

        // Heaviest-first would stop at 10; the exact search finds 7.5 + 7.5.
        let odd = [PlateStock(weight: 10, pairs: 1), PlateStock(weight: 7.5, pairs: 2)]
        XCTAssertEqual(PlateCalculator.load(target: 50, bar: 20, inventory: odd).perSide, [7.5, 7.5])
    }

    func testOneRepMaxAndWarmups() {
        XCTAssertEqual(OneRepMax.estimate(weight: 100, reps: 1), 100)
        XCTAssertEqual(OneRepMax.estimate(weight: 100, reps: 10) ?? 0, 133.333, accuracy: 0.01)
        XCTAssertNil(OneRepMax.estimate(weight: 100, reps: 20))
        XCTAssertEqual(OneRepMax.weight(forReps: 10, oneRepMax: 133.333), 100, accuracy: 0.01)
        XCTAssertEqual(OneRepMax.table(oneRepMax: 200).first?.weight, 200)

        let steps = WarmupCalculator.steps(workingWeight: 140, bar: 20, increment: 2.5)
        XCTAssertEqual(steps.map(\.weight), [20, 55, 85, 112.5])
        XCTAssertEqual(steps.map(\.reps), [10, 5, 3, 2])
        XCTAssertTrue(WarmupCalculator.steps(workingWeight: 20, bar: 20, increment: 2.5).isEmpty)
    }
}

final class UnitsTests: XCTestCase {
    let posix = Locale(identifier: "en_US_POSIX")

    func testWeightConversionRoundTrips() {
        for pounds in stride(from: 2.5, through: 1000, by: 2.5) {
            let kg = WeightUnit.lb.toKilograms(pounds)
            XCTAssertEqual(WeightUnit.lb.fromKilograms(kg), pounds, accuracy: 1e-9)
        }
        XCTAssertEqual(WeightUnit.lb.fromKilograms(100), 220.462, accuracy: 0.001)
    }

    func testFormatting() {
        let kg = UnitPreferences(weight: .kg, distance: .kilometers, length: .centimeters, locale: posix)
        XCTAssertEqual(kg.weight(102.5), "102.5 kg")
        XCTAssertEqual(kg.weight(100), "100 kg")
        XCTAssertEqual(kg.volume(12345.6), "12,346 kg")
        XCTAssertEqual(kg.distance(5200, short: false), "5.2 km")
        XCTAssertEqual(kg.distance(40, short: true), "40 m")
        XCTAssertEqual(kg.pace(meters: 5000, seconds: 1500), "5:00 /km")

        let lb = UnitPreferences(weight: .lb, distance: .miles, length: .inches, locale: posix)
        XCTAssertEqual(lb.weight(WeightUnit.lb.toKilograms(225)), "225 lb")
        XCTAssertEqual(lb.setDescription(weight: WeightUnit.lb.toKilograms(45), reps: 8, duration: nil, distance: nil, tracking: .weightedBodyweight), "+45 lb × 8")
        XCTAssertEqual(lb.setDescription(weight: nil, reps: nil, duration: 95, distance: nil, tracking: .duration), "1:35")
    }

    func testDecimalParsing() {
        XCTAssertEqual(NumberFormatting.parseDecimal("80"), 80)
        XCTAssertEqual(NumberFormatting.parseDecimal("80.5"), 80.5)
        XCTAssertEqual(NumberFormatting.parseDecimal("80,5"), 80.5)
        XCTAssertEqual(NumberFormatting.parseDecimal(" 1,234.5 "), 1234.5)
        XCTAssertEqual(NumberFormatting.parseDecimal("1.234,5"), 1234.5)
        XCTAssertNil(NumberFormatting.parseDecimal(""))
        XCTAssertNil(NumberFormatting.parseDecimal("abc"))
        XCTAssertNil(NumberFormatting.parseDecimal("1e400"))
    }

    func testDurationFormatting() {
        XCTAssertEqual(DurationFormat.clock(0), "0:00")
        XCTAssertEqual(DurationFormat.clock(754), "12:34")
        XCTAssertEqual(DurationFormat.clock(3723), "1:02:03")
        XCTAssertEqual(DurationFormat.countdownClock(2.1), "0:03")
        XCTAssertEqual(DurationFormat.compact(90), "1m 30s")
        XCTAssertEqual(DurationFormat.compact(3900), "1h 5m")
        XCTAssertEqual(DurationFormat.parse("90"), 90)
        XCTAssertEqual(DurationFormat.parse("1:30"), 90)
        XCTAssertEqual(DurationFormat.parse("1:02:03"), 3723)
        XCTAssertEqual(DurationFormat.parse("0,5"), 0.5)
        XCTAssertNil(DurationFormat.parse("1:2:3:4"))
        XCTAssertNil(DurationFormat.parse("x"))
    }
}
