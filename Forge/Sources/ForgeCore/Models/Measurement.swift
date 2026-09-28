import Foundation

public enum MeasurementKind: String, ResilientStringEnum, Identifiable, Hashable, Sendable {
    case bodyWeight = "body_weight"
    case bodyFat = "body_fat"
    case leanMass = "lean_mass"
    case neck
    case shoulders
    case chest
    case waist
    case hips
    case leftBicep = "left_bicep"
    case rightBicep = "right_bicep"
    case leftForearm = "left_forearm"
    case rightForearm = "right_forearm"
    case leftThigh = "left_thigh"
    case rightThigh = "right_thigh"
    case leftCalf = "left_calf"
    case rightCalf = "right_calf"
    case restingHeartRate = "resting_heart_rate"
    case sleep
    case calories

    public static var fallback: MeasurementKind { .bodyWeight }
    public var id: String { rawValue }

    public enum Dimension: Sendable {
        case mass, length, percent, beatsPerMinute, hours, kilocalories
    }

    public var dimension: Dimension {
        switch self {
        case .bodyWeight, .leanMass: return .mass
        case .bodyFat: return .percent
        case .restingHeartRate: return .beatsPerMinute
        case .sleep: return .hours
        case .calories: return .kilocalories
        default: return .length
        }
    }

    public var displayName: String {
        switch self {
        case .bodyWeight: return "Body Weight"
        case .bodyFat: return "Body Fat"
        case .leanMass: return "Lean Mass"
        case .neck: return "Neck"
        case .shoulders: return "Shoulders"
        case .chest: return "Chest"
        case .waist: return "Waist"
        case .hips: return "Hips"
        case .leftBicep: return "Left Bicep"
        case .rightBicep: return "Right Bicep"
        case .leftForearm: return "Left Forearm"
        case .rightForearm: return "Right Forearm"
        case .leftThigh: return "Left Thigh"
        case .rightThigh: return "Right Thigh"
        case .leftCalf: return "Left Calf"
        case .rightCalf: return "Right Calf"
        case .restingHeartRate: return "Resting Heart Rate"
        case .sleep: return "Sleep"
        case .calories: return "Calories"
        }
    }

    public var symbolName: String {
        switch dimension {
        case .mass: return "scalemass"
        case .percent: return "percent"
        case .length: return "ruler"
        case .beatsPerMinute: return "heart"
        case .hours: return "bed.double"
        case .kilocalories: return "fork.knife"
        }
    }

    /// Lower is generally better (for color-coding changes).
    public var lowerIsBetter: Bool? {
        switch self {
        case .bodyFat, .waist, .restingHeartRate: return true
        case .leanMass: return false
        default: return nil
        }
    }
}

/// Values are stored canonically: kilograms, centimeters, percent, bpm,
/// hours, kcal.
public struct BodyMeasurement: Identifiable, Hashable, Codable, Sendable {
    public var id: UUID
    public var kind: MeasurementKind
    public var value: Double
    public var measuredAt: Date
    public var note: String
    public var createdAt: Date

    public init(id: UUID = UUID(), kind: MeasurementKind, value: Double, measuredAt: Date = Date(), note: String = "", createdAt: Date = Date()) {
        self.id = id
        self.kind = kind
        self.value = value
        self.measuredAt = measuredAt
        self.note = note
        self.createdAt = createdAt
    }

    enum CodingKeys: String, CodingKey { case id, kind, value, measuredAt, note, createdAt }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        kind = c.value(.kind, default: .bodyWeight)
        value = c.value(.value, default: 0)
        measuredAt = c.value(.measuredAt, default: Date())
        note = c.value(.note, default: "")
        createdAt = c.value(.createdAt, default: measuredAt)
    }
}

public struct TimerPreset: Identifiable, Hashable, Codable, Sendable {
    public var id: UUID
    public var name: String
    public var config: TimerConfig
    public var sortOrder: Double
    public var createdAt: Date
    public var updatedAt: Date

    public init(id: UUID = UUID(), name: String, config: TimerConfig, sortOrder: Double = 0, createdAt: Date = Date(), updatedAt: Date = Date()) {
        self.id = id
        self.name = name
        self.config = config
        self.sortOrder = sortOrder
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    enum CodingKeys: String, CodingKey { case id, name, config, sortOrder, createdAt, updatedAt }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        name = c.value(.name, default: "Timer")
        config = c.value(.config, default: TimerConfig.standard(.stopwatch))
        sortOrder = c.value(.sortOrder, default: 0)
        createdAt = c.value(.createdAt, default: Date())
        updatedAt = c.value(.updatedAt, default: Date())
    }
}
