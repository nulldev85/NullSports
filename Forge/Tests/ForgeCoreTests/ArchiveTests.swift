import Foundation
import XCTest
@testable import ForgeCore

final class ArchiveTests: XCTestCase {
    private func populate(_ db: AppDatabase) throws {
        let folder = Folder(name: "Strength")
        try db.routines.saveFolder(folder)
        try db.routines.save(Routine(folderID: folder.id, name: "Upper", blocks: [
            RoutineBlock(exercises: [RoutineExercise(exerciseID: Fixtures.bench.id, sets: [RoutineSet(target: SetTarget(reps: 5, weight: 100))])]),
        ]))
        var deleted = Routine(name: "Old routine")
        deleted.deletedAt = Fixtures.date(2)
        try db.routines.save(deleted)
        try db.exercises.saveCustom(Exercise(id: "custom-1", name: "Custom Lift", primaryMuscle: .upperBack, equipment: .cable, isCustom: true))
        try db.exercises.savePreference(ExercisePreference(exerciseID: Fixtures.bench.id, isFavorite: true))
        try db.workouts.save(Fixtures.workout(on: Fixtures.date(3), name: "Session", [(Fixtures.bench, [(100, 5), (102.5, 3)])]))
        try db.workouts.save(WorkoutFactory.timerWorkout(
            config: .standard(.tabata),
            result: BlockResult(rounds: 8, elapsed: 230),
            name: "Tabata",
            startedAt: Fixtures.date(4),
            endedAt: Fixtures.date(4).addingTimeInterval(240)
        ))
        try db.measurements.save(BodyMeasurement(kind: .bodyWeight, value: 80.4, measuredAt: Fixtures.date(3)))
        try db.timerPresets.save(TimerPreset(name: "My EMOM", config: .standard(.emom)))
        var settings = AppSettings()
        settings.weightUnit = .lb
        try db.meta.saveSettings(settings)
    }

    func testExportImportRoundTrip() throws {
        let sourceDir = TemporaryDirectory()
        let source = try AppDatabase.open(at: sourceDir.location)
        try populate(source)
        let data = try ArchiveService.exportData(from: source, appVersion: "1.0 (1)", now: Fixtures.date(10))

        let archive = try ArchiveService.decode(data)
        XCTAssertEqual(archive.format, BackupArchive.formatIdentifier)
        XCTAssertEqual(archive.completedWorkoutCount, 2)
        XCTAssertEqual(archive.activeRoutineCount, 1)

        let targetDir = TemporaryDirectory()
        let target = try AppDatabase.open(at: targetDir.location)
        try target.routines.save(Routine(name: "Will be replaced"))
        try ArchiveService.restore(archive, into: target, now: Fixtures.date(11))

        XCTAssertEqual(try target.routines.routines().map(\.name), ["Upper"])
        XCTAssertEqual(try target.routines.deletedRoutines().map(\.name), ["Old routine"])
        XCTAssertEqual(try target.routines.folders().map(\.name), ["Strength"])
        XCTAssertEqual(try target.exercises.customExercises().map(\.name), ["Custom Lift"])
        XCTAssertEqual(try target.exercises.preferences()[Fixtures.bench.id]?.isFavorite, true)
        XCTAssertEqual(try target.workouts.allWorkouts(), try source.workouts.allWorkouts())
        XCTAssertEqual(try target.measurements.all(), try source.measurements.all())
        XCTAssertEqual(try target.timerPresets.all().map(\.name), ["My EMOM"])
        XCTAssertEqual(try target.meta.loadSettings(default: AppSettings()).weightUnit, .lb)

        // The replaced data is still available as a pre-import snapshot.
        let snapshot = try XCTUnwrap(target.backups.snapshots().first { $0.reason == .preImport })
        XCTAssertEqual(target.backups.summary(of: snapshot)?.routines, 1)
    }

    func testExportIsStableAcrossRepeatedRoundTrips() throws {
        let dir = TemporaryDirectory()
        let db = try AppDatabase.open(at: dir.location)
        try populate(db)
        let first = try ArchiveService.exportData(from: db, appVersion: "1", now: Fixtures.date(10))
        try ArchiveService.restore(try ArchiveService.decode(first), into: db)
        let second = try ArchiveService.exportData(from: db, appVersion: "1", now: Fixtures.date(10))
        XCTAssertEqual(String(decoding: first, as: UTF8.self), String(decoding: second, as: UTF8.self))
    }

    func testRejectsForeignAndNewerFiles() throws {
        XCTAssertThrowsError(try ArchiveService.decode(Data("not json".utf8)))
        XCTAssertThrowsError(try ArchiveService.decode(Data(#"{"format":"something-else","version":1}"#.utf8)))
        XCTAssertThrowsError(try ArchiveService.decode(Data(#"{"format":"forge-backup","version":99}"#.utf8))) { error in
            guard case BackupError.newerArchive(99) = error else { return XCTFail("\(error)") }
        }
    }

    func testImportsMinimalOlderArchive() throws {
        // A hand-written archive with only a few fields must still import.
        let json = """
        {
          "format": "forge-backup",
          "version": 1,
          "workouts": [
            {
              "id": "6B0F3C2E-0000-4000-8000-000000000001",
              "name": "Old style",
              "status": "completed",
              "startedAt": "2025-01-02T10:00:00Z",
              "duration": 1800,
              "blocks": [
                {"exercises": [{"exerciseID": "bench-press-barbell", "name": "Bench", "sets": [{"weight": 60, "reps": 10, "isCompleted": true, "kind": "future-kind"}]}]}
              ]
            }
          ]
        }
        """
        let archive = try ArchiveService.decode(Data(json.utf8))
        let dir = TemporaryDirectory()
        let db = try AppDatabase.open(at: dir.location)
        try ArchiveService.restore(archive, into: db)
        let summary = try XCTUnwrap(db.workouts.summaries().first)
        XCTAssertEqual(summary.name, "Old style")
        XCTAssertEqual(summary.volume, 600, accuracy: 0.001)
        let workout = try XCTUnwrap(db.workouts.workout(id: summary.id))
        XCTAssertEqual(workout.blocks[0].exercises[0].sets[0].kind, .normal, "unknown set kinds fall back safely")
    }

    func testCSVExportEscapesFields() throws {
        var workout = Fixtures.workout(on: Fixtures.date(3), name: "Push, \"heavy\"", [(Fixtures.bench, [(100, 5)])])
        workout.notes = "line1\nline2"
        let csv = CSVExporter.sets([workout], units: UnitPreferences(weight: .kg, locale: Locale(identifier: "en_US_POSIX")))
        let lines = csv.components(separatedBy: "\r\n")
        XCTAssertTrue(lines[0].hasPrefix("Date,Workout,"))
        XCTAssertTrue(lines[1].contains("\"Push, \"\"heavy\"\"\""))
        XCTAssertTrue(lines[1].contains(",100,5,"))
        XCTAssertTrue(lines[1].hasSuffix("\"line1\nline2\""))
    }
}
