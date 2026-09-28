import Foundation

public struct Exercise: Identifiable, Hashable, Codable, Sendable {
    public var id: String
    public var name: String
    public var primaryMuscle: MuscleGroup
    public var secondaryMuscles: [MuscleGroup]
    public var equipment: Equipment
    public var category: ExerciseCategory
    public var tracking: TrackingType
    public var aliases: [String]
    public var instructions: String
    public var isCustom: Bool
    /// Custom exercises are archived rather than deleted so history that
    /// references them never loses its meaning.
    public var archivedAt: Date?
    public var createdAt: Date?
    public var updatedAt: Date?

    public init(
        id: String,
        name: String,
        primaryMuscle: MuscleGroup,
        secondaryMuscles: [MuscleGroup] = [],
        equipment: Equipment,
        category: ExerciseCategory = .strength,
        tracking: TrackingType = .weightReps,
        aliases: [String] = [],
        instructions: String = "",
        isCustom: Bool = false,
        archivedAt: Date? = nil,
        createdAt: Date? = nil,
        updatedAt: Date? = nil
    ) {
        self.id = id
        self.name = name
        self.primaryMuscle = primaryMuscle
        self.secondaryMuscles = secondaryMuscles
        self.equipment = equipment
        self.category = category
        self.tracking = tracking
        self.aliases = aliases
        self.instructions = instructions
        self.isCustom = isCustom
        self.archivedAt = archivedAt
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    public var isArchived: Bool { archivedAt != nil }

    public var allMuscles: [MuscleGroup] { [primaryMuscle] + secondaryMuscles }

    public static func newCustomID() -> String {
        "custom-" + UUID().uuidString.lowercased()
    }

    enum CodingKeys: String, CodingKey {
        case id, name, primaryMuscle, secondaryMuscles, equipment, category, tracking
        case aliases, instructions, isCustom, archivedAt, createdAt, updatedAt
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        name = c.value(.name, default: "Exercise")
        primaryMuscle = c.value(.primaryMuscle, default: .other)
        secondaryMuscles = c.value(.secondaryMuscles, default: [])
        equipment = c.value(.equipment, default: .other)
        category = c.value(.category, default: .strength)
        tracking = c.value(.tracking, default: .weightReps)
        aliases = c.value(.aliases, default: [])
        instructions = c.value(.instructions, default: "")
        isCustom = c.value(.isCustom, default: false)
        archivedAt = c.optionalValue(.archivedAt)
        createdAt = c.optionalValue(.createdAt)
        updatedAt = c.optionalValue(.updatedAt)
    }
}

/// Per-exercise user preferences that apply to built-in and custom
/// exercises alike.
public struct ExercisePreference: Hashable, Codable, Sendable {
    public var exerciseID: String
    public var isFavorite: Bool
    public var note: String
    public var restSeconds: Int?
    public var updatedAt: Date

    public init(exerciseID: String, isFavorite: Bool = false, note: String = "", restSeconds: Int? = nil, updatedAt: Date = Date()) {
        self.exerciseID = exerciseID
        self.isFavorite = isFavorite
        self.note = note
        self.restSeconds = restSeconds
        self.updatedAt = updatedAt
    }

    enum CodingKeys: String, CodingKey {
        case exerciseID, isFavorite, note, restSeconds, updatedAt
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        exerciseID = try c.decode(String.self, forKey: .exerciseID)
        isFavorite = c.value(.isFavorite, default: false)
        note = c.value(.note, default: "")
        restSeconds = c.optionalValue(.restSeconds)
        updatedAt = c.value(.updatedAt, default: Date())
    }

    public var isEmpty: Bool {
        !isFavorite && note.isEmpty && restSeconds == nil
    }
}
