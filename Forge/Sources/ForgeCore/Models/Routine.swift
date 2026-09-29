import Foundation

/// What the athlete is aiming for on a set. Every field is optional; the
/// exercise's tracking type decides which ones are shown.
public struct SetTarget: Hashable, Codable, Sendable {
    public var reps: Int?
    /// Upper bound for a rep range such as 8–12.
    public var repsMax: Int?
    /// Kilograms.
    public var weight: Double?
    /// Seconds.
    public var duration: Double?
    /// Meters.
    public var distance: Double?
    public var rpe: Double?

    public init(reps: Int? = nil, repsMax: Int? = nil, weight: Double? = nil, duration: Double? = nil, distance: Double? = nil, rpe: Double? = nil) {
        self.reps = reps
        self.repsMax = repsMax
        self.weight = weight
        self.duration = duration
        self.distance = distance
        self.rpe = rpe
    }

    enum CodingKeys: String, CodingKey { case reps, repsMax, weight, duration, distance, rpe }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        reps = c.optionalValue(.reps)
        repsMax = c.optionalValue(.repsMax)
        weight = c.optionalValue(.weight)
        duration = c.optionalValue(.duration)
        distance = c.optionalValue(.distance)
        rpe = c.optionalValue(.rpe)
    }

    public var isEmpty: Bool {
        reps == nil && repsMax == nil && weight == nil && duration == nil && distance == nil && rpe == nil
    }

    /// "8", "8–12", or nil.
    public var repsText: String? {
        guard let reps else { return nil }
        if let repsMax, repsMax > reps {
            return "\(reps)–\(repsMax)"
        }
        return "\(reps)"
    }
}

public struct RoutineSet: Identifiable, Hashable, Codable, Sendable {
    public var id: UUID
    public var kind: SetKind
    public var target: SetTarget

    public init(id: UUID = UUID(), kind: SetKind = .normal, target: SetTarget = SetTarget()) {
        self.id = id
        self.kind = kind
        self.target = target
    }

    enum CodingKeys: String, CodingKey { case id, kind, target }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = c.value(.id, default: UUID())
        kind = c.value(.kind, default: .normal)
        target = c.value(.target, default: SetTarget())
    }
}

public struct RoutineExercise: Identifiable, Hashable, Codable, Sendable {
    public var id: UUID
    public var exerciseID: String
    public var sets: [RoutineSet]
    /// Rest after each set; nil means "use the default".
    public var restSeconds: Int?
    public var notes: String

    public init(id: UUID = UUID(), exerciseID: String, sets: [RoutineSet] = [], restSeconds: Int? = nil, notes: String = "") {
        self.id = id
        self.exerciseID = exerciseID
        self.sets = sets
        self.restSeconds = restSeconds
        self.notes = notes
    }

    enum CodingKeys: String, CodingKey { case id, exerciseID, sets, restSeconds, notes }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = c.value(.id, default: UUID())
        exerciseID = c.value(.exerciseID, default: "")
        sets = c.value(.sets, default: [])
        restSeconds = c.optionalValue(.restSeconds)
        notes = c.value(.notes, default: "")
    }
}

/// A group of exercises. With no timer it's straight sets (one exercise) or
/// a superset/circuit (several). With a timer it's a timed piece such as an
/// AMRAP or EMOM, where each exercise's first set is its per-round target.
public struct RoutineBlock: Identifiable, Hashable, Codable, Sendable {
    public var id: UUID
    public var exercises: [RoutineExercise]
    public var timer: TimerConfig?
    public var notes: String

    public init(id: UUID = UUID(), exercises: [RoutineExercise] = [], timer: TimerConfig? = nil, notes: String = "") {
        self.id = id
        self.exercises = exercises
        self.timer = timer
        self.notes = notes
    }

    enum CodingKeys: String, CodingKey { case id, exercises, timer, notes }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = c.value(.id, default: UUID())
        exercises = c.value(.exercises, default: [])
        timer = c.optionalValue(.timer)
        notes = c.value(.notes, default: "")
    }

    public var isTimed: Bool { timer != nil }
    public var isSuperset: Bool { timer == nil && exercises.count > 1 }
}

public struct Folder: Identifiable, Hashable, Codable, Sendable {
    public var id: UUID
    public var parentID: UUID?
    public var name: String
    public var colorTag: String?
    public var sortOrder: Double
    public var createdAt: Date
    public var updatedAt: Date

    public init(id: UUID = UUID(), parentID: UUID? = nil, name: String, colorTag: String? = nil, sortOrder: Double = 0, createdAt: Date = Date(), updatedAt: Date = Date()) {
        self.id = id
        self.parentID = parentID
        self.name = name
        self.colorTag = colorTag
        self.sortOrder = sortOrder
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    enum CodingKeys: String, CodingKey { case id, parentID, name, colorTag, sortOrder, createdAt, updatedAt }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        parentID = c.optionalValue(.parentID)
        name = c.value(.name, default: "Folder")
        colorTag = c.optionalValue(.colorTag)
        sortOrder = c.value(.sortOrder, default: 0)
        createdAt = c.value(.createdAt, default: Date())
        updatedAt = c.value(.updatedAt, default: Date())
    }
}

public struct Routine: Identifiable, Hashable, Codable, Sendable {
    public var id: UUID
    public var folderID: UUID?
    public var name: String
    public var notes: String
    public var colorTag: String?
    public var sortOrder: Double
    public var blocks: [RoutineBlock]
    public var createdAt: Date
    public var updatedAt: Date
    /// No longer kept up to date: when a routine was last done comes from
    /// History (`HistoryDigest.lastDone(routineID:)`), so it follows deleted
    /// and restored workouts. Kept so older backups still read.
    public var lastPerformedAt: Date?
    public var deletedAt: Date?

    public init(
        id: UUID = UUID(),
        folderID: UUID? = nil,
        name: String,
        notes: String = "",
        colorTag: String? = nil,
        sortOrder: Double = 0,
        blocks: [RoutineBlock] = [],
        createdAt: Date = Date(),
        updatedAt: Date = Date(),
        lastPerformedAt: Date? = nil,
        deletedAt: Date? = nil
    ) {
        self.id = id
        self.folderID = folderID
        self.name = name
        self.notes = notes
        self.colorTag = colorTag
        self.sortOrder = sortOrder
        self.blocks = blocks
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.lastPerformedAt = lastPerformedAt
        self.deletedAt = deletedAt
    }

    enum CodingKeys: String, CodingKey {
        case id, folderID, name, notes, colorTag, sortOrder, blocks, createdAt, updatedAt, lastPerformedAt, deletedAt
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        folderID = c.optionalValue(.folderID)
        name = c.value(.name, default: "Routine")
        notes = c.value(.notes, default: "")
        colorTag = c.optionalValue(.colorTag)
        sortOrder = c.value(.sortOrder, default: 0)
        blocks = c.value(.blocks, default: [])
        createdAt = c.value(.createdAt, default: Date())
        updatedAt = c.value(.updatedAt, default: Date())
        lastPerformedAt = c.optionalValue(.lastPerformedAt)
        deletedAt = c.optionalValue(.deletedAt)
    }

    public var exerciseCount: Int {
        blocks.reduce(0) { $0 + $1.exercises.count }
    }

    /// Working sets; warm-ups aren't counted, matching workout totals.
    public var setCount: Int {
        blocks.reduce(0) { total, block in
            guard !block.isTimed else { return total }
            return total + block.exercises.reduce(0) { $0 + $1.sets.filter { $0.kind.isWorking }.count }
        }
    }

    public var allExerciseIDs: [String] {
        blocks.flatMap { $0.exercises.map(\.exerciseID) }
    }

    /// Returns a deep copy with fresh identifiers (for duplicating).
    public func duplicated(name newName: String? = nil, now: Date = Date()) -> Routine {
        var copy = self
        copy.id = UUID()
        copy.name = newName ?? name
        copy.createdAt = now
        copy.updatedAt = now
        copy.lastPerformedAt = nil
        copy.deletedAt = nil
        copy.blocks = blocks.map { block in
            var b = block
            b.id = UUID()
            b.exercises = block.exercises.map { exercise in
                var e = exercise
                e.id = UUID()
                e.sets = exercise.sets.map { set in
                    var s = set
                    s.id = UUID()
                    return s
                }
                return e
            }
            return b
        }
        return copy
    }
}

/// The JSON document stored in a routine row alongside its columns.
struct RoutineBody: Codable {
    var blocks: [RoutineBlock]

    init(blocks: [RoutineBlock]) {
        self.blocks = blocks
    }

    enum CodingKeys: String, CodingKey { case blocks }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        blocks = c.value(.blocks, default: [])
    }
}
