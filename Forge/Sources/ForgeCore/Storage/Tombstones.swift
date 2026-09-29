import Foundation

/// What the athlete deleted for good: workouts and routines emptied from
/// Recently Deleted (by hand or after 30 days), deleted measurements, timer
/// presets and custom exercises. Older backups still hold these, so
/// recovery checks here and never offers them back as "missing".
public enum Tombstones {
    public enum Kind: String, Sendable, CaseIterable {
        case workout
        case routine
        case measurement
        case timerPreset = "timer_preset"
        case customExercise = "custom_exercise"
    }

    static func record(_ kind: Kind, _ id: String, db: Connection, now: Date = Date()) throws {
        try db.run(
            "INSERT OR REPLACE INTO tombstone (kind, id, deleted_at) VALUES (?, ?, ?)",
            [kind.rawValue, id, now]
        )
    }

    static func record(_ kind: Kind, _ id: UUID, db: Connection, now: Date = Date()) throws {
        try record(kind, id.uuidString, db: db, now: now)
    }

    /// An item saved again (an undone delete, a restore) is no longer gone.
    static func clear(_ kind: Kind, _ id: String, db: Connection) {
        try? db.run("DELETE FROM tombstone WHERE kind = ? AND id = ?", [kind.rawValue, id])
    }

    /// IDs by kind; empty for a file from before tombstones existed.
    static func all(db: Connection) -> [Kind: Set<String>] {
        guard let rows = try? db.query("SELECT kind, id FROM tombstone") else { return [:] }
        var result: [Kind: Set<String>] = [:]
        for row in rows {
            guard let kind = row.string("kind").flatMap(Kind.init(rawValue:)), let id = row.string("id") else { continue }
            result[kind, default: []].insert(id)
        }
        return result
    }
}

extension AppDatabase {
    /// Forgets deletions older than `cutoff` (by then no backup is likely
    /// to still hold the item).
    public func forgetTombstones(before cutoff: Date) {
        _ = try? queue.write { db in
            try db.run("DELETE FROM tombstone WHERE deleted_at < ?", [cutoff])
        }
    }

    public func tombstones() -> [Tombstones.Kind: Set<String>] {
        (try? queue.read { Tombstones.all(db: $0) }) ?? [:]
    }
}
