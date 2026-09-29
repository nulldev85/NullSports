import SwiftUI

/// Built-in and custom exercises plus per-exercise preferences.
///
/// Everything is loaded off the main thread; changes show immediately and
/// are saved in the background.
@MainActor
@Observable
final class LibraryStore {
    let builtins: [Exercise]
    private(set) var customs: [Exercise] = []
    private(set) var preferences: [String: ExercisePreference] = [:]
    private(set) var usageCounts: [String: Int] = [:]
    private(set) var lastUsed: [String: Date] = [:]
    private(set) var index: ExerciseSearchIndex
    /// Bumped whenever search results could change (exercises, favorites,
    /// usage), so screens can keep results between redraws.
    private(set) var revision = 0
    private var byID: [String: Exercise] = [:]
    @ObservationIgnored private var usageTask: Task<Void, Never>?
    @ObservationIgnored private var indexTask: Task<Void, Never>?
    @ObservationIgnored private var indexGeneration = 0
    /// Called after custom exercises change (their muscles feed the
    /// history numbers).
    @ObservationIgnored var onChange: (() -> Void)?
    /// Called after a preference (favorite, note, rest time) is saved.
    @ObservationIgnored var onPreferencesSaved: (() -> Void)?

    private let database: AppDatabase
    private let feedback: Feedback

    /// What the store starts with, loaded off the main thread.
    struct Loaded: Sendable {
        var customs: [Exercise]
        var preferences: [String: ExercisePreference]
        var usageCounts: [String: Int]
        var lastUsed: [String: Date]
        var index: ExerciseSearchIndex
    }

    nonisolated static func load(from database: AppDatabase, builtins: [Exercise]) -> Loaded {
        let customs = (try? database.exercises.customExercises()) ?? []
        return Loaded(
            customs: customs,
            preferences: (try? database.exercises.preferences()) ?? [:],
            usageCounts: (try? database.workouts.exerciseUsageCounts()) ?? [:],
            lastUsed: (try? database.workouts.lastUsedDates()) ?? [:],
            index: makeIndex(builtins: builtins, customs: customs)
        )
    }

    /// Active exercises sorted by name, ready to search.
    nonisolated static func makeIndex(builtins: [Exercise], customs: [Exercise]) -> ExerciseSearchIndex {
        let active = (builtins + customs.filter { !$0.isArchived })
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        return ExerciseSearchIndex(exercises: active)
    }

    init(database: AppDatabase, catalog: ExerciseCatalog, feedback: Feedback, loaded: Loaded) {
        self.database = database
        self.feedback = feedback
        self.builtins = catalog.exercises
        self.index = loaded.index
        apply(loaded)
    }

    private func apply(_ loaded: Loaded) {
        customs = loaded.customs
        preferences = loaded.preferences
        usageCounts = loaded.usageCounts
        lastUsed = loaded.lastUsed
        index = loaded.index
        rebuildMap()
        revision += 1
    }

    /// After a restore or import replaced the data.
    func reload() {
        let database = database
        let builtins = builtins
        Task {
            let loaded = await Task.detached(priority: .userInitiated) { Self.load(from: database, builtins: builtins) }.value
            apply(loaded)
            onChange?()
        }
    }

    /// Usage numbers, with the queries off the main thread (after a workout
    /// is saved, when nothing is waiting on them).
    func refreshUsageInBackground() {
        let workouts = database.workouts
        usageTask?.cancel()
        usageTask = Task { [weak self] in
            let loaded = await Task.detached(priority: .utility) {
                ((try? workouts.exerciseUsageCounts()) ?? [:], (try? workouts.lastUsedDates()) ?? [:])
            }.value
            guard let self, !Task.isCancelled else { return }
            guard self.usageCounts != loaded.0 || self.lastUsed != loaded.1 else { return }
            self.usageCounts = loaded.0
            self.lastUsed = loaded.1
            self.revision += 1
        }
    }

    private func rebuildMap() {
        var map: [String: Exercise] = [:]
        for exercise in builtins { map[exercise.id] = exercise }
        for exercise in customs { map[exercise.id] = exercise }
        byID = map
    }

    /// Custom exercises changed: lookups update now, the search index
    /// (a sort of the whole library) is rebuilt in the background.
    private func customsChanged() {
        customs.sort { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        rebuildMap()
        indexGeneration += 1
        let generation = indexGeneration
        let builtins = builtins
        let customs = customs
        indexTask = Task { [weak self] in
            let index = await Task.detached(priority: .userInitiated) { Self.makeIndex(builtins: builtins, customs: customs) }.value
            guard let self, generation == self.indexGeneration else { return }
            self.index = index
            self.revision += 1
        }
        revision += 1
        onChange?()
    }

    /// Every exercise by ID, archived customs included (a value copy that's
    /// safe to hand to background work).
    var exerciseMap: [String: Exercise] { byID }

    /// Includes archived custom exercises so old workouts still resolve.
    func exercise(_ id: String) -> Exercise? {
        byID[id]
    }

    var activeCount: Int { index.exercises.count }

    var archivedCustoms: [Exercise] {
        customs.filter(\.isArchived)
    }

    func search(_ query: String, filter: ExerciseSearchIndex.Filter = .init(), favoritesOnly: Bool = false, customOnly: Bool = false) -> [Exercise] {
        var results = index.search(query, filter: filter, boost: usageCounts)
        if favoritesOnly {
            results = results.filter { preferences[$0.id]?.isFavorite == true }
        }
        if customOnly {
            results = results.filter(\.isCustom)
        }
        return results
    }

    /// Recently used exercises, most recent first.
    func recent(limit: Int = 20) -> [Exercise] {
        lastUsed.sorted { $0.value > $1.value }
            .compactMap { byID[$0.key] }
            .filter { !$0.isArchived }
            .prefix(limit)
            .map { $0 }
    }

    func isFavorite(_ id: String) -> Bool {
        preferences[id]?.isFavorite == true
    }

    func toggleFavorite(_ id: String) {
        var preference = preferences[id] ?? ExercisePreference(exerciseID: id)
        preference.isFavorite.toggle()
        preference.updatedAt = Date()
        savePreference(preference)
    }

    func note(for id: String) -> String {
        preferences[id]?.note ?? ""
    }

    func setNote(_ note: String, for id: String) {
        var preference = preferences[id] ?? ExercisePreference(exerciseID: id)
        preference.note = note
        preference.updatedAt = Date()
        savePreference(preference)
    }

    func restSeconds(for id: String) -> Int? {
        preferences[id]?.restSeconds
    }

    func setRestSeconds(_ seconds: Int?, for id: String) {
        var preference = preferences[id] ?? ExercisePreference(exerciseID: id)
        preference.restSeconds = seconds
        preference.updatedAt = Date()
        savePreference(preference)
    }

    private func savePreference(_ preference: ExercisePreference) {
        let id = preference.exerciseID
        preferences[id] = preference.isEmpty ? nil : preference
        revision += 1
        database.writeInBackground({ try $0.exercises.savePreference(preference) }) { [weak self] result in
            guard let self else { return }
            switch result {
            case .success:
                self.onPreferencesSaved?()
            case .failure(let error):
                self.feedback.report(error, while: "save that change")
                self.reload()
            }
        }
    }

    // MARK: Custom exercises

    /// Saves a custom exercise and returns it as saved (it's usable right
    /// away; the write follows in the background).
    @discardableResult
    func saveCustom(_ exercise: Exercise) -> Exercise? {
        var copy = exercise
        copy.isCustom = true
        copy.name = copy.name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !copy.name.isEmpty else { return nil }
        let now = Date()
        copy.updatedAt = now
        if copy.createdAt == nil { copy.createdAt = now }
        if let index = customs.firstIndex(where: { $0.id == copy.id }) {
            customs[index] = copy
        } else {
            customs.append(copy)
        }
        customsChanged()
        let saved = copy
        database.writeInBackground({ try $0.exercises.saveCustom(saved, now: now) }) { [weak self] result in
            if case .failure(let error) = result {
                self?.feedback.report(error, while: "save the exercise")
                self?.reload()
            }
        }
        return copy
    }

    func archive(_ id: String) {
        guard let index = customs.firstIndex(where: { $0.id == id }) else { return }
        let now = Date()
        customs[index].archivedAt = now
        customs[index].updatedAt = now
        customsChanged()
        feedback.show("Exercise archived. Its history is kept, and you can restore it from Settings.", style: .info, duration: 4)
        database.writeInBackground({ try $0.exercises.archiveCustom(id: id, at: now) }) { [weak self] result in
            if case .failure(let error) = result {
                self?.feedback.report(error, while: "archive the exercise")
                self?.reload()
            }
        }
    }

    func unarchive(_ id: String) {
        guard let index = customs.firstIndex(where: { $0.id == id }) else { return }
        let now = Date()
        customs[index].archivedAt = nil
        customs[index].updatedAt = now
        customsChanged()
        database.writeInBackground({ try $0.exercises.unarchiveCustom(id: id, now: now) }) { [weak self] result in
            if case .failure(let error) = result {
                self?.feedback.report(error, while: "restore the exercise")
                self?.reload()
            }
        }
    }

    func usageCount(of id: String) -> Int {
        (try? database.exercises.usageCount(exerciseID: id)) ?? 1
    }

    /// Only possible for an exercise nothing refers to; removed from the
    /// list once the database agrees.
    func deletePermanently(_ id: String) {
        database.writeInBackground({ try $0.exercises.deleteCustomPermanently(id: id) }) { [weak self] result in
            guard let self else { return }
            switch result {
            case .success:
                withAnimation(Motion.smooth) {
                    self.customs.removeAll { $0.id == id }
                    self.preferences[id] = nil
                    self.customsChanged()
                }
            case .failure(let error):
                self.feedback.report(error, while: "delete the exercise")
            }
        }
    }

    /// Whether another active exercise already has this name (a lookup in
    /// the search index, so it's cheap enough to check on every keystroke).
    func isNameTaken(_ name: String, excluding id: String?) -> Bool {
        index.exerciseIDs(named: name).contains { $0 != id }
    }
}
