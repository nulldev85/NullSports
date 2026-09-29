import Foundation
#if canImport(SQLite3)
import SQLite3
#else
import CSQLite
#endif

/// Where the app keeps its data. Application Support is never purged by the
/// system and is included in iCloud/computer device backups.
public struct StorageLocation: Sendable {
    public let directory: URL

    public init(directory: URL) {
        self.directory = directory
    }

    public static func applicationSupport(fileManager: FileManager = .default) throws -> StorageLocation {
        let base = try fileManager.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
        return StorageLocation(directory: base.appendingPathComponent("Forge", isDirectory: true))
    }

    public var databaseURL: URL { directory.appendingPathComponent("forge.sqlite") }
    public var backupsDirectory: URL { directory.appendingPathComponent("Backups", isDirectory: true) }
    public var quarantineDirectory: URL { directory.appendingPathComponent("Quarantine", isDirectory: true) }
}

public struct OpenReport: Sendable {
    public enum Recovery: Sendable, Equatable {
        /// The database was damaged; it was set aside and the newest intact
        /// backup was restored, plus anything newer that could still be read
        /// from the damaged file (`salvaged` items).
        case restoredFromBackup(Date, salvaged: Int)
        /// The database was damaged and no intact backup existed. The damaged
        /// file is kept in the quarantine folder.
        case startedFresh
    }

    public var createdNewDatabase = false
    public var migratedFrom: Int?
    public var migratedTo: Int?
    public var recovery: Recovery?
    /// Set when the file was written by a newer build than this one.
    public var newerSchemaVersion: Int?
}

public final class AppDatabase: @unchecked Sendable {
    public let queue: DatabaseQueue
    public let location: StorageLocation
    public let backups: BackupManager
    public let report: OpenReport

    public let routines: RoutineRepository
    public let workouts: WorkoutRepository
    public let exercises: ExerciseRepository
    public let measurements: MeasurementRepository
    public let timerPresets: TimerPresetRepository
    public let meta: MetaRepository

    private init(queue: DatabaseQueue, location: StorageLocation, backups: BackupManager, report: OpenReport) {
        self.queue = queue
        self.location = location
        self.backups = backups
        self.report = report
        self.routines = RoutineRepository(queue: queue)
        self.workouts = WorkoutRepository(queue: queue)
        self.exercises = ExerciseRepository(queue: queue)
        self.measurements = MeasurementRepository(queue: queue)
        self.timerPresets = TimerPresetRepository(queue: queue)
        self.meta = MetaRepository(queue: queue)
    }

    /// Opens (creating if needed), verifies, and migrates the database.
    ///
    /// Safety rules:
    /// - The database file is only ever moved aside when SQLite itself says
    ///   it is corrupt. Any other failure (disk full, I/O error) is thrown so
    ///   the UI can report it and retry; the file is left untouched.
    /// - A damaged file is quarantined, never deleted.
    /// - A snapshot is taken before any schema migration.
    public static func open(at location: StorageLocation, now: Date = Date()) throws -> AppDatabase {
        let fileManager = FileManager.default
        try fileManager.createDirectory(at: location.directory, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: location.backupsDirectory, withIntermediateDirectories: true)
        #if os(iOS)
        // Keep the data readable while the phone is locked after first
        // unlock, so saves during a locked-screen workout never fail.
        try? fileManager.setAttributes(
            [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication],
            ofItemAtPath: location.directory.path
        )
        #endif

        let backups = BackupManager(directory: location.backupsDirectory)
        var report = OpenReport()
        let path = location.databaseURL.path
        let queue: DatabaseQueue

        if fileManager.fileExists(atPath: path) {
            do {
                queue = try openVerified(path: path)
            } catch let error as DatabaseError where error.isCorruption {
                try quarantine(location: location, now: now)
                if let snapshot = backups.latestValidSnapshot() {
                    try fileManager.copyItem(at: snapshot.url, to: location.databaseURL)
                    queue = try DatabaseQueue(path: path)
                    report.recovery = .restoredFromBackup(snapshot.date, salvaged: 0)
                } else {
                    queue = try DatabaseQueue(path: path)
                    report.recovery = .startedFresh
                }
            }
        } else {
            queue = try DatabaseQueue(path: path)
            report.createdNewDatabase = true
        }

        let current = try queue.read { try $0.userVersion() }
        if current > Schema.latestVersion {
            report.newerSchemaVersion = current
        } else if current < Schema.latestVersion {
            if current > 0 {
                try backups.createSnapshot(from: queue, reason: .preMigration, now: now)
            }
            let result = try Schema.migrate(queue)
            report.migratedFrom = result.from
            report.migratedTo = result.to
        }

        var database = AppDatabase(queue: queue, location: location, backups: backups, report: report)
        try database.meta.setIfMissing("created_at", value: ISO8601.string(from: now))
        if case .restoredFromBackup(let date, _) = report.recovery {
            // The snapshot can be hours old: pull in whatever newer data the
            // damaged file still gives up.
            let salvaged = database.salvageFromSetAsideFiles()
            if salvaged > 0 {
                report.recovery = .restoredFromBackup(date, salvaged: salvaged)
                database = AppDatabase(queue: queue, location: location, backups: backups, report: report)
            }
        }
        return database
    }

    /// Adds back everything readable in set-aside (damaged) database files
    /// that the live data lacks. Returns how many items were added.
    @discardableResult
    public func salvageFromSetAsideFiles() -> Int {
        let sources = RecoveryService.deviceSources(for: self).filter { $0.kind == .damagedDatabase }
        guard !sources.isEmpty,
              let report = try? RecoveryService.scan(self, sources: sources),
              !report.isEmpty else { return 0 }
        do {
            try RecoveryService.restore(report, into: self)
            return report.itemCount
        } catch {
            return 0
        }
    }

    private static func openVerified(path: String) throws -> DatabaseQueue {
        let queue = try DatabaseQueue(path: path)
        do {
            let problems = try queue.read { try $0.integrityProblems() }
            if !problems.isEmpty {
                throw DatabaseError(code: SQLITE_CORRUPT, message: problems.prefix(5).joined(separator: "; "))
            }
            // Touch the schema so a non-database file surfaces as NOTADB here.
            _ = try queue.read { try $0.userVersion() }
            return queue
        } catch {
            queue.close()
            throw error
        }
    }

    /// Moves the database and its WAL/SHM side files into a timestamped
    /// quarantine folder.
    private static func quarantine(location: StorageLocation, now: Date) throws {
        let fileManager = FileManager.default
        let stamp = Int64(now.timeIntervalSince1970 * 1000)
        let folder = location.quarantineDirectory.appendingPathComponent("\(stamp)", isDirectory: true)
        try fileManager.createDirectory(at: folder, withIntermediateDirectories: true)
        for suffix in ["", "-wal", "-shm", "-journal"] {
            let source = URL(fileURLWithPath: location.databaseURL.path + suffix)
            guard fileManager.fileExists(atPath: source.path) else { continue }
            try fileManager.moveItem(at: source, to: folder.appendingPathComponent(source.lastPathComponent))
        }
    }

    // MARK: Maintenance

    /// Makes the daily automatic snapshot when one is due.
    @discardableResult
    public func performAutomaticBackupIfDue(now: Date = Date()) -> BackupManager.Snapshot? {
        guard backups.isAutomaticBackupDue(now: now), hasUserData() else { return nil }
        let snapshot = try? backups.createSnapshot(from: queue, reason: .automatic, now: now)
        backups.prune()
        return snapshot
    }

    public func hasUserData() -> Bool {
        let count = try? queue.read { db -> Int in
            var total = 0
            for table in ["routine", "workout", "custom_exercise", "measurement", "folder"] {
                total += try db.scalarInt("SELECT COUNT(*) FROM \(table)")
                if total > 0 { break }
            }
            return total
        }
        return (count ?? 0) > 0
    }

    /// Replaces all data with the contents of a snapshot. A "before restore"
    /// snapshot of the current data is taken first, so the restore itself
    /// can be undone.
    public func restore(from snapshot: BackupManager.Snapshot, now: Date = Date()) throws {
        guard backups.validate(snapshot) else {
            throw BackupError.invalidSnapshot("It failed an integrity check.")
        }
        try backups.createSnapshot(from: queue, reason: .preRestore, now: now)
        let source = try Connection(path: snapshot.url.path, readOnly: true)
        defer { source.close() }
        try queue.read { db in
            try db.replaceContents(from: source)
            _ = try? db.scalar("PRAGMA journal_mode = WAL")
        }
        try Schema.migrate(queue)
    }

    public func checkpoint() {
        queue.checkpoint()
    }

    /// Takes a "Before app update" snapshot the first time a different
    /// build opens this data, before the new build changes anything. The
    /// build is only recorded once the snapshot exists, so a failed attempt
    /// is retried on the next launch.
    @discardableResult
    public func snapshotIfNewBuild(_ build: String, now: Date = Date()) -> BackupManager.Snapshot? {
        let previous: String? = try? meta.get(MetaRepository.Key.lastBuild)
        guard previous != build else { return nil }
        guard hasUserData() else {
            try? meta.set(MetaRepository.Key.lastBuild, value: build)
            return nil
        }
        guard let snapshot = try? backups.createSnapshot(from: queue, reason: .preUpdate, now: now) else { return nil }
        try? meta.set(MetaRepository.Key.lastBuild, value: build)
        backups.prune()
        return snapshot
    }

    /// A snapshot right after a workout is saved, so the newest backup is
    /// never more than one workout behind.
    @discardableResult
    public func snapshotAfterWorkout(now: Date = Date()) -> BackupManager.Snapshot? {
        let snapshot = try? backups.createSnapshot(from: queue, reason: .afterWorkout, now: now)
        backups.prune()
        return snapshot
    }

    public struct IntegrityStatus: Sendable, Equatable {
        public var checkedAt: Date?
        /// Empty when everything was fine.
        public var problems: [String]
    }

    /// The last full integrity check.
    public var integrityStatus: IntegrityStatus {
        let checkedText: String? = try? meta.get(MetaRepository.Key.integrityCheckedAt)
        let problemsText: String? = try? meta.get(MetaRepository.Key.integrityProblems)
        let problems = problemsText ?? ""
        return IntegrityStatus(
            checkedAt: checkedText.flatMap(ISO8601.date(from:)),
            problems: problems.isEmpty ? [] : problems.components(separatedBy: "\n")
        )
    }

    /// Runs SQLite's full integrity check if the last one is older than
    /// `interval` (launch only runs the quick check). Returns the problems
    /// found, or nil if no check was due.
    @discardableResult
    public func fullIntegrityCheckIfDue(now: Date = Date(), interval: TimeInterval = 6 * 86_400) -> [String]? {
        if let last = integrityStatus.checkedAt, now.timeIntervalSince(last) < interval, last <= now {
            return nil
        }
        var problems: [String]
        do {
            problems = try queue.read { try $0.integrityProblems(full: true) }
            if !problems.isEmpty {
                // What a full check finds beyond the quick one is almost
                // always in indexes, which are rebuilt from the tables
                // themselves without touching a row.
                try? queue.write { try $0.execute("REINDEX") }
                problems = try queue.read { try $0.integrityProblems(full: true) }
            }
        } catch {
            problems = [String(describing: error)]
        }
        try? meta.set(MetaRepository.Key.integrityCheckedAt, value: ISO8601.string(from: now))
        try? meta.set(MetaRepository.Key.integrityProblems, value: problems.prefix(20).joined(separator: "\n"))
        return problems
    }

    public var fileSize: Int {
        let fileManager = FileManager.default
        var total = 0
        for suffix in ["", "-wal"] {
            let path = location.databaseURL.path + suffix
            if let size = (try? fileManager.attributesOfItem(atPath: path)[.size] as? NSNumber)?.intValue {
                total += size
            }
        }
        return total
    }
}
