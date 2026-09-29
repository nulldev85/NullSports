import SwiftUI

/// Folders and routines (the workout builder's data).
@MainActor
@Observable
final class RoutineStore {
    private(set) var folders: [Folder] = []
    private(set) var routines: [Routine] = []
    private(set) var deletedRoutines: [Routine] = []

    private let database: AppDatabase
    private let feedback: Feedback
    /// Called after routines or folders change on disk.
    @ObservationIgnored var onChange: (() -> Void)?

    init(database: AppDatabase, feedback: Feedback) {
        self.database = database
        self.feedback = feedback
        reload()
    }

    func reload() {
        do {
            folders = try database.routines.folders()
            routines = try database.routines.routines()
            deletedRoutines = try database.routines.deletedRoutines()
        } catch {
            feedback.report(error, while: "load your routines")
        }
        onChange?()
    }

    // MARK: Queries

    func folder(_ id: UUID?) -> Folder? {
        guard let id else { return nil }
        return folders.first { $0.id == id }
    }

    func routine(_ id: UUID?) -> Routine? {
        guard let id else { return nil }
        return routines.first { $0.id == id }
    }

    func subfolders(of parent: UUID?) -> [Folder] {
        folders.filter { $0.parentID == parent }
            .sorted { ($0.sortOrder, $0.name.lowercased()) < ($1.sortOrder, $1.name.lowercased()) }
    }

    func routines(in folder: UUID?) -> [Routine] {
        routines.filter { $0.folderID == folder }
            .sorted { ($0.sortOrder, $0.name.lowercased()) < ($1.sortOrder, $1.name.lowercased()) }
    }

    /// Routines in the folder and all of its subfolders.
    func routineCount(inTree folderID: UUID) -> Int {
        var ids: Set<UUID> = [folderID]
        var frontier = [folderID]
        while let next = frontier.popLast() {
            for child in folders where child.parentID == next && !ids.contains(child.id) {
                ids.insert(child.id)
                frontier.append(child.id)
            }
        }
        return routines.filter { $0.folderID.map(ids.contains) ?? false }.count
    }

    /// Breadcrumb from the top level down to (and including) the folder.
    func path(to folderID: UUID?) -> [Folder] {
        var result: [Folder] = []
        var cursor = folder(folderID)
        var seen = Set<UUID>()
        while let current = cursor, !seen.contains(current.id) {
            result.insert(current, at: 0)
            seen.insert(current.id)
            cursor = folder(current.parentID)
        }
        return result
    }

    /// Folders that `folderID` may be moved into (not itself or its descendants).
    func validDestinations(forFolder folderID: UUID) -> [Folder] {
        var excluded: Set<UUID> = [folderID]
        var frontier = [folderID]
        while let next = frontier.popLast() {
            for child in folders where child.parentID == next {
                excluded.insert(child.id)
                frontier.append(child.id)
            }
        }
        return folders.filter { !excluded.contains($0.id) }
    }

    func search(_ query: String) -> [Routine] {
        let key = ExerciseSearchIndex.normalize(query)
        guard !key.isEmpty else { return [] }
        return routines.filter { ExerciseSearchIndex.normalize($0.name).contains(key) || ExerciseSearchIndex.normalize($0.notes).contains(key) }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    private func nextSortOrder(in folder: UUID?) -> Double {
        let orders = routines(in: folder).map(\.sortOrder) + subfolders(of: folder).map(\.sortOrder)
        return (orders.max() ?? 0) + 1
    }

    // MARK: Routines

    @discardableResult
    func save(_ routine: Routine) -> Bool {
        var copy = routine
        copy.name = copy.name.trimmingCharacters(in: .whitespacesAndNewlines)
        if copy.name.isEmpty { copy.name = "Untitled Routine" }
        copy.updatedAt = Date()
        if self.routine(copy.id) == nil, copy.sortOrder == 0 {
            copy.sortOrder = nextSortOrder(in: copy.folderID)
        }
        do {
            try database.routines.save(copy)
            reload()
            return true
        } catch {
            feedback.report(error, while: "save the routine")
            return false
        }
    }

    @discardableResult
    func duplicate(_ routine: Routine) -> Routine? {
        var copy = routine.duplicated(name: "\(routine.name) Copy")
        copy.sortOrder = routine.sortOrder + 0.5
        guard save(copy) else { return nil }
        feedback.show("Duplicated “\(routine.name)”", style: .success)
        return copy
    }

    func delete(_ routine: Routine) {
        do {
            try database.routines.softDelete(routineID: routine.id)
            reload()
            feedback.show("Moved “\(routine.name)” to Recently Deleted", style: .info)
        } catch {
            feedback.report(error, while: "delete the routine")
        }
    }

    func restore(_ routineID: UUID) {
        do {
            try database.routines.restore(routineID: routineID)
            reload()
        } catch {
            feedback.report(error, while: "restore the routine")
        }
    }

    func purge(_ routineID: UUID) {
        do {
            try database.routines.purge(routineID: routineID)
            reload()
        } catch {
            feedback.report(error, while: "delete the routine")
        }
    }

    func move(_ routineID: UUID, to folderID: UUID?) {
        guard var routine = routine(routineID) else { return }
        routine.folderID = folderID
        routine.sortOrder = nextSortOrder(in: folderID)
        save(routine)
    }

    func markPerformed(_ routineID: UUID, at date: Date) {
        try? database.routines.markPerformed(routineID: routineID, at: date)
        reload()
    }

    /// Persists a new manual order for the items shown in one folder.
    func reorder(_ ids: [UUID]) {
        var orders: [UUID: Double] = [:]
        for (index, id) in ids.enumerated() {
            orders[id] = Double(index + 1)
        }
        do {
            try database.routines.setSortOrders(orders)
            reload()
        } catch {
            feedback.report(error, while: "save the new order")
        }
    }

    // MARK: Folders

    @discardableResult
    func createFolder(name: String, parent: UUID?, colorTag: String? = nil) -> Folder? {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let folder = Folder(parentID: parent, name: trimmed.isEmpty ? "New Folder" : trimmed, colorTag: colorTag, sortOrder: nextSortOrder(in: parent))
        do {
            try database.routines.saveFolder(folder)
            reload()
            return folder
        } catch {
            feedback.report(error, while: "create the folder")
            return nil
        }
    }

    func updateFolder(_ folder: Folder) {
        var copy = folder
        copy.name = copy.name.trimmingCharacters(in: .whitespacesAndNewlines)
        if copy.name.isEmpty { copy.name = "Folder" }
        copy.updatedAt = Date()
        do {
            try database.routines.saveFolder(copy)
            reload()
        } catch {
            feedback.report(error, while: "update the folder")
        }
    }

    func moveFolder(_ folderID: UUID, to parent: UUID?) {
        guard var folder = folder(folderID) else { return }
        folder.parentID = parent
        folder.sortOrder = nextSortOrder(in: parent)
        updateFolder(folder)
    }

    func deleteFolder(_ folderID: UUID, keepContents: Bool) {
        do {
            try database.routines.deleteFolder(id: folderID, mode: keepContents ? .keepContents : .deleteContents)
            reload()
        } catch {
            feedback.report(error, while: "delete the folder")
        }
    }

    // MARK: Editor drafts

    /// The routine editor autosaves its draft here so a crash or force-quit
    /// mid-edit never loses a half-built routine.
    func saveDraft(_ routine: Routine?) {
        try? database.meta.setJSON(MetaRepository.Key.routineDraft, routine)
    }

    func loadDraft() -> Routine? {
        try? database.meta.getJSON(MetaRepository.Key.routineDraft, as: Routine.self)
    }
}
