import Foundation

/// Versioned schema. Migrations only ever add; nothing here drops or
/// rewrites user data. Each migration runs in one transaction together with
/// its version bump, so a failure leaves the database exactly as it was.
public enum Schema {
    public struct Migration {
        public let version: Int
        public let name: String
        public let apply: (Connection) throws -> Void
    }

    public static let migrations: [Migration] = [
        Migration(version: 1, name: "initial") { db in
            try db.execute(version1)
        },
    ]

    public static var latestVersion: Int { migrations.last?.version ?? 0 }

    /// Tables that hold user data (everything except `meta` bookkeeping).
    public static let userTables = [
        "folder", "routine", "custom_exercise", "exercise_pref",
        "workout", "workout_block", "workout_exercise", "workout_set",
        "measurement", "timer_preset",
    ]

    @discardableResult
    public static func migrate(_ queue: DatabaseQueue) throws -> (from: Int, to: Int) {
        try queue.read { db in
            let start = try db.userVersion()
            var version = start
            for migration in migrations where migration.version > version {
                try db.inTransaction {
                    try migration.apply(db)
                    try db.setUserVersion(migration.version)
                }
                version = migration.version
            }
            return (start, version)
        }
    }

    static let version1 = """
    CREATE TABLE IF NOT EXISTS meta (
        key TEXT PRIMARY KEY NOT NULL,
        value TEXT NOT NULL
    );

    CREATE TABLE IF NOT EXISTS folder (
        id TEXT PRIMARY KEY NOT NULL,
        parent_id TEXT,
        name TEXT NOT NULL,
        color TEXT,
        sort_order REAL NOT NULL DEFAULT 0,
        created_at REAL NOT NULL,
        updated_at REAL NOT NULL
    );
    CREATE INDEX IF NOT EXISTS folder_parent ON folder(parent_id);

    CREATE TABLE IF NOT EXISTS routine (
        id TEXT PRIMARY KEY NOT NULL,
        folder_id TEXT,
        name TEXT NOT NULL,
        notes TEXT NOT NULL DEFAULT '',
        color TEXT,
        sort_order REAL NOT NULL DEFAULT 0,
        body TEXT NOT NULL,
        created_at REAL NOT NULL,
        updated_at REAL NOT NULL,
        last_performed_at REAL,
        deleted_at REAL
    );
    CREATE INDEX IF NOT EXISTS routine_folder ON routine(folder_id);

    CREATE TABLE IF NOT EXISTS custom_exercise (
        id TEXT PRIMARY KEY NOT NULL,
        name TEXT NOT NULL,
        primary_muscle TEXT NOT NULL,
        secondary_muscles TEXT NOT NULL DEFAULT '',
        equipment TEXT NOT NULL,
        category TEXT NOT NULL,
        tracking TEXT NOT NULL,
        aliases TEXT NOT NULL DEFAULT '',
        instructions TEXT NOT NULL DEFAULT '',
        created_at REAL NOT NULL,
        updated_at REAL NOT NULL,
        archived_at REAL
    );

    CREATE TABLE IF NOT EXISTS exercise_pref (
        exercise_id TEXT PRIMARY KEY NOT NULL,
        is_favorite INTEGER NOT NULL DEFAULT 0,
        note TEXT NOT NULL DEFAULT '',
        rest_seconds INTEGER,
        updated_at REAL NOT NULL
    );

    CREATE TABLE IF NOT EXISTS workout (
        id TEXT PRIMARY KEY NOT NULL,
        kind TEXT NOT NULL DEFAULT 'strength',
        status TEXT NOT NULL,
        routine_id TEXT,
        name TEXT NOT NULL,
        notes TEXT NOT NULL DEFAULT '',
        started_at REAL NOT NULL,
        ended_at REAL,
        duration REAL,
        bodyweight REAL,
        rating INTEGER,
        runtime TEXT,
        created_at REAL NOT NULL,
        updated_at REAL NOT NULL,
        deleted_at REAL
    );
    CREATE INDEX IF NOT EXISTS workout_started ON workout(started_at);
    CREATE INDEX IF NOT EXISTS workout_status ON workout(status, deleted_at);

    CREATE TABLE IF NOT EXISTS workout_block (
        id TEXT PRIMARY KEY NOT NULL,
        workout_id TEXT NOT NULL REFERENCES workout(id) ON DELETE CASCADE,
        position INTEGER NOT NULL,
        timer TEXT,
        result TEXT,
        notes TEXT NOT NULL DEFAULT ''
    );
    CREATE INDEX IF NOT EXISTS workout_block_workout ON workout_block(workout_id);

    CREATE TABLE IF NOT EXISTS workout_exercise (
        id TEXT PRIMARY KEY NOT NULL,
        workout_id TEXT NOT NULL REFERENCES workout(id) ON DELETE CASCADE,
        block_id TEXT NOT NULL REFERENCES workout_block(id) ON DELETE CASCADE,
        position INTEGER NOT NULL,
        exercise_id TEXT NOT NULL,
        exercise_name TEXT NOT NULL,
        tracking TEXT NOT NULL,
        notes TEXT NOT NULL DEFAULT '',
        rest_seconds INTEGER
    );
    CREATE INDEX IF NOT EXISTS workout_exercise_workout ON workout_exercise(workout_id);
    CREATE INDEX IF NOT EXISTS workout_exercise_exercise ON workout_exercise(exercise_id);

    CREATE TABLE IF NOT EXISTS workout_set (
        id TEXT PRIMARY KEY NOT NULL,
        workout_id TEXT NOT NULL REFERENCES workout(id) ON DELETE CASCADE,
        workout_exercise_id TEXT NOT NULL REFERENCES workout_exercise(id) ON DELETE CASCADE,
        exercise_id TEXT NOT NULL,
        position INTEGER NOT NULL,
        kind TEXT NOT NULL DEFAULT 'normal',
        weight REAL,
        reps INTEGER,
        duration REAL,
        distance REAL,
        rpe REAL,
        is_completed INTEGER NOT NULL DEFAULT 0,
        completed_at REAL,
        target TEXT
    );
    CREATE INDEX IF NOT EXISTS workout_set_workout ON workout_set(workout_id);
    CREATE INDEX IF NOT EXISTS workout_set_exercise ON workout_set(exercise_id);
    CREATE INDEX IF NOT EXISTS workout_set_parent ON workout_set(workout_exercise_id);

    CREATE TABLE IF NOT EXISTS measurement (
        id TEXT PRIMARY KEY NOT NULL,
        kind TEXT NOT NULL,
        value REAL NOT NULL,
        measured_at REAL NOT NULL,
        note TEXT NOT NULL DEFAULT '',
        created_at REAL NOT NULL
    );
    CREATE INDEX IF NOT EXISTS measurement_kind ON measurement(kind, measured_at);

    CREATE TABLE IF NOT EXISTS timer_preset (
        id TEXT PRIMARY KEY NOT NULL,
        name TEXT NOT NULL,
        config TEXT NOT NULL,
        sort_order REAL NOT NULL DEFAULT 0,
        created_at REAL NOT NULL,
        updated_at REAL NOT NULL
    );
    """
}
