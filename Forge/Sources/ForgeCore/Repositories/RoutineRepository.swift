import Foundation

public final class RoutineRepository: @unchecked Sendable {
    let queue: DatabaseQueue

    init(queue: DatabaseQueue) {
        self.queue = queue
    }

    public enum FolderDeletion {
        /// Routines and subfolders move up to the folder's parent.
        case keepContents
        /// Routines go to Recently Deleted; subfolders are removed.
        case deleteContents
    }

    // MARK: Folders

    public func folders() throws -> [Folder] {
        try queue.read { db in
            try db.query("SELECT * FROM folder ORDER BY sort_order, name COLLATE NOCASE").map(Self.folder(from:))
        }
    }

    static func folder(from row: Row) -> Folder {
        Folder(
            id: row.uuid("id") ?? UUID(),
            parentID: row.uuid("parent_id"),
            name: row.string("name") ?? "Folder",
            colorTag: row.string("color"),
            sortOrder: row.double("sort_order") ?? 0,
            createdAt: row.date("created_at") ?? Date(),
            updatedAt: row.date("updated_at") ?? Date()
        )
    }

    static func insertFolder(_ folder: Folder, db: Connection) throws {
        try db.run(
            """
            INSERT INTO folder (id, parent_id, name, color, sort_order, created_at, updated_at)
            VALUES (?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(id) DO UPDATE SET
                parent_id = excluded.parent_id,
                name = excluded.name,
                color = excluded.color,
                sort_order = excluded.sort_order,
                updated_at = excluded.updated_at
            """,
            [folder.id, folder.parentID, folder.name, folder.colorTag, folder.sortOrder, folder.createdAt, folder.updatedAt]
        )
    }

    public func saveFolder(_ folder: Folder) throws {
        try queue.write { db in
            if let parent = folder.parentID {
                // Refuse to create a cycle (a folder inside its own subtree).
                var cursor: UUID? = parent
                var seen = Set<UUID>()
                while let current = cursor, !seen.contains(current) {
                    if current == folder.id {
                        throw DatabaseError(code: 19, message: "A folder can't be moved inside itself.")
                    }
                    seen.insert(current)
                    cursor = try db.queryOne("SELECT parent_id FROM folder WHERE id = ?", [current])?.uuid("parent_id")
                }
            }
            try Self.insertFolder(folder, db: db)
        }
    }

    public func deleteFolder(id: UUID, mode: FolderDeletion, now: Date = Date()) throws {
        try queue.write { db in
            guard let row = try db.queryOne("SELECT * FROM folder WHERE id = ?", [id]) else { return }
            let parent = row.uuid("parent_id")
            switch mode {
            case .keepContents:
                try db.run("UPDATE folder SET parent_id = ?, updated_at = ? WHERE parent_id = ?", [parent, now, id])
                try db.run("UPDATE routine SET folder_id = ?, updated_at = ? WHERE folder_id = ?", [parent, now, id])
                try db.run("DELETE FROM folder WHERE id = ?", [id])
            case .deleteContents:
                var toVisit = [id]
                var subtree: [UUID] = []
                while let next = toVisit.popLast() {
                    subtree.append(next)
                    for child in try db.query("SELECT id FROM folder WHERE parent_id = ?", [next]) {
                        if let childID = child.uuid("id") { toVisit.append(childID) }
                    }
                }
                for folderID in subtree {
                    try db.run(
                        "UPDATE routine SET deleted_at = ?, updated_at = ? WHERE folder_id = ? AND deleted_at IS NULL",
                        [now, now, folderID]
                    )
                    try db.run("DELETE FROM folder WHERE id = ?", [folderID])
                }
            }
        }
    }

    // MARK: Routines

    public func routines(includeDeleted: Bool = false) throws -> [Routine] {
        try queue.read { db in
            let sql = includeDeleted
                ? "SELECT * FROM routine ORDER BY sort_order, name COLLATE NOCASE"
                : "SELECT * FROM routine WHERE deleted_at IS NULL ORDER BY sort_order, name COLLATE NOCASE"
            return try db.query(sql).map(Self.routine(from:))
        }
    }

    public func deletedRoutines() throws -> [Routine] {
        try queue.read { db in
            try db.query("SELECT * FROM routine WHERE deleted_at IS NOT NULL ORDER BY deleted_at DESC").map(Self.routine(from:))
        }
    }

    public func routine(id: UUID) throws -> Routine? {
        try queue.read { db in
            try db.queryOne("SELECT * FROM routine WHERE id = ?", [id]).map(Self.routine(from:))
        }
    }

    static func routine(from row: Row) -> Routine {
        let body = row.string("body").flatMap { try? JSONCoding.decode(RoutineBody.self, from: $0) }
        return Routine(
            id: row.uuid("id") ?? UUID(),
            folderID: row.uuid("folder_id"),
            name: row.string("name") ?? "Routine",
            notes: row.string("notes") ?? "",
            colorTag: row.string("color"),
            sortOrder: row.double("sort_order") ?? 0,
            blocks: body?.blocks ?? [],
            createdAt: row.date("created_at") ?? Date(),
            updatedAt: row.date("updated_at") ?? Date(),
            lastPerformedAt: row.date("last_performed_at"),
            deletedAt: row.date("deleted_at")
        )
    }

    static func insertRoutine(_ routine: Routine, db: Connection) throws {
        let body = try JSONCoding.encodeString(RoutineBody(blocks: routine.blocks))
        try db.run(
            """
            INSERT INTO routine (id, folder_id, name, notes, color, sort_order, body, created_at, updated_at, last_performed_at, deleted_at)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(id) DO UPDATE SET
                folder_id = excluded.folder_id,
                name = excluded.name,
                notes = excluded.notes,
                color = excluded.color,
                sort_order = excluded.sort_order,
                body = excluded.body,
                updated_at = excluded.updated_at,
                last_performed_at = excluded.last_performed_at,
                deleted_at = excluded.deleted_at
            """,
            [
                routine.id, routine.folderID, routine.name, routine.notes, routine.colorTag, routine.sortOrder,
                body, routine.createdAt, routine.updatedAt, routine.lastPerformedAt, routine.deletedAt,
            ]
        )
    }

    public func save(_ routine: Routine) throws {
        try queue.write { db in
            try Self.insertRoutine(routine, db: db)
        }
    }

    public func setSortOrders(_ orders: [UUID: Double], now: Date = Date()) throws {
        try queue.write { db in
            for (id, order) in orders {
                try db.run("UPDATE routine SET sort_order = ? WHERE id = ?", [order, id])
                try db.run("UPDATE folder SET sort_order = ? WHERE id = ?", [order, id])
            }
        }
    }

    public func move(routineID: UUID, toFolder folderID: UUID?, now: Date = Date()) throws {
        try queue.write { db in
            try db.run("UPDATE routine SET folder_id = ?, updated_at = ? WHERE id = ?", [folderID, now, routineID])
        }
    }

    public func softDelete(routineID: UUID, at date: Date = Date()) throws {
        try queue.write { db in
            try db.run("UPDATE routine SET deleted_at = ?, updated_at = ? WHERE id = ?", [date, date, routineID])
        }
    }

    /// Restores a routine from Recently Deleted. If its folder no longer
    /// exists it returns to the top level.
    public func restore(routineID: UUID, now: Date = Date()) throws {
        try queue.write { db in
            try db.run(
                """
                UPDATE routine SET deleted_at = NULL, updated_at = ?,
                    folder_id = CASE WHEN folder_id IN (SELECT id FROM folder) THEN folder_id ELSE NULL END
                WHERE id = ?
                """,
                [now, routineID]
            )
        }
    }

    public func purge(routineID: UUID) throws {
        try queue.write { db in
            try db.run("DELETE FROM routine WHERE id = ? AND deleted_at IS NOT NULL", [routineID])
            if db.changes > 0 {
                try Tombstones.record(.routine, routineID, db: db)
            }
        }
    }

    @discardableResult
    public func purgeDeleted(before cutoff: Date) throws -> Int {
        try queue.write { db in
            let ids = try db.query("SELECT id FROM routine WHERE deleted_at IS NOT NULL AND deleted_at < ?", [cutoff]).compactMap { $0.uuid("id") }
            for id in ids {
                try db.run("DELETE FROM routine WHERE id = ?", [id])
                try Tombstones.record(.routine, id, db: db)
            }
            return ids.count
        }
    }
}
