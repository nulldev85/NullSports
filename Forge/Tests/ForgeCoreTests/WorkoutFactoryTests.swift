import Foundation
import XCTest
@testable import ForgeCore

final class WorkoutFactoryTests: XCTestCase {
    let now = Fixtures.date(5)

    private lazy var routine: Routine = {
        Routine(name: "Full Body", blocks: [
            RoutineBlock(exercises: [
                RoutineExercise(exerciseID: Fixtures.squat.id, sets: [
                    RoutineSet(kind: .warmup, target: SetTarget(reps: 10, weight: 60)),
                    RoutineSet(target: SetTarget(reps: 5, weight: 120)),
                    RoutineSet(target: SetTarget(reps: 5, weight: 120)),
                ], restSeconds: 180),
            ]),
            RoutineBlock(exercises: [
                RoutineExercise(exerciseID: Fixtures.bench.id, sets: [RoutineSet(target: SetTarget(reps: 8, repsMax: 12, weight: 80))]),
                RoutineExercise(exerciseID: Fixtures.pushUp.id, sets: [RoutineSet(target: SetTarget(reps: 15))]),
            ]),
            RoutineBlock(exercises: [
                RoutineExercise(exerciseID: Fixtures.pushUp.id, sets: [RoutineSet(target: SetTarget(reps: 10))]),
                RoutineExercise(exerciseID: Fixtures.squat.id, sets: [RoutineSet(target: SetTarget(reps: 5, weight: 60))]),
            ], timer: TimerConfig(kind: .amrap, duration: 600)),
            RoutineBlock(exercises: [RoutineExercise(exerciseID: "deleted-exercise", sets: [RoutineSet()])]),
        ])
    }()

    func testWorkoutFromRoutine() {
        let workout = WorkoutFactory.workout(from: routine, lookup: Fixtures.lookup, now: now)
        XCTAssertEqual(workout.status, .active)
        XCTAssertEqual(workout.routineID, routine.id)
        XCTAssertEqual(workout.name, "Full Body")
        XCTAssertEqual(workout.blocks.count, 4)
        let squat = workout.blocks[0].exercises[0]
        XCTAssertEqual(squat.name, "Squat (Barbell)")
        XCTAssertEqual(squat.restSeconds, 180)
        XCTAssertEqual(squat.sets.map(\.kind), [.warmup, .normal, .normal])
        XCTAssertNil(squat.sets[1].weight, "values stay empty; targets show as placeholders")
        XCTAssertEqual(squat.sets[1].target?.weight, 120)
        XCTAssertTrue(workout.blocks[1].isSuperset)
        XCTAssertEqual(workout.blocks[2].exercises.map { $0.sets.count }, [1, 1])
        XCTAssertEqual(workout.blocks[3].exercises[0].name, "Unknown Exercise")
    }

    func testAmrapResultGeneratesRoundsAndPartialReps() {
        let workout = WorkoutFactory.workout(from: routine, lookup: Fixtures.lookup, now: now)
        let block = workout.blocks[2]
        let program = TimerProgram(config: block.timer!)
        let updated = WorkoutFactory.applyResult(BlockResult(rounds: 3, extraReps: 13, elapsed: 600), to: block, program: program, now: now)
        XCTAssertEqual(updated.result?.rounds, 3)
        let pushUps = updated.exercises[0].sets
        let squats = updated.exercises[1].sets
        XCTAssertEqual(pushUps.map(\.reps), [10, 10, 10, 10])
        XCTAssertEqual(squats.map(\.reps), [5, 5, 5, 3], "13 extra reps = 10 push-ups + 3 squats")
        XCTAssertEqual(squats.first?.weight, 60)
        XCTAssertTrue((pushUps + squats).allSatisfy(\.isCompleted))

        let cleared = WorkoutFactory.clearResult(of: updated)
        XCTAssertNil(cleared.result)
        XCTAssertEqual(cleared.exercises[0].sets.count, 1)
        XCTAssertEqual(cleared.exercises[0].sets[0].target?.reps, 10)
        XCTAssertFalse(cleared.exercises[0].sets[0].isCompleted)
    }

    func testEmomAlternatingAndDeathBy() {
        var block = WorkoutBlock(
            exercises: [
                WorkoutExercise(exerciseID: "a", name: "A", tracking: .reps, sets: [WorkoutSet(target: SetTarget(reps: 12))]),
                WorkoutExercise(exerciseID: "b", name: "B", tracking: .reps, sets: [WorkoutSet(target: SetTarget(reps: 8))]),
            ],
            timer: TimerConfig(kind: .emom, interval: 60, rounds: 10, alternateMovements: true)
        )
        var updated = WorkoutFactory.applyResult(BlockResult(rounds: 5), to: block, program: TimerProgram(config: block.timer!), now: now)
        XCTAssertEqual(updated.exercises.map { $0.sets.count }, [3, 2])

        block.timer?.alternateMovements = false
        updated = WorkoutFactory.applyResult(BlockResult(rounds: 5), to: block, program: TimerProgram(config: block.timer!), now: now)
        XCTAssertEqual(updated.exercises.map { $0.sets.count }, [5, 5])

        let deathBy = WorkoutBlock(
            exercises: [WorkoutExercise(exerciseID: "burpee", name: "Burpee", tracking: .reps, sets: [WorkoutSet()])],
            timer: TimerConfig(kind: .deathBy, interval: 60, rounds: 30, startReps: 1, repIncrement: 1)
        )
        let deathResult = WorkoutFactory.applyResult(BlockResult(rounds: 4), to: deathBy, program: TimerProgram(config: deathBy.timer!), now: now)
        XCTAssertEqual(deathResult.exercises[0].sets.map(\.reps), [1, 2, 3, 4])
    }

    func testForTimeFinishedUsesPrescribedRounds() {
        let block = WorkoutBlock(
            exercises: [WorkoutExercise(exerciseID: "a", name: "A", tracking: .reps, sets: [WorkoutSet(target: SetTarget(reps: 21))])],
            timer: TimerConfig(kind: .forTime, duration: 1200, rounds: 3)
        )
        let updated = WorkoutFactory.applyResult(BlockResult(rounds: 0, elapsed: 700, finished: true), to: block, program: TimerProgram(config: block.timer!), now: now)
        XCTAssertEqual(updated.exercises[0].sets.count, 3)
    }

    func testFinalizeDropsUncheckedSetsAndUnrunTimedBlocks() {
        var workout = WorkoutFactory.workout(from: routine, lookup: Fixtures.lookup, now: now)
        workout.blocks[0].exercises[0].sets[1].weight = 120
        workout.blocks[0].exercises[0].sets[1].reps = 5
        workout.blocks[0].exercises[0].sets[1].isCompleted = true
        let end = now.addingTimeInterval(3000)

        let strict = WorkoutFactory.finalize(workout, completeRemaining: false, now: end)
        XCTAssertEqual(strict.status, .completed)
        XCTAssertEqual(strict.duration, 3000)
        XCTAssertEqual(strict.blocks.count, 1)
        XCTAssertEqual(strict.blocks[0].exercises[0].sets.count, 1)

        let lenient = WorkoutFactory.finalize(workout, completeRemaining: true, now: end)
        // Remaining sets are filled from their targets and completed; the
        // un-run AMRAP and the targetless unknown exercise are dropped.
        XCTAssertEqual(lenient.blocks.count, 2)
        XCTAssertEqual(lenient.blocks[0].exercises[0].sets.map(\.weight), [60, 120, 120])
        XCTAssertEqual(lenient.blocks[1].exercises.map(\.name), ["Bench Press (Barbell)", "Push-Up"])
        XCTAssertTrue(lenient.runtime.isEmpty)
    }

    func testUpdatedRoutineKeepsRepRangesAndCopiesPerformance() {
        var workout = WorkoutFactory.workout(from: routine, lookup: Fixtures.lookup, now: now)
        workout.blocks[1].exercises[0].sets[0].weight = 85
        workout.blocks[1].exercises[0].sets[0].reps = 10
        workout.blocks[1].exercises[0].sets[0].isCompleted = true
        let finished = WorkoutFactory.finalize(workout, completeRemaining: true, now: now.addingTimeInterval(100))
        XCTAssertTrue(WorkoutFactory.differsFromRoutine(finished, routine: routine))

        let updated = WorkoutFactory.updatedRoutine(routine, from: finished, now: now)
        XCTAssertEqual(updated.id, routine.id)
        let bench = updated.blocks[1].exercises[0].sets[0].target
        XCTAssertEqual(bench.weight, 85)
        XCTAssertEqual(bench.reps, 8, "10 reps sits inside 8–12, so the range is kept")
        XCTAssertEqual(bench.repsMax, 12)
        XCTAssertEqual(updated.blocks[0].exercises[0].restSeconds, 180)
        XCTAssertTrue(updated.blocks[2].isTimed, "a skipped finisher stays in the routine")
        XCTAssertEqual(updated.blocks.count, 3, "the unknown, never-logged exercise is dropped")

        var withoutFinisher = updated
        withoutFinisher.blocks.remove(at: 2)
        XCTAssertFalse(WorkoutFactory.differsFromRoutine(finished, routine: withoutFinisher))
    }

    func testRoutineFromWorkoutAndDuplication() {
        let workout = Fixtures.workout(on: now, [(Fixtures.bench, [(100, 5), (100, 4)])])
        let saved = WorkoutFactory.routine(from: workout, name: "Copied", now: now)
        XCTAssertEqual(saved.name, "Copied")
        XCTAssertEqual(saved.blocks[0].exercises[0].sets.map(\.target.weight), [100, 100])
        XCTAssertEqual(saved.blocks[0].exercises[0].sets.map(\.target.reps), [5, 4])

        let copy = saved.duplicated(name: "Copy", now: now)
        XCTAssertNotEqual(copy.id, saved.id)
        XCTAssertNotEqual(copy.blocks[0].id, saved.blocks[0].id)
        XCTAssertNotEqual(copy.blocks[0].exercises[0].sets[0].id, saved.blocks[0].exercises[0].sets[0].id)
        XCTAssertEqual(copy.blocks[0].exercises[0].sets.map(\.target), saved.blocks[0].exercises[0].sets.map(\.target))
    }

    func testIdentifierBasedEditing() {
        var workout = WorkoutFactory.workout(from: routine, lookup: Fixtures.lookup, now: now)
        let squatEntry = workout.blocks[0].exercises[0]
        let setID = squatEntry.sets[1].id
        XCTAssertTrue(workout.updateSet(setID) { $0.weight = 125 })
        XCTAssertEqual(workout.set(setID)?.weight, 125)

        let newSetID = workout.addSet(to: squatEntry.id)
        XCTAssertEqual(workout.set(newSetID!)?.target?.weight, 120, "new sets copy the previous set's target")

        workout.removeSet(setID)
        XCTAssertNil(workout.set(setID))
        XCTAssertFalse(workout.updateSet(setID) { $0.weight = 1 }, "edits to removed sets are ignored, not misapplied")

        let supersetID = workout.blocks[1].id
        workout.splitBlock(supersetID)
        XCTAssertEqual(workout.blocks.count, 5)
        workout.mergeWithNext(supersetID)
        XCTAssertEqual(workout.blocks.count, 4)
        XCTAssertEqual(workout.blocks[1].exercises.count, 2)

        workout.removeExercise(squatEntry.id)
        XCTAssertEqual(workout.blocks.count, 3, "an emptied block is removed")
        workout.moveBlock(workout.blocks[0].id, by: 1)
        XCTAssertTrue(workout.blocks[0].isTimed)
    }

    func testRestTimerAdjustments() {
        var rest = RestTimerState(startedAt: now, duration: 90)
        XCTAssertEqual(rest.remaining(at: now.addingTimeInterval(30)), 60)
        rest.adjust(by: 15, now: now.addingTimeInterval(30))
        XCTAssertEqual(rest.remaining(at: now.addingTimeInterval(30)), 75)
        rest.adjust(by: -200, now: now.addingTimeInterval(30))
        XCTAssertEqual(rest.remaining(at: now.addingTimeInterval(30)), 0)
        XCTAssertEqual(rest.progress(at: now.addingTimeInterval(30)), 1)
    }
}

final class ResilientDecodingTests: XCTestCase {
    func testUnknownEnumValuesFallBack() throws {
        let json = #"{"kind":"hyper-set","isCompleted":true,"weight":"heavy","reps":5}"#
        let set = try JSONCoding.decode(WorkoutSet.self, from: json)
        XCTAssertEqual(set.kind, .normal)
        XCTAssertNil(set.weight, "a malformed field is dropped, the rest survives")
        XCTAssertEqual(set.reps, 5)
        XCTAssertTrue(set.isCompleted)
    }

    func testRoutineBodyFromFutureVersionStillLoads() throws {
        let json = """
        {"blocks":[{"id":"8D1C4E5A-0000-4000-8000-000000000001","futureField":{"x":1},"exercises":[{"exerciseID":"squat-barbell","sets":[{"kind":"cluster","target":{"reps":3,"tempo":"31X1"}}]}],"timer":{"kind":"new-format","rounds":4}}]}
        """
        let body = try JSONCoding.decode(RoutineBody.self, from: json)
        XCTAssertEqual(body.blocks.count, 1)
        XCTAssertEqual(body.blocks[0].exercises[0].sets[0].target.reps, 3)
        XCTAssertEqual(body.blocks[0].timer?.kind, .stopwatch)
        XCTAssertEqual(body.blocks[0].timer?.rounds, 4)
    }

    func testDatesDecodeFromEitherFormat() throws {
        struct Holder: Codable { var date: Date }
        let iso = try JSONCoding.decode(Holder.self, from: #"{"date":"2026-03-01T09:00:00.250Z"}"#)
        XCTAssertEqual(iso.date.timeIntervalSince1970, 1772355600.25, accuracy: 0.0001)
        let plain = try JSONCoding.decode(Holder.self, from: #"{"date":"2026-03-01T09:00:00Z"}"#)
        XCTAssertEqual(plain.date.timeIntervalSince1970, 1772355600, accuracy: 0.0001)
        let numeric = try JSONCoding.decode(Holder.self, from: #"{"date":1772355600}"#)
        XCTAssertEqual(numeric.date, plain.date)
        let encoded = try JSONCoding.encodeString(Holder(date: iso.date))
        XCTAssertEqual(encoded, #"{"date":"2026-03-01T09:00:00.250Z"}"#)
    }
}
