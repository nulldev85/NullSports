import Foundation

public final class MeasurementRepository: @unchecked Sendable {
    let queue: DatabaseQueue

    init(queue: DatabaseQueue) {
        self.queue = queue
    }

    public func all() throws -> [BodyMeasurement] {
        try queue.read { db in
            try db.query("SELECT * FROM measurement ORDER BY measured_at").map(Self.measurement(from:))
        }
    }

    static func measurement(from row: Row) -> BodyMeasurement {
        let measuredAt = row.date("measured_at") ?? Date()
        return BodyMeasurement(
            id: row.uuid("id") ?? UUID(),
            kind: MeasurementKind(storedValue: row.string("kind")),
            value: row.double("value") ?? 0,
            measuredAt: measuredAt,
            note: row.string("note") ?? "",
            createdAt: row.date("created_at") ?? measuredAt
        )
    }

    static func insert(_ measurement: BodyMeasurement, db: Connection) throws {
        try db.run(
            """
            INSERT INTO measurement (id, kind, value, measured_at, note, created_at) VALUES (?, ?, ?, ?, ?, ?)
            ON CONFLICT(id) DO UPDATE SET kind = excluded.kind, value = excluded.value, measured_at = excluded.measured_at, note = excluded.note
            """,
            [measurement.id, measurement.kind.rawValue, measurement.value, measurement.measuredAt, measurement.note, measurement.createdAt]
        )
    }

    public func save(_ measurement: BodyMeasurement) throws {
        try queue.write { db in
            try Self.insert(measurement, db: db)
        }
    }

    public func delete(id: UUID) throws {
        try queue.write { db in
            try db.run("DELETE FROM measurement WHERE id = ?", [id])
        }
    }

    /// Latest body weight on or before `date`, in kilograms.
    public func bodyweight(onOrBefore date: Date) throws -> Double? {
        try queue.read { db in
            try db.queryOne(
                "SELECT value FROM measurement WHERE kind = ? AND measured_at <= ? ORDER BY measured_at DESC LIMIT 1",
                [MeasurementKind.bodyWeight.rawValue, date]
            )?.double("value")
        }
    }
}

public final class TimerPresetRepository: @unchecked Sendable {
    let queue: DatabaseQueue

    init(queue: DatabaseQueue) {
        self.queue = queue
    }

    public func all() throws -> [TimerPreset] {
        try queue.read { db in
            try db.query("SELECT * FROM timer_preset ORDER BY sort_order, created_at").map(Self.preset(from:))
        }
    }

    static func preset(from row: Row) -> TimerPreset {
        TimerPreset(
            id: row.uuid("id") ?? UUID(),
            name: row.string("name") ?? "Timer",
            config: row.string("config").flatMap { try? JSONCoding.decode(TimerConfig.self, from: $0) } ?? TimerConfig.standard(.stopwatch),
            sortOrder: row.double("sort_order") ?? 0,
            createdAt: row.date("created_at") ?? Date(),
            updatedAt: row.date("updated_at") ?? Date()
        )
    }

    static func insert(_ preset: TimerPreset, db: Connection) throws {
        try db.run(
            """
            INSERT INTO timer_preset (id, name, config, sort_order, created_at, updated_at) VALUES (?, ?, ?, ?, ?, ?)
            ON CONFLICT(id) DO UPDATE SET name = excluded.name, config = excluded.config, sort_order = excluded.sort_order, updated_at = excluded.updated_at
            """,
            [preset.id, preset.name, try JSONCoding.encodeString(preset.config), preset.sortOrder, preset.createdAt, preset.updatedAt]
        )
    }

    public func save(_ preset: TimerPreset) throws {
        try queue.write { db in
            try Self.insert(preset, db: db)
        }
    }

    public func delete(id: UUID) throws {
        try queue.write { db in
            try db.run("DELETE FROM timer_preset WHERE id = ?", [id])
        }
    }
}
