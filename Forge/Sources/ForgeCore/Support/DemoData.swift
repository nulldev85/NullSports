import Foundation

/// Realistic sample data for UI tests and screenshots. Never runs for real
/// users; it's only triggered by a launch argument.
public enum DemoData {
    /// - Parameter imperial: round loads to 5 lb and body measurements to
    ///   pounds/inches, so the sample numbers look natural in those units.
    public static func seed(into database: AppDatabase, catalog: ExerciseCatalog, now: Date = Date(), imperial: Bool = false) throws {
        let lookup = Dictionary(uniqueKeysWithValues: catalog.exercises.map { ($0.id, $0) })
        func exercise(_ id: String) -> Exercise? { lookup[id] }

        /// A loadable weight in the athlete's unit, stored as kilograms.
        func load(_ kilograms: Double) -> Double {
            if imperial {
                let pounds = kilograms / WeightUnit.kilogramsPerPound
                return (pounds / 5).rounded() * 5 * WeightUnit.kilogramsPerPound
            }
            return (kilograms / 1.25).rounded() * 1.25
        }
        func bodyWeight(_ kilograms: Double) -> Double {
            if imperial {
                let pounds = kilograms / WeightUnit.kilogramsPerPound
                return (pounds * 5).rounded() / 5 * WeightUnit.kilogramsPerPound
            }
            return (kilograms * 10).rounded() / 10
        }
        func length(_ centimeters: Double) -> Double {
            if imperial {
                let inches = centimeters / LengthUnit.centimetersPerInch
                return (inches * 4).rounded() / 4 * LengthUnit.centimetersPerInch
            }
            return (centimeters * 10).rounded() / 10
        }

        let strength = Folder(name: "Strength", colorTag: "sage", sortOrder: 1)
        let upperLower = Folder(parentID: strength.id, name: "Upper / Lower", sortOrder: 1)
        let conditioning = Folder(name: "Conditioning", colorTag: "mist", sortOrder: 2)
        for folder in [strength, upperLower, conditioning] {
            try database.routines.saveFolder(folder)
        }

        func sets(_ count: Int, reps: Int, repsMax: Int? = nil, weight: Double?, warmups: Int = 0) -> [RoutineSet] {
            var result: [RoutineSet] = []
            for index in 0..<warmups {
                let fraction = 0.5 + 0.2 * Double(index)
                result.append(RoutineSet(kind: .warmup, target: SetTarget(reps: 8, weight: weight.map { load($0 * fraction) })))
            }
            for _ in 0..<count {
                result.append(RoutineSet(target: SetTarget(reps: reps, repsMax: repsMax, weight: weight.map(load))))
            }
            return result
        }

        let upper = Routine(folderID: upperLower.id, name: "Upper A", notes: "Heavy horizontal push/pull", colorTag: "sage", sortOrder: 1, blocks: [
            RoutineBlock(exercises: [RoutineExercise(exerciseID: "bench-press-barbell", sets: sets(3, reps: 5, weight: 100, warmups: 2), restSeconds: 180)]),
            RoutineBlock(exercises: [RoutineExercise(exerciseID: "bent-over-row-barbell", sets: sets(3, reps: 8, weight: 80), restSeconds: 120)]),
            RoutineBlock(exercises: [
                RoutineExercise(exerciseID: "overhead-press-dumbbell", sets: sets(3, reps: 8, repsMax: 12, weight: 24), restSeconds: 90),
                RoutineExercise(exerciseID: "pull-up", sets: sets(3, reps: 8, weight: nil), restSeconds: 90),
            ]),
            RoutineBlock(exercises: [RoutineExercise(exerciseID: "bicep-curl-dumbbell", sets: sets(3, reps: 10, repsMax: 15, weight: 14), restSeconds: 60)]),
        ])
        let lower = Routine(folderID: upperLower.id, name: "Lower A", notes: "Squat focus", colorTag: "lavender", sortOrder: 2, blocks: [
            RoutineBlock(exercises: [RoutineExercise(exerciseID: "squat-barbell", sets: sets(3, reps: 5, weight: 140, warmups: 2), restSeconds: 180)]),
            RoutineBlock(exercises: [RoutineExercise(exerciseID: "romanian-deadlift-barbell", sets: sets(3, reps: 8, weight: 110), restSeconds: 150)]),
            RoutineBlock(exercises: [RoutineExercise(exerciseID: "leg-press-machine", sets: sets(3, reps: 10, repsMax: 12, weight: 200), restSeconds: 120)]),
            RoutineBlock(exercises: [RoutineExercise(exerciseID: "standing-calf-raise-machine", sets: sets(4, reps: 12, weight: 80), restSeconds: 60)]),
        ])
        let cindy = Routine(folderID: conditioning.id, name: "Cindy", notes: "20-minute AMRAP", sortOrder: 1, blocks: [
            RoutineBlock(exercises: [
                RoutineExercise(exerciseID: "pull-up", sets: [RoutineSet(target: SetTarget(reps: 5))]),
                RoutineExercise(exerciseID: "push-up", sets: [RoutineSet(target: SetTarget(reps: 10))]),
                RoutineExercise(exerciseID: "bodyweight-squat", sets: [RoutineSet(target: SetTarget(reps: 15))]),
            ], timer: TimerConfig(kind: .amrap, duration: 20 * 60)),
        ])
        let engine = Routine(folderID: conditioning.id, name: "Engine EMOM", notes: "Alternate every minute", sortOrder: 2, blocks: [
            RoutineBlock(exercises: [
                RoutineExercise(exerciseID: "kettlebell-swing", sets: [RoutineSet(target: SetTarget(reps: 15, weight: load(24)))]),
                RoutineExercise(exerciseID: "burpee", sets: [RoutineSet(target: SetTarget(reps: 10))]),
            ], timer: TimerConfig(kind: .emom, interval: 60, rounds: 12, alternateMovements: true)),
        ])
        let fullBody = Routine(name: "Full Body Express", notes: "45 minutes, in and out", sortOrder: 3, blocks: [
            RoutineBlock(exercises: [RoutineExercise(exerciseID: "deadlift-barbell", sets: sets(3, reps: 5, weight: 160), restSeconds: 180)]),
            RoutineBlock(exercises: [RoutineExercise(exerciseID: "incline-bench-press-dumbbell", sets: sets(3, reps: 10, weight: 30), restSeconds: 90)]),
            RoutineBlock(exercises: [RoutineExercise(exerciseID: "plank", sets: [RoutineSet(target: SetTarget(duration: 60)), RoutineSet(target: SetTarget(duration: 60))], restSeconds: 45)]),
        ])
        for routine in [upper, lower, cindy, engine, fullBody] {
            try database.routines.save(routine)
        }

        // Eight weeks of progressive training, the last session yesterday.
        var generator = SeededGenerator(seed: 42)
        let calendar = Calendar(identifier: .gregorian)
        func sessionDay(week: Int, offset: Int) -> Date? {
            // offset 0...5 within the week; offset 5 of week 7 is yesterday.
            calendar.date(byAdding: .day, value: -((7 - week) * 7 + (5 - offset) + 1), to: now)
        }
        for week in 0..<8 {
            for (dayOffset, routine) in [(0, upper), (2, lower), (4, fullBody)] {
                guard let day = sessionDay(week: week, offset: dayOffset) else { continue }
                let start = calendar.date(bySettingHour: 7 + Int(generator.next() % 3), minute: Int(generator.next() % 50), second: 0, of: day) ?? day
                var workout = WorkoutFactory.workout(from: routine, lookup: exercise, now: start)
                let progression = Double(week) * 1.25
                for blockIndex in workout.blocks.indices {
                    for exerciseIndex in workout.blocks[blockIndex].exercises.indices {
                        let tracking = workout.blocks[blockIndex].exercises[exerciseIndex].tracking
                        for setIndex in workout.blocks[blockIndex].exercises[exerciseIndex].sets.indices {
                            var set = workout.blocks[blockIndex].exercises[exerciseIndex].sets[setIndex]
                            if let target = set.target {
                                if tracking.usesWeight, let weight = target.weight {
                                    set.weight = load(weight * 0.9 + progression * (set.kind == .warmup ? 0.5 : 1))
                                }
                                if tracking.usesReps {
                                    set.reps = max(1, (target.reps ?? 8) + Int(generator.next() % 3) - 1)
                                }
                                if tracking.usesDuration {
                                    set.duration = (target.duration ?? 45) + Double(week * 5)
                                }
                            } else if tracking.usesReps {
                                set.reps = 6 + Int(generator.next() % 5)
                            }
                            set.isCompleted = true
                            set.completedAt = start.addingTimeInterval(Double(setIndex + blockIndex * 4) * 180)
                            workout.blocks[blockIndex].exercises[exerciseIndex].sets[setIndex] = set
                        }
                    }
                }
                let minutes = Double(48 + Int(generator.next() % 25))
                workout = WorkoutFactory.finalize(workout, completeRemaining: false, now: start.addingTimeInterval(minutes * 60))
                workout.rating = 3 + Int(generator.next() % 3)
                try database.workouts.save(workout)
            }
            // A weekly conditioning session.
            if let day = sessionDay(week: week, offset: 5) {
                let start = calendar.date(bySettingHour: 18, minute: 0, second: 0, of: day) ?? day
                var workout = WorkoutFactory.workout(from: cindy, lookup: exercise, now: start)
                let rounds = 14 + week / 2
                let config = cindy.blocks[0].timer!
                workout.blocks[0] = WorkoutFactory.applyResult(
                    BlockResult(rounds: rounds, extraReps: Int(generator.next() % 20), elapsed: 1200),
                    to: workout.blocks[0],
                    program: TimerProgram(config: config),
                    now: start.addingTimeInterval(1200)
                )
                workout = WorkoutFactory.finalize(workout, completeRemaining: false, now: start.addingTimeInterval(25 * 60))
                try database.workouts.save(workout)
            }
            if let day = sessionDay(week: week, offset: 3) {
                try database.measurements.save(BodyMeasurement(kind: .bodyWeight, value: bodyWeight(84 - Double(week) * 0.35), measuredAt: day))
            }
        }
        try database.measurements.save(BodyMeasurement(kind: .waist, value: length(86), measuredAt: now.addingTimeInterval(-40 * 86_400)))
        try database.measurements.save(BodyMeasurement(kind: .waist, value: length(84.5), measuredAt: now.addingTimeInterval(-5 * 86_400)))

        try database.timerPresets.save(TimerPreset(name: "Tabata 20/10", config: .standard(.tabata), sortOrder: 1))
        try database.timerPresets.save(TimerPreset(name: "EMOM 10", config: .standard(.emom), sortOrder: 2))
        try database.timerPresets.save(TimerPreset(name: "Sprint Intervals", config: TimerConfig(kind: .intervals, rounds: 8, work: 30, rest: 90), sortOrder: 3))
    }
}

/// Deterministic generator so demo data is identical on every run.
struct SeededGenerator {
    private var state: UInt64

    init(seed: UInt64) {
        state = seed &+ 0x9E37_79B9_7F4A_7C15
    }

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}
