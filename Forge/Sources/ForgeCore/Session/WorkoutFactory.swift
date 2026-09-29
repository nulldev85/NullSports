import Foundation

/// Turns routines into workouts, timed-block results into logged sets, and
/// workouts back into routines.
public enum WorkoutFactory {
    public static func emptyWorkout(now: Date = Date(), calendar: Calendar = .current) -> Workout {
        Workout(name: Workout.defaultName(for: now, calendar: calendar), startedAt: now, createdAt: now, updatedAt: now)
    }

    public static func workout(
        from routine: Routine,
        lookup: (String) -> Exercise?,
        now: Date = Date()
    ) -> Workout {
        let blocks = routine.blocks.map { block -> WorkoutBlock in
            let exercises = block.exercises.map { entry -> WorkoutExercise in
                let exercise = lookup(entry.exerciseID)
                let tracking = exercise?.tracking ?? .weightReps
                let sets: [WorkoutSet]
                if block.isTimed {
                    // One template set holds the per-round target until the
                    // timer runs and real sets are generated.
                    sets = [WorkoutSet(kind: .normal, target: entry.sets.first?.target ?? SetTarget())]
                } else {
                    sets = entry.sets.map { WorkoutSet(kind: $0.kind, target: $0.target.isEmpty ? nil : $0.target) }
                }
                return WorkoutExercise(
                    exerciseID: entry.exerciseID,
                    name: exercise?.name ?? "Unknown Exercise",
                    tracking: tracking,
                    sets: sets.isEmpty ? [WorkoutSet()] : sets,
                    notes: entry.notes,
                    restSeconds: entry.restSeconds
                )
            }
            return WorkoutBlock(exercises: exercises, timer: block.timer, notes: block.notes)
        }
        return Workout(
            kind: .strength,
            status: .active,
            routineID: routine.id,
            name: routine.name,
            startedAt: now,
            blocks: blocks.filter { !$0.exercises.isEmpty || $0.isTimed },
            createdAt: now,
            updatedAt: now
        )
    }

    /// A new exercise entry for an in-progress workout: as many sets as last
    /// time (warm-ups included), otherwise one.
    public static func entry(for exercise: Exercise, lastPerformance: [WorkoutSet]?, restSeconds: Int? = nil) -> WorkoutExercise {
        let previous = lastPerformance ?? []
        let sets: [WorkoutSet] = previous.isEmpty
            ? [WorkoutSet()]
            : previous.map { WorkoutSet(kind: $0.kind) }
        return WorkoutExercise(
            exerciseID: exercise.id,
            name: exercise.name,
            tracking: exercise.tracking,
            sets: sets,
            restSeconds: restSeconds
        )
    }

    public static func timerWorkout(config: TimerConfig, result: BlockResult, name: String, startedAt: Date, endedAt: Date, notes: String = "") -> Workout {
        let block = WorkoutBlock(exercises: [], timer: config, result: result)
        return Workout(
            kind: .timer,
            status: .completed,
            name: name,
            notes: notes,
            startedAt: startedAt,
            endedAt: endedAt,
            duration: result.elapsed,
            blocks: [block],
            createdAt: endedAt,
            updatedAt: endedAt
        )
    }

    // MARK: Timed blocks

    /// Replaces a timed block's template sets with completed sets that
    /// reflect what the athlete did, so timed work shows up in exercise
    /// history, volume and records.
    public static func applyResult(_ result: BlockResult, to block: WorkoutBlock, program: TimerProgram, now: Date = Date()) -> WorkoutBlock {
        guard let config = block.timer else { return block }
        var updated = block
        updated.result = result
        let movements = block.exercises
        guard !movements.isEmpty else { return updated }
        let templates = movements.map { $0.sets.first?.target ?? SetTarget() }

        func completedSet(from target: SetTarget, tracking: TrackingType, reps overrideReps: Int? = nil) -> WorkoutSet {
            WorkoutSet(
                kind: .normal,
                weight: tracking.usesWeight ? target.weight : nil,
                reps: tracking.usesReps ? (overrideReps ?? target.reps) : nil,
                duration: tracking.usesDuration ? target.duration : nil,
                distance: tracking.usesDistance ? target.distance : nil,
                isCompleted: true,
                completedAt: now,
                target: target.isEmpty ? nil : target
            )
        }

        var newSets: [[WorkoutSet]] = Array(repeating: [], count: movements.count)

        switch config.kind {
        case .amrap, .forTime, .stopwatch, .countdown:
            var fullRounds = result.rounds
            if config.kind == .forTime, result.finished {
                fullRounds = max(config.rounds, result.rounds, 1)
            }
            for _ in 0..<max(0, fullRounds) {
                for (index, movement) in movements.enumerated() {
                    newSets[index].append(completedSet(from: templates[index], tracking: movement.tracking))
                }
            }
            // Spread partial-round reps across rep-based movements in order.
            var remaining = result.extraReps
            if remaining > 0 {
                for (index, movement) in movements.enumerated() where remaining > 0 && movement.tracking.usesReps {
                    let full = templates[index].reps ?? remaining
                    let done = min(full, remaining)
                    if done > 0 {
                        newSets[index].append(completedSet(from: templates[index], tracking: movement.tracking, reps: done))
                    }
                    remaining -= done
                }
            }
        case .deathBy:
            for round in 0..<max(0, result.rounds) {
                let reps = config.startReps + round * config.repIncrement
                for (index, movement) in movements.enumerated() {
                    newSets[index].append(completedSet(from: templates[index], tracking: movement.tracking, reps: movement.tracking.usesReps ? reps : nil))
                }
            }
        case .emom, .tabata, .intervals, .custom:
            let intervals = max(0, result.rounds)
            for interval in 0..<intervals {
                if config.alternateMovements, movements.count > 1 {
                    let index = interval % movements.count
                    newSets[index].append(completedSet(from: templates[index], tracking: movements[index].tracking))
                } else {
                    for (index, movement) in movements.enumerated() {
                        newSets[index].append(completedSet(from: templates[index], tracking: movement.tracking))
                    }
                }
            }
        }

        for index in movements.indices {
            // Keep the template when nothing was generated so the target
            // isn't lost if the timer is run again.
            updated.exercises[index].sets = newSets[index].isEmpty
                ? [WorkoutSet(kind: .normal, target: templates[index])]
                : newSets[index]
        }
        return updated
    }

    /// Undo a timed block's result back to its template state.
    public static func clearResult(of block: WorkoutBlock) -> WorkoutBlock {
        var updated = block
        updated.result = nil
        for index in updated.exercises.indices {
            let target = updated.exercises[index].sets.first?.target ?? SetTarget()
            updated.exercises[index].sets = [WorkoutSet(kind: .normal, target: target)]
        }
        return updated
    }

    // MARK: Finishing

    /// Prepares an active workout for saving as completed, and stamps the
    /// end time and duration.
    ///
    /// - Checked sets are always kept.
    /// - Unchecked sets with numbers typed in are kept and marked done when
    ///   `keepEnteredSets` is on (the default).
    /// - With `completeRemaining`, untouched sets are logged from their
    ///   targets too.
    /// - Everything else, and exercises left with no sets, is dropped.
    public static func finalize(_ workout: Workout, completeRemaining: Bool, keepEnteredSets: Bool = true, now: Date = Date()) -> Workout {
        var finished = workout
        for blockIndex in finished.blocks.indices {
            let isTimed = finished.blocks[blockIndex].isTimed
            for exerciseIndex in finished.blocks[blockIndex].exercises.indices {
                let tracking = finished.blocks[blockIndex].exercises[exerciseIndex].tracking
                var sets = finished.blocks[blockIndex].exercises[exerciseIndex].sets
                if isTimed, finished.blocks[blockIndex].result == nil {
                    sets = []
                } else {
                    for setIndex in sets.indices where !sets[setIndex].isCompleted {
                        // Numbers typed into a set mean it was almost always
                        // done, just not ticked; those are kept unless the
                        // athlete says otherwise.
                        let entered = sets[setIndex].hasValues
                        if completeRemaining {
                            sets[setIndex].fillEmptyFields(from: sets[setIndex].target, tracking: tracking)
                        }
                        let keep = (keepEnteredSets && entered) || (completeRemaining && sets[setIndex].hasValues)
                        if keep {
                            sets[setIndex].isCompleted = true
                            sets[setIndex].completedAt = now
                        }
                    }
                    sets = sets.filter(\.isCompleted)
                }
                finished.blocks[blockIndex].exercises[exerciseIndex].sets = sets
            }
            finished.blocks[blockIndex].exercises.removeAll { $0.sets.isEmpty }
        }
        finished.blocks.removeAll { $0.exercises.isEmpty && $0.result == nil }
        finished.status = .completed
        finished.endedAt = now
        finished.duration = max(0, now.timeIntervalSince(finished.startedAt))
        finished.runtime = WorkoutRuntimeState()
        finished.updatedAt = now
        return finished
    }

    // MARK: Routines from workouts

    /// "Save as routine": the workout's structure with performed values as
    /// targets.
    public static func routine(from workout: Workout, name: String, folderID: UUID? = nil, now: Date = Date()) -> Routine {
        let blocks = workout.blocks.map { block -> RoutineBlock in
            RoutineBlock(
                exercises: block.exercises.map { exercise in
                    let sets: [RoutineSet]
                    if block.isTimed {
                        let target = exercise.sets.first?.target ?? targetFrom(exercise.sets.first, tracking: exercise.tracking)
                        sets = [RoutineSet(kind: .normal, target: target)]
                    } else {
                        sets = exercise.sets.map { RoutineSet(kind: $0.kind, target: targetFrom($0, tracking: exercise.tracking)) }
                    }
                    return RoutineExercise(exerciseID: exercise.exerciseID, sets: sets, restSeconds: exercise.restSeconds, notes: exercise.notes)
                },
                timer: block.timer,
                notes: block.notes
            )
        }
        return Routine(folderID: folderID, name: name, notes: "", blocks: blocks, createdAt: now, updatedAt: now)
    }

    static func targetFrom(_ set: WorkoutSet?, tracking: TrackingType) -> SetTarget {
        guard let set else { return SetTarget() }
        return SetTarget(
            reps: tracking.usesReps ? (set.reps ?? set.target?.reps) : nil,
            repsMax: set.target?.repsMax,
            weight: tracking.usesWeight ? (set.weight ?? set.target?.weight) : nil,
            duration: tracking.usesDuration ? (set.duration ?? set.target?.duration) : nil,
            distance: tracking.usesDistance ? (set.distance ?? set.target?.distance) : nil,
            rpe: set.target?.rpe
        )
    }

    /// Rewrites a routine's structure and targets from a completed workout
    /// (the "update routine" option after finishing). Rep ranges and RPE
    /// targets that the routine already had are kept.
    public static func updatedRoutine(_ routine: Routine, from workout: Workout, now: Date = Date()) -> Routine {
        var updated = routine
        let originalByExercise = Dictionary(grouping: routine.blocks.flatMap(\.exercises), by: \.exerciseID)
        updated.blocks = workout.blocks.map { block -> RoutineBlock in
            RoutineBlock(
                exercises: block.exercises.map { exercise in
                    let original = originalByExercise[exercise.exerciseID]?.first
                    let sets: [RoutineSet]
                    if block.isTimed {
                        sets = [RoutineSet(kind: .normal, target: exercise.sets.first?.target ?? original?.sets.first?.target ?? SetTarget())]
                    } else {
                        sets = exercise.sets.enumerated().map { index, set in
                            var target = targetFrom(set, tracking: exercise.tracking)
                            if let old = original?.sets[safe: index]?.target {
                                if let low = old.reps, let high = old.repsMax, let reps = target.reps, reps >= low, reps <= high {
                                    target.reps = low
                                    target.repsMax = high
                                }
                                if target.rpe == nil { target.rpe = old.rpe }
                            }
                            return RoutineSet(kind: set.kind, target: target)
                        }
                    }
                    return RoutineExercise(
                        exerciseID: exercise.exerciseID,
                        sets: sets,
                        restSeconds: exercise.restSeconds ?? original?.restSeconds,
                        notes: exercise.notes.isEmpty ? (original?.notes ?? "") : exercise.notes
                    )
                },
                timer: block.timer,
                notes: block.notes
            )
        }
        // Timed blocks that weren't run are dropped when a workout finishes;
        // that's skipping, not deleting, so keep them in the routine.
        for (index, block) in routine.blocks.enumerated() where block.isTimed {
            let signature = block.exercises.map(\.exerciseID)
            let performed = updated.blocks.contains { candidate in
                candidate.timer?.kind == block.timer?.kind && candidate.exercises.map(\.exerciseID) == signature
            }
            if !performed {
                updated.blocks.insert(block, at: min(index, updated.blocks.count))
            }
        }
        updated.updatedAt = now
        return updated
    }

    /// Whether finishing this workout could meaningfully update its routine.
    public static func differsFromRoutine(_ workout: Workout, routine: Routine) -> Bool {
        let workoutShape = workout.blocks.map { block in block.exercises.map { "\($0.exerciseID):\(block.isTimed ? 1 : $0.sets.count)" } }
        let routineShape = routine.blocks.map { block in block.exercises.map { "\($0.exerciseID):\(block.isTimed ? 1 : $0.sets.count)" } }
        if workoutShape != routineShape { return true }
        for (block, routineBlock) in zip(workout.blocks, routine.blocks) where !block.isTimed {
            for (exercise, routineExercise) in zip(block.exercises, routineBlock.exercises) {
                for (set, routineSet) in zip(exercise.sets, routineExercise.sets) {
                    let target = routineSet.target
                    if exercise.tracking.usesWeight, let weight = set.weight, abs(weight - (target.weight ?? -1)) > 0.001 { return true }
                    if exercise.tracking.usesReps, let reps = set.reps {
                        let low = target.reps ?? -1
                        let high = target.repsMax ?? low
                        if reps < low || reps > high { return true }
                    }
                    if exercise.tracking.usesDuration, let duration = set.duration, abs(duration - (target.duration ?? -1)) > 0.5 { return true }
                    if exercise.tracking.usesDistance, let distance = set.distance, abs(distance - (target.distance ?? -1)) > 0.5 { return true }
                }
            }
        }
        return false
    }
}

extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
