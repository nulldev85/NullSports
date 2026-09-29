import Foundation
import XCTest
@testable import ForgeCore

/// Exercises done for a set time ("Track by Time") and the countdown each
/// timed set runs.
final class TimedSetTests: XCTestCase {
    private let farmersWalk = Exercise(id: "farmers-walk-dumbbell", name: "Farmer's Walk (Dumbbell)", primaryMuscle: .forearms, equipment: .dumbbell, category: .strongman, tracking: .weightDistance)
    private let start = Fixtures.date(5)

    private func lookup(_ id: String) -> Exercise? {
        id == farmersWalk.id ? farmersWalk : Fixtures.lookup(id)
    }

    func testEveryExerciseHasATimedVariant() {
        XCTAssertEqual(TrackingType.weightDistance.timedVariant, .weightDuration, "a carry keeps its weight")
        XCTAssertEqual(TrackingType.weightReps.timedVariant, .weightDuration)
        XCTAssertEqual(TrackingType.weightedBodyweight.timedVariant, .weightDuration)
        XCTAssertEqual(TrackingType.reps.timedVariant, .duration)
        XCTAssertEqual(TrackingType.assistedBodyweight.timedVariant, .duration)
        XCTAssertEqual(TrackingType.distanceDuration.timedVariant, .duration)
        XCTAssertEqual(TrackingType.duration.timedVariant, .duration, "already timed")
        XCTAssertEqual(TrackingType.weightDuration.timedVariant, .weightDuration)
        for tracking in TrackingType.allCases {
            XCTAssertTrue(tracking.timedVariant.isTimed)
            XCTAssertTrue(tracking.timedVariant.usesDuration)
        }
        XCTAssertFalse(TrackingType.distanceDuration.isTimed, "a run's time is a result, not a countdown")
    }

    func testRoutineTrackedByTimeStartsTimedSets() throws {
        let routine = Routine(name: "Carries", blocks: [
            RoutineBlock(exercises: [RoutineExercise(
                exerciseID: farmersWalk.id,
                sets: (0..<3).map { _ in RoutineSet(target: SetTarget(weight: 32, duration: 120, distance: 40)) },
                byTime: true
            )]),
            RoutineBlock(exercises: [RoutineExercise(exerciseID: farmersWalk.id, sets: [RoutineSet(target: SetTarget(weight: 32, distance: 40))])]),
        ])
        let workout = WorkoutFactory.workout(from: routine, lookup: lookup, now: start)
        XCTAssertEqual(workout.blocks[0].exercises[0].tracking, .weightDuration)
        XCTAssertEqual(workout.blocks[0].exercises[0].sets.map { $0.target?.duration }, [120, 120, 120])
        XCTAssertEqual(workout.blocks[1].exercises[0].tracking, .weightDistance, "the same exercise without the switch keeps its distance")

        // The switch survives a save and older routines without it read as off.
        let data = try JSONCoding.encoder().encode(routine)
        let decoded = try JSONCoding.decoder().decode(Routine.self, from: data)
        XCTAssertEqual(decoded.blocks.map { $0.exercises[0].byTime }, [true, false])
        let legacy = try JSONCoding.decoder().decode(RoutineExercise.self, from: Data(#"{"exerciseID":"plank","sets":[]}"#.utf8))
        XCTAssertFalse(legacy.byTime)
    }

    func testTypingOneTargetTimeFillsTheSetsAfterIt() {
        var entry = RoutineExercise(exerciseID: farmersWalk.id, sets: [
            RoutineSet(kind: .warmup), RoutineSet(), RoutineSet(), RoutineSet(),
        ], byTime: true)
        // Typed a keystroke at a time: 2, then 2:00.
        entry.setTargetDuration(2, at: 1)
        entry.setTargetDuration(120, at: 1)
        XCTAssertEqual(entry.sets.map(\.target.duration), [nil, 120, 120, 120], "warm-ups aren't linked")

        // A set given its own time keeps it.
        entry.setTargetDuration(90, at: 3)
        entry.setTargetDuration(150, at: 1)
        XCTAssertEqual(entry.sets.map(\.target.duration), [nil, 150, 150, 90])
        // Editing a later set never changes earlier ones.
        entry.setTargetDuration(60, at: 2)
        XCTAssertEqual(entry.sets.map(\.target.duration), [nil, 150, 60, 90])
    }

    func testPlannedTimes() {
        func entry(_ sets: [WorkoutSet]) -> WorkoutExercise {
            WorkoutExercise(exerciseID: farmersWalk.id, name: farmersWalk.name, tracking: .weightDuration, sets: sets)
        }
        // Routine targets, set by set.
        let targets = entry([120, 90, 60].map { WorkoutSet(target: SetTarget(duration: $0)) })
        XCTAssertEqual(targets.plannedDurations(), [120, 90, 60])

        // "3 × 2:00" typed once.
        let typedOnce = entry([WorkoutSet(duration: 120), WorkoutSet(), WorkoutSet()])
        XCTAssertEqual(typedOnce.plannedDurations(), [120, 120, 120])

        // Last time's times, unless a time was typed for today.
        let previous = [WorkoutSet(duration: 90), WorkoutSet(duration: 80), WorkoutSet(duration: 70)]
        XCTAssertEqual(entry([WorkoutSet(), WorkoutSet(), WorkoutSet()]).plannedDurations(previous: previous), [90, 80, 70])
        XCTAssertEqual(typedOnce.plannedDurations(previous: previous), [120, 120, 120])
        // More sets than last time: the extra follows the one before.
        XCTAssertEqual(entry([WorkoutSet(), WorkoutSet(), WorkoutSet(), WorkoutSet()]).plannedDurations(previous: previous), [90, 80, 70, 70])

        // A set stopped early logs what was done but keeps its plan as the
        // target, so the next set is still planned at the full time.
        let stoppedEarly = entry([
            WorkoutSet(duration: 105, isCompleted: true, target: SetTarget(duration: 120)),
            WorkoutSet(),
        ])
        XCTAssertEqual(stoppedEarly.plannedDurations(), [120, 120])

        // Nothing to go on: a stopwatch.
        XCTAssertEqual(entry([WorkoutSet(), WorkoutSet()]).plannedDurations(), [nil, nil])
    }

    func testCountdownWithLeadInAndPauses() {
        var timer = SetTimerState(setID: UUID(), duration: 120, leadIn: 5, startedAt: start)
        XCTAssertEqual(timer.leadInRemaining(at: start.addingTimeInterval(2)), 3, accuracy: 0.001)
        XCTAssertEqual(timer.remaining(at: start.addingTimeInterval(2)) ?? -1, 120, accuracy: 0.001, "the set's clock waits for the lead-in")
        XCTAssertEqual(timer.workStartsAt, start.addingTimeInterval(5))
        XCTAssertEqual(timer.endsAt, start.addingTimeInterval(125))
        XCTAssertEqual(timer.fractionRemaining(at: start.addingTimeInterval(65)), 0.5, accuracy: 0.001)

        // Paused 30 s into the set, resumed a minute later.
        timer.pause(at: start.addingTimeInterval(35))
        XCTAssertTrue(timer.isPaused)
        XCTAssertNil(timer.endsAt)
        XCTAssertEqual(timer.remaining(at: start.addingTimeInterval(90)) ?? -1, 90, accuracy: 0.001)
        timer.resume(at: start.addingTimeInterval(95))
        XCTAssertNil(timer.workStartsAt, "already under way")
        XCTAssertEqual(timer.endsAt, start.addingTimeInterval(185))
        XCTAssertFalse(timer.isFinished(at: start.addingTimeInterval(184)))
        XCTAssertTrue(timer.isFinished(at: start.addingTimeInterval(185)))
        XCTAssertEqual(timer.elapsed(at: start.addingTimeInterval(500)), 120, accuracy: 0.001, "never past the plan")

        // No planned time: it counts up and never finishes on its own.
        let stopwatch = SetTimerState(setID: UUID(), duration: nil, leadIn: 3, startedAt: start)
        XCTAssertNil(stopwatch.endsAt)
        XCTAssertNil(stopwatch.remaining(at: start.addingTimeInterval(10)))
        XCTAssertEqual(stopwatch.elapsed(at: start.addingTimeInterval(10)), 7, accuracy: 0.001)
        XCTAssertFalse(stopwatch.isFinished(at: start.addingTimeInterval(10_000)))
    }

    func testSwitchingToTimeClearsNumbersItWouldHide() {
        var entry = WorkoutExercise(exerciseID: farmersWalk.id, name: farmersWalk.name, tracking: .weightDistance, sets: [
            WorkoutSet(weight: 32, distance: 40, isCompleted: true, target: SetTarget(weight: 32, distance: 40)),
            WorkoutSet(weight: 32),
            WorkoutSet(target: SetTarget(weight: 32, distance: 40)),
        ])
        XCTAssertEqual(entry.setsLosingValues(switchingTo: .weightDuration), 1, "only the set with a distance entered")
        entry.retrack(.weightDuration)
        XCTAssertEqual(entry.tracking, .weightDuration)
        XCTAssertEqual(entry.sets.map(\.weight), [32, 32, nil], "weight is kept")
        XCTAssertTrue(entry.sets.allSatisfy { $0.distance == nil }, "no hidden distance gets logged")
        XCTAssertEqual(entry.sets[2].target?.distance, 40, "targets stay for switching back")
        XCTAssertEqual(entry.setsLosingValues(switchingTo: .weightDistance), 0)
    }

    func testNewEntriesRememberAnExerciseDoneByTime() throws {
        let byTime = LastPerformance(tracking: .weightDuration, sets: [WorkoutSet(weight: 32, duration: 120, isCompleted: true)])
        let byDistance = LastPerformance(tracking: .weightDistance, sets: [WorkoutSet(weight: 32, distance: 40, isCompleted: true)])
        XCTAssertEqual(farmersWalk.tracking(rememberedFrom: byTime), .weightDuration)
        XCTAssertEqual(farmersWalk.tracking(rememberedFrom: byDistance), .weightDistance)
        XCTAssertEqual(farmersWalk.tracking(rememberedFrom: nil), .weightDistance)
        // Tracked some other way than this exercise's own or its time (an
        // edited custom exercise, say): its own way.
        XCTAssertEqual(Fixtures.bench.tracking(rememberedFrom: LastPerformance(tracking: .duration, sets: [])), .weightReps)

        let entry = WorkoutFactory.entry(for: farmersWalk, lastPerformance: byTime)
        XCTAssertEqual(entry.tracking, .weightDuration)
        XCTAssertEqual(entry.sets.count, 1)

        // The database says how each exercise was last tracked.
        let directory = TemporaryDirectory()
        let database = try AppDatabase.open(at: directory.location)
        var workout = Workout(status: .completed, name: "Carries", startedAt: start, endedAt: start.addingTimeInterval(600), blocks: [
            WorkoutBlock(exercises: [WorkoutExercise(exerciseID: farmersWalk.id, name: farmersWalk.name, tracking: .weightDuration, sets: [
                WorkoutSet(weight: 32, duration: 120, isCompleted: true),
            ])]),
        ])
        workout.duration = 600
        try database.workouts.save(workout)
        let last = try database.workouts.lastPerformanceDetails(exerciseIDs: [farmersWalk.id, "never-done"])
        XCTAssertEqual(last[farmersWalk.id]?.tracking, .weightDuration)
        XCTAssertEqual(last[farmersWalk.id]?.sets.map(\.duration), [120])
        XCTAssertNil(last["never-done"])
        XCTAssertEqual(try database.workouts.lastPerformances(exerciseIDs: [farmersWalk.id])[farmersWalk.id]?.count, 1)
    }

    func testRoutinesLearnTheSwitchFromWorkouts() {
        let routine = Routine(name: "Carries", blocks: [
            RoutineBlock(exercises: [RoutineExercise(exerciseID: farmersWalk.id, sets: [RoutineSet(target: SetTarget(weight: 32, distance: 40))])]),
            RoutineBlock(exercises: [RoutineExercise(exerciseID: Fixtures.plank.id, sets: [RoutineSet(target: SetTarget(duration: 60))])]),
        ])
        var workout = WorkoutFactory.workout(from: routine, lookup: lookup, now: start)
        XCTAssertFalse(WorkoutFactory.differsFromRoutine(workout, routine: routine, lookup: lookup))

        // Switched to time during the workout.
        workout.updateExercise(workout.blocks[0].exercises[0].id) { $0.retrack(.weightDuration) }
        for block in workout.blocks.indices {
            for set in workout.blocks[block].exercises[0].sets.indices {
                workout.blocks[block].exercises[0].sets[set].duration = 60
                workout.blocks[block].exercises[0].sets[set].isCompleted = true
            }
        }
        let finished = WorkoutFactory.finalize(workout, completeRemaining: false, now: start.addingTimeInterval(900))
        XCTAssertTrue(WorkoutFactory.differsFromRoutine(finished, routine: routine, lookup: lookup))

        let updated = WorkoutFactory.updatedRoutine(routine, from: finished, lookup: lookup)
        XCTAssertEqual(updated.blocks[0].exercises[0].byTime, true)
        XCTAssertEqual(updated.blocks[0].exercises[0].sets.first?.target.duration, 60)
        XCTAssertEqual(updated.blocks[1].exercises[0].byTime, false, "timed anyway, not switched")

        let saved = WorkoutFactory.routine(from: finished, name: "Carries 2", lookup: lookup)
        XCTAssertEqual(saved.blocks.map { $0.exercises[0].byTime }, [true, false])
        // Unknown exercises can't be told apart, so the routine keeps its own switch.
        XCTAssertEqual(WorkoutFactory.updatedRoutine(updated, from: finished).blocks[0].exercises[0].byTime, true)
    }

    func testRunningSetTimerIsSavedWithTheWorkout() throws {
        let directory = TemporaryDirectory()
        let database = try AppDatabase.open(at: directory.location)
        var workout = WorkoutFactory.emptyWorkout(now: start)
        let set = WorkoutSet(weight: 32)
        workout.blocks = [WorkoutBlock(exercises: [WorkoutExercise(exerciseID: farmersWalk.id, name: farmersWalk.name, tracking: .weightDuration, sets: [set])])]
        var timer = SetTimerState(setID: set.id, duration: 120, leadIn: 5, startedAt: start)
        timer.pause(at: start.addingTimeInterval(20))
        workout.runtime.setTimer = timer
        XCTAssertFalse(workout.runtime.isEmpty)
        try database.workouts.save(workout)

        let loaded = try XCTUnwrap(database.workouts.workout(id: workout.id))
        XCTAssertEqual(loaded.runtime.setTimer, timer)
        XCTAssertEqual(loaded.runtime.setTimer?.remaining(at: start.addingTimeInterval(999)) ?? -1, 105, accuracy: 0.001)
    }

    func testTimedTargetsReadNaturally() {
        XCTAssertEqual(WorkoutFactory.targetFrom(WorkoutSet(weight: 32, duration: 120, distance: 40), tracking: .weightDuration).distance, nil)
        XCTAssertEqual(WorkoutFactory.targetFrom(WorkoutSet(weight: 32, duration: 120), tracking: .weightDuration).duration, 120)
    }
}
