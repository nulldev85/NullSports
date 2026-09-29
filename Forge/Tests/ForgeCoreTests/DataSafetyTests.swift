import Foundation
import XCTest
@testable import ForgeCore

/// Rules that decide whether anything the athlete entered can disappear.
final class DataSafetyTests: XCTestCase {
    private let now = Fixtures.date(10, hour: 18)

    /// Bench: one checked set, one typed-in but unticked set, one untouched
    /// set that only has a target.
    private func benchWorkout() -> Workout {
        let sets = [
            WorkoutSet(weight: 100, reps: 5, isCompleted: true, completedAt: now),
            WorkoutSet(weight: 100, reps: 5),
            WorkoutSet(target: SetTarget(reps: 5, weight: 100)),
        ]
        let exercise = WorkoutExercise(exerciseID: Fixtures.bench.id, name: Fixtures.bench.name, tracking: .weightReps, sets: sets)
        var workout = Workout(name: "Push", startedAt: now, blocks: [WorkoutBlock(exercises: [exercise])])
        workout.status = .active
        return workout
    }

    func testFinishingKeepsUncheckedSetsWithNumbersTypedIn() {
        let workout = benchWorkout()
        XCTAssertEqual(workout.enteredUncheckedSetCount, 1)
        XCTAssertEqual(workout.emptyUncheckedSetCount, 1)

        let finished = WorkoutFactory.finalize(workout, completeRemaining: false, now: now.addingTimeInterval(600))
        let sets = finished.blocks[0].exercises[0].sets
        XCTAssertEqual(sets.count, 2, "the typed-in set is kept, the untouched one dropped")
        XCTAssertTrue(sets.allSatisfy(\.isCompleted))
        XCTAssertEqual(sets[1].weight, 100)

        let strict = WorkoutFactory.finalize(workout, completeRemaining: false, keepEnteredSets: false, now: now)
        XCTAssertEqual(strict.blocks[0].exercises[0].sets.count, 1, "only when the athlete asks are typed-in sets left out")

        let everything = WorkoutFactory.finalize(workout, completeRemaining: true, now: now)
        XCTAssertEqual(everything.blocks[0].exercises[0].sets.count, 3)
    }

    func testInputDetection() {
        let empty = WorkoutFactory.workout(from: Routine(name: "Plan", blocks: [
            RoutineBlock(exercises: [RoutineExercise(exerciseID: Fixtures.bench.id, sets: [RoutineSet(target: SetTarget(reps: 5, weight: 100))])]),
        ]), lookup: Fixtures.lookup, now: now)
        XCTAssertFalse(empty.hasUserInput, "targets alone aren't input")

        var typed = empty
        typed.blocks[0].exercises[0].sets[0].reps = 5
        XCTAssertTrue(typed.hasUserInput)

        var noted = empty
        noted.notes = "Felt good"
        XCTAssertTrue(noted.hasUserInput)

        XCTAssertTrue(benchWorkout().hasUserInput)
    }

    func testStrandedUnfinishedWorkoutsAreSavedNotHidden() throws {
        let directory = TemporaryDirectory()
        let database = try AppDatabase.open(at: directory.location)

        var oldest = Workout(name: "Empty shell", startedAt: now.addingTimeInterval(-7200), blocks: [])
        oldest.status = .active
        var middle = benchWorkout()
        middle.name = "Forgotten push day"
        middle.startedAt = now.addingTimeInterval(-3600)
        middle.updatedAt = now.addingTimeInterval(-1800)
        var newest = Workout(name: "Today", startedAt: now, blocks: [])
        newest.status = .active
        for workout in [oldest, middle, newest] {
            try database.workouts.save(workout)
        }

        let outcome = try UnfinishedWorkouts.resolve(in: database)
        XCTAssertEqual(outcome.active?.id, newest.id, "the newest stays open")
        XCTAssertEqual(outcome.recovered.map(\.id), [middle.id])
        XCTAssertEqual(outcome.removedEmpty, 1)

        XCTAssertEqual(try database.workouts.activeWorkouts().map(\.id), [newest.id])
        let saved = try XCTUnwrap(database.workouts.workout(id: middle.id))
        XCTAssertEqual(saved.status, .completed)
        XCTAssertEqual(saved.blocks[0].exercises[0].sets.count, 2, "the checked and the typed-in set")
        XCTAssertEqual(saved.endedAt, middle.updatedAt, "it ended when it was last touched")
        XCTAssertNil(try database.workouts.workout(id: oldest.id))

        // Running it again changes nothing.
        let again = try UnfinishedWorkouts.resolve(in: database)
        XCTAssertEqual(again.active?.id, newest.id)
        XCTAssertTrue(again.recovered.isEmpty)
    }

    // MARK: Backups

    func testSnapshotBeforeEachNewBuild() throws {
        let directory = TemporaryDirectory()
        let database = try AppDatabase.open(at: directory.location)
        XCTAssertNil(database.snapshotIfNewBuild("1.0 (1)"), "nothing to protect in an empty install")

        try database.workouts.save(Fixtures.workout(on: now, [(Fixtures.bench, [(100, 5)])]))
        XCTAssertNil(database.snapshotIfNewBuild("1.0 (1)"), "same build, no snapshot")
        let snapshot = try XCTUnwrap(database.snapshotIfNewBuild("1.0 (2)"))
        XCTAssertEqual(snapshot.reason, .preUpdate)
        XCTAssertTrue(database.backups.validate(snapshot))
        XCTAssertNil(database.snapshotIfNewBuild("1.0 (2)"), "once per build")
    }

    func testSnapshotsAfterWorkoutsAreKeptAlongsideDailyOnes() throws {
        let directory = TemporaryDirectory()
        let database = try AppDatabase.open(at: directory.location)
        try database.workouts.save(Fixtures.workout(on: now, [(Fixtures.bench, [(100, 5)])]))
        for index in 0..<14 {
            try database.backups.createSnapshot(from: database.queue, reason: .afterWorkout, now: now.addingTimeInterval(Double(index) * 3600))
        }
        try database.backups.createSnapshot(from: database.queue, reason: .automatic, now: now)
        try database.backups.createSnapshot(from: database.queue, reason: .preUpdate, now: now)
        database.backups.prune()
        let remaining = database.backups.snapshots()
        XCTAssertEqual(remaining.filter { $0.reason == .afterWorkout }.count, 10)
        XCTAssertEqual(remaining.filter { $0.reason == .automatic }.count, 1)
        XCTAssertEqual(remaining.filter { $0.reason == .preUpdate }.count, 1)
        XCTAssertNotNil(database.snapshotAfterWorkout())
    }

    func testFullIntegrityCheckRunsWhenDue() throws {
        let directory = TemporaryDirectory()
        let database = try AppDatabase.open(at: directory.location)
        XCTAssertNil(database.integrityStatus.checkedAt)
        XCTAssertEqual(database.fullIntegrityCheckIfDue(now: now), [])
        XCTAssertEqual(database.integrityStatus, AppDatabase.IntegrityStatus(checkedAt: now, problems: []))
        XCTAssertNil(database.fullIntegrityCheckIfDue(now: now.addingTimeInterval(86_400)), "not due again for days")
        XCTAssertNotNil(database.fullIntegrityCheckIfDue(now: now.addingTimeInterval(7 * 86_400)))
    }

    func testVerifiedSaveReadsTheWorkoutBack() throws {
        let directory = TemporaryDirectory()
        let database = try AppDatabase.open(at: directory.location)
        let workout = WorkoutFactory.finalize(benchWorkout(), completeRemaining: false, now: now)
        XCTAssertNoThrow(try database.workouts.saveVerified(workout))
        XCTAssertEqual(try database.workouts.workout(id: workout.id)?.allExercises.first?.sets.count, 2)
    }

    func testBackupFileRetentionThinsOutOlderCopies() {
        let calendar = Fixtures.utcCalendar
        var files: [BackupRetention.File] = []
        // Four exports a day for 120 days.
        for day in 0..<120 {
            for hour in [8, 12, 16, 20] {
                let date = now.addingTimeInterval(-Double(day) * 86_400 + Double(hour - 18) * 3600)
                files.append(BackupRetention.File(name: "file-\(day)-\(hour)", date: date))
            }
        }
        let removed = Set(BackupRetention.filesToRemove(files, now: now, calendar: calendar))
        let kept = files.filter { !removed.contains($0.name) }
        XCTAssertTrue(kept.contains { $0.name == "file-0-16" }, "the newest is always kept")
        XCTAssertGreaterThanOrEqual(kept.count, 10 + 25)
        XCTAssertLessThanOrEqual(kept.count, 10 + 31 + 14)
        let oldest = kept.map(\.date).min()!
        XCTAssertGreaterThan(now.timeIntervalSince(oldest), 100 * 86_400, "weekly copies reach back months")
        XCTAssertTrue(kept.contains { $0.name == "file-40-20" || $0.name == "file-41-20" || $0.name == "file-42-20" || $0.name == "file-39-20" || $0.name == "file-43-20" || $0.name == "file-44-20" || $0.name == "file-45-20" }, "one copy survives from each older week")
    }

    func testBackupNamesParseToDates() {
        let date = BackupRetention.date(fromBackupName: "Forge-Backup-2026-09-29-1802.json")
        let components = Calendar(identifier: .gregorian).dateComponents([.year, .month, .day, .hour, .minute], from: date!)
        XCTAssertEqual([components.year, components.month, components.day, components.hour, components.minute], [2026, 9, 29, 18, 2])
        XCTAssertNil(BackupRetention.date(fromBackupName: "Forge-Backup-latest.json"))
        XCTAssertNil(BackupRetention.date(fromBackupName: "notes.txt"))
    }

    func testFingerprintIgnoresExportTimeOnly() throws {
        let workout = Fixtures.workout(on: now, [(Fixtures.bench, [(100, 5)])])
        let archive = BackupArchive(
            exportedAt: now, appVersion: "1", settings: nil, folders: [], routines: [], customExercises: [],
            exercisePreferences: [], workouts: [workout], measurements: [], timerPresets: []
        )
        var later = archive
        later.exportedAt = now.addingTimeInterval(3600)
        XCTAssertEqual(try archive.contentFingerprint(), try later.contentFingerprint())
        var changed = archive
        changed.workouts[0].notes = "Different"
        XCTAssertNotEqual(try archive.contentFingerprint(), try changed.contentFingerprint())
    }

    func testBackgroundWritesLandInOrder() throws {
        let directory = TemporaryDirectory()
        let database = try AppDatabase.open(at: directory.location)
        let done = XCTestExpectation(description: "last write")
        for index in 0..<50 {
            database.perform { try $0.meta.set("order", value: "\(index)") }
        }
        database.perform({ try $0.meta.get("order") }) { result in
            XCTAssertEqual(try? result.get(), "49")
            done.fulfill()
        }
        wait(for: [done], timeout: 5)
        XCTAssertEqual(try database.meta.get("order"), "49", "and reads after them see the result")
    }
}
