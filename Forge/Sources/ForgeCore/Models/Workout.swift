import Foundation

public enum WorkoutKind: String, ResilientStringEnum, Hashable, Sendable {
    /// A logged session of exercises and sets (may contain timed blocks).
    case strength
    /// A standalone interval timer session from the Timers tab.
    case timer

    public static var fallback: WorkoutKind { .strength }
}

public enum WorkoutStatus: String, ResilientStringEnum, Hashable, Sendable {
    case active
    case completed

    public static var fallback: WorkoutStatus { .completed }
}

public struct WorkoutSet: Identifiable, Hashable, Codable, Sendable {
    public var id: UUID
    public var kind: SetKind
    /// Kilograms (added weight for weighted bodyweight, assistance for assisted).
    public var weight: Double?
    public var reps: Int?
    /// Seconds.
    public var duration: Double?
    /// Meters.
    public var distance: Double?
    public var rpe: Double?
    public var isCompleted: Bool
    public var completedAt: Date?
    /// What the routine prescribed, shown as placeholder text.
    public var target: SetTarget?

    public init(
        id: UUID = UUID(),
        kind: SetKind = .normal,
        weight: Double? = nil,
        reps: Int? = nil,
        duration: Double? = nil,
        distance: Double? = nil,
        rpe: Double? = nil,
        isCompleted: Bool = false,
        completedAt: Date? = nil,
        target: SetTarget? = nil
    ) {
        self.id = id
        self.kind = kind
        self.weight = weight
        self.reps = reps
        self.duration = duration
        self.distance = distance
        self.rpe = rpe
        self.isCompleted = isCompleted
        self.completedAt = completedAt
        self.target = target
    }

    enum CodingKeys: String, CodingKey {
        case id, kind, weight, reps, duration, distance, rpe, isCompleted, completedAt, target
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = c.value(.id, default: UUID())
        kind = c.value(.kind, default: .normal)
        weight = c.optionalValue(.weight)
        reps = c.optionalValue(.reps)
        duration = c.optionalValue(.duration)
        distance = c.optionalValue(.distance)
        rpe = c.optionalValue(.rpe)
        isCompleted = c.value(.isCompleted, default: false)
        completedAt = c.optionalValue(.completedAt)
        target = c.optionalValue(.target)
    }

    /// True when any measurement has been entered.
    public var hasValues: Bool {
        weight != nil || reps != nil || duration != nil || distance != nil
    }

    /// Fills empty fields from the target (used when a set is checked off
    /// without typing anything).
    public mutating func fillEmptyFields(from target: SetTarget?, tracking: TrackingType) {
        guard let target else { return }
        if tracking.usesWeight, weight == nil { weight = target.weight }
        if tracking.usesReps, reps == nil { reps = target.reps }
        if tracking.usesDuration, duration == nil { duration = target.duration }
        if tracking.usesDistance, distance == nil { distance = target.distance }
    }

    public var volume: Double {
        guard let weight, let reps else { return 0 }
        return weight * Double(reps)
    }
}

public struct WorkoutExercise: Identifiable, Hashable, Codable, Sendable {
    public var id: UUID
    public var exerciseID: String
    /// Name at the time of the workout, so history reads correctly even if
    /// the exercise is renamed or archived later.
    public var name: String
    public var tracking: TrackingType
    public var sets: [WorkoutSet]
    public var notes: String
    public var restSeconds: Int?

    public init(
        id: UUID = UUID(),
        exerciseID: String,
        name: String,
        tracking: TrackingType,
        sets: [WorkoutSet] = [],
        notes: String = "",
        restSeconds: Int? = nil
    ) {
        self.id = id
        self.exerciseID = exerciseID
        self.name = name
        self.tracking = tracking
        self.sets = sets
        self.notes = notes
        self.restSeconds = restSeconds
    }

    enum CodingKeys: String, CodingKey { case id, exerciseID, name, tracking, sets, notes, restSeconds }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = c.value(.id, default: UUID())
        exerciseID = c.value(.exerciseID, default: "")
        name = c.value(.name, default: "Exercise")
        tracking = c.value(.tracking, default: .weightReps)
        sets = c.value(.sets, default: [])
        notes = c.value(.notes, default: "")
        restSeconds = c.optionalValue(.restSeconds)
    }

    public var completedSets: [WorkoutSet] { sets.filter(\.isCompleted) }

    /// The time each set of a timed exercise is planned for, in order: the
    /// time entered in the set, else its target, else a time entered in an
    /// earlier set (so "3 sets of 2:00" is typed once), else last time's,
    /// else the set before's plan. Nil where nothing says, and the set's
    /// timer then counts up instead.
    public func plannedDurations(previous: [WorkoutSet]? = nil) -> [Double?] {
        var plans: [Double?] = []
        var carried: Double?
        for (index, set) in sets.enumerated() {
            // A finished set's plan is its target when it has one (a set
            // stopped early logs the time actually done).
            let given = set.isCompleted ? (set.target?.duration ?? set.duration) : set.duration
            let plan = given
                ?? set.target?.duration
                ?? carried
                ?? previous?[safe: index]?.duration
                ?? (plans.last ?? nil)
            plans.append(plan)
            if let given { carried = given }
        }
        return plans
    }

    /// How many sets have numbers entered that tracking this exercise
    /// another way would clear.
    public func setsLosingValues(switchingTo tracking: TrackingType) -> Int {
        sets.filter { set in
            (!tracking.usesWeight && set.weight != nil)
                || (!tracking.usesReps && set.reps != nil)
                || (!tracking.usesDuration && set.duration != nil)
                || (!tracking.usesDistance && set.distance != nil)
        }.count
    }

    /// Switches how the sets are tracked. Numbers the new way doesn't use
    /// are cleared, so nothing hidden is ever logged; targets stay, since
    /// only the ones the tracking uses are read.
    public mutating func retrack(_ newTracking: TrackingType) {
        tracking = newTracking
        for index in sets.indices {
            if !newTracking.usesWeight { sets[index].weight = nil }
            if !newTracking.usesReps { sets[index].reps = nil }
            if !newTracking.usesDuration { sets[index].duration = nil }
            if !newTracking.usesDistance { sets[index].distance = nil }
        }
    }
}

/// Outcome of a timed block or standalone timer.
public struct BlockResult: Hashable, Codable, Sendable {
    public var rounds: Int
    public var extraReps: Int
    /// Seconds of work (excludes the lead-in countdown).
    public var elapsed: Double
    /// For Time: finished before the cap. Others: ran to the end.
    public var finished: Bool
    /// Elapsed time at each round tap.
    public var roundSplits: [Double]

    public init(rounds: Int = 0, extraReps: Int = 0, elapsed: Double = 0, finished: Bool = true, roundSplits: [Double] = []) {
        self.rounds = rounds
        self.extraReps = extraReps
        self.elapsed = elapsed
        self.finished = finished
        self.roundSplits = roundSplits
    }

    enum CodingKeys: String, CodingKey { case rounds, extraReps, elapsed, finished, roundSplits }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        rounds = c.value(.rounds, default: 0)
        extraReps = c.value(.extraReps, default: 0)
        elapsed = c.value(.elapsed, default: 0)
        finished = c.value(.finished, default: true)
        roundSplits = c.value(.roundSplits, default: [])
    }

    /// e.g. "7 rounds + 12 reps", "12:34", "Capped at 15 rounds".
    public func summary(for config: TimerConfig) -> String {
        switch config.kind {
        case .amrap:
            return extraReps > 0 ? "\(rounds) rounds + \(extraReps) reps" : "\(rounds) rounds"
        case .forTime:
            if finished {
                return DurationFormat.clock(elapsed)
            }
            return extraReps > 0 ? "Time cap · \(rounds) rounds + \(extraReps) reps" : "Time cap · \(rounds) rounds"
        case .deathBy:
            return "\(rounds) rounds"
        case .emom, .tabata, .intervals, .custom:
            return "\(rounds) rounds · \(DurationFormat.clock(elapsed))"
        case .stopwatch, .countdown:
            return DurationFormat.clock(elapsed)
        }
    }
}

public struct WorkoutBlock: Identifiable, Hashable, Codable, Sendable {
    public var id: UUID
    public var exercises: [WorkoutExercise]
    public var timer: TimerConfig?
    public var result: BlockResult?
    public var notes: String

    public init(id: UUID = UUID(), exercises: [WorkoutExercise] = [], timer: TimerConfig? = nil, result: BlockResult? = nil, notes: String = "") {
        self.id = id
        self.exercises = exercises
        self.timer = timer
        self.result = result
        self.notes = notes
    }

    enum CodingKeys: String, CodingKey { case id, exercises, timer, result, notes }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = c.value(.id, default: UUID())
        exercises = c.value(.exercises, default: [])
        timer = c.optionalValue(.timer)
        result = c.optionalValue(.result)
        notes = c.value(.notes, default: "")
    }

    public var isTimed: Bool { timer != nil }
    public var isSuperset: Bool { timer == nil && exercises.count > 1 }
}

/// State that only matters while a workout is in progress, persisted so a
/// relaunch picks up exactly where the athlete left off.
public struct WorkoutRuntimeState: Hashable, Codable, Sendable {
    public var restTimer: RestTimerState?
    public var runningBlockID: UUID?
    public var runningTimer: TimerRun?
    /// The countdown of a timed set in progress.
    public var setTimer: SetTimerState?

    public init(restTimer: RestTimerState? = nil, runningBlockID: UUID? = nil, runningTimer: TimerRun? = nil, setTimer: SetTimerState? = nil) {
        self.restTimer = restTimer
        self.runningBlockID = runningBlockID
        self.runningTimer = runningTimer
        self.setTimer = setTimer
    }

    enum CodingKeys: String, CodingKey { case restTimer, runningBlockID, runningTimer, setTimer }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        restTimer = c.optionalValue(.restTimer)
        runningBlockID = c.optionalValue(.runningBlockID)
        runningTimer = c.optionalValue(.runningTimer)
        setTimer = c.optionalValue(.setTimer)
    }

    public var isEmpty: Bool { restTimer == nil && runningBlockID == nil && runningTimer == nil && setTimer == nil }
}

/// The countdown for one set of a timed exercise, or a stopwatch when no
/// time is planned. Kept with the workout, so it carries on if the app is
/// closed and reopened.
public struct SetTimerState: Hashable, Codable, Sendable {
    public var setID: UUID
    /// Seconds planned for the set; nil counts up instead.
    public var duration: Double?
    /// "Get ready" seconds before the set's own clock starts.
    public var leadIn: Double
    /// When it was last started or resumed; nil while paused.
    public var resumedAt: Date?
    /// Seconds already run (lead-in included) before the last pause.
    public var banked: Double

    public init(setID: UUID, duration: Double?, leadIn: Double = 0, startedAt: Date) {
        self.setID = setID
        self.duration = duration.map { max(1, $0) }
        self.leadIn = max(0, leadIn)
        self.resumedAt = startedAt
        self.banked = 0
    }

    enum CodingKeys: String, CodingKey { case setID, duration, leadIn, resumedAt, banked }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        setID = try c.decode(UUID.self, forKey: .setID)
        duration = c.optionalValue(.duration)
        leadIn = c.value(.leadIn, default: 0)
        resumedAt = c.optionalValue(.resumedAt)
        banked = c.value(.banked, default: 0)
    }

    public var isPaused: Bool { resumedAt == nil }

    /// Seconds since it started, lead-in included and pauses left out.
    public func total(at now: Date) -> Double {
        banked + (resumedAt.map { max(0, now.timeIntervalSince($0)) } ?? 0)
    }

    /// Seconds of the set itself, after the lead-in (never past the plan).
    public func elapsed(at now: Date) -> Double {
        let value = max(0, total(at: now) - leadIn)
        return duration.map { min($0, value) } ?? value
    }

    /// "Get ready" seconds left; 0 once the set is under way.
    public func leadInRemaining(at now: Date) -> Double {
        max(0, leadIn - total(at: now))
    }

    /// Seconds left of the planned time (nil when counting up).
    public func remaining(at now: Date) -> Double? {
        duration.map { max(0, $0 - elapsed(at: now)) }
    }

    /// Share of the planned time still to go: 1 at the start, 0 at the end.
    public func fractionRemaining(at now: Date) -> Double {
        guard let duration, duration > 0 else { return 1 }
        return min(1, max(0, 1 - elapsed(at: now) / duration))
    }

    public func isFinished(at now: Date) -> Bool {
        guard let duration else { return false }
        // A hair of slack, so a timer firing right on the end always counts.
        return total(at: now) >= leadIn + duration - 0.01
    }

    /// When the set's own clock starts, while the lead-in is running.
    public var workStartsAt: Date? {
        guard let resumedAt, banked < leadIn else { return nil }
        return resumedAt.addingTimeInterval(leadIn - banked)
    }

    /// When the countdown reaches zero, while it's running.
    public var endsAt: Date? {
        guard let resumedAt, let duration else { return nil }
        return resumedAt.addingTimeInterval(leadIn + duration - banked)
    }

    public mutating func pause(at now: Date) {
        guard resumedAt != nil else { return }
        banked = total(at: now)
        resumedAt = nil
    }

    public mutating func resume(at now: Date) {
        guard resumedAt == nil else { return }
        resumedAt = now
    }
}

public struct RestTimerState: Hashable, Codable, Sendable {
    public var startedAt: Date
    public var duration: Double
    public var exerciseName: String

    public init(startedAt: Date, duration: Double, exerciseName: String = "") {
        self.startedAt = startedAt
        self.duration = duration
        self.exerciseName = exerciseName
    }

    enum CodingKeys: String, CodingKey { case startedAt, duration, exerciseName }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        startedAt = c.value(.startedAt, default: Date())
        duration = c.value(.duration, default: 0)
        exerciseName = c.value(.exerciseName, default: "")
    }

    public var endsAt: Date { startedAt.addingTimeInterval(duration) }

    public func remaining(at now: Date) -> Double {
        max(0, endsAt.timeIntervalSince(now))
    }

    public func progress(at now: Date) -> Double {
        guard duration > 0 else { return 1 }
        return min(1, max(0, now.timeIntervalSince(startedAt) / duration))
    }

    public mutating func adjust(by seconds: Double, now: Date) {
        let remainingAfter = remaining(at: now) + seconds
        if remainingAfter <= 0 {
            duration = max(0, now.timeIntervalSince(startedAt))
        } else {
            duration = max(0, duration + seconds)
        }
    }
}

public struct Workout: Identifiable, Hashable, Codable, Sendable {
    public var id: UUID
    public var kind: WorkoutKind
    public var status: WorkoutStatus
    public var routineID: UUID?
    public var name: String
    public var notes: String
    public var startedAt: Date
    public var endedAt: Date?
    /// Stored elapsed seconds. For completed workouts this is authoritative
    /// (and editable); while active it is derived from the clock.
    public var duration: Double?
    /// Body weight in kg at the time, if known.
    public var bodyweight: Double?
    /// 1–5 "how did it feel".
    public var rating: Int?
    public var blocks: [WorkoutBlock]
    public var runtime: WorkoutRuntimeState
    public var createdAt: Date
    public var updatedAt: Date
    public var deletedAt: Date?

    public init(
        id: UUID = UUID(),
        kind: WorkoutKind = .strength,
        status: WorkoutStatus = .active,
        routineID: UUID? = nil,
        name: String,
        notes: String = "",
        startedAt: Date = Date(),
        endedAt: Date? = nil,
        duration: Double? = nil,
        bodyweight: Double? = nil,
        rating: Int? = nil,
        blocks: [WorkoutBlock] = [],
        runtime: WorkoutRuntimeState = WorkoutRuntimeState(),
        createdAt: Date = Date(),
        updatedAt: Date = Date(),
        deletedAt: Date? = nil
    ) {
        self.id = id
        self.kind = kind
        self.status = status
        self.routineID = routineID
        self.name = name
        self.notes = notes
        self.startedAt = startedAt
        self.endedAt = endedAt
        self.duration = duration
        self.bodyweight = bodyweight
        self.rating = rating
        self.blocks = blocks
        self.runtime = runtime
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.deletedAt = deletedAt
    }

    enum CodingKeys: String, CodingKey {
        case id, kind, status, routineID, name, notes, startedAt, endedAt, duration
        case bodyweight, rating, blocks, runtime, createdAt, updatedAt, deletedAt
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        kind = c.value(.kind, default: .strength)
        status = c.value(.status, default: .completed)
        routineID = c.optionalValue(.routineID)
        name = c.value(.name, default: "Workout")
        notes = c.value(.notes, default: "")
        startedAt = c.value(.startedAt, default: Date())
        endedAt = c.optionalValue(.endedAt)
        duration = c.optionalValue(.duration)
        bodyweight = c.optionalValue(.bodyweight)
        rating = c.optionalValue(.rating)
        blocks = c.value(.blocks, default: [])
        runtime = c.value(.runtime, default: WorkoutRuntimeState())
        createdAt = c.value(.createdAt, default: startedAt)
        updatedAt = c.value(.updatedAt, default: startedAt)
        deletedAt = c.optionalValue(.deletedAt)
    }

    public func elapsed(at now: Date = Date()) -> Double {
        if status == .completed, let duration { return duration }
        if let endedAt { return max(0, endedAt.timeIntervalSince(startedAt)) }
        return max(0, now.timeIntervalSince(startedAt))
    }

    public var allExercises: [WorkoutExercise] {
        blocks.flatMap(\.exercises)
    }

    public var completedWorkingSets: [WorkoutSet] {
        allExercises.flatMap { $0.sets.filter { $0.isCompleted && $0.kind.isWorking } }
    }

    public var volume: Double {
        allExercises.reduce(0) { total, exercise in
            guard exercise.tracking.countsVolume else { return total }
            return total + exercise.sets.reduce(0) { $0 + (($1.isCompleted && $1.kind.isWorking) ? $1.volume : 0) }
        }
    }

    public var totalReps: Int {
        allExercises.reduce(0) { total, exercise in
            guard exercise.tracking.usesReps else { return total }
            return total + exercise.sets.reduce(0) { $0 + (($1.isCompleted && $1.kind.isWorking) ? ($1.reps ?? 0) : 0) }
        }
    }

    public var hasCompletedSets: Bool {
        allExercises.contains { $0.sets.contains(where: \.isCompleted) } || blocks.contains { $0.result != nil }
    }

    public var incompleteSetCount: Int {
        allExercises.reduce(0) { $0 + $1.sets.filter { !$0.isCompleted }.count }
    }

    /// Unchecked sets (outside timed blocks) that have numbers typed in.
    public var enteredUncheckedSetCount: Int {
        blocks.filter { !$0.isTimed }.flatMap(\.exercises).reduce(0) { total, exercise in
            total + exercise.sets.filter { !$0.isCompleted && $0.hasValues }.count
        }
    }

    /// Unchecked sets (outside timed blocks) with nothing typed in.
    public var emptyUncheckedSetCount: Int {
        blocks.filter { !$0.isTimed }.flatMap(\.exercises).reduce(0) { total, exercise in
            total + exercise.sets.filter { !$0.isCompleted && !$0.hasValues }.count
        }
    }

    /// Whether the athlete put anything into this workout: a checked set,
    /// numbers typed into any set, a timed result, or notes. A workout with
    /// input is never deleted outright.
    public var hasUserInput: Bool {
        hasCompletedSets
            || allExercises.contains { exercise in exercise.sets.contains(where: \.hasValues) || !exercise.notes.isEmpty }
            || !notes.isEmpty
    }

    // MARK: ID-based editing
    //
    // Views edit by identifier, never by index, so an edit that races a
    // deletion can't land on the wrong set.

    public func location(ofSet setID: UUID) -> (block: Int, exercise: Int, set: Int)? {
        for (b, block) in blocks.enumerated() {
            for (e, exercise) in block.exercises.enumerated() {
                if let s = exercise.sets.firstIndex(where: { $0.id == setID }) {
                    return (b, e, s)
                }
            }
        }
        return nil
    }

    public func location(ofExercise exerciseEntryID: UUID) -> (block: Int, exercise: Int)? {
        for (b, block) in blocks.enumerated() {
            if let e = block.exercises.firstIndex(where: { $0.id == exerciseEntryID }) {
                return (b, e)
            }
        }
        return nil
    }

    public func set(_ setID: UUID) -> WorkoutSet? {
        guard let loc = location(ofSet: setID) else { return nil }
        return blocks[loc.block].exercises[loc.exercise].sets[loc.set]
    }

    public func exercise(_ entryID: UUID) -> WorkoutExercise? {
        guard let loc = location(ofExercise: entryID) else { return nil }
        return blocks[loc.block].exercises[loc.exercise]
    }

    public func block(_ blockID: UUID) -> WorkoutBlock? {
        blocks.first { $0.id == blockID }
    }

    public func blockID(containingExercise entryID: UUID) -> UUID? {
        guard let loc = location(ofExercise: entryID) else { return nil }
        return blocks[loc.block].id
    }

    @discardableResult
    public mutating func updateSet(_ setID: UUID, _ change: (inout WorkoutSet) -> Void) -> Bool {
        guard let loc = location(ofSet: setID) else { return false }
        change(&blocks[loc.block].exercises[loc.exercise].sets[loc.set])
        return true
    }

    @discardableResult
    public mutating func updateExercise(_ entryID: UUID, _ change: (inout WorkoutExercise) -> Void) -> Bool {
        guard let loc = location(ofExercise: entryID) else { return false }
        change(&blocks[loc.block].exercises[loc.exercise])
        return true
    }

    @discardableResult
    public mutating func updateBlock(_ blockID: UUID, _ change: (inout WorkoutBlock) -> Void) -> Bool {
        guard let index = blocks.firstIndex(where: { $0.id == blockID }) else { return false }
        change(&blocks[index])
        return true
    }

    public mutating func removeSet(_ setID: UUID) {
        guard let loc = location(ofSet: setID) else { return }
        blocks[loc.block].exercises[loc.exercise].sets.remove(at: loc.set)
    }

    /// Removes an exercise; drops its block if that leaves the block empty.
    public mutating func removeExercise(_ entryID: UUID) {
        guard let loc = location(ofExercise: entryID) else { return }
        blocks[loc.block].exercises.remove(at: loc.exercise)
        if blocks[loc.block].exercises.isEmpty {
            blocks.remove(at: loc.block)
        }
    }

    /// Adds a set to an exercise, copying the previous set's values and kind
    /// (but not completion) the way lifters expect.
    @discardableResult
    public mutating func addSet(to entryID: UUID) -> UUID? {
        guard let loc = location(ofExercise: entryID) else { return nil }
        var exercise = blocks[loc.block].exercises[loc.exercise]
        var newSet = WorkoutSet()
        if let last = exercise.sets.last {
            newSet.kind = last.kind == .warmup ? .normal : last.kind
            if last.kind == .warmup {
                newSet.target = last.target
            } else {
                newSet.weight = last.weight
                newSet.reps = last.reps
                newSet.duration = last.duration
                newSet.distance = last.distance
                newSet.target = last.target
            }
        }
        exercise.sets.append(newSet)
        blocks[loc.block].exercises[loc.exercise] = exercise
        return newSet.id
    }

    /// Moves an exercise's block (or the exercise within a superset) up/down.
    public mutating func moveBlock(_ blockID: UUID, by offset: Int) {
        guard let index = blocks.firstIndex(where: { $0.id == blockID }) else { return }
        let target = index + offset
        guard target >= 0, target < blocks.count else { return }
        let block = blocks.remove(at: index)
        blocks.insert(block, at: target)
    }

    /// Merges the block after `blockID` into it, forming a superset.
    public mutating func mergeWithNext(_ blockID: UUID) {
        guard let index = blocks.firstIndex(where: { $0.id == blockID }), index + 1 < blocks.count else { return }
        guard !blocks[index].isTimed, !blocks[index + 1].isTimed else { return }
        let next = blocks.remove(at: index + 1)
        blocks[index].exercises.append(contentsOf: next.exercises)
    }

    /// Splits a superset back into straight-set blocks.
    public mutating func splitBlock(_ blockID: UUID) {
        guard let index = blocks.firstIndex(where: { $0.id == blockID }), blocks[index].exercises.count > 1, !blocks[index].isTimed else { return }
        let block = blocks.remove(at: index)
        let singles = block.exercises.enumerated().map { offset, exercise in
            WorkoutBlock(id: offset == 0 ? block.id : UUID(), exercises: [exercise], notes: offset == 0 ? block.notes : "")
        }
        blocks.insert(contentsOf: singles, at: index)
    }
}

extension Workout {
    /// "Morning Workout", "Evening Workout", …
    public static func defaultName(for date: Date, calendar: Calendar = .current) -> String {
        let hour = calendar.component(.hour, from: date)
        switch hour {
        case 5..<12: return "Morning Workout"
        case 12..<17: return "Afternoon Workout"
        case 17..<22: return "Evening Workout"
        default: return "Night Workout"
        }
    }
}
