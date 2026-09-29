import SwiftUI

/// Completed workouts plus everything derived from them (records, stats).
///
/// Loading happens off the main thread and lands all at once, so the
/// screens never wait on the database or recompute totals while drawing.
/// Deletes and restores update the lists immediately, then reload.
@MainActor
@Observable
final class HistoryStore {
    private(set) var summaries: [WorkoutSummary] = []
    private(set) var deleted: [WorkoutSummary] = []
    private(set) var setRecords: [SetRecord] = []
    private(set) var records = RecordBook()
    /// The newest personal records, newest first.
    private(set) var recentRecords: [PersonalRecord] = []
    /// Totals, streaks, calendar days and search text, precomputed.
    private(set) var digest = HistoryDigest()
    private(set) var isLoaded = false
    /// Bumped whenever history changes so dependent views can refresh.
    private(set) var revision = 0

    private let database: AppDatabase
    private let feedback: Feedback
    private let settings: SettingsStore
    private let library: LibraryStore
    private var generation = 0
    /// Called when workouts are added, edited or deleted.
    var onChange: (() -> Void)?

    func markChanged() {
        onChange?()
    }

    /// `preloaded` is history loaded during launch; without it the store
    /// loads in the background.
    init(database: AppDatabase, feedback: Feedback, settings: SettingsStore, library: LibraryStore, preloaded: HistorySnapshot? = nil) {
        self.database = database
        self.feedback = feedback
        self.settings = settings
        self.library = library
        if let preloaded {
            apply(preloaded)
        } else {
            reload()
        }
    }

    /// Reloads everything in the background and swaps it in when ready.
    func reload() {
        generation += 1
        let current = generation
        let database = database
        let calendar = settings.calendar
        let exercises = library.exerciseMap
        Task { [weak self] in
            let result = await Task.detached(priority: .userInitiated) {
                Result { try HistorySnapshot.load(from: database, calendar: calendar, exercises: exercises) }
            }.value
            // A newer reload supersedes this one.
            guard let self, current == self.generation else { return }
            switch result {
            case .success(let snapshot):
                self.apply(snapshot)
            case .failure(let error):
                self.feedback.report(error, while: "load your history")
            }
        }
    }

    private func apply(_ snapshot: HistorySnapshot) {
        if summaries != snapshot.summaries { summaries = snapshot.summaries }
        if deleted != snapshot.deleted { deleted = snapshot.deleted }
        setRecords = snapshot.setRecords
        records = snapshot.records
        recentRecords = snapshot.recentRecords
        digest = snapshot.digest
        isLoaded = true
        revision += 1
    }

    /// The record book, computed on the spot if the first load hasn't
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
            try database.workouts.saveVerified(copy)
            reload()
            markChanged()
        } catch {
            feedback.report(error, while: "save the workout")
        }
    }

    func delete(_ id: UUID) {
        do {
            try database.workouts.softDelete(workoutID: id)
            if let index = summaries.firstIndex(where: { $0.id == id }) {
                var removed = summaries.remove(at: index)
                removed.deletedAt = Date()
                deleted.insert(removed, at: 0)
            }
            reload()
            markChanged()
            feedback.show("Workout moved to Recently Deleted", style: .info, action: ToastAction(title: "Undo") { [weak self] in
                withAnimation(Motion.smooth) { self?.restore(id) }
            })
        } catch {
            feedback.report(error, while: "delete the workout")
        }
    }

    func restore(_ id: UUID) {
        do {
            try database.workouts.restore(workoutID: id)
            if let index = deleted.firstIndex(where: { $0.id == id }) {
                var restored = deleted.remove(at: index)
                restored.deletedAt = nil
                let position = summaries.firstIndex { $0.startedAt < restored.startedAt } ?? summaries.count
                summaries.insert(restored, at: position)
            }
            reload()
            markChanged()
        } catch {
            feedback.report(error, while: "restore the workout")
        }
    }

    func purge(_ id: UUID) {
        do {
            try database.workouts.purge(workoutID: id)
            deleted.removeAll { $0.id == id }
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
