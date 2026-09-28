import SwiftUI

/// Completed workouts plus everything derived from them (records, stats).
@MainActor
@Observable
final class HistoryStore {
    private(set) var summaries: [WorkoutSummary] = []
    private(set) var deleted: [WorkoutSummary] = []
    private(set) var setRecords: [SetRecord] = []
    private(set) var records = RecordBook()
    private(set) var isLoaded = false
    /// Bumped whenever history changes so dependent views can refresh.
    private(set) var revision = 0

    private let database: AppDatabase
    private let feedback: Feedback
    private var loadTask: Task<Void, Never>?
    /// Called when workouts are added, edited or deleted.
    var onChange: (() -> Void)?

    func markChanged() {
        onChange?()
    }

    init(database: AppDatabase, feedback: Feedback) {
        self.database = database
        self.feedback = feedback
        reload()
    }

    /// Reloads summaries immediately and recomputes analytics in the
    /// background.
    func reload() {
        do {
            summaries = try database.workouts.summaries()
            deleted = try database.workouts.summaries(deleted: true)
        } catch {
            feedback.report(error, while: "load your history")
        }
        revision += 1
        loadTask?.cancel()
        let database = database
        loadTask = Task { [weak self] in
            let computed = await Task.detached(priority: .userInitiated) { () -> ([SetRecord], RecordBook)? in
                guard let records = try? database.workouts.setRecords() else { return nil }
                return (records, RecordBook(records: records))
            }.value
            guard let self, !Task.isCancelled, let computed else { return }
            self.setRecords = computed.0
            self.records = computed.1
            self.isLoaded = true
            self.revision += 1
        }
    }

    /// The record book, computed on the spot if the background load hasn't
    /// finished yet (so a workout finished right after launch still gets
    /// its records).
    func currentRecords() -> RecordBook {
        if isLoaded { return records }
        return RecordBook(records: (try? database.workouts.setRecords()) ?? [])
    }

    func workout(_ id: UUID) -> Workout? {
        try? database.workouts.workout(id: id)
    }

    func summary(_ id: UUID) -> WorkoutSummary? {
        summaries.first { $0.id == id }
    }

    func save(_ workout: Workout) {
        var copy = workout
        copy.updatedAt = Date()
        do {
            try database.workouts.save(copy)
            reload()
            markChanged()
        } catch {
            feedback.report(error, while: "save the workout")
        }
    }

    func delete(_ id: UUID) {
        do {
            try database.workouts.softDelete(workoutID: id)
            reload()
            markChanged()
            feedback.show("Workout moved to Recently Deleted", style: .info)
        } catch {
            feedback.report(error, while: "delete the workout")
        }
    }

    func restore(_ id: UUID) {
        do {
            try database.workouts.restore(workoutID: id)
            reload()
            markChanged()
        } catch {
            feedback.report(error, while: "restore the workout")
        }
    }

    func purge(_ id: UUID) {
        do {
            try database.workouts.purge(workoutID: id)
            reload()
        } catch {
            feedback.report(error, while: "delete the workout")
        }
    }

    func sessions(for exerciseID: String) -> [ExerciseSession] {
        (try? database.workouts.sessions(exerciseID: exerciseID)) ?? []
    }

    func lastPerformances(_ exerciseIDs: [String], excluding workoutID: UUID?) -> [String: [WorkoutSet]] {
        (try? database.workouts.lastPerformances(exerciseIDs: exerciseIDs, excluding: workoutID)) ?? [:]
    }

    func summaries(on day: Date, calendar: Calendar) -> [WorkoutSummary] {
        summaries.filter { calendar.isDate($0.startedAt, inSameDayAs: day) }
    }

    /// Most recent completed workout that came from a routine.
    func lastPerformed(routineID: UUID) -> WorkoutSummary? {
        summaries.first { $0.routineID == routineID }
    }
}
