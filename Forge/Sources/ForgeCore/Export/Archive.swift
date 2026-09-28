import Foundation

/// A complete, human-readable export of everything the app stores. It is
/// the portable safety net: it lives outside the app (Files, iCloud Drive,
/// AirDrop) and survives the app being deleted.
public struct BackupArchive: Codable, Sendable {
    public static let formatIdentifier = "forge-backup"
    public static let currentVersion = 1

    public var format: String
    public var version: Int
    public var exportedAt: Date
    public var appVersion: String
    public var schemaVersion: Int
    public var settings: AppSettings?
    public var folders: [Folder]
    public var routines: [Routine]
    public var customExercises: [Exercise]
    public var exercisePreferences: [ExercisePreference]
    public var workouts: [Workout]
    public var measurements: [BodyMeasurement]
    public var timerPresets: [TimerPreset]

    public init(
        exportedAt: Date,
        appVersion: String,
        settings: AppSettings?,
        folders: [Folder],
        routines: [Routine],
        customExercises: [Exercise],
        exercisePreferences: [ExercisePreference],
        workouts: [Workout],
        measurements: [BodyMeasurement],
        timerPresets: [TimerPreset]
    ) {
        self.format = Self.formatIdentifier
        self.version = Self.currentVersion
        self.exportedAt = exportedAt
        self.appVersion = appVersion
        self.schemaVersion = Schema.latestVersion
        self.settings = settings
        self.folders = folders
        self.routines = routines
        self.customExercises = customExercises
        self.exercisePreferences = exercisePreferences
        self.workouts = workouts
        self.measurements = measurements
        self.timerPresets = timerPresets
    }

    enum CodingKeys: String, CodingKey {
        case format, version, exportedAt, appVersion, schemaVersion, settings, folders, routines
        case customExercises, exercisePreferences, workouts, measurements, timerPresets
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        format = c.value(.format, default: "")
        version = c.value(.version, default: 0)
        exportedAt = c.value(.exportedAt, default: Date())
        appVersion = c.value(.appVersion, default: "")
        schemaVersion = c.value(.schemaVersion, default: 0)
        settings = c.optionalValue(.settings)
        folders = c.value(.folders, default: [])
        routines = c.value(.routines, default: [])
        customExercises = c.value(.customExercises, default: [])
        exercisePreferences = c.value(.exercisePreferences, default: [])
        workouts = c.value(.workouts, default: [])
        measurements = c.value(.measurements, default: [])
        timerPresets = c.value(.timerPresets, default: [])
    }

    public var completedWorkoutCount: Int {
        workouts.filter { $0.status == .completed && $0.deletedAt == nil }.count
    }

    public var activeRoutineCount: Int {
        routines.filter { $0.deletedAt == nil }.count
    }
}

public enum ArchiveService {
    public static func makeArchive(from database: AppDatabase, appVersion: String, now: Date = Date()) throws -> BackupArchive {
        let preferences = try database.exercises.preferences()
        return BackupArchive(
            exportedAt: now,
            appVersion: appVersion,
            settings: try database.meta.getJSON(MetaRepository.Key.settings, as: AppSettings.self),
            folders: try database.routines.folders(),
            routines: try database.routines.routines(includeDeleted: true),
            customExercises: try database.exercises.customExercises(),
            exercisePreferences: preferences.values.sorted { $0.exerciseID < $1.exerciseID },
            workouts: try database.workouts.allWorkouts(includeDeleted: true),
            measurements: try database.measurements.all(),
            timerPresets: try database.timerPresets.all()
        )
    }

    public static func encode(_ archive: BackupArchive) throws -> Data {
        try JSONCoding.encoder(pretty: true).encode(archive)
    }

    public static func decode(_ data: Data) throws -> BackupArchive {
        let archive: BackupArchive
        do {
            archive = try JSONCoding.decoder().decode(BackupArchive.self, from: data)
        } catch {
            throw BackupError.invalidArchive("The file couldn't be decoded.")
        }
        guard archive.format == BackupArchive.formatIdentifier else {
            throw BackupError.invalidArchive("It isn't a Forge backup file.")
        }
        guard archive.version <= BackupArchive.currentVersion else {
            throw BackupError.newerArchive(archive.version)
        }
        return archive
    }

    public static func exportData(from database: AppDatabase, appVersion: String, now: Date = Date()) throws -> Data {
        try encode(try makeArchive(from: database, appVersion: appVersion, now: now))
    }

    /// Replaces all user data with the archive's contents in one
    /// transaction. Takes a "before import" snapshot first so this can be
    /// undone from the backups list.
    public static func restore(_ archive: BackupArchive, into database: AppDatabase, now: Date = Date()) throws {
        try database.backups.createSnapshot(from: database.queue, reason: .preImport, now: now)
        try database.queue.write { db in
            for table in Schema.userTables.reversed() {
                try db.run("DELETE FROM \(table)")
            }
            for folder in archive.folders {
                try RoutineRepository.insertFolder(folder, db: db)
            }
            for routine in archive.routines {
                try RoutineRepository.insertRoutine(routine, db: db)
            }
            for exercise in archive.customExercises {
                try ExerciseRepository.insertCustom(exercise, db: db, now: now)
            }
            for preference in archive.exercisePreferences {
                try ExerciseRepository.insertPreference(preference, db: db)
            }
            for workout in archive.workouts {
                try WorkoutRepository.insert(workout, db: db)
            }
            for measurement in archive.measurements {
                try MeasurementRepository.insert(measurement, db: db)
            }
            for preset in archive.timerPresets {
                try TimerPresetRepository.insert(preset, db: db)
            }
            if let settings = archive.settings {
                try db.run(
                    "INSERT INTO meta (key, value) VALUES (?, ?) ON CONFLICT(key) DO UPDATE SET value = excluded.value",
                    [MetaRepository.Key.settings, try JSONCoding.encodeString(settings)]
                )
            }
        }
    }

    public static func suggestedFileName(now: Date = Date()) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd-HHmm"
        return "Forge-Backup-\(formatter.string(from: now)).json"
    }
}

public enum CSVExporter {
    /// One row per logged set, for spreadsheets.
    public static func sets(_ workouts: [Workout], units: UnitPreferences) -> String {
        var lines = [row([
            "Date", "Workout", "Duration (min)", "Exercise", "Set", "Set Type",
            "Weight (\(units.weight.symbol))", "Reps", "Distance (m)", "Seconds", "RPE", "Completed", "Workout Notes",
        ])]
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        for workout in workouts.sorted(by: { $0.startedAt < $1.startedAt }) where workout.deletedAt == nil && workout.status == .completed {
            let minutes = String(format: "%.1f", workout.elapsed() / 60)
            for exercise in workout.allExercises {
                for (index, set) in exercise.sets.enumerated() {
                    lines.append(row([
                        formatter.string(from: workout.startedAt),
                        workout.name,
                        minutes,
                        exercise.name,
                        String(index + 1),
                        set.kind.displayName,
                        set.weight.map { plain(units.weight.fromKilograms($0)) } ?? "",
                        set.reps.map(String.init) ?? "",
                        set.distance.map { plain($0) } ?? "",
                        set.duration.map { plain($0) } ?? "",
                        set.rpe.map { plain($0) } ?? "",
                        set.isCompleted ? "yes" : "no",
                        workout.notes,
                    ]))
                }
            }
        }
        return lines.joined(separator: "\r\n") + "\r\n"
    }

    private static func plain(_ value: Double) -> String {
        let rounded = (value * 100).rounded() / 100
        if rounded == rounded.rounded() { return String(Int(rounded)) }
        return String(rounded)
    }

    private static func row(_ fields: [String]) -> String {
        fields.map(escape).joined(separator: ",")
    }

    static func escape(_ field: String) -> String {
        if field.contains(where: { $0 == "," || $0 == "\"" || $0 == "\n" || $0 == "\r" }) {
            return "\"" + field.replacingOccurrences(of: "\"", with: "\"\"") + "\""
        }
        return field
    }
}
