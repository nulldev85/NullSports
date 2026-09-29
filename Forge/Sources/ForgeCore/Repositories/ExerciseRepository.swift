import Foundation

public final class ExerciseRepository: @unchecked Sendable {
    let queue: DatabaseQueue

    init(queue: DatabaseQueue) {
        self.queue = queue
    }

    // MARK: Custom exercises

    public func customExercises() throws -> [Exercise] {
        try queue.read { db in
            try db.query("SELECT * FROM custom_exercise ORDER BY name COLLATE NOCASE").map(Self.exercise(from:))
        }
    }

    public func customExercise(id: String) throws -> Exercise? {
        try queue.read { db in
            try db.queryOne("SELECT * FROM custom_exercise WHERE id = ?", [id]).map(Self.exercise(from:))
        }
    }

    static func exercise(from row: Row) -> Exercise {
        let secondary = (row.string("secondary_muscles")).flatMap { try? JSONCoding.decode([MuscleGroup].self, from: $0) } ?? []
        let aliases = (row.string("aliases")).flatMap { try? JSONCoding.decode([String].self, from: $0) } ?? []
        return Exercise(
            id: row.string("id") ?? Exercise.newCustomID(),
            name: row.string("name") ?? "Exercise",
            primaryMuscle: MuscleGroup(storedValue: row.string("primary_muscle")),
            secondaryMuscles: secondary,
            equipment: Equipment(storedValue: row.string("equipment")),
            category: ExerciseCategory(storedValue: row.string("category")),
            tracking: TrackingType(storedValue: row.string("tracking")),
            aliases: aliases,
            instructions: row.string("instructions") ?? "",
            isCustom: true,
            archivedAt: row.date("archived_at"),
            createdAt: row.date("created_at"),
            updatedAt: row.date("updated_at")
        )
    }

    static func insertCustom(_ exercise: Exercise, db: Connection, now: Date) throws {
        let secondary = (try? JSONCoding.encodeString(exercise.secondaryMuscles)) ?? "[]"
        let aliases = (try? JSONCoding.encodeString(exercise.aliases)) ?? "[]"
        try db.run(
            """
            INSERT INTO custom_exercise (id, name, primary_muscle, secondary_muscles, equipment, category, tracking, aliases, instructions, created_at, updated_at, archived_at)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(id) DO UPDATE SET
                name = excluded.name,
                primary_muscle = excluded.primary_muscle,
                secondary_muscles = excluded.secondary_muscles,
                equipment = excluded.equipment,
                category = excluded.category,
                tracking = excluded.tracking,
                aliases = excluded.aliases,
                instructions = excluded.instructions,
                updated_at = excluded.updated_at,
                archived_at = excluded.archived_at
            """,
            [
                exercise.id, exercise.name, exercise.primaryMuscle.rawValue, secondary,
                exercise.equipment.rawValue, exercise.category.rawValue, exercise.tracking.rawValue,
                aliases, exercise.instructions, exercise.createdAt ?? now, exercise.updatedAt ?? now, exercise.archivedAt,
            ]
        )
    }

    public func saveCustom(_ exercise: Exercise, now: Date = Date()) throws {
        var copy = exercise
        copy.isCustom = true
        copy.updatedAt = now
        if copy.createdAt == nil { copy.createdAt = now }
        try queue.write { db in
            try Self.insertCustom(copy, db: db, now: now)
        }
    }

    public func archiveCustom(id: String, at date: Date = Date()) throws {
        try queue.write { db in
            try db.run("UPDATE custom_exercise SET archived_at = ?, updated_at = ? WHERE id = ?", [date, date, id])
        }
    }

    public func unarchiveCustom(id: String, now: Date = Date()) throws {
        try queue.write { db in
            try db.run("UPDATE custom_exercise SET archived_at = NULL, updated_at = ? WHERE id = ?", [now, id])
        }
    }

    /// Only allowed for exercises no workout or routine refers to.
    public func deleteCustomPermanently(id: String) throws {
        try queue.write { db in
            let uses = try Self.usageCount(exerciseID: id, db: db)
            guard uses == 0 else {
                throw DatabaseError(code: 19, message: "This exercise is used by \(uses) workouts or routines and can only be archived.")
            }
            try db.run("DELETE FROM custom_exercise WHERE id = ?", [id])
            try Tombstones.record(.customExercise, id, db: db)
            try db.run("DELETE FROM exercise_pref WHERE exercise_id = ?", [id])
        }
    }

    public func usageCount(exerciseID: String) throws -> Int {
        try queue.read { db in try Self.usageCount(exerciseID: exerciseID, db: db) }
    }

    static func usageCount(exerciseID: String, db: Connection) throws -> Int {
        let workouts = try db.scalarInt("SELECT COUNT(DISTINCT workout_id) FROM workout_exercise WHERE exercise_id = ?", [exerciseID])
        let needle = "%\"exerciseID\":\"\(exerciseID)\"%"
        let routines = try db.scalarInt("SELECT COUNT(*) FROM routine WHERE body LIKE ?", [needle])
        return workouts + routines
    }

    // MARK: Preferences

    public func preferences() throws -> [String: ExercisePreference] {
        try queue.read { db in
            var result: [String: ExercisePreference] = [:]
            for row in try db.query("SELECT * FROM exercise_pref") {
                guard let id = row.string("exercise_id") else { continue }
                result[id] = ExercisePreference(
                    exerciseID: id,
                    isFavorite: row.bool("is_favorite"),
                    note: row.string("note") ?? "",
                    restSeconds: row.int("rest_seconds"),
                    updatedAt: row.date("updated_at") ?? Date()
                )
            }
            return result
        }
    }

    static func insertPreference(_ preference: ExercisePreference, db: Connection) throws {
        if preference.isEmpty {
            try db.run("DELETE FROM exercise_pref WHERE exercise_id = ?", [preference.exerciseID])
            return
        }
        try db.run(
            """
            INSERT INTO exercise_pref (exercise_id, is_favorite, note, rest_seconds, updated_at)
            VALUES (?, ?, ?, ?, ?)
            ON CONFLICT(exercise_id) DO UPDATE SET
                is_favorite = excluded.is_favorite,
                note = excluded.note,
                rest_seconds = excluded.rest_seconds,
                updated_at = excluded.updated_at
            """,
            [preference.exerciseID, preference.isFavorite, preference.note, preference.restSeconds, preference.updatedAt]
        )
    }

    public func savePreference(_ preference: ExercisePreference) throws {
        try queue.write { db in
            try Self.insertPreference(preference, db: db)
        }
    }
}
