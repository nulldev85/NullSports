import Foundation
import XCTest
@testable import ForgeCore

final class SQLiteTests: XCTestCase {
    func testRoundTripsEveryValueType() throws {
        let dir = TemporaryDirectory()
        let queue = try DatabaseQueue(path: dir.url.appendingPathComponent("t.sqlite").path)
        try queue.write { db in
            try db.execute("CREATE TABLE t (i INTEGER, r REAL, s TEXT, b BLOB, n TEXT)")
            try db.run("INSERT INTO t VALUES (?, ?, ?, ?, ?)", [42, 3.5, "héllo\u{0}world ✓", Data([0, 1, 2, 255]), Optional<String>.none])
        }
        let row = try XCTUnwrap(queue.read { try $0.queryOne("SELECT * FROM t") })
        XCTAssertEqual(row.int("i"), 42)
        XCTAssertEqual(row.double("r"), 3.5)
        XCTAssertEqual(row.string("s"), "héllo\u{0}world ✓")
        XCTAssertEqual(row.data("b"), Data([0, 1, 2, 255]))
        XCTAssertTrue(row.isNull("n"))
        XCTAssertTrue(row.isNull("missing_column"))
    }

    func testEmptyBlobAndNonFiniteDoubles() throws {
        let dir = TemporaryDirectory()
        let queue = try DatabaseQueue(path: dir.url.appendingPathComponent("t.sqlite").path)
        try queue.write { db in
            try db.execute("CREATE TABLE t (b BLOB, r REAL)")
            try db.run("INSERT INTO t VALUES (?, ?)", [Data(), Double.nan])
        }
        let row = try XCTUnwrap(queue.read { try $0.queryOne("SELECT * FROM t") })
        XCTAssertEqual(row.data("b"), Data())
        XCTAssertTrue(row.isNull("r"), "NaN must be stored as NULL, not garbage")
    }

    func testFailedTransactionRollsBackEverything() throws {
        let dir = TemporaryDirectory()
        let queue = try DatabaseQueue(path: dir.url.appendingPathComponent("t.sqlite").path)
        try queue.write { db in try db.execute("CREATE TABLE t (id INTEGER PRIMARY KEY)") }
        struct Boom: Error {}
        XCTAssertThrowsError(try queue.write { db in
            try db.run("INSERT INTO t VALUES (1)")
            try db.run("INSERT INTO t VALUES (2)")
            throw Boom()
        })
        XCTAssertEqual(try queue.read { try $0.scalarInt("SELECT COUNT(*) FROM t") }, 0)

        // A constraint failure mid-transaction also leaves nothing behind.
        XCTAssertThrowsError(try queue.write { db in
            try db.run("INSERT INTO t VALUES (5)")
            try db.run("INSERT INTO t VALUES (5)")
        })
        XCTAssertEqual(try queue.read { try $0.scalarInt("SELECT COUNT(*) FROM t") }, 0)

        // And the connection is still usable afterwards.
        try queue.write { db in try db.run("INSERT INTO t VALUES (7)") }
        XCTAssertEqual(try queue.read { try $0.scalarInt("SELECT COUNT(*) FROM t") }, 1)
    }

    func testNestedWritesUseSavepoints() throws {
        let dir = TemporaryDirectory()
        let queue = try DatabaseQueue(path: dir.url.appendingPathComponent("t.sqlite").path)
        try queue.write { db in try db.execute("CREATE TABLE t (id INTEGER PRIMARY KEY)") }
        struct Boom: Error {}
        try queue.write { db in
            try db.run("INSERT INTO t VALUES (1)")
            XCTAssertThrowsError(try queue.write { inner in
                try inner.run("INSERT INTO t VALUES (2)")
                throw Boom()
            })
            try db.run("INSERT INTO t VALUES (3)")
        }
        let ids = try queue.read { try $0.query("SELECT id FROM t ORDER BY id").compactMap { $0.int("id") } }
        XCTAssertEqual(ids, [1, 3])
    }

    func testArgumentCountMismatchIsAnError() throws {
        let dir = TemporaryDirectory()
        let queue = try DatabaseQueue(path: dir.url.appendingPathComponent("t.sqlite").path)
        try queue.write { db in try db.execute("CREATE TABLE t (a, b)") }
        XCTAssertThrowsError(try queue.write { db in try db.run("INSERT INTO t VALUES (?, ?)", [1]) })
    }

    func testUsesWriteAheadLogAndFullSync() throws {
        let dir = TemporaryDirectory()
        let queue = try DatabaseQueue(path: dir.url.appendingPathComponent("t.sqlite").path)
        let mode = try queue.read { try $0.scalar("PRAGMA journal_mode") }
        XCTAssertEqual(mode, .text("wal"))
        let sync = try queue.read { try $0.scalarInt("PRAGMA synchronous") }
        XCTAssertEqual(sync, 2, "synchronous should be FULL")
        let fk = try queue.read { try $0.scalarInt("PRAGMA foreign_keys") }
        XCTAssertEqual(fk, 1)
    }

    func testConcurrentWritesAreSerialized() throws {
        let dir = TemporaryDirectory()
        let queue = try DatabaseQueue(path: dir.url.appendingPathComponent("t.sqlite").path)
        try queue.write { db in try db.execute("CREATE TABLE t (id INTEGER PRIMARY KEY AUTOINCREMENT, v INTEGER)") }
        DispatchQueue.concurrentPerform(iterations: 200) { index in
            try? queue.write { db in try db.run("INSERT INTO t (v) VALUES (?)", [index]) }
        }
        XCTAssertEqual(try queue.read { try $0.scalarInt("SELECT COUNT(*) FROM t") }, 200)
    }
}

final class AppDatabaseTests: XCTestCase {
    func testCreatesAndMigratesNewDatabase() throws {
        let dir = TemporaryDirectory()
        let db = try AppDatabase.open(at: dir.location)
        XCTAssertTrue(db.report.createdNewDatabase)
        XCTAssertEqual(db.report.migratedTo, Schema.latestVersion)
        XCTAssertEqual(try db.queue.read { try $0.userVersion() }, Schema.latestVersion)
        for table in Schema.userTables {
            XCTAssertTrue(try db.queue.read { try $0.tableExists(table) }, table)
        }
    }

    func testDataSurvivesReopen() throws {
        let dir = TemporaryDirectory()
        let routineID: UUID
        do {
            let db = try AppDatabase.open(at: dir.location)
            let routine = Routine(name: "Push Day", blocks: [RoutineBlock(exercises: [RoutineExercise(exerciseID: "bench-press-barbell", sets: [RoutineSet()])])])
            routineID = routine.id
            try db.routines.save(routine)
            db.queue.close()
        }
        let reopened = try AppDatabase.open(at: dir.location)
        XCTAssertFalse(reopened.report.createdNewDatabase)
        XCTAssertNil(reopened.report.recovery)
        XCTAssertEqual(try reopened.routines.routine(id: routineID)?.name, "Push Day")
    }

    func testMigrationIsIdempotent() throws {
        let dir = TemporaryDirectory()
        let db = try AppDatabase.open(at: dir.location)
        let result = try Schema.migrate(db.queue)
        XCTAssertEqual(result.from, result.to)
    }

    func testCorruptDatabaseIsQuarantinedAndRestoredFromBackup() throws {
        let dir = TemporaryDirectory()
        let location = dir.location
        do {
            let db = try AppDatabase.open(at: location)
            try db.workouts.save(Fixtures.workout(on: Fixtures.date(1), name: "Saved", [(Fixtures.bench, [(100, 5)])]))
            try db.backups.createSnapshot(from: db.queue, reason: .automatic)
            db.queue.close()
        }
        // Scribble over the file the way a failing disk might.
        let garbage = Data((0..<8192).map { _ in UInt8.random(in: 0...255) })
        try garbage.write(to: location.databaseURL)
        try? FileManager.default.removeItem(atPath: location.databaseURL.path + "-wal")
        try? FileManager.default.removeItem(atPath: location.databaseURL.path + "-shm")

        let recovered = try AppDatabase.open(at: location)
        guard case .restoredFromBackup = recovered.report.recovery else {
            return XCTFail("expected restore from backup, got \(String(describing: recovered.report.recovery))")
        }
        XCTAssertEqual(try recovered.workouts.summaries().map(\.name), ["Saved"])
        let quarantined = try FileManager.default.contentsOfDirectory(atPath: location.quarantineDirectory.path)
        XCTAssertEqual(quarantined.count, 1, "the damaged file must be kept, not deleted")
    }

    func testCorruptDatabaseWithoutBackupStartsFreshButKeepsTheDamagedFile() throws {
        let dir = TemporaryDirectory()
        let location = dir.location
        try FileManager.default.createDirectory(at: location.directory, withIntermediateDirectories: true)
        try Data(repeating: 0x41, count: 4096).write(to: location.databaseURL)

        let db = try AppDatabase.open(at: location)
        XCTAssertEqual(db.report.recovery, .startedFresh)
        let folders = try FileManager.default.contentsOfDirectory(atPath: location.quarantineDirectory.path)
        XCTAssertEqual(folders.count, 1)
        let moved = try FileManager.default.contentsOfDirectory(atPath: location.quarantineDirectory.appendingPathComponent(folders[0]).path)
        XCTAssertTrue(moved.contains("forge.sqlite"))
    }

    func testNewerSchemaIsReportedAndNotTouched() throws {
        let dir = TemporaryDirectory()
        do {
            let db = try AppDatabase.open(at: dir.location)
            try db.queue.read { try $0.setUserVersion(Schema.latestVersion + 5) }
            db.queue.close()
        }
        let db = try AppDatabase.open(at: dir.location)
        XCTAssertEqual(db.report.newerSchemaVersion, Schema.latestVersion + 5)
        XCTAssertEqual(try db.queue.read { try $0.userVersion() }, Schema.latestVersion + 5)
    }

    func testAutomaticBackupOnlyWhenDueAndDataExists() throws {
        let dir = TemporaryDirectory()
        let db = try AppDatabase.open(at: dir.location)
        XCTAssertNil(db.performAutomaticBackupIfDue(), "nothing to back up yet")
        try db.routines.save(Routine(name: "A"))
        let now = Fixtures.date(10)
        XCTAssertNotNil(db.performAutomaticBackupIfDue(now: now))
        XCTAssertNil(db.performAutomaticBackupIfDue(now: now.addingTimeInterval(3600)), "not due again within the day")
        XCTAssertNotNil(db.performAutomaticBackupIfDue(now: now.addingTimeInterval(21 * 3600)))
    }
}

final class BackupManagerTests: XCTestCase {
    func testSnapshotRestoreRoundTrip() throws {
        let dir = TemporaryDirectory()
        let db = try AppDatabase.open(at: dir.location)
        try db.routines.save(Routine(name: "Before"))
        let snapshot = try db.backups.createSnapshot(from: db.queue, reason: .manual)
        XCTAssertTrue(db.backups.validate(snapshot))
        XCTAssertEqual(db.backups.summary(of: snapshot)?.routines, 1)

        try db.routines.save(Routine(name: "After"))
        XCTAssertEqual(try db.routines.routines().count, 2)

        try db.restore(from: snapshot)
        XCTAssertEqual(try db.routines.routines().map(\.name), ["Before"])
        XCTAssertEqual(try db.queue.read { try $0.scalar("PRAGMA journal_mode") }, .text("wal"))

        // The pre-restore snapshot lets the restore itself be undone.
        let undo = try XCTUnwrap(db.backups.snapshots().first { $0.reason == .preRestore })
        try db.restore(from: undo)
        XCTAssertEqual(Set(try db.routines.routines().map(\.name)), ["Before", "After"])

        // The database is still fully writable after restores.
        try db.routines.save(Routine(name: "Third"))
        XCTAssertEqual(try db.routines.routines().count, 3)
    }

    func testInvalidSnapshotIsRejected() throws {
        let dir = TemporaryDirectory()
        let db = try AppDatabase.open(at: dir.location)
        try db.routines.save(Routine(name: "Keep"))
        let snapshot = try db.backups.createSnapshot(from: db.queue, reason: .manual)
        try Data(repeating: 7, count: 1000).write(to: snapshot.url)
        XCTAssertFalse(db.backups.validate(snapshot))
        XCTAssertThrowsError(try db.restore(from: snapshot))
        XCTAssertEqual(try db.routines.routines().map(\.name), ["Keep"])
    }

    func testPruneKeepsRecentAndWeeklyAutomaticBackups() throws {
        let dir = TemporaryDirectory()
        let db = try AppDatabase.open(at: dir.location)
        try db.routines.save(Routine(name: "A"))
        let start = Fixtures.date(1, month: 1)
        for day in 0..<40 {
            try db.backups.createSnapshot(from: db.queue, reason: .automatic, now: start.addingTimeInterval(Double(day) * 86400))
        }
        try db.backups.createSnapshot(from: db.queue, reason: .manual, now: start)
        db.backups.prune(keepAutomatic: 10, keepWeekly: 4)
        let remaining = db.backups.snapshots()
        XCTAssertEqual(remaining.filter { $0.reason == .automatic }.count, 14)
        XCTAssertEqual(remaining.filter { $0.reason == .manual }.count, 1, "manual backups are never pruned")
        XCTAssertEqual(remaining.first?.date, start.addingTimeInterval(39 * 86400))
    }

    func testSnapshotsSortNewestFirstAndIgnoreStrayFiles() throws {
        let dir = TemporaryDirectory()
        let db = try AppDatabase.open(at: dir.location)
        try db.backups.createSnapshot(from: db.queue, reason: .automatic, now: Fixtures.date(1))
        try db.backups.createSnapshot(from: db.queue, reason: .automatic, now: Fixtures.date(3))
        try db.backups.createSnapshot(from: db.queue, reason: .automatic, now: Fixtures.date(2))
        try Data("x".utf8).write(to: db.location.backupsDirectory.appendingPathComponent("notes.txt"))
        try Data("x".utf8).write(to: db.location.backupsDirectory.appendingPathComponent("forge-1-auto.sqlite.partial"))
        let dates = db.backups.snapshots().map(\.date)
        XCTAssertEqual(dates, [Fixtures.date(3), Fixtures.date(2), Fixtures.date(1)])
        db.backups.prune()
        XCTAssertFalse(FileManager.default.fileExists(atPath: db.location.backupsDirectory.appendingPathComponent("forge-1-auto.sqlite.partial").path))
    }
}
