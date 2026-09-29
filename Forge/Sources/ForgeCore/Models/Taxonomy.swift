import Foundation

public enum MuscleGroup: String, ResilientStringEnum, Identifiable, Hashable, Sendable {
    case chest
    case shoulders
    case triceps
    case biceps
    case forearms
    case lats
    case upperBack = "upper_back"
    case traps
    case lowerBack = "lower_back"
    case abdominals
    case obliques
    case quadriceps
    case hamstrings
    case glutes
    case adductors
    case abductors
    case calves
    case neck
    case fullBody = "full_body"
    case cardio
    case other

    public static var fallback: MuscleGroup { .other }
    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .chest: return "Chest"
        case .shoulders: return "Shoulders"
        case .triceps: return "Triceps"
        case .biceps: return "Biceps"
        case .forearms: return "Forearms"
        case .lats: return "Lats"
        case .upperBack: return "Upper Back"
        case .traps: return "Traps"
        case .lowerBack: return "Lower Back"
        case .abdominals: return "Abs"
        case .obliques: return "Obliques"
        case .quadriceps: return "Quads"
        case .hamstrings: return "Hamstrings"
        case .glutes: return "Glutes"
        case .adductors: return "Adductors"
        case .abductors: return "Abductors"
        case .calves: return "Calves"
        case .neck: return "Neck"
        case .fullBody: return "Full Body"
        case .cardio: return "Cardio"
        case .other: return "Other"
        }
    }

    /// Coarse grouping used for summaries and charts.
    public var region: BodyRegion {
        switch self {
        case .chest, .shoulders, .triceps: return .push
        case .biceps, .forearms, .lats, .upperBack, .traps: return .pull
        case .quadriceps, .hamstrings, .glutes, .adductors, .abductors, .calves: return .legs
        case .abdominals, .obliques, .lowerBack: return .core
        case .neck, .fullBody, .cardio, .other: return .other
        }
    }
}

public enum BodyRegion: String, CaseIterable, Sendable {
    case push, pull, legs, core, other

    public var displayName: String {
        switch self {
        case .push: return "Push"
        case .pull: return "Pull"
        case .legs: return "Legs"
        case .core: return "Core"
        case .other: return "Other"
        }
    }
}

public enum Equipment: String, ResilientStringEnum, Identifiable, Hashable, Sendable {
    case none
    case barbell
    case dumbbell
    case kettlebell
    case machine
    case cable
    case smithMachine = "smith_machine"
    case ezBar = "ez_bar"
    case trapBar = "trap_bar"
    case band
    case plate
    case medicineBall = "medicine_ball"
    case stabilityBall = "stability_ball"
    case suspension
    case landmine
    case sled
    case sandbag
    case rings
    case battleRope = "battle_rope"
    case jumpRope = "jump_rope"
    case cardioMachine = "cardio_machine"
    case foamRoller = "foam_roller"
    case other

    public static var fallback: Equipment { .other }
    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .none: return "Bodyweight"
        case .barbell: return "Barbell"
        case .dumbbell: return "Dumbbell"
        case .kettlebell: return "Kettlebell"
        case .machine: return "Machine"
        case .cable: return "Cable"
        case .smithMachine: return "Smith Machine"
        case .ezBar: return "EZ Bar"
        case .trapBar: return "Trap Bar"
        case .band: return "Band"
        case .plate: return "Plate"
        case .medicineBall: return "Medicine Ball"
        case .stabilityBall: return "Stability Ball"
        case .suspension: return "Suspension"
        case .landmine: return "Landmine"
        case .sled: return "Sled"
        case .sandbag: return "Sandbag"
        case .rings: return "Rings"
        case .battleRope: return "Battle Rope"
        case .jumpRope: return "Jump Rope"
        case .cardioMachine: return "Cardio Machine"
        case .foamRoller: return "Foam Roller"
        case .other: return "Other"
        }
    }
}

public enum ExerciseCategory: String, ResilientStringEnum, Identifiable, Hashable, Sendable {
    case strength
    case cardio
    case plyometric
    case olympic
    case strongman
    case calisthenics
    case mobility
    case sport

    public static var fallback: ExerciseCategory { .strength }
    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .strength: return "Strength"
        case .cardio: return "Cardio"
        case .plyometric: return "Plyometrics"
        case .olympic: return "Olympic"
        case .strongman: return "Strongman"
        case .calisthenics: return "Calisthenics"
        case .mobility: return "Mobility"
        case .sport: return "Sports"
        }
    }
}

/// Which numbers a set records for an exercise.
public enum TrackingType: String, ResilientStringEnum, Identifiable, Hashable, Sendable {
    case weightReps = "weight_reps"
    case reps = "reps"
    case weightedBodyweight = "weighted_bodyweight"
    case assistedBodyweight = "assisted_bodyweight"
    case duration = "duration"
    case weightDuration = "weight_duration"
    case distanceDuration = "distance_duration"
    case weightDistance = "weight_distance"
    case shortDistance = "short_distance"

    public static var fallback: TrackingType { .weightReps }
    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .weightReps: return "Weight & Reps"
        case .reps: return "Reps Only"
        case .weightedBodyweight: return "Bodyweight + Added Weight"
        case .assistedBodyweight: return "Assisted Bodyweight"
        case .duration: return "Time"
        case .weightDuration: return "Weight & Time"
        case .distanceDuration: return "Distance & Time"
        case .weightDistance: return "Weight & Distance"
        case .shortDistance: return "Short Distance & Time"
        }
    }

    public var explanation: String {
        switch self {
        case .weightReps: return "Bench press, curls, squats"
        case .reps: return "Push-ups, burpees, sit-ups"
        case .weightedBodyweight: return "Weighted pull-ups and dips (log the added weight)"
        case .assistedBodyweight: return "Assisted pull-ups (log the assistance)"
        case .duration: return "Planks, holds, stretches"
        case .weightDuration: return "Weighted planks, farmer's holds"
        case .distanceDuration: return "Running, rowing, cycling"
        case .weightDistance: return "Farmer's walks, sled pushes"
        case .shortDistance: return "Sprints, shuttles, handstand walks"
        }
    }

    public var fields: [SetField] {
        switch self {
        case .weightReps, .weightedBodyweight, .assistedBodyweight: return [.weight, .reps]
        case .reps: return [.reps]
        case .duration: return [.duration]
        case .weightDuration: return [.weight, .duration]
        case .distanceDuration, .shortDistance: return [.distance, .duration]
        case .weightDistance: return [.weight, .distance]
        }
    }

    public var usesWeight: Bool { fields.contains(.weight) }
    public var usesReps: Bool { fields.contains(.reps) }
    public var usesDuration: Bool { fields.contains(.duration) }
    public var usesDistance: Bool { fields.contains(.distance) }

    /// Whether weight × reps counts toward training volume.
    public var countsVolume: Bool {
        self == .weightReps || self == .weightedBodyweight
    }

    /// Distances for carries and sleds are short (meters/yards); runs and
    /// rides are long (km/miles).
    public var usesShortDistance: Bool { self == .weightDistance || self == .shortDistance }

    /// Time is the goal (a hold, a carry or an effort for a set time), so a
    /// workout counts each set down.
    public var isTimed: Bool { self == .duration || self == .weightDuration }

    /// The same exercise done for a set time instead ("Track by Time"):
    /// carries, reps and runs become efforts for time, keeping the weight
    /// where there is one.
    public var timedVariant: TrackingType {
        switch self {
        case .duration, .weightDuration: return self
        case .weightReps, .weightedBodyweight, .weightDistance: return .weightDuration
        case .reps, .assistedBodyweight, .distanceDuration, .shortDistance: return .duration
        }
    }
}

public enum SetField: String, CaseIterable, Sendable {
    case weight, reps, duration, distance
}

public enum SetKind: String, ResilientStringEnum, Identifiable, Hashable, Sendable {
    case normal
    case warmup
    case drop
    case failure

    public static var fallback: SetKind { .normal }
    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .normal: return "Working Set"
        case .warmup: return "Warm-up"
        case .drop: return "Drop Set"
        case .failure: return "Failure"
        }
    }

    public var shortLabel: String? {
        switch self {
        case .normal: return nil
        case .warmup: return "W"
        case .drop: return "D"
        case .failure: return "F"
        }
    }

    /// Warm-ups don't count toward volume, set totals, or records.
    public var isWorking: Bool { self != .warmup }
}
