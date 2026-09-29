import Foundation
import XCTest
@testable import ForgeCore

final class RecoveryTests: XCTestCase {
    private let day = Fixtures.date(12, hour: 18)

    private func open() throws -> (TemporaryDirectory, AppDatabase) {
        let directory = TemporaryDirectory()
        return (directory, try AppDatabase.open(at: directory.location))
    }

    private func finished(_ name: String, daysAgo: Double, sets: Int = 2) -> Workout {
        var workout = Fixtures.workout(on: day.addingTimeInterval(-daysAgo * 86_400), name: name, [
            (Fixtures.bench, Array(repeating: (100, 5), count: sets)),
        ])
        workout.status = .completed
        return workout
    }

    /// Removes a workout the way a loss would: straight out of the tables,
    /// with no record of the athlete deleting it.
    private func lose(_ id: UUID, in database: AppDatabase) throws {
        try database.queue.write { db in
            for table in ["workout_set", "workout_exercise", "workout_block"] {
                try db.run("DELETE FROM \(table) WHERE workout_id = ?", [id])
            }
            try db.run("DELETE FROM workout WHERE id = ?", [id])
        }
    }

    func testFindsAndRestoresWorkoutsMissingFromLiveData() throws {
        let (directory, database) = try open()
        _ = directory
        let kept = finished("Kept", daysAgo: 3)
        let lost = finished("Lost", daysAgo: 2)
        try database.workouts.save(kept)
        try database.workouts.save(lost)
        try database.backups.createSnapshot(from: database.queue, reason: .automatic)

        try lose(lost.id, in: database)
        let newer = finished("Newer", daysAgo: 1)
        try database.workouts.save(newer)

        let report = try RecoveryService.scan(database, sources: RecoveryService.deviceSources(for: database))
        XCTAssertEqual(report.workouts.map(\.workout.id), [lost.id])
        XCTAssertFalse(report.workouts[0].isReplacement)
        XCTAssertEqual(report.sourcesScanned, 1)

        try RecoveryService.restore(report, into: database)
        let names = try database.workouts.summaries().map(\.name).sorted()
        XCTAssertEqual(names, ["Kept", "Lost", "Newer"], "the lost workout is back and nothing else changed")

        let again = try RecoveryService.scan(database, sources: RecoveryService.deviceSources(for: database))
        XCTAssertTrue(again.workouts.isEmpty, "nothing left to recover")
    }

    func testOffersAFullerCopySavedMidWorkout() throws {
        let (directory, database) = try open()
        _ = directory
        // Mid-workout: three sets typed in, one ticked.
        var inProgress = finished("Upper A", daysAgo: 1, sets: 3)
        inProgress.status = .active
        inProgress.endedAt = nil
        for index in 1..<3 {
            inProgress.blocks[0].exercises[0].sets[index].isCompleted = false
            inProgress.blocks[0].exercises[0].sets[index].completedAt = nil
        }
        let midWorkout = BackupArchive(
            exportedAt: day, appVersion: "1", settings: nil, folders: [], routines: [], customExercises: [],
            exercisePreferences: [], workouts: [inProgress], measurements: [], timerPresets: []
        )
        // What got saved: only the ticked set, renamed afterwards.
        var saved = WorkoutFactory.finalize(inProgress, completeRemaining: false, keepEnteredSets: false, now: day)
        saved.name = "Upper A (heavy)"
        try database.workouts.save(saved)

        let data = try ArchiveService.encode(midWorkout)
        let source = RecoveryService.backupFileSource(label: "Backup file", date: day) { data }
        let report = try RecoveryService.scan(database, sources: [source])
        let found = try XCTUnwrap(report.workouts.first)
        XCTAssertTrue(found.isReplacement)
        XCTAssertEqual(found.loggedSets, 3)
        XCTAssertEqual(found.replacesLoggedSets, 1)

        try RecoveryService.restore(report, into: database)
        let restored = try XCTUnwrap(database.workouts.workout(id: saved.id))
        XCTAssertEqual(restored.status, .completed)
        XCTAssertEqual(restored.blocks[0].exercises[0].sets.count, 3)
        XCTAssertEqual(restored.name, "Upper A (heavy)", "the athlete's edits to the saved copy are kept")
    }

    func testLeavesDeletedAndSmallerCopiesAlone() throws {
        let (directory, database) = try open()
        _ = directory
        let full = finished("Full", daysAgo: 1, sets: 4)
        let trashed = finished("Trashed", daysAgo: 2)
        try database.workouts.save(full)
        try database.workouts.save(trashed)
        try database.workouts.softDelete(workoutID: trashed.id)

        var smaller = full
        smaller.blocks[0].exercises[0].sets.removeLast(2)
        var deletedInBackup = finished("Deleted on purpose", daysAgo: 5)
        deletedInBackup.deletedAt = day
        let archive = BackupArchive(
            exportedAt: day, appVersion: "1", settings: nil, folders: [], routines: [], customExercises: [],
            exercisePreferences: [], workouts: [smaller, trashed, deletedInBackup], measurements: [], timerPresets: []
        )
        let data = try ArchiveService.encode(archive)
        let report = try RecoveryService.scan(database, sources: [RecoveryService.backupFileSource(label: "file", date: nil) { data }])
        XCTAssertTrue(report.workouts.isEmpty, "a smaller copy, one in Recently Deleted and one deleted on purpose are not offered")
    }

    func testRestoresRoutinesAndTheirFolders() throws {
        let (directory, database) = try open()
        _ = directory
        let folder = Folder(name: "Strength")
        let inFolder = Routine(folderID: folder.id, name: "Upper A")
        let orphan = Routine(folderID: UUID(), name: "Lonely")
        let deleted = Routine(name: "Gone on purpose", deletedAt: day)
        let custom = Exercise(id: "custom-zercher", name: "Zercher Carry", primaryMuscle: .glutes, equipment: .other, tracking: .distanceDuration, isCustom: true)
        let archive = BackupArchive(
            exportedAt: day, appVersion: "1", settings: nil, folders: [folder], routines: [inFolder, orphan, deleted],
            customExercises: [custom], exercisePreferences: [], workouts: [], measurements: [], timerPresets: []
        )
        let data = try ArchiveService.encode(archive)
        let report = try RecoveryService.scan(database, sources: [RecoveryService.backupFileSource(label: "file", date: nil) { data }])
        XCTAssertEqual(Set(report.routines.map(\.name)), ["Upper A", "Lonely"])
        XCTAssertEqual(report.folders.map(\.id), [folder.id])
        XCTAssertEqual(report.customExercises.map(\.id), [custom.id])

        try RecoveryService.restore(report, into: database)
        let routines = try database.routines.routines()
        XCTAssertEqual(routines.first { $0.name == "Upper A" }?.folderID, folder.id)
        XCTAssertNil(routines.first { $0.name == "Lonely" }?.folderID, "a routine whose folder is gone lands at the top level")
        XCTAssertEqual(try database.exercises.customExercises().map(\.id), [custom.id])
    }

    func testUnreadableSourcesDontStopTheScan() throws {
        let (directory, database) = try open()
        _ = directory
        struct Broken: Error {}
        let broken = RecoveryService.Source(kind: .backupFile, label: "Broken file", date: nil) { throw Broken() }
        let lost = finished("Lost", daysAgo: 1)
        let archive = BackupArchive(
            exportedAt: day, appVersion: "1", settings: nil, folders: [], routines: [], customExercises: [],
            exercisePreferences: [], workouts: [lost], measurements: [], timerPresets: []
        )
        let data = try ArchiveService.encode(archive)
        let good = RecoveryService.backupFileSource(label: "Good file", date: nil) { data }
        let report = try RecoveryService.scan(database, sources: [broken, good])
        XCTAssertEqual(report.unreadableSources, ["Broken file"])
        XCTAssertEqual(report.workouts.map(\.workout.id), [lost.id])
    }

    func testReadingABackupFileNeverChangesIt() throws {
        let (directory, database) = try open()
        _ = directory
        try database.workouts.save(finished("A", daysAgo: 1))
        let snapshot = try database.backups.createSnapshot(from: database.queue, reason: .manual)
        let before = try Data(contentsOf: snapshot.url)
        let archive = try RecoveryService.archive(fromDatabaseAt: snapshot.url)
        XCTAssertEqual(archive.workouts.count, 1)
        XCTAssertEqual(try Data(contentsOf: snapshot.url), before)
        XCTAssertTrue(database.backups.validate(snapshot))
    }

    func testSelectingBringsAlongWhatItemsNeed() throws {
        let (directory, database) = try open()
        _ = directory
        let parent = Folder(name: "Programs")
        var child = Folder(name: "Strength")
        child.parentID = parent.id
        let custom = Exercise(id: "custom-sled", name: "Sled Push", primaryMuscle: .quadriceps, equipment: .other, tracking: .distanceDuration, isCustom: true)
        let unused = Exercise(id: "custom-unused", name: "Unused", primaryMuscle: .quadriceps, equipment: .other, tracking: .reps, isCustom: true)
        let routine = Routine(folderID: child.id, name: "Legs", blocks: [RoutineBlock(exercises: [RoutineExercise(exerciseID: custom.id)])])
        let other = Routine(name: "Other")
        let lost = finished("Lost", daysAgo: 1)
        let archive = BackupArchive(
            exportedAt: day, appVersion: "1", settings: nil, folders: [parent, child], routines: [routine, other],
            customExercises: [custom, unused], exercisePreferences: [], workouts: [lost], measurements: [], timerPresets: []
        )
        let data = try ArchiveService.encode(archive)
        let report = try RecoveryService.scan(database, sources: [RecoveryService.backupFileSource(label: "file", date: nil) { data }])
        XCTAssertEqual(report.routines.count, 2)

        let chosen = report.selecting(workouts: [], routines: [routine.id], customExercises: [], measurements: [], timerPresets: [])
        XCTAssertEqual(chosen.routines.map(\.id), [routine.id])
        XCTAssertEqual(Set(chosen.folders.map(\.id)), [parent.id, child.id], "the routine's folder and its parent")
        XCTAssertEqual(chosen.customExercises.map(\.id), [custom.id], "the custom exercise the routine uses")
        XCTAssertTrue(chosen.workouts.isEmpty)

        try RecoveryService.restore(chosen, into: database)
        XCTAssertEqual(try database.routines.routines().map(\.name), ["Legs"])
        XCTAssertEqual(try database.routines.routines().first?.folderID, child.id)
        XCTAssertEqual(Set(try database.routines.folders().map(\.id)), [parent.id, child.id])
    }

    func testAClashingSetIDDoesntBlockTheRestore() throws {
        let (directory, database) = try open()
        _ = directory
        let live = finished("Live", daysAgo: 2)
        try database.workouts.save(live)
        // A lost workout whose set happens to share an ID with a saved one.
        var lost = finished("Lost", daysAgo: 1)
        lost.blocks[0].exercises[0].sets[0].id = live.blocks[0].exercises[0].sets[0].id
        let archive = BackupArchive(
            exportedAt: day, appVersion: "1", settings: nil, folders: [], routines: [], customExercises: [],
            exercisePreferences: [], workouts: [lost], measurements: [], timerPresets: []
        )
        let data = try ArchiveService.encode(archive)
        let report = try RecoveryService.scan(database, sources: [RecoveryService.backupFileSource(label: "file", date: nil) { data }])
        try RecoveryService.restore(report, into: database)
        XCTAssertEqual(try database.workouts.workout(id: lost.id)?.allExercises.first?.sets.count, 2)
        XCTAssertEqual(try database.workouts.workout(id: live.id)?.allExercises.first?.sets.count, 2, "the saved workout keeps its sets")
    }

    func testScanReportsProgress() throws {
        let (directory, database) = try open()
        _ = directory
        final class Steps: @unchecked Sendable {
            var values: [Int] = []
        }
        let steps = Steps()
        let sources = (0..<3).map { index in
            RecoveryService.Source(kind: .backupFile, label: "file \(index)", date: nil) {
                BackupArchive(
                    exportedAt: Date(), appVersion: "1", settings: nil, folders: [], routines: [], customExercises: [],
                    exercisePreferences: [], workouts: [], measurements: [], timerPresets: []
                )
            }
        }
        _ = try RecoveryService.scan(database, sources: sources) { done, total in
            XCTAssertEqual(total, 3)
            steps.values.append(done)
        }
        XCTAssertEqual(steps.values, [0, 1, 2, 3])
    }

    func testItemsDeletedOnPurposeAreNotOfferedBack() throws {
        let (directory, database) = try open()
        _ = directory
        let emptied = finished("Emptied from Recently Deleted", daysAgo: 3)
        let lost = finished("Lost", daysAgo: 2)
        let routine = Routine(name: "Old plan")
        let measurement = BodyMeasurement(kind: .bodyWeight, value: 80, measuredAt: day)
        try database.workouts.save(emptied)
        try database.workouts.save(lost)
        try database.routines.save(routine)
        try database.measurements.save(measurement)
        try database.backups.createSnapshot(from: database.queue, reason: .automatic)

        try database.workouts.softDelete(workoutID: emptied.id)
        try database.workouts.purge(workoutID: emptied.id)
        try database.routines.softDelete(routineID: routine.id)
        XCTAssertEqual(try database.routines.purgeDeleted(before: Date().addingTimeInterval(60)), 1)
        try database.measurements.delete(id: measurement.id)
        try lose(lost.id, in: database)

        let report = try RecoveryService.scan(database, sources: RecoveryService.deviceSources(for: database))
        XCTAssertEqual(report.workouts.map(\.workout.id), [lost.id], "only the workout that vanished on its own")
        XCTAssertTrue(report.routines.isEmpty)
        XCTAssertTrue(report.measurements.isEmpty)
        XCTAssertEqual(report.deletedOnPurpose, 3)

        // Saving a deleted measurement again (Undo) takes it off the list.
        try database.measurements.save(measurement)
        XCTAssertFalse(database.tombstones()[.measurement]?.contains(measurement.id.uuidString) ?? false)
    }

    func testTombstonesAreForgottenEventually() throws {
        let (directory, database) = try open()
        _ = directory
        let workout = finished("Old", daysAgo: 1)
        try database.workouts.save(workout)
        try database.workouts.softDelete(workoutID: workout.id)
        try database.workouts.purge(workoutID: workout.id)
        XCTAssertEqual(database.tombstones()[.workout], [workout.id.uuidString])
        database.forgetTombstones(before: Date().addingTimeInterval(60))
        XCTAssertTrue(database.tombstones().isEmpty)
    }
}
