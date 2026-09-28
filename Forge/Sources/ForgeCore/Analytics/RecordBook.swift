import Foundation

public enum RecordKind: String, CaseIterable, Hashable, Sendable {
    case heaviestWeight
    case bestOneRepMax
    case bestSetVolume
    case bestSessionVolume
    case mostReps
    case mostSessionReps
    case longestDuration
    case longestDistance
    case bestPace

    public var displayName: String {
        switch self {
        case .heaviestWeight: return "Heaviest Weight"
        case .bestOneRepMax: return "Best Est. 1RM"
        case .bestSetVolume: return "Best Set Volume"
        case .bestSessionVolume: return "Best Session Volume"
        case .mostReps: return "Most Reps"
        case .mostSessionReps: return "Most Reps in a Session"
        case .longestDuration: return "Longest Time"
        case .longestDistance: return "Longest Distance"
        case .bestPace: return "Best Pace"
        }
    }

    public var lowerIsBetter: Bool { self == .bestPace }

    public static func kinds(for tracking: TrackingType) -> [RecordKind] {
        switch tracking {
        case .weightReps: return [.heaviestWeight, .bestOneRepMax, .bestSetVolume, .bestSessionVolume, .mostReps]
        case .weightedBodyweight: return [.heaviestWeight, .bestSetVolume, .mostReps]
        case .assistedBodyweight: return [.mostReps, .mostSessionReps]
        case .reps: return [.mostReps, .mostSessionReps]
        case .duration: return [.longestDuration]
        case .weightDuration: return [.heaviestWeight, .longestDuration]
        case .distanceDuration: return [.longestDistance, .longestDuration, .bestPace]
        case .weightDistance: return [.heaviestWeight, .longestDistance]
        case .shortDistance: return [.longestDistance, .bestPace]
        }
    }
}

public struct PersonalRecord: Hashable, Sendable, Identifiable {
    public var exerciseID: String
    public var kind: RecordKind
    /// kg, kg·reps, reps, seconds, meters, or seconds per km for pace.
    public var value: Double
    public var date: Date
    public var workoutID: UUID
    /// The set behind the record, for context ("100 kg × 5").
    public var weight: Double?
    public var reps: Int?
    public var previousValue: Double?

    public var id: String { "\(exerciseID)|\(kind.rawValue)|\(workoutID.uuidString)" }

    public init(exerciseID: String, kind: RecordKind, value: Double, date: Date, workoutID: UUID, weight: Double? = nil, reps: Int? = nil, previousValue: Double? = nil) {
        self.exerciseID = exerciseID
        self.kind = kind
        self.value = value
        self.date = date
        self.workoutID = workoutID
        self.weight = weight
        self.reps = reps
        self.previousValue = previousValue
    }

    func beats(_ other: PersonalRecord) -> Bool {
        let epsilon = 1e-6
        return kind.lowerIsBetter ? value < other.value - epsilon : value > other.value + epsilon
    }
}

/// All-time bests per exercise, plus which workouts set new records.
/// A first-ever performance establishes a baseline but isn't a "PR".
public struct RecordBook: Sendable {
    public private(set) var best: [String: [RecordKind: PersonalRecord]] = [:]
    public private(set) var prsByWorkout: [UUID: [PersonalRecord]] = [:]

    public init() {}

    /// `records` may be in any order; they're processed chronologically.
    public init(records: [SetRecord]) {
        let working = records.filter { $0.kind.isWorking }
        var byWorkout: [UUID: [SetRecord]] = [:]
        var workoutDates: [UUID: Date] = [:]
        for record in working {
            byWorkout[record.workoutID, default: []].append(record)
            workoutDates[record.workoutID] = record.date
        }
        let ordered = workoutDates.sorted { lhs, rhs in
            lhs.value == rhs.value ? lhs.key.uuidString < rhs.key.uuidString : lhs.value < rhs.value
        }
        for (workoutID, _) in ordered {
            apply(workoutRecords: byWorkout[workoutID] ?? [])
        }
    }

    private mutating func apply(workoutRecords: [SetRecord]) {
        var byExercise: [String: [SetRecord]] = [:]
        for record in workoutRecords {
            byExercise[record.exerciseID, default: []].append(record)
        }
        for (exerciseID, sets) in byExercise {
            for candidate in Self.candidates(exerciseID: exerciseID, sets: sets) {
                if let existing = best[exerciseID]?[candidate.kind] {
                    if candidate.beats(existing) {
                        var pr = candidate
                        pr.previousValue = existing.value
                        prsByWorkout[candidate.workoutID, default: []].append(pr)
                        best[exerciseID, default: [:]][candidate.kind] = candidate
                    }
                } else {
                    best[exerciseID, default: [:]][candidate.kind] = candidate
                }
            }
        }
    }

    public func records(for exerciseID: String) -> [PersonalRecord] {
        guard let kinds = best[exerciseID] else { return [] }
        return RecordKind.allCases.compactMap { kinds[$0] }
    }

    public func prs(in workoutID: UUID) -> [PersonalRecord] {
        prsByWorkout[workoutID] ?? []
    }

    public func prCount(in workoutID: UUID) -> Int {
        prsByWorkout[workoutID]?.count ?? 0
    }

    /// The best values one exercise produced within one workout.
    static func candidates(exerciseID: String, sets: [SetRecord]) -> [PersonalRecord] {
        guard let first = sets.first else { return [] }
        let tracking = first.tracking
        let workoutID = first.workoutID
        let date = first.date
        var result: [PersonalRecord] = []

        func add(_ kind: RecordKind, _ value: Double, weight: Double? = nil, reps: Int? = nil) {
            guard value.isFinite, value > 0 else { return }
            result.append(PersonalRecord(exerciseID: exerciseID, kind: kind, value: value, date: date, workoutID: workoutID, weight: weight, reps: reps))
        }

        for kind in RecordKind.kinds(for: tracking) {
            switch kind {
            case .heaviestWeight:
                let eligible = sets.filter { $0.weight != nil && (!tracking.usesReps || ($0.reps ?? 0) >= 1) }
                if let top = eligible.max(by: { ($0.weight ?? 0) < ($1.weight ?? 0) }) {
                    add(kind, top.weight ?? 0, weight: top.weight, reps: top.reps)
                }
            case .bestOneRepMax:
                var bestSet: SetRecord?
                var bestValue = 0.0
                for set in sets {
                    guard let weight = set.weight, let reps = set.reps, let estimate = OneRepMax.estimate(weight: weight, reps: reps) else { continue }
                    if estimate > bestValue {
                        bestValue = estimate
                        bestSet = set
                    }
                }
                if let bestSet { add(kind, bestValue, weight: bestSet.weight, reps: bestSet.reps) }
            case .bestSetVolume:
                if let top = sets.max(by: { $0.volume < $1.volume }), top.volume > 0 {
                    add(kind, top.volume, weight: top.weight, reps: top.reps)
                }
            case .bestSessionVolume:
                add(kind, sets.reduce(0) { $0 + $1.volume })
            case .mostReps:
                if let top = sets.max(by: { ($0.reps ?? 0) < ($1.reps ?? 0) }), let reps = top.reps {
                    add(kind, Double(reps), weight: top.weight, reps: reps)
                }
            case .mostSessionReps:
                add(kind, Double(sets.reduce(0) { $0 + ($1.reps ?? 0) }))
            case .longestDuration:
                if let top = sets.compactMap(\.duration).max() { add(kind, top) }
            case .longestDistance:
                if let top = sets.compactMap(\.distance).max() { add(kind, top) }
            case .bestPace:
                let paces = sets.compactMap { set -> Double? in
                    guard let distance = set.distance, let duration = set.duration, distance >= 100, duration > 0 else { return nil }
                    return duration / (distance / 1000)
                }
                if let fastest = paces.min() { add(kind, fastest) }
            }
        }
        return result
    }
}

extension RecordBook {
    /// Records `workout` would set against this book. The book must not
    /// already include the workout (use it right before saving).
    public func newRecords(in workout: Workout) -> [PersonalRecord] {
        var byExercise: [String: [SetRecord]] = [:]
        for record in workout.setRecords where record.kind.isWorking {
            byExercise[record.exerciseID, default: []].append(record)
        }
        var result: [PersonalRecord] = []
        for exerciseID in byExercise.keys.sorted() {
            for candidate in Self.candidates(exerciseID: exerciseID, sets: byExercise[exerciseID] ?? []) {
                if let existing = best[exerciseID]?[candidate.kind], candidate.beats(existing) {
                    var record = candidate
                    record.previousValue = existing.value
                    result.append(record)
                }
            }
        }
        return result
    }
}

extension Workout {
    /// Completed sets as analytics records.
    public var setRecords: [SetRecord] {
        allExercises.flatMap { exercise in
            exercise.sets.filter(\.isCompleted).map { set in
                SetRecord(
                    workoutID: id,
                    date: startedAt,
                    exerciseID: exercise.exerciseID,
                    tracking: exercise.tracking,
                    kind: set.kind,
                    weight: set.weight,
                    reps: set.reps,
                    duration: set.duration,
                    distance: set.distance
                )
            }
        }
    }
}
