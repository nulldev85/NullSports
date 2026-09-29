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
        // After the first load, rows that come or go animate in and out.
        let animation: Animation? = isLoaded ? Motion.smooth : nil
        withAnimation(animation) {
            if summaries != snapshot.summaries { summaries = snapshot.summaries }
            if deleted != snapshot.deleted { deleted = snapshot.deleted }
        }
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

    /// When the routine was last done, from the workouts in History.
    func lastDone(_ routineID: UUID) -> Date? {
        digest.lastDone(routineID: routineID)
    }

    func workout(_ id: UUID) -> Workout? {
        try? database.workouts.workout(id: id)
    }

    func summary(_ id: UUID) -> WorkoutSummary? {
        summaries.first { $0.id == id }
    }

    /// Saves an edited workout. The copy on screen is already the edited
    /// one; this reads it back from disk to be sure, then refreshes.
    func save(_ workout: Workout) {
        var copy = workout
        copy.updatedAt = Date()
        let saved = copy
        database.writeInBackground({ try $0.workouts.saveVerified(saved) }) { [weak self] result in
            guard let self else { return }
            switch result {
            case .success:
                self.reload()
                self.markChanged()
            case .failure(let error):
                self.feedback.report(error, while: "save the workout")
                self.reload()
            }
        }
    }

    func delete(_ id: UUID) {
        if let index = summaries.firstIndex(where: { $0.id == id }) {
            var removed = summaries.remove(at: index)
            removed.deletedAt = Date()
            deleted.insert(removed, at: 0)
        }
        feedback.show("Workout moved to Recently Deleted", style: .info, action: ToastAction(title: "Undo") { [weak self] in
            withAnimation(Motion.smooth) { self?.restore(id) }
        })
        write("delete the workout") { try $0.workouts.softDelete(workoutID: id) }
    }

    func restore(_ id: UUID) {
        if let index = deleted.firstIndex(where: { $0.id == id }) {
            var restored = deleted.remove(at: index)
            restored.deletedAt = nil
            let position = summaries.firstIndex { $0.startedAt < restored.startedAt } ?? summaries.count
            summaries.insert(restored, at: position)
        }
        write("restore the workout") { try $0.workouts.restore(workoutID: id) }
    }

    func purge(_ id: UUID) {
        deleted.removeAll { $0.id == id }
        write("delete the workout", notifies: false) { try $0.workouts.purge(workoutID: id) }
    }

    /// Saves in the background, then refreshes the numbers that depend on
    /// history (the lists on screen changed already).
    private func write(_ action: String, notifies: Bool = true, _ work: @escaping @Sendable (AppDatabase) throws -> Void) {
        database.writeInBackground(work) { [weak self] result in
            guard let self else { return }
            if case .failure(let error) = result {
                self.feedback.report(error, while: action)
            }
            self.reload()
            if notifies { self.markChanged() }
        }
    }

    /// Every past session of an exercise, read off the main thread.
    func loadSessions(for exerciseID: String) async -> [ExerciseSession] {
        (try? await database.readInBackground { try $0.workouts.sessions(exerciseID: exerciseID) }) ?? []
    }

    /// Last time's sets for each exercise, read off the main thread.
    func loadLastPerformances(_ exerciseIDs: [String], excluding workoutID: UUID?) async -> [String: [WorkoutSet]] {
        await loadLastPerformanceDetails(exerciseIDs, excluding: workoutID).mapValues(\.sets)
    }

    /// The same, with how each exercise was tracked that time.
    func loadLastPerformanceDetails(_ exerciseIDs: [String], excluding workoutID: UUID?) async -> [String: LastPerformance] {
        guard !exerciseIDs.isEmpty else { return [:] }
        return (try? await database.readInBackground { try $0.workouts.lastPerformanceDetails(exerciseIDs: exerciseIDs, excluding: workoutID) }) ?? [:]
    }

    func summaries(on day: Date, calendar: Calendar) -> [WorkoutSummary] {
        summaries.filter { calendar.isDate($0.startedAt, inSameDayAs: day) }
    }

    /// Most recent completed workout that came from a routine.
    func lastPerformed(routineID: UUID) -> WorkoutSummary? {
        summaries.first { $0.routineID == routineID }
    }
}
