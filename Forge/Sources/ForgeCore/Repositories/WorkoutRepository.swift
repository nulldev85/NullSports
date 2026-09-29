import Foundation

public final class WorkoutRepository: @unchecked Sendable {
    let queue: DatabaseQueue

    init(queue: DatabaseQueue) {
        self.queue = queue
    }

    // MARK: Saving

    /// Writes the complete workout in one transaction: the header row is
    /// upserted and its blocks, exercises and sets are replaced. Either the
    /// whole new state is on disk afterwards or the previous one still is.
    public func save(_ workout: Workout) throws {
        try queue.write { db in
            try Self.insert(workout, db: db)
        }
    }

    /// Saves, then reads the workout back and confirms every set arrived.
    /// Used for the saves that matter most (finishing a workout), so a
    /// problem surfaces while the workout is still open instead of later.
    public func saveVerified(_ workout: Workout) throws {
        try save(workout)
        guard let stored = try self.workout(id: workout.id) else {
            throw DatabaseError(code: 1, message: "The workout couldn't be read back after saving.")
        }
        let expected = workout.allExercises.flatMap(\.sets)
        let actual = stored.allExercises.flatMap(\.sets)
        let matches = stored.status == workout.status
            && expected.map(\.id) == actual.map(\.id)
            && zip(expected, actual).allSatisfy { lhs, rhs in
                lhs.isCompleted == rhs.isCompleted && lhs.reps == rhs.reps
                    && Self.same(lhs.weight, rhs.weight) && Self.same(lhs.duration, rhs.duration) && Self.same(lhs.distance, rhs.distance)
            }
        guard matches else {
            throw DatabaseError(code: 1, message: "The saved workout didn't match what was logged.")
        }
    }

    private static func same(_ lhs: Double?, _ rhs: Double?) -> Bool {
        switch (lhs, rhs) {
        case (nil, nil): return true
        case let (l?, r?): return abs(l - r) < 1e-6
        default: return false
        }
    }

    static func insert(_ workout: Workout, db: Connection) throws {
        let runtime: String? = workout.runtime.isEmpty ? nil : try JSONCoding.encodeString(workout.runtime)
        try db.run(
            """
            INSERT INTO workout (id, kind, status, routine_id, name, notes, started_at, ended_at, duration, bodyweight, rating, runtime, created_at, updated_at, deleted_at)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(id) DO UPDATE SET
                kind = excluded.kind,
                status = excluded.status,
                routine_id = excluded.routine_id,
                name = excluded.name,
                notes = excluded.notes,
                started_at = excluded.started_at,
                ended_at = excluded.ended_at,
                duration = excluded.duration,
                bodyweight = excluded.bodyweight,
                rating = excluded.rating,
                runtime = excluded.runtime,
                updated_at = excluded.updated_at,
                deleted_at = excluded.deleted_at
            """,
            [
                workout.id, workout.kind.rawValue, workout.status.rawValue, workout.routineID, workout.name, workout.notes,
                workout.startedAt, workout.endedAt, workout.duration, workout.bodyweight, workout.rating, runtime,
                workout.createdAt, workout.updatedAt, workout.deletedAt,
            ]
        )
        try db.run("DELETE FROM workout_set WHERE workout_id = ?", [workout.id])
        try db.run("DELETE FROM workout_exercise WHERE workout_id = ?", [workout.id])
        try db.run("DELETE FROM workout_block WHERE workout_id = ?", [workout.id])

        for (blockIndex, block) in workout.blocks.enumerated() {
            let timer: String? = try block.timer.map { try JSONCoding.encodeString($0) }
            let result: String? = try block.result.map { try JSONCoding.encodeString($0) }
            try db.run(
                "INSERT INTO workout_block (id, workout_id, position, timer, result, notes) VALUES (?, ?, ?, ?, ?, ?)",
                [block.id, workout.id, blockIndex, timer, result, block.notes]
            )
            for (exerciseIndex, exercise) in block.exercises.enumerated() {
                try db.run(
                    """
                    INSERT INTO workout_exercise (id, workout_id, block_id, position, exercise_id, exercise_name, tracking, notes, rest_seconds)
                    VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
                    """,
                    [
                        exercise.id, workout.id, block.id, exerciseIndex, exercise.exerciseID, exercise.name,
                        exercise.tracking.rawValue, exercise.notes, exercise.restSeconds,
                    ]
                )
                for (setIndex, set) in exercise.sets.enumerated() {
                    let target: String? = try set.target.flatMap { $0.isEmpty ? nil : try JSONCoding.encodeString($0) }
                    try db.run(
                        """
                        INSERT INTO workout_set (id, workout_id, workout_exercise_id, exercise_id, position, kind, weight, reps, duration, distance, rpe, is_completed, completed_at, target)
                        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                        """,
                        [
                            set.id, workout.id, exercise.id, exercise.exerciseID, setIndex, set.kind.rawValue,
                            set.weight, set.reps, set.duration, set.distance, set.rpe, set.isCompleted, set.completedAt, target,
                        ]
                    )
                }
            }
        }
    }

    // MARK: Loading

    public func workout(id: UUID) throws -> Workout? {
        try queue.read { db in
            try Self.load(where: "w.id = ?", arguments: [id], db: db).first
        }
    }

    /// The in-progress workout, if the app was closed during one.
    public func activeWorkout() throws -> Workout? {
        try queue.read { db in
            try Self.load(where: "w.status = 'active' AND w.deleted_at IS NULL", arguments: [], order: "w.started_at DESC", db: db).first
        }
    }

    /// Every workout still marked in progress, newest first. Normally there
    /// is at most one; more means an earlier one was never closed.
    public func activeWorkouts() throws -> [Workout] {
        try queue.read { db in
            try Self.load(where: "w.status = 'active' AND w.deleted_at IS NULL", arguments: [], order: "w.started_at DESC", db: db)
        }
    }

    public func allWorkouts(includeDeleted: Bool = true) throws -> [Workout] {
        try queue.read { db in
            try Self.load(where: includeDeleted ? "1 = 1" : "w.deleted_at IS NULL", arguments: [], db: db)
        }
    }

    public func completedWorkouts() throws -> [Workout] {
        try queue.read { db in
            try Self.load(where: "w.status = 'completed' AND w.deleted_at IS NULL", arguments: [], db: db)
        }
    }

    /// Loads workouts and their children with four queries total, however
    /// many workouts match.
    static func load(where clause: String, arguments: [DatabaseValueConvertible], order: String = "w.started_at", db: Connection) throws -> [Workout] {
        let headerRows = try db.query("SELECT w.* FROM workout w WHERE \(clause) ORDER BY \(order)", arguments)
        guard !headerRows.isEmpty else { return [] }
        let subquery = "SELECT w.id FROM workout w WHERE \(clause)"

        var setsByExercise: [UUID: [WorkoutSet]] = [:]
        for row in try db.query("SELECT * FROM workout_set WHERE workout_id IN (\(subquery)) ORDER BY workout_exercise_id, position", arguments) {
            guard let parent = row.uuid("workout_exercise_id") else { continue }
            setsByExercise[parent, default: []].append(set(from: row))
        }

        var exercisesByBlock: [UUID: [WorkoutExercise]] = [:]
        for row in try db.query("SELECT * FROM workout_exercise WHERE workout_id IN (\(subquery)) ORDER BY block_id, position", arguments) {
            guard let blockID = row.uuid("block_id"), let id = row.uuid("id") else { continue }
            exercisesByBlock[blockID, default: []].append(
                WorkoutExercise(
                    id: id,
                    exerciseID: row.string("exercise_id") ?? "",
                    name: row.string("exercise_name") ?? "Exercise",
                    tracking: TrackingType(storedValue: row.string("tracking")),
                    sets: setsByExercise[id] ?? [],
                    notes: row.string("notes") ?? "",
                    restSeconds: row.int("rest_seconds")
                )
            )
        }

        var blocksByWorkout: [UUID: [WorkoutBlock]] = [:]
        for row in try db.query("SELECT * FROM workout_block WHERE workout_id IN (\(subquery)) ORDER BY workout_id, position", arguments) {
            guard let workoutID = row.uuid("workout_id"), let id = row.uuid("id") else { continue }
            blocksByWorkout[workoutID, default: []].append(
                WorkoutBlock(
                    id: id,
                    exercises: exercisesByBlock[id] ?? [],
                    timer: row.string("timer").flatMap { try? JSONCoding.decode(TimerConfig.self, from: $0) },
                    result: row.string("result").flatMap { try? JSONCoding.decode(BlockResult.self, from: $0) },
                    notes: row.string("notes") ?? ""
                )
            )
        }

        return headerRows.compactMap { row -> Workout? in
            guard let id = row.uuid("id") else { return nil }
            let startedAt = row.date("started_at") ?? Date()
            return Workout(
                id: id,
                kind: WorkoutKind(storedValue: row.string("kind")),
                status: WorkoutStatus(storedValue: row.string("status")),
                routineID: row.uuid("routine_id"),
                name: row.string("name") ?? "Workout",
                notes: row.string("notes") ?? "",
                startedAt: startedAt,
                endedAt: row.date("ended_at"),
                duration: row.double("duration"),
                bodyweight: row.double("bodyweight"),
                rating: row.int("rating"),
                blocks: blocksByWorkout[id] ?? [],
                runtime: row.string("runtime").flatMap { try? JSONCoding.decode(WorkoutRuntimeState.self, from: $0) } ?? WorkoutRuntimeState(),
                createdAt: row.date("created_at") ?? startedAt,
                updatedAt: row.date("updated_at") ?? startedAt,
                deletedAt: row.date("deleted_at")
            )
        }
    }

    static func set(from row: Row) -> WorkoutSet {
        WorkoutSet(
            id: row.uuid("id") ?? UUID(),
            kind: SetKind(storedValue: row.string("kind")),
            weight: row.double("weight"),
            reps: row.int("reps"),
            duration: row.double("duration"),
            distance: row.double("distance"),
            rpe: row.double("rpe"),
            isCompleted: row.bool("is_completed"),
            completedAt: row.date("completed_at"),
            target: row.string("target").flatMap { try? JSONCoding.decode(SetTarget.self, from: $0) }
        )
    }

    // MARK: Summaries

    public func summaries(deleted: Bool = false) throws -> [WorkoutSummary] {
        try queue.read { db in
            let filter = deleted
                ? "w.status = 'completed' AND w.deleted_at IS NOT NULL"
                : "w.status = 'completed' AND w.deleted_at IS NULL"
            let headers = try db.query("SELECT w.* FROM workout w WHERE \(filter) ORDER BY w.started_at DESC")
            guard !headers.isEmpty else { return [] }
            let subquery = "SELECT w.id FROM workout w WHERE \(filter)"

            var names: [UUID: [String]] = [:]
            for row in try db.query(
                """
                SELECT e.workout_id, e.exercise_name FROM workout_exercise e
                JOIN workout_block b ON b.id = e.block_id
                WHERE e.workout_id IN (\(subquery))
                ORDER BY e.workout_id, b.position, e.position
                """
            ) {
                if let id = row.uuid("workout_id"), let name = row.string("exercise_name") {
                    names[id, default: []].append(name)
                }
            }

            struct Totals { var sets = 0; var volume = 0.0; var reps = 0; var distance = 0.0 }
            var totals: [UUID: Totals] = [:]
            for row in try db.query(
                """
                SELECT s.workout_id AS workout_id,
                       COUNT(*) AS set_count,
                       SUM(CASE WHEN e.tracking IN ('weight_reps', 'weighted_bodyweight') THEN COALESCE(s.weight, 0) * COALESCE(s.reps, 0) ELSE 0 END) AS volume,
                       SUM(CASE WHEN e.tracking IN ('weight_reps', 'reps', 'weighted_bodyweight', 'assisted_bodyweight') THEN COALESCE(s.reps, 0) ELSE 0 END) AS reps,
                       SUM(COALESCE(s.distance, 0)) AS distance
                FROM workout_set s
                JOIN workout_exercise e ON e.id = s.workout_exercise_id
                WHERE s.is_completed = 1 AND s.kind != 'warmup' AND s.workout_id IN (\(subquery))
                GROUP BY s.workout_id
                """
            ) {
                guard let id = row.uuid("workout_id") else { continue }
                totals[id] = Totals(
                    sets: row.int("set_count") ?? 0,
                    volume: row.double("volume") ?? 0,
                    reps: row.int("reps") ?? 0,
                    distance: row.double("distance") ?? 0
                )
            }

            var timers: [UUID: [String]] = [:]
            for row in try db.query(
                "SELECT workout_id, timer, result FROM workout_block WHERE timer IS NOT NULL AND workout_id IN (\(subquery)) ORDER BY workout_id, position"
            ) {
                guard let id = row.uuid("workout_id"),
                      let config = row.string("timer").flatMap({ try? JSONCoding.decode(TimerConfig.self, from: $0) }) else { continue }
                var text = config.summary
                if let result = row.string("result").flatMap({ try? JSONCoding.decode(BlockResult.self, from: $0) }) {
                    text += " · " + result.summary(for: config)
                }
                timers[id, default: []].append(text)
            }

            return headers.compactMap { row -> WorkoutSummary? in
                guard let id = row.uuid("id") else { return nil }
                let startedAt = row.date("started_at") ?? Date()
                let endedAt = row.date("ended_at")
                let duration = row.double("duration") ?? endedAt.map { $0.timeIntervalSince(startedAt) } ?? 0
                let total = totals[id] ?? Totals()
                let exerciseNames = names[id] ?? []
                return WorkoutSummary(
                    id: id,
                    kind: WorkoutKind(storedValue: row.string("kind")),
                    name: row.string("name") ?? "Workout",
                    notes: row.string("notes") ?? "",
                    routineID: row.uuid("routine_id"),
                    startedAt: startedAt,
                    endedAt: endedAt,
                    duration: max(0, duration),
                    rating: row.int("rating"),
                    exerciseNames: exerciseNames,
                    exerciseCount: exerciseNames.count,
                    setCount: total.sets,
                    volume: total.volume,
                    totalReps: total.reps,
                    totalDistance: total.distance,
                    timerSummaries: timers[id] ?? [],
                    deletedAt: row.date("deleted_at")
                )
            }
        }
    }

    // MARK: Analytics queries

    /// Every completed set from completed workouts, oldest first.
    public func setRecords() throws -> [SetRecord] {
        try queue.read { db in
            try db.query(
                """
                SELECT s.workout_id, w.started_at, s.exercise_id, e.tracking, s.kind, s.weight, s.reps, s.duration, s.distance
                FROM workout_set s
                JOIN workout w ON w.id = s.workout_id
                JOIN workout_exercise e ON e.id = s.workout_exercise_id
                WHERE w.status = 'completed' AND w.deleted_at IS NULL AND s.is_completed = 1
                ORDER BY w.started_at, e.position, s.position
                """
            ).compactMap { row -> SetRecord? in
                guard let workoutID = row.uuid("workout_id"), let date = row.date("started_at"), let exerciseID = row.string("exercise_id") else { return nil }
                return SetRecord(
                    workoutID: workoutID,
                    date: date,
                    exerciseID: exerciseID,
                    tracking: TrackingType(storedValue: row.string("tracking")),
                    kind: SetKind(storedValue: row.string("kind")),
                    weight: row.double("weight"),
                    reps: row.int("reps"),
                    duration: row.double("duration"),
                    distance: row.double("distance")
                )
            }
        }
    }

    /// Completed sets from the most recent completed workout containing each
    /// exercise, for the "previous" column while logging.
    public func lastPerformances(exerciseIDs: [String], excluding workoutID: UUID? = nil) throws -> [String: [WorkoutSet]] {
        try lastPerformanceDetails(exerciseIDs: exerciseIDs, excluding: workoutID).mapValues(\.sets)
    }

    /// The same, with how each exercise was tracked that time.
    public func lastPerformanceDetails(exerciseIDs: [String], excluding workoutID: UUID? = nil) throws -> [String: LastPerformance] {
        guard !exerciseIDs.isEmpty else { return [:] }
        return try queue.read { db in
            var result: [String: LastPerformance] = [:]
            for exerciseID in Set(exerciseIDs) {
                guard let entry = try db.queryOne(
                    """
                    SELECT e.id AS entry_id, e.tracking FROM workout_exercise e
                    JOIN workout w ON w.id = e.workout_id
                    JOIN workout_block b ON b.id = e.block_id
                    WHERE e.exercise_id = ? AND w.status = 'completed' AND w.deleted_at IS NULL AND w.id != ?
                      AND EXISTS (SELECT 1 FROM workout_set s WHERE s.workout_exercise_id = e.id AND s.is_completed = 1)
                    ORDER BY w.started_at DESC, b.position, e.position
                    LIMIT 1
                    """,
                    [exerciseID, workoutID?.uuidString ?? ""]
                ), let entryID = entry.uuid("entry_id") else { continue }
                let sets = try db.query(
                    "SELECT * FROM workout_set WHERE workout_exercise_id = ? AND is_completed = 1 ORDER BY position",
                    [entryID]
                ).map(Self.set(from:))
                result[exerciseID] = LastPerformance(tracking: TrackingType(storedValue: entry.string("tracking")), sets: sets)
            }
            return result
        }
    }

    /// Every session of one exercise, newest first.
    public func sessions(exerciseID: String) throws -> [ExerciseSession] {
        try queue.read { db in
            let entries = try db.query(
                """
                SELECT e.id AS entry_id, e.workout_id, e.tracking, e.notes, w.name AS workout_name, w.started_at
                FROM workout_exercise e
                JOIN workout w ON w.id = e.workout_id
                WHERE e.exercise_id = ? AND w.status = 'completed' AND w.deleted_at IS NULL
                ORDER BY w.started_at DESC
                """,
                [exerciseID]
            )
            var setsByEntry: [UUID: [WorkoutSet]] = [:]
            for row in try db.query(
                """
                SELECT s.* FROM workout_set s
                JOIN workout w ON w.id = s.workout_id
                WHERE s.exercise_id = ? AND s.is_completed = 1 AND w.status = 'completed' AND w.deleted_at IS NULL
                ORDER BY s.workout_exercise_id, s.position
                """,
                [exerciseID]
            ) {
                if let parent = row.uuid("workout_exercise_id") {
                    setsByEntry[parent, default: []].append(Self.set(from: row))
                }
            }
            return entries.compactMap { row -> ExerciseSession? in
                guard let entryID = row.uuid("entry_id"), let workoutID = row.uuid("workout_id") else { return nil }
                let sets = setsByEntry[entryID] ?? []
                guard !sets.isEmpty else { return nil }
                return ExerciseSession(
                    id: entryID,
                    workoutID: workoutID,
                    workoutName: row.string("workout_name") ?? "Workout",
                    date: row.date("started_at") ?? Date(),
                    tracking: TrackingType(storedValue: row.string("tracking")),
                    sets: sets,
                    notes: row.string("notes") ?? ""
                )
            }
        }
    }

    public func exerciseUsageCounts() throws -> [String: Int] {
        try queue.read { db in
            var counts: [String: Int] = [:]
            for row in try db.query(
                """
                SELECT e.exercise_id, COUNT(DISTINCT e.workout_id) AS uses FROM workout_exercise e
                JOIN workout w ON w.id = e.workout_id
                WHERE w.status = 'completed' AND w.deleted_at IS NULL
                GROUP BY e.exercise_id
                """
            ) {
                if let id = row.string("exercise_id") { counts[id] = row.int("uses") ?? 0 }
            }
            return counts
        }
    }

    /// Most recent completion date per exercise (for "recent" sorting).
    public func lastUsedDates() throws -> [String: Date] {
        try queue.read { db in
            var dates: [String: Date] = [:]
            for row in try db.query(
                """
                SELECT e.exercise_id, MAX(w.started_at) AS last FROM workout_exercise e
                JOIN workout w ON w.id = e.workout_id
                WHERE w.deleted_at IS NULL
                GROUP BY e.exercise_id
                """
            ) {
                if let id = row.string("exercise_id"), let date = row.date("last") { dates[id] = date }
            }
            return dates
        }
    }

    // MARK: Deletion

    public func softDelete(workoutID: UUID, at date: Date = Date()) throws {
        try queue.write { db in
            try db.run("UPDATE workout SET deleted_at = ?, updated_at = ? WHERE id = ?", [date, date, workoutID])
        }
    }

    public func restore(workoutID: UUID, now: Date = Date()) throws {
        try queue.write { db in
            try db.run("UPDATE workout SET deleted_at = NULL, updated_at = ? WHERE id = ?", [now, workoutID])
        }
    }

    /// Permanently removes a workout that is already in Recently Deleted, or
    /// an in-progress workout being discarded.
    public func purge(workoutID: UUID) throws {
        try queue.write { db in
            let deletable = try db.scalarInt(
                "SELECT COUNT(*) FROM workout WHERE id = ? AND (deleted_at IS NOT NULL OR status = 'active')",
                [workoutID]
            )
            guard deletable > 0 else { return }
            try db.run("DELETE FROM workout_set WHERE workout_id = ?", [workoutID])
            try db.run("DELETE FROM workout_exercise WHERE workout_id = ?", [workoutID])
            try db.run("DELETE FROM workout_block WHERE workout_id = ?", [workoutID])
            try db.run("DELETE FROM workout WHERE id = ?", [workoutID])
            try Tombstones.record(.workout, workoutID, db: db)
        }
    }

    @discardableResult
    public func purgeDeleted(before cutoff: Date) throws -> Int {
        let ids = try queue.read { db in
            try db.query("SELECT id FROM workout WHERE deleted_at IS NOT NULL AND deleted_at < ?", [cutoff]).compactMap { $0.uuid("id") }
        }
        for id in ids {
            try purge(workoutID: id)
        }
        return ids.count
    }

    public func completedCount() throws -> Int {
        try queue.read { db in
            try db.scalarInt("SELECT COUNT(*) FROM workout WHERE status = 'completed' AND deleted_at IS NULL")
        }
    }
}
