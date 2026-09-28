import Foundation

/// Lightweight row for history lists and dashboards.
public struct WorkoutSummary: Identifiable, Hashable, Sendable {
    public var id: UUID
    public var kind: WorkoutKind
    public var name: String
    public var notes: String
    public var routineID: UUID?
    public var startedAt: Date
    public var endedAt: Date?
    public var duration: Double
    public var rating: Int?
    /// Exercise names in workout order.
    public var exerciseNames: [String]
    public var exerciseCount: Int
    /// Completed working sets.
    public var setCount: Int
    /// Kilograms.
    public var volume: Double
    public var totalReps: Int
    /// Meters.
    public var totalDistance: Double
    /// Timer description for timer sessions and timed blocks, e.g. "AMRAP 12:00 · 7 rounds".
    public var timerSummaries: [String]
    public var deletedAt: Date?

    public init(
        id: UUID,
        kind: WorkoutKind,
        name: String,
        notes: String = "",
        routineID: UUID? = nil,
        startedAt: Date,
        endedAt: Date? = nil,
        duration: Double,
        rating: Int? = nil,
        exerciseNames: [String] = [],
        exerciseCount: Int = 0,
        setCount: Int = 0,
        volume: Double = 0,
        totalReps: Int = 0,
        totalDistance: Double = 0,
        timerSummaries: [String] = [],
        deletedAt: Date? = nil
    ) {
        self.id = id
        self.kind = kind
        self.name = name
        self.notes = notes
        self.routineID = routineID
        self.startedAt = startedAt
        self.endedAt = endedAt
        self.duration = duration
        self.rating = rating
        self.exerciseNames = exerciseNames
        self.exerciseCount = exerciseCount
        self.setCount = setCount
        self.volume = volume
        self.totalReps = totalReps
        self.totalDistance = totalDistance
        self.timerSummaries = timerSummaries
        self.deletedAt = deletedAt
    }
}

/// One completed set with just enough context for analytics.
public struct SetRecord: Hashable, Sendable {
    public var workoutID: UUID
    public var date: Date
    public var exerciseID: String
    public var tracking: TrackingType
    public var kind: SetKind
    public var weight: Double?
    public var reps: Int?
    public var duration: Double?
    public var distance: Double?

    public init(workoutID: UUID, date: Date, exerciseID: String, tracking: TrackingType, kind: SetKind = .normal, weight: Double? = nil, reps: Int? = nil, duration: Double? = nil, distance: Double? = nil) {
        self.workoutID = workoutID
        self.date = date
        self.exerciseID = exerciseID
        self.tracking = tracking
        self.kind = kind
        self.weight = weight
        self.reps = reps
        self.duration = duration
        self.distance = distance
    }

    public var volume: Double {
        guard tracking.countsVolume, let weight, let reps else { return 0 }
        return weight * Double(reps)
    }
}

/// Everything done for one exercise in one workout.
public struct ExerciseSession: Identifiable, Hashable, Sendable {
    public var id: UUID
    public var workoutID: UUID
    public var workoutName: String
    public var date: Date
    public var tracking: TrackingType
    public var sets: [WorkoutSet]
    public var notes: String

    public init(id: UUID, workoutID: UUID, workoutName: String, date: Date, tracking: TrackingType, sets: [WorkoutSet], notes: String = "") {
        self.id = id
        self.workoutID = workoutID
        self.workoutName = workoutName
        self.date = date
        self.tracking = tracking
        self.sets = sets
        self.notes = notes
    }

    public var workingSets: [WorkoutSet] { sets.filter { $0.kind.isWorking } }

    public var volume: Double {
        guard tracking.countsVolume else { return 0 }
        return workingSets.reduce(0) { $0 + $1.volume }
    }

    public var maxWeight: Double? {
        workingSets.compactMap { $0.reps != nil || !tracking.usesReps ? $0.weight : nil }.max()
    }

    public var bestOneRepMax: Double? {
        guard tracking.countsVolume else { return nil }
        return workingSets.compactMap { set -> Double? in
            guard let weight = set.weight, let reps = set.reps else { return nil }
            return OneRepMax.estimate(weight: weight, reps: reps)
        }.max()
    }

    public var totalReps: Int {
        workingSets.reduce(0) { $0 + ($1.reps ?? 0) }
    }

    public var maxReps: Int? {
        workingSets.compactMap(\.reps).max()
    }

    public var totalDuration: Double {
        workingSets.reduce(0) { $0 + ($1.duration ?? 0) }
    }

    public var totalDistance: Double {
        workingSets.reduce(0) { $0 + ($1.distance ?? 0) }
    }
}
