import Foundation
import XCTest
@testable import ForgeCore

final class RoutineRepositoryTests: XCTestCase {
    func testRoutineRoundTripKeepsEveryDetail() throws {
        let dir = TemporaryDirectory()
        let db = try AppDatabase.open(at: dir.location)
        let folder = Folder(name: "Push/Pull/Legs")
        try db.routines.saveFolder(folder)
        let routine = Routine(
            folderID: folder.id,
            name: "Push A",
            notes: "Heavy day",
            colorTag: "ember",
            blocks: [
                RoutineBlock(exercises: [
                    RoutineExercise(exerciseID: "bench-press-barbell", sets: [
                        RoutineSet(kind: .warmup, target: SetTarget(reps: 10, weight: 40)),
                        RoutineSet(kind: .normal, target: SetTarget(reps: 6, repsMax: 8, weight: 100, rpe: 8)),
                    ], restSeconds: 180, notes: "Pause first rep"),
                ]),
                RoutineBlock(exercises: [
                    RoutineExercise(exerciseID: "push-up", sets: [RoutineSet(target: SetTarget(reps: 10))]),
                    RoutineExercise(exerciseID: "plank", sets: [RoutineSet(target: SetTarget(duration: 60))]),
                ]),
                RoutineBlock(exercises: [
                    RoutineExercise(exerciseID: "push-up", sets: [RoutineSet(target: SetTarget(reps: 15))]),
                ], timer: TimerConfig.standard(.amrap), notes: "Finisher"),
            ]
        )
        try db.routines.save(routine)
        let loaded = try XCTUnwrap(db.routines.routine(id: routine.id))
        XCTAssertEqual(loaded.name, "Push A")
        XCTAssertEqual(loaded.folderID, folder.id)
        XCTAssertEqual(loaded.blocks, routine.blocks)
        XCTAssertTrue(loaded.blocks[1].isSuperset)
        XCTAssertTrue(loaded.blocks[2].isTimed)
        XCTAssertEqual(loaded.setCount, 4)
    }

    func testFolderCyclesAreRejected() throws {
        let dir = TemporaryDirectory()
        let db = try AppDatabase.open(at: dir.location)
        let a = Folder(name: "A")
        let b = Folder(parentID: a.id, name: "B")
        try db.routines.saveFolder(a)
        try db.routines.saveFolder(b)
        var moved = a
        moved.parentID = b.id
        XCTAssertThrowsError(try db.routines.saveFolder(moved))
        var selfParent = a
        selfParent.parentID = a.id
        XCTAssertThrowsError(try db.routines.saveFolder(selfParent))
    }

    func testDeletingFolderCanKeepContents() throws {
        let dir = TemporaryDirectory()
        let db = try AppDatabase.open(at: dir.location)
        let parent = Folder(name: "Parent")
        let child = Folder(parentID: parent.id, name: "Child")
        let grandchild = Folder(parentID: child.id, name: "Grandchild")
        for folder in [parent, child, grandchild] { try db.routines.saveFolder(folder) }
        let routine = Routine(folderID: child.id, name: "In child")
        try db.routines.save(routine)

        try db.routines.deleteFolder(id: child.id, mode: .keepContents)
        XCTAssertEqual(try db.routines.routine(id: routine.id)?.folderID, parent.id)
        XCTAssertEqual(try db.routines.folders().first { $0.id == grandchild.id }?.parentID, parent.id)
        XCTAssertNil(try db.routines.folders().first { $0.id == child.id })
    }

    func testDeletingFolderWithContentsSendsRoutinesToRecentlyDeleted() throws {
        let dir = TemporaryDirectory()
        let db = try AppDatabase.open(at: dir.location)
        let parent = Folder(name: "Parent")
        let child = Folder(parentID: parent.id, name: "Child")
        try db.routines.saveFolder(parent)
        try db.routines.saveFolder(child)
        let r1 = Routine(folderID: parent.id, name: "R1")
        let r2 = Routine(folderID: child.id, name: "R2")
        try db.routines.save(r1)
        try db.routines.save(r2)

        try db.routines.deleteFolder(id: parent.id, mode: .deleteContents)
        XCTAssertTrue(try db.routines.folders().isEmpty)
        XCTAssertTrue(try db.routines.routines().isEmpty)
        XCTAssertEqual(Set(try db.routines.deletedRoutines().map(\.name)), ["R1", "R2"])

        // Restoring puts a routine back at the top level since its folder is gone.
        try db.routines.restore(routineID: r2.id)
        let restored = try XCTUnwrap(db.routines.routine(id: r2.id))
        XCTAssertNil(restored.deletedAt)
        XCTAssertNil(restored.folderID)
    }

    func testPurgeOnlyRemovesOldDeletedRoutines() throws {
        let dir = TemporaryDirectory()
        let db = try AppDatabase.open(at: dir.location)
        let old = Routine(name: "Old")
        let recent = Routine(name: "Recent")
        let live = Routine(name: "Live")
        for r in [old, recent, live] { try db.routines.save(r) }
        try db.routines.softDelete(routineID: old.id, at: Fixtures.date(1))
        try db.routines.softDelete(routineID: recent.id, at: Fixtures.date(20))
        XCTAssertEqual(try db.routines.purgeDeleted(before: Fixtures.date(10)), 1)
        XCTAssertNil(try db.routines.routine(id: old.id))
        XCTAssertNotNil(try db.routines.routine(id: recent.id))
        XCTAssertNotNil(try db.routines.routine(id: live.id))
        // Purging a routine that isn't deleted does nothing.
        try db.routines.purge(routineID: live.id)
        XCTAssertNotNil(try db.routines.routine(id: live.id))
    }

    func testUndecodableBodyDoesNotLoseTheRoutine() throws {
        let dir = TemporaryDirectory()
        let db = try AppDatabase.open(at: dir.location)
        let routine = Routine(name: "Weird")
        try db.routines.save(routine)
        try db.queue.write { db in try db.run("UPDATE routine SET body = 'not json' WHERE id = ?", [routine.id]) }
        let loaded = try XCTUnwrap(db.routines.routine(id: routine.id))
        XCTAssertEqual(loaded.name, "Weird")
        XCTAssertTrue(loaded.blocks.isEmpty)
    }
}

final class WorkoutRepositoryTests: XCTestCase {
    func testWorkoutRoundTripPreservesStructureAndOrder() throws {
        let dir = TemporaryDirectory()
        let db = try AppDatabase.open(at: dir.location)
        var workout = Fixtures.workout(on: Fixtures.date(2), name: "Leg Day", [
            (Fixtures.squat, [(60, 10), (100, 5), (120, 3)]),
            (Fixtures.pushUp, [(nil, 20), (nil, 18)]),
        ])
        workout.blocks[0].exercises[0].sets[0].kind = .warmup
        workout.blocks[0].exercises[0].sets[2].target = SetTarget(reps: 3, weight: 120)
        workout.notes = "Felt strong"
        workout.rating = 5
        workout.bodyweight = 82.5
        workout.blocks.append(WorkoutBlock(
            exercises: [WorkoutExercise(exerciseID: "plank", name: "Plank", tracking: .duration, sets: [WorkoutSet(duration: 60, isCompleted: true)])],
            timer: TimerConfig.standard(.emom),
            result: BlockResult(rounds: 10, elapsed: 600)
        ))
        try db.workouts.save(workout)
        let loaded = try XCTUnwrap(db.workouts.workout(id: workout.id))
        XCTAssertEqual(loaded, workout)
    }

    func testSavingAgainReplacesChildrenCompletely() throws {
        let dir = TemporaryDirectory()
        let db = try AppDatabase.open(at: dir.location)
        var workout = Fixtures.workout(on: Fixtures.date(2), [(Fixtures.bench, [(100, 5), (100, 5), (100, 5)])])
        try db.workouts.save(workout)
        workout.blocks[0].exercises[0].sets.removeLast()
        workout.blocks.append(Fixtures.workout(on: Fixtures.date(2), [(Fixtures.squat, [(140, 3)])]).blocks[0])
        try db.workouts.save(workout)
        let loaded = try XCTUnwrap(db.workouts.workout(id: workout.id))
        XCTAssertEqual(loaded.blocks.count, 2)
        XCTAssertEqual(loaded.blocks[0].exercises[0].sets.count, 2)
        XCTAssertEqual(try db.queue.read { try $0.scalarInt("SELECT COUNT(*) FROM workout_set") }, 3)
    }

    func testActiveWorkoutIsRecoverable() throws {
        let dir = TemporaryDirectory()
        do {
            let db = try AppDatabase.open(at: dir.location)
            var active = WorkoutFactory.emptyWorkout(now: Fixtures.date(3))
            active.blocks = [WorkoutBlock(exercises: [WorkoutFactory.entry(for: Fixtures.bench, lastPerformance: nil)])]
            active.runtime.restTimer = RestTimerState(startedAt: Fixtures.date(3), duration: 90, exerciseName: "Bench")
            try db.workouts.save(active)
            db.queue.close()
        }
        let db = try AppDatabase.open(at: dir.location)
        let restored = try XCTUnwrap(db.workouts.activeWorkout())
        XCTAssertEqual(restored.status, .active)
        XCTAssertEqual(restored.runtime.restTimer?.duration, 90)
        XCTAssertEqual(restored.blocks.first?.exercises.first?.exerciseID, Fixtures.bench.id)
        XCTAssertTrue(try db.workouts.summaries().isEmpty, "active workouts aren't history yet")
    }

    func testSummariesComputeTotals() throws {
        let dir = TemporaryDirectory()
        let db = try AppDatabase.open(at: dir.location)
        var workout = Fixtures.workout(on: Fixtures.date(4), name: "Mixed", [
            (Fixtures.bench, [(50, 10), (100, 5), (100, 5)]),
            (Fixtures.pushUp, [(nil, 20)]),
        ])
        workout.blocks[0].exercises[0].sets[0].kind = .warmup
        workout.blocks[0].exercises[0].sets.append(WorkoutSet(weight: 100, reps: 5, isCompleted: false))
        try db.workouts.save(workout)
        let summary = try XCTUnwrap(db.workouts.summaries().first)
        XCTAssertEqual(summary.name, "Mixed")
        XCTAssertEqual(summary.setCount, 3, "warm-ups and unchecked sets don't count")
        XCTAssertEqual(summary.volume, 1000, accuracy: 0.001)
        XCTAssertEqual(summary.totalReps, 30)
        XCTAssertEqual(summary.exerciseNames, ["Bench Press (Barbell)", "Push-Up"])
        XCTAssertEqual(summary.duration, 3600)
    }

    func testSoftDeleteRestoreAndPurge() throws {
        let dir = TemporaryDirectory()
        let db = try AppDatabase.open(at: dir.location)
        let workout = Fixtures.workout(on: Fixtures.date(5), [(Fixtures.bench, [(100, 5)])])
        try db.workouts.save(workout)
        try db.workouts.softDelete(workoutID: workout.id, at: Fixtures.date(6))
        XCTAssertTrue(try db.workouts.summaries().isEmpty)
        XCTAssertEqual(try db.workouts.summaries(deleted: true).count, 1)
        XCTAssertTrue(try db.workouts.setRecords().isEmpty, "deleted workouts don't feed stats")

        try db.workouts.restore(workoutID: workout.id)
        XCTAssertEqual(try db.workouts.summaries().count, 1)

        try db.workouts.purge(workoutID: workout.id)
        XCTAssertNotNil(try db.workouts.workout(id: workout.id), "completed, non-deleted workouts can't be purged")

        try db.workouts.softDelete(workoutID: workout.id, at: Fixtures.date(6))
        XCTAssertEqual(try db.workouts.purgeDeleted(before: Fixtures.date(7)), 1)
        XCTAssertNil(try db.workouts.workout(id: workout.id))
        XCTAssertEqual(try db.queue.read { try $0.scalarInt("SELECT COUNT(*) FROM workout_set") }, 0)
    }

    func testLastPerformanceAndSessions() throws {
        let dir = TemporaryDirectory()
        let db = try AppDatabase.open(at: dir.location)
        let first = Fixtures.workout(on: Fixtures.date(1), [(Fixtures.bench, [(90, 5), (90, 5)])])
        let second = Fixtures.workout(on: Fixtures.date(8), [(Fixtures.bench, [(95, 5), (95, 4)]), (Fixtures.squat, [(140, 3)])])
        try db.workouts.save(first)
        try db.workouts.save(second)

        let last = try db.workouts.lastPerformances(exerciseIDs: [Fixtures.bench.id, Fixtures.squat.id, "never-done"])
        XCTAssertEqual(last[Fixtures.bench.id]?.map(\.weight), [95, 95])
        XCTAssertEqual(last[Fixtures.squat.id]?.first?.reps, 3)
        XCTAssertNil(last["never-done"])

        let excluding = try db.workouts.lastPerformances(exerciseIDs: [Fixtures.bench.id], excluding: second.id)
        XCTAssertEqual(excluding[Fixtures.bench.id]?.map(\.weight), [90, 90])

        let sessions = try db.workouts.sessions(exerciseID: Fixtures.bench.id)
        XCTAssertEqual(sessions.map(\.date), [Fixtures.date(8), Fixtures.date(1)])
        XCTAssertEqual(sessions.first?.volume ?? 0, 95 * 9, accuracy: 0.001)
        XCTAssertEqual(try db.workouts.exerciseUsageCounts()[Fixtures.bench.id], 2)
    }

    func testSetRecordsFeedAnalytics() throws {
        let dir = TemporaryDirectory()
        let db = try AppDatabase.open(at: dir.location)
        try db.workouts.save(Fixtures.workout(on: Fixtures.date(1), [(Fixtures.bench, [(90, 5)])]))
        try db.workouts.save(Fixtures.workout(on: Fixtures.date(8), [(Fixtures.bench, [(100, 5)])]))
        let records = try db.workouts.setRecords()
        XCTAssertEqual(records.count, 2)
        XCTAssertEqual(records.first?.weight, 90)
        let book = RecordBook(records: records)
        XCTAssertEqual(book.records(for: Fixtures.bench.id).first { $0.kind == .heaviestWeight }?.value, 100)
    }
}

final class ExerciseRepositoryTests: XCTestCase {
    func testCustomExerciseLifecycle() throws {
        let dir = TemporaryDirectory()
        let db = try AppDatabase.open(at: dir.location)
        var custom = Exercise(
            id: Exercise.newCustomID(),
            name: "Zercher Carry",
            primaryMuscle: .fullBody,
            secondaryMuscles: [.abdominals, .biceps],
            equipment: .barbell,
            category: .strongman,
            tracking: .weightDistance,
            aliases: ["Zerch walk"],
            instructions: "Bar in elbows, walk."
        )
        try db.exercises.saveCustom(custom)
        var loaded = try XCTUnwrap(db.exercises.customExercise(id: custom.id))
        XCTAssertTrue(loaded.isCustom)
        XCTAssertEqual(loaded.secondaryMuscles, [.abdominals, .biceps])
        XCTAssertEqual(loaded.aliases, ["Zerch walk"])
        XCTAssertEqual(loaded.tracking, .weightDistance)

        custom.name = "Zercher Walk"
        try db.exercises.saveCustom(custom)
        loaded = try XCTUnwrap(db.exercises.customExercise(id: custom.id))
        XCTAssertEqual(loaded.name, "Zercher Walk")

        // Once used, it can be archived but never permanently deleted.
        var workout = Fixtures.workout(on: Fixtures.date(1), [])
        workout.blocks = [WorkoutBlock(exercises: [WorkoutExercise(exerciseID: custom.id, name: custom.name, tracking: custom.tracking, sets: [WorkoutSet(weight: 60, distance: 20, isCompleted: true)])])]
        try db.workouts.save(workout)
        XCTAssertEqual(try db.exercises.usageCount(exerciseID: custom.id), 1)
        XCTAssertThrowsError(try db.exercises.deleteCustomPermanently(id: custom.id))

        try db.exercises.archiveCustom(id: custom.id)
        XCTAssertNotNil(try db.exercises.customExercise(id: custom.id)?.archivedAt)
        try db.exercises.unarchiveCustom(id: custom.id)
        XCTAssertNil(try db.exercises.customExercise(id: custom.id)?.archivedAt)
    }

    func testUnusedCustomExerciseCanBeDeleted() throws {
        let dir = TemporaryDirectory()
        let db = try AppDatabase.open(at: dir.location)
        let custom = Exercise(id: Exercise.newCustomID(), name: "Temp", primaryMuscle: .other, equipment: .other, isCustom: true)
        try db.exercises.saveCustom(custom)
        try db.exercises.savePreference(ExercisePreference(exerciseID: custom.id, isFavorite: true))
        try db.exercises.deleteCustomPermanently(id: custom.id)
        XCTAssertNil(try db.exercises.customExercise(id: custom.id))
        XCTAssertNil(try db.exercises.preferences()[custom.id])
    }

    func testRoutineReferenceBlocksPermanentDeletion() throws {
        let dir = TemporaryDirectory()
        let db = try AppDatabase.open(at: dir.location)
        let custom = Exercise(id: Exercise.newCustomID(), name: "Temp", primaryMuscle: .other, equipment: .other, isCustom: true)
        try db.exercises.saveCustom(custom)
        try db.routines.save(Routine(name: "Uses it", blocks: [RoutineBlock(exercises: [RoutineExercise(exerciseID: custom.id)])]))
        XCTAssertEqual(try db.exercises.usageCount(exerciseID: custom.id), 1)
        XCTAssertThrowsError(try db.exercises.deleteCustomPermanently(id: custom.id))
    }

    func testPreferencesUpsertAndClear() throws {
        let dir = TemporaryDirectory()
        let db = try AppDatabase.open(at: dir.location)
        try db.exercises.savePreference(ExercisePreference(exerciseID: "bench-press-barbell", isFavorite: true, note: "Elbows in", restSeconds: 150))
        var prefs = try db.exercises.preferences()
        XCTAssertEqual(prefs["bench-press-barbell"]?.note, "Elbows in")
        XCTAssertEqual(prefs["bench-press-barbell"]?.restSeconds, 150)
        try db.exercises.savePreference(ExercisePreference(exerciseID: "bench-press-barbell"))
        prefs = try db.exercises.preferences()
        XCTAssertNil(prefs["bench-press-barbell"], "empty preferences are removed")
    }
}

final class MiscRepositoryTests: XCTestCase {
    func testMeasurementsAndBodyweightLookup() throws {
        let dir = TemporaryDirectory()
        let db = try AppDatabase.open(at: dir.location)
        try db.measurements.save(BodyMeasurement(kind: .bodyWeight, value: 80, measuredAt: Fixtures.date(1)))
        try db.measurements.save(BodyMeasurement(kind: .bodyWeight, value: 81, measuredAt: Fixtures.date(10)))
        let waist = BodyMeasurement(kind: .waist, value: 84, measuredAt: Fixtures.date(5))
        try db.measurements.save(waist)
        XCTAssertEqual(try db.measurements.bodyweight(onOrBefore: Fixtures.date(5)), 80)
        XCTAssertEqual(try db.measurements.bodyweight(onOrBefore: Fixtures.date(11)), 81)
        XCTAssertNil(try db.measurements.bodyweight(onOrBefore: Fixtures.date(1).addingTimeInterval(-1)))
        try db.measurements.delete(id: waist.id)
        XCTAssertEqual(try db.measurements.all().count, 2)
    }

    func testTimerPresets() throws {
        let dir = TemporaryDirectory()
        let db = try AppDatabase.open(at: dir.location)
        var preset = TimerPreset(name: "Tabata", config: .standard(.tabata))
        try db.timerPresets.save(preset)
        preset.config.rounds = 10
        try db.timerPresets.save(preset)
        let all = try db.timerPresets.all()
        XCTAssertEqual(all.count, 1)
        XCTAssertEqual(all.first?.config.rounds, 10)
        try db.timerPresets.delete(id: preset.id)
        XCTAssertTrue(try db.timerPresets.all().isEmpty)
    }

    func testSettingsPersistAndTolerateMissingFields() throws {
        let dir = TemporaryDirectory()
        let db = try AppDatabase.open(at: dir.location)
        XCTAssertEqual(try db.meta.loadSettings(default: .defaults(usesMetric: false)).weightUnit, .lb)
        var settings = AppSettings()
        settings.defaultRestSeconds = 150
        settings.accent = "volt"
        try db.meta.saveSettings(settings)
        XCTAssertEqual(try db.meta.loadSettings(default: AppSettings()), settings)

        // A settings document from an older build with only some keys.
        try db.meta.set(MetaRepository.Key.settings, value: #"{"weightUnit":"lb","mysteryFutureKey":true,"weeklyGoal":"not a number"}"#)
        let loaded = try db.meta.loadSettings(default: AppSettings())
        XCTAssertEqual(loaded.weightUnit, .lb)
        XCTAssertEqual(loaded.weeklyGoal, AppSettings().weeklyGoal)
        XCTAssertEqual(loaded.defaultRestSeconds, 90)
    }
}
