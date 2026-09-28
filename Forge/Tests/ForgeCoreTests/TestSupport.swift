import Foundation
import XCTest
@testable import ForgeCore

/// A throwaway directory per test so databases never collide.
final class TemporaryDirectory {
    let url: URL

    init() {
        url = FileManager.default.temporaryDirectory
            .appendingPathComponent("forge-tests-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }

    deinit {
        try? FileManager.default.removeItem(at: url)
    }

    var location: StorageLocation {
        StorageLocation(directory: url.appendingPathComponent("Forge", isDirectory: true))
    }
}

enum Fixtures {
    static let bench = Exercise(id: "bench-press-barbell", name: "Bench Press (Barbell)", primaryMuscle: .chest, secondaryMuscles: [.triceps, .shoulders], equipment: .barbell, tracking: .weightReps)
    static let squat = Exercise(id: "squat-barbell", name: "Squat (Barbell)", primaryMuscle: .quadriceps, secondaryMuscles: [.glutes], equipment: .barbell, tracking: .weightReps)
    static let pushUp = Exercise(id: "push-up", name: "Push-Up", primaryMuscle: .chest, equipment: .none, tracking: .reps)
    static let plank = Exercise(id: "plank", name: "Plank", primaryMuscle: .abdominals, equipment: .none, tracking: .duration)
    static let run = Exercise(id: "running", name: "Running", primaryMuscle: .cardio, equipment: .none, category: .cardio, tracking: .distanceDuration)

    static var all: [Exercise] { [bench, squat, pushUp, plank, run] }

    static func lookup(_ id: String) -> Exercise? {
        all.first { $0.id == id }
    }

    static func date(_ day: Int, hour: Int = 9, month: Int = 3, year: Int = 2026) -> Date {
        var components = DateComponents()
        components.year = year
        components.month = month
        components.day = day
        components.hour = hour
        components.timeZone = TimeZone(identifier: "UTC")
        return Calendar(identifier: .gregorian).date(from: components)!
    }

    static var utcCalendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        calendar.firstWeekday = 2
        return calendar
    }

    /// A completed workout with the given (exercise, [(weight, reps)]) sets.
    static func workout(
        on date: Date,
        name: String = "Workout",
        _ entries: [(Exercise, [(Double?, Int?)])]
    ) -> Workout {
        let blocks = entries.map { exercise, sets in
            WorkoutBlock(exercises: [
                WorkoutExercise(
                    exerciseID: exercise.id,
                    name: exercise.name,
                    tracking: exercise.tracking,
                    sets: sets.map { WorkoutSet(weight: $0.0, reps: $0.1, isCompleted: true, completedAt: date) }
                ),
            ])
        }
        return Workout(
            status: .completed,
            name: name,
            startedAt: date,
            endedAt: date.addingTimeInterval(3600),
            duration: 3600,
            blocks: blocks,
            createdAt: date,
            updatedAt: date
        )
    }
}
