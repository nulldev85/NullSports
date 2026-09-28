import SwiftUI

/// Built-in and custom exercises plus per-exercise preferences.
@MainActor
@Observable
final class LibraryStore {
    let builtins: [Exercise]
    private(set) var customs: [Exercise] = []
    private(set) var preferences: [String: ExercisePreference] = [:]
    private(set) var usageCounts: [String: Int] = [:]
    private(set) var lastUsed: [String: Date] = [:]
    private(set) var index: ExerciseSearchIndex
    private var byID: [String: Exercise] = [:]

    private let database: AppDatabase
    private let feedback: Feedback

    init(database: AppDatabase, catalog: ExerciseCatalog, feedback: Feedback) {
        self.database = database
        self.feedback = feedback
        self.builtins = catalog.exercises
        self.index = ExerciseSearchIndex(exercises: catalog.exercises)
        reload()
    }

    func reload() {
        do {
            customs = try database.exercises.customExercises()
            preferences = try database.exercises.preferences()
        } catch {
            feedback.report(error, while: "load your exercises")
        }
        rebuild()
        refreshUsage()
    }

    func refreshUsage() {
        usageCounts = (try? database.workouts.exerciseUsageCounts()) ?? [:]
        lastUsed = (try? database.workouts.lastUsedDates()) ?? [:]
    }

    private func rebuild() {
        var map: [String: Exercise] = [:]
        for exercise in builtins { map[exercise.id] = exercise }
        for exercise in customs { map[exercise.id] = exercise }
        byID = map
        let active = (builtins + customs.filter { !$0.isArchived })
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        index = ExerciseSearchIndex(exercises: active)
    }

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
        do {
            try database.exercises.savePreference(preference)
            if preference.isEmpty {
                preferences[preference.exerciseID] = nil
            } else {
                preferences[preference.exerciseID] = preference
            }
        } catch {
            feedback.report(error, while: "save that change")
        }
    }

    // MARK: Custom exercises

    @discardableResult
    func saveCustom(_ exercise: Exercise) -> Exercise? {
        var copy = exercise
        copy.isCustom = true
        copy.name = copy.name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !copy.name.isEmpty else { return nil }
        do {
            try database.exercises.saveCustom(copy)
            customs = try database.exercises.customExercises()
            rebuild()
            return byID[copy.id]
        } catch {
            feedback.report(error, while: "save the exercise")
            return nil
        }
    }

    func archive(_ id: String) {
        do {
            try database.exercises.archiveCustom(id: id)
            customs = try database.exercises.customExercises()
            rebuild()
            feedback.show("Exercise archived. Its history is kept, and you can restore it from Settings.", style: .info, duration: 4)
        } catch {
            feedback.report(error, while: "archive the exercise")
        }
    }

    func unarchive(_ id: String) {
        do {
            try database.exercises.unarchiveCustom(id: id)
            customs = try database.exercises.customExercises()
            rebuild()
        } catch {
            feedback.report(error, while: "restore the exercise")
        }
    }

    func usageCount(of id: String) -> Int {
        (try? database.exercises.usageCount(exerciseID: id)) ?? 1
    }

    func deletePermanently(_ id: String) {
        do {
            try database.exercises.deleteCustomPermanently(id: id)
            customs = try database.exercises.customExercises()
            preferences[id] = nil
            rebuild()
        } catch {
            feedback.report(error, while: "delete the exercise")
        }
    }

    func isNameTaken(_ name: String, excluding id: String?) -> Bool {
        let normalized = ExerciseSearchIndex.normalize(name)
        return (builtins + customs.filter { !$0.isArchived }).contains {
            $0.id != id && ExerciseSearchIndex.normalize($0.name) == normalized
        }
    }
}
