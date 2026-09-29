import Foundation

/// Finds data that exists in a backup — an on-device snapshot, a damaged
/// database that was set aside, or a JSON backup file — but not in the live
/// database, and adds it back without changing anything that's there.
///
/// Nothing is ever overwritten except when the athlete picks a fuller copy
/// of a workout they already have (for example one saved while sets were
/// still unticked).
public enum RecoveryService {
    public struct Source: Sendable {
        public enum Kind: String, Sendable {
            case snapshot, damagedDatabase, backupFile
        }

        public var kind: Kind
        /// Shown to the athlete ("Backup from Sep 28, 6:02 PM").
        public var label: String
        public var date: Date?
        public var load: @Sendable () throws -> BackupArchive

        public init(kind: Kind, label: String, date: Date?, load: @escaping @Sendable () throws -> BackupArchive) {
            self.kind = kind
            self.label = label
            self.date = date
            self.load = load
        }
    }

    public struct FoundWorkout: Identifiable, Sendable {
        /// Ready to save: always a finished workout.
        public var workout: Workout
        public var sourceLabel: String
        /// Sets with numbers in this copy.
        public var loggedSets: Int
        /// Set when this is a fuller copy of a workout already in History:
        /// how many sets the current copy has.
        public var replacesLoggedSets: Int?

        public var id: UUID { workout.id }
        public var isReplacement: Bool { replacesLoggedSets != nil }
    }

    public struct Report: Sendable {
        public var workouts: [FoundWorkout] = []
        public var routines: [Routine] = []
        public var folders: [Folder] = []
        public var customExercises: [Exercise] = []
        public var measurements: [BodyMeasurement] = []
        public var timerPresets: [TimerPreset] = []
        /// Sources looked at, and ones that couldn't be read at all.
        public var sourcesScanned = 0
        public var unreadableSources: [String] = []
        /// Items in backups that the athlete deleted for good; not offered.
        public var deletedOnPurpose = 0

        public init() {}

        public var isEmpty: Bool {
            workouts.isEmpty && routines.isEmpty && customExercises.isEmpty && measurements.isEmpty && timerPresets.isEmpty
        }

        public var itemCount: Int {
            workouts.count + routines.count + customExercises.count + measurements.count + timerPresets.count
        }
    }

    // MARK: Sources

    /// Every on-device source: snapshots (newest first) and damaged
    /// databases that were set aside.
    public static func deviceSources(for database: AppDatabase) -> [Source] {
        var sources: [Source] = []
        for snapshot in database.backups.snapshots() {
            let url = snapshot.url
            sources.append(Source(
                kind: .snapshot,
                label: "\(snapshot.reason.displayName) backup · \(Self.label(for: snapshot.date))",
                date: snapshot.date
            ) {
                try archive(fromDatabaseAt: url)
            })
        }
        let quarantine = database.location.quarantineDirectory
        let folders = (try? FileManager.default.contentsOfDirectory(at: quarantine, includingPropertiesForKeys: nil)) ?? []
        for folder in folders.sorted(by: { $0.lastPathComponent > $1.lastPathComponent }) {
            let file = folder.appendingPathComponent(database.location.databaseURL.lastPathComponent)
            guard FileManager.default.fileExists(atPath: file.path) else { continue }
            let date = Double(folder.lastPathComponent).map { Date(timeIntervalSince1970: $0 / 1000) }
            sources.append(Source(
                kind: .damagedDatabase,
                label: "Set-aside data file · \(date.map(Self.label(for:)) ?? folder.lastPathComponent)",
                date: date
            ) {
                try archive(fromDatabaseAt: file)
            })
        }
        return sources
    }

    /// A JSON backup file as a source.
    public static func backupFileSource(label: String, date: Date?, read: @escaping @Sendable () throws -> Data) -> Source {
        Source(kind: .backupFile, label: label, date: date) {
            try ArchiveService.decode(try read())
        }
    }

    /// Everything readable in a database file. The file is copied first
    /// (with its journal) so the original is never changed, and each kind
    /// of data is read on its own so one damaged table doesn't hide the
    /// rest; workouts fall back to one at a time.
    public static func archive(fromDatabaseAt url: URL) throws -> BackupArchive {
        let fileManager = FileManager.default
        let scratch = fileManager.temporaryDirectory.appendingPathComponent("forge-recovery-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: scratch, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: scratch) }
        let copy = scratch.appendingPathComponent("inspect.sqlite")
        try fileManager.copyItem(at: url, to: copy)
        for suffix in ["-wal", "-shm"] {
            let side = URL(fileURLWithPath: url.path + suffix)
            if fileManager.fileExists(atPath: side.path) {
                try? fileManager.copyItem(at: side, to: URL(fileURLWithPath: copy.path + suffix))
            }
        }
        let queue = try DatabaseQueue(inspecting: copy.path)
        defer { queue.close() }
        return salvage(queue)
    }

    static func salvage(_ queue: DatabaseQueue) -> BackupArchive {
        let routines = RoutineRepository(queue: queue)
        let workouts = WorkoutRepository(queue: queue)
        let exercises = ExerciseRepository(queue: queue)
        let measurements = MeasurementRepository(queue: queue)
        let presets = TimerPresetRepository(queue: queue)
        var allWorkouts: [Workout]
        if let all = try? workouts.allWorkouts(includeDeleted: true) {
            allWorkouts = all
        } else {
            let ids = (try? queue.read { db in
                try db.query("SELECT id FROM workout").compactMap { $0.uuid("id") }
            }) ?? []
            allWorkouts = ids.compactMap { try? workouts.workout(id: $0) }
        }
        allWorkouts.sort { $0.startedAt < $1.startedAt }
        return BackupArchive(
            exportedAt: Date(),
            appVersion: "",
            settings: nil,
            folders: (try? routines.folders()) ?? [],
            routines: (try? routines.routines(includeDeleted: true)) ?? [],
            customExercises: (try? exercises.customExercises()) ?? [],
            exercisePreferences: [],
            workouts: allWorkouts,
            measurements: (try? measurements.all()) ?? [],
            timerPresets: (try? presets.all()) ?? []
        )
    }

    // MARK: Scanning

    /// What the live database is missing, across every source. When the
    /// same item turns up in several sources the most complete copy wins.
    /// `progress` is told how many sources are done, out of how many.
    public static func scan(
        _ database: AppDatabase,
        sources: [Source],
        progress: (@Sendable (_ done: Int, _ total: Int) -> Void)? = nil
    ) throws -> Report {
        let live = try LiveIndex(database)
        var report = Report()
        var workouts: [UUID: FoundWorkout] = [:]
        var routines: [UUID: Routine] = [:]
        var folders: [UUID: Folder] = [:]
        var customs: [String: Exercise] = [:]
        var measurements: [UUID: BodyMeasurement] = [:]
        var presets: [UUID: TimerPreset] = [:]
        var skipped = Set<String>()
        /// Deleted for good by the athlete (and not back in live data).
        func gone(_ kind: Tombstones.Kind, _ id: String) -> Bool {
            guard live.tombstones[kind]?.contains(id) == true else { return false }
            skipped.insert("\(kind.rawValue):\(id)")
            return true
        }

        progress?(0, sources.count)
        for source in sources {
            report.sourcesScanned += 1
            defer { progress?(report.sourcesScanned, sources.count) }
            let archive: BackupArchive
            do {
                archive = try source.load()
            } catch {
                report.unreadableSources.append(source.label)
                continue
            }
            for candidate in archive.workouts {
                if live.workouts[candidate.id] == nil, gone(.workout, candidate.id.uuidString) { continue }
                guard let found = recoverable(candidate, live: live, sourceLabel: source.label) else { continue }
                if let existing = workouts[found.id], !isBetter(found, than: existing) { continue }
                workouts[found.id] = found
            }
            for routine in archive.routines where routine.deletedAt == nil && !live.routines.contains(routine.id) {
                if gone(.routine, routine.id.uuidString) { continue }
                if let existing = routines[routine.id], existing.updatedAt >= routine.updatedAt { continue }
                routines[routine.id] = routine
            }
            for folder in archive.folders where !live.folders.contains(folder.id) {
                folders[folder.id] = folders[folder.id] ?? folder
            }
            for exercise in archive.customExercises where !live.customExercises.contains(exercise.id) {
                if gone(.customExercise, exercise.id) { continue }
                if let existing = customs[exercise.id], (existing.updatedAt ?? .distantPast) >= (exercise.updatedAt ?? .distantPast) { continue }
                customs[exercise.id] = exercise
            }
            for measurement in archive.measurements where !live.measurements.contains(measurement.id) {
                if gone(.measurement, measurement.id.uuidString) { continue }
                measurements[measurement.id] = measurements[measurement.id] ?? measurement
            }
            for preset in archive.timerPresets where !live.presets.contains(preset.id) {
                if gone(.timerPreset, preset.id.uuidString) { continue }
                if let existing = presets[preset.id], existing.updatedAt >= preset.updatedAt { continue }
                presets[preset.id] = preset
            }
        }

        report.workouts = workouts.values.sorted { $0.workout.startedAt > $1.workout.startedAt }
        report.routines = routines.values.sorted { $0.updatedAt > $1.updatedAt }
        // Only the folders those routines need (and their parents).
        var neededFolders: [UUID: Folder] = [:]
        for routine in report.routines {
            var cursor = routine.folderID
            while let id = cursor, !live.folders.contains(id), neededFolders[id] == nil, let folder = folders[id] {
                neededFolders[id] = folder
                cursor = folder.parentID
            }
        }
        report.folders = Array(neededFolders.values)
        report.customExercises = customs.values.sorted { $0.name < $1.name }
        report.measurements = measurements.values.sorted { $0.measuredAt > $1.measuredAt }
        report.timerPresets = presets.values.sorted { $0.name < $1.name }
        report.deletedOnPurpose = skipped.count
        return report
    }

    /// A backup's copy of a workout, if it's something the live data lacks.
    static func recoverable(_ candidate: Workout, live: LiveIndex, sourceLabel: String) -> FoundWorkout? {
        // Deleted in that backup: the athlete removed it on purpose.
        guard candidate.deletedAt == nil else { return nil }
        var workout = candidate
        if workout.status == .active {
            // An in-progress copy (a backup made mid-workout). Keep it only
            // if something was entered, finished as of its last change.
            guard workout.hasUserInput else { return nil }
            workout = WorkoutFactory.finalize(workout, completeRemaining: false, keepEnteredSets: true, now: max(workout.startedAt, workout.updatedAt))
        }
        let logged = loggedSetCount(workout)
        guard logged > 0 || workout.blocks.contains(where: { $0.result != nil }) || !workout.notes.isEmpty else { return nil }
        switch live.workouts[workout.id] {
        case nil:
            return FoundWorkout(workout: workout, sourceLabel: sourceLabel, loggedSets: logged, replacesLoggedSets: nil)
        case .some(let current):
            // In Recently Deleted, or still open: leave it to the athlete.
            guard current.isCompletedAndVisible else { return nil }
            guard logged > current.loggedSets else { return nil }
            // Keep what the athlete edited on the saved copy.
            workout.name = current.name
            workout.notes = current.notes.isEmpty ? workout.notes : current.notes
            workout.rating = current.rating ?? workout.rating
            return FoundWorkout(workout: workout, sourceLabel: sourceLabel, loggedSets: logged, replacesLoggedSets: current.loggedSets)
        }
    }

    static func isBetter(_ candidate: FoundWorkout, than existing: FoundWorkout) -> Bool {
        if candidate.loggedSets != existing.loggedSets { return candidate.loggedSets > existing.loggedSets }
        return candidate.workout.updatedAt > existing.workout.updatedAt
    }

    static func loggedSetCount(_ workout: Workout) -> Int {
        workout.allExercises.reduce(0) { total, exercise in
            total + exercise.sets.filter { $0.isCompleted || $0.hasValues }.count
        }
    }

    /// What the live database holds, by ID.
    struct LiveIndex {
        struct WorkoutInfo {
            var isCompletedAndVisible: Bool
            var loggedSets: Int
            var name: String
            var notes: String
            var rating: Int?
        }

        var workouts: [UUID: WorkoutInfo] = [:]
        var routines: Set<UUID> = []
        var folders: Set<UUID> = []
        var customExercises: Set<String> = []
        var measurements: Set<UUID> = []
        var presets: Set<UUID> = []
        var tombstones: [Tombstones.Kind: Set<String>] = [:]

        init(_ database: AppDatabase) throws {
            for workout in try database.workouts.allWorkouts(includeDeleted: true) {
                workouts[workout.id] = WorkoutInfo(
                    isCompletedAndVisible: workout.status == .completed && workout.deletedAt == nil,
                    loggedSets: RecoveryService.loggedSetCount(workout),
                    name: workout.name,
                    notes: workout.notes,
                    rating: workout.rating
                )
            }
            routines = Set(try database.routines.routines(includeDeleted: true).map(\.id))
            folders = Set(try database.routines.folders().map(\.id))
            customExercises = Set(try database.exercises.customExercises().map(\.id))
            measurements = Set(try database.measurements.all().map(\.id))
            presets = Set(try database.timerPresets.all().map(\.id))
            tombstones = database.tombstones()
        }
    }

    // MARK: Restoring

    /// Adds the chosen items in one transaction, after a safety snapshot.
    /// Items that appeared in the meantime are left as they are.
    public static func restore(_ report: Report, into database: AppDatabase, now: Date = Date()) throws {
        try database.backups.createSnapshot(from: database.queue, reason: .preImport, now: now)
        try database.queue.write { db in
            func exists(_ table: String, _ id: DatabaseValueConvertible) throws -> Bool {
                try db.scalarInt("SELECT COUNT(*) FROM \(table) WHERE id = ?", [id]) > 0
            }
            for folder in report.folders {
                if try exists("folder", folder.id) { continue }
                try RoutineRepository.insertFolder(folder, db: db)
            }
            for exercise in report.customExercises {
                if try exists("custom_exercise", exercise.id) { continue }
                try ExerciseRepository.insertCustom(exercise, db: db, now: now)
            }
            for original in report.routines {
                if try exists("routine", original.id) { continue }
                var routine = original
                // A routine in a folder that no longer exists would be
                // invisible; put it at the top level instead.
                if let folderID = routine.folderID, try !exists("folder", folderID) {
                    routine.folderID = nil
                }
                try RoutineRepository.insertRoutine(routine, db: db)
            }
            for measurement in report.measurements {
                if try exists("measurement", measurement.id) { continue }
                try MeasurementRepository.insert(measurement, db: db)
            }
            for preset in report.timerPresets {
                if try exists("timer_preset", preset.id) { continue }
                try TimerPresetRepository.insert(preset, db: db)
            }
            for found in report.workouts {
                let present = try exists("workout", found.workout.id)
                // A fuller copy replaces the saved one; anything else is only
                // ever added.
                guard !present || found.isReplacement else { continue }
                try WorkoutRepository.insert(try withFreeChildIDs(found.workout, db: db), db: db)
            }
        }
    }

    /// The workout as is, or with new IDs for its blocks, exercises and
    /// sets if another workout already uses any of them (so one clash can't
    /// stop the whole restore).
    static func withFreeChildIDs(_ workout: Workout, db: Connection) throws -> Workout {
        func taken(_ table: String, _ id: UUID) throws -> Bool {
            try db.scalarInt("SELECT COUNT(*) FROM \(table) WHERE id = ? AND workout_id != ?", [id, workout.id]) > 0
        }
        var clash = false
        search: for block in workout.blocks {
            if try taken("workout_block", block.id) { clash = true; break search }
            for exercise in block.exercises {
                if try taken("workout_exercise", exercise.id) { clash = true; break search }
                for set in exercise.sets {
                    if try taken("workout_set", set.id) { clash = true; break search }
                }
            }
        }
        guard clash else { return workout }
        var copy = workout
        for blockIndex in copy.blocks.indices {
            copy.blocks[blockIndex].id = UUID()
            for exerciseIndex in copy.blocks[blockIndex].exercises.indices {
                copy.blocks[blockIndex].exercises[exerciseIndex].id = UUID()
                for setIndex in copy.blocks[blockIndex].exercises[exerciseIndex].sets.indices {
                    copy.blocks[blockIndex].exercises[exerciseIndex].sets[setIndex].id = UUID()
                }
            }
        }
        return copy
    }

    static func label(for date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter.string(from: date)
    }
}

extension RecoveryService.Report {
    /// Only the chosen items, plus what they depend on: the folders chosen
    /// routines sit in and the custom exercises chosen workouts and
    /// routines use.
    public func selecting(
        workouts workoutIDs: Set<UUID>,
        routines routineIDs: Set<UUID>,
        customExercises customIDs: Set<String>,
        measurements measurementIDs: Set<UUID>,
        timerPresets presetIDs: Set<UUID>
    ) -> RecoveryService.Report {
        var result = RecoveryService.Report()
        result.sourcesScanned = sourcesScanned
        result.unreadableSources = unreadableSources
        result.workouts = workouts.filter { workoutIDs.contains($0.id) }
        result.routines = routines.filter { routineIDs.contains($0.id) }

        var neededCustoms = customIDs
        for found in result.workouts {
            for exercise in found.workout.allExercises {
                neededCustoms.insert(exercise.exerciseID)
            }
        }
        for routine in result.routines {
            for block in routine.blocks {
                for exercise in block.exercises {
                    neededCustoms.insert(exercise.exerciseID)
                }
            }
        }
        result.customExercises = customExercises.filter { neededCustoms.contains($0.id) }

        var folderByID: [UUID: Folder] = [:]
        for folder in folders { folderByID[folder.id] = folder }
        var neededFolders = Set<UUID>()
        for routine in result.routines {
            var cursor = routine.folderID
            while let id = cursor, !neededFolders.contains(id), let folder = folderByID[id] {
                neededFolders.insert(id)
                cursor = folder.parentID
            }
        }
        result.folders = folders.filter { neededFolders.contains($0.id) }
        result.measurements = measurements.filter { measurementIDs.contains($0.id) }
        result.timerPresets = timerPresets.filter { presetIDs.contains($0.id) }
        return result
    }
}
