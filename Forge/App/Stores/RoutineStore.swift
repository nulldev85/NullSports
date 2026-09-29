import SwiftUI

/// Folders and routines (the workout builder's data).
///
/// Changes show immediately (so lists animate on the same frame as the tap)
/// and are saved in the background, in order. If a save fails, the error is
/// reported and the lists are reloaded from what's actually stored.
@MainActor
@Observable
final class RoutineStore {
    private(set) var folders: [Folder] = []
    private(set) var routines: [Routine] = []
    private(set) var deletedRoutines: [Routine] = []
    /// The routine editor's autosaved draft, if one is waiting.
    private(set) var draft: Routine?

    private let database: AppDatabase
    private let feedback: Feedback
    /// Called after routines or folders change.
    @ObservationIgnored var onChange: (() -> Void)?
    @ObservationIgnored private var reloadGeneration = 0

    /// What the store starts with, loaded off the main thread.
    struct Loaded: Sendable {
        var folders: [Folder] = []
        var routines: [Routine] = []
        var deleted: [Routine] = []
        var draft: Routine?
        var error: String?
    }

    nonisolated static func load(from database: AppDatabase) -> Loaded {
        var loaded = Loaded()
        do {
            loaded.folders = try database.routines.folders()
            loaded.routines = try database.routines.routines()
            loaded.deleted = try database.routines.deletedRoutines()
        } catch {
            loaded.error = (error as? LocalizedError)?.errorDescription ?? String(describing: error)
        }
        loaded.draft = try? database.meta.getJSON(MetaRepository.Key.routineDraft, as: Routine.self)
        return loaded
    }

    init(database: AppDatabase, feedback: Feedback, loaded: Loaded) {
        self.database = database
        self.feedback = feedback
        folders = loaded.folders
        routines = loaded.routines
        deletedRoutines = loaded.deleted
        draft = loaded.draft
    }

    /// Reloads from the database in the background (after a restore or
    /// import, or when a save failed).
    func reload() {
        reloadGeneration += 1
        let generation = reloadGeneration
        let database = database
        Task {
            let loaded = await Task.detached(priority: .userInitiated) { Self.load(from: database) }.value
            guard generation == reloadGeneration else { return }
            if let error = loaded.error {
                feedback.show("Couldn't load your routines. \(error)", style: .error, duration: 5)
                return
            }
            withAnimation(Motion.smooth) {
                if folders != loaded.folders { folders = loaded.folders }
                if routines != loaded.routines { routines = loaded.routines }
                if deletedRoutines != loaded.deleted { deletedRoutines = loaded.deleted }
            }
            onChange?()
        }
    }

    /// Saves in the background; on failure, says so and shows what's stored.
    private func persist(_ action: String, _ work: @escaping @Sendable (AppDatabase) throws -> Void) {
        onChange?()
        database.writeInBackground(work) { [weak self] result in
            guard let self, case .failure(let error) = result else { return }
            self.feedback.report(error, while: action)
            self.reload()
        }
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
        let ids = subtree(of: folderID)
        return routines.filter { $0.folderID.map(ids.contains) ?? false }.count
    }

    /// The folder and every folder inside it.
    private func subtree(of folderID: UUID) -> Set<UUID> {
        var ids: Set<UUID> = [folderID]
        var frontier = [folderID]
        while let next = frontier.popLast() {
            for child in folders where child.parentID == next && !ids.contains(child.id) {
                ids.insert(child.id)
                frontier.append(child.id)
            }
        }
        return ids
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
        let excluded = subtree(of: folderID)
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
        if let index = routines.firstIndex(where: { $0.id == copy.id }) {
            routines[index] = copy
        } else {
            if copy.sortOrder == 0 {
                copy.sortOrder = nextSortOrder(in: copy.folderID)
            }
            routines.append(copy)
        }
        let saved = copy
        persist("save the routine") { try $0.routines.save(saved) }
        return true
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
        let now = Date()
        guard let index = routines.firstIndex(where: { $0.id == routine.id }) else { return }
        var removed = routines.remove(at: index)
        removed.deletedAt = now
        removed.updatedAt = now
        deletedRoutines.insert(removed, at: 0)
        feedback.show("Moved “\(routine.name)” to Recently Deleted", style: .info, action: ToastAction(title: "Undo") { [weak self] in
            withAnimation(Motion.smooth) { self?.restore(routine.id) }
        })
        let id = routine.id
        persist("delete the routine") { try $0.routines.softDelete(routineID: id, at: now) }
    }

    func restore(_ routineID: UUID) {
        guard let index = deletedRoutines.firstIndex(where: { $0.id == routineID }) else { return }
        var restored = deletedRoutines.remove(at: index)
        restored.deletedAt = nil
        restored.updatedAt = Date()
        // A routine whose folder is gone returns to the top level.
        if let folderID = restored.folderID, folder(folderID) == nil {
            restored.folderID = nil
        }
        routines.append(restored)
        persist("restore the routine") { try $0.routines.restore(routineID: routineID) }
    }

    func purge(_ routineID: UUID) {
        deletedRoutines.removeAll { $0.id == routineID }
        persist("delete the routine") { try $0.routines.purge(routineID: routineID) }
    }

    func move(_ routineID: UUID, to folderID: UUID?) {
        guard var routine = routine(routineID) else { return }
        routine.folderID = folderID
        routine.sortOrder = nextSortOrder(in: folderID)
        save(routine)
    }

    func markPerformed(_ routineID: UUID, at date: Date) {
        if let index = routines.firstIndex(where: { $0.id == routineID }) {
            let current = routines[index].lastPerformedAt ?? .distantPast
            if date > current { routines[index].lastPerformedAt = date }
        }
        persist("update the routine") { try $0.routines.markPerformed(routineID: routineID, at: date) }
    }

    /// Persists a new manual order for the items shown in one folder.
    func reorder(_ ids: [UUID]) {
        var orders: [UUID: Double] = [:]
        for (index, id) in ids.enumerated() {
            orders[id] = Double(index + 1)
        }
        for index in routines.indices {
            if let order = orders[routines[index].id] { routines[index].sortOrder = order }
        }
        for index in folders.indices {
            if let order = orders[folders[index].id] { folders[index].sortOrder = order }
        }
        let saved = orders
        persist("save the new order") { try $0.routines.setSortOrders(saved) }
    }

    // MARK: Folders

    @discardableResult
    func createFolder(name: String, parent: UUID?, colorTag: String? = nil) -> Folder? {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let folder = Folder(parentID: parent, name: trimmed.isEmpty ? "New Folder" : trimmed, colorTag: colorTag, sortOrder: nextSortOrder(in: parent))
        folders.append(folder)
        persist("create the folder") { try $0.routines.saveFolder(folder) }
        return folder
    }

    func updateFolder(_ folder: Folder) {
        var copy = folder
        copy.name = copy.name.trimmingCharacters(in: .whitespacesAndNewlines)
        if copy.name.isEmpty { copy.name = "Folder" }
        copy.updatedAt = Date()
        // A folder can't go inside its own subtree.
        if let parent = copy.parentID, subtree(of: copy.id).contains(parent) {
            feedback.show("A folder can't be moved inside itself.", style: .warning)
            return
        }
        if let index = folders.firstIndex(where: { $0.id == copy.id }) {
            folders[index] = copy
        } else {
            folders.append(copy)
        }
        let saved = copy
        persist("update the folder") { try $0.routines.saveFolder(saved) }
    }

    func moveFolder(_ folderID: UUID, to parent: UUID?) {
        guard var folder = folder(folderID) else { return }
        folder.parentID = parent
        folder.sortOrder = nextSortOrder(in: parent)
        updateFolder(folder)
    }

    func deleteFolder(_ folderID: UUID, keepContents: Bool) {
        guard let folder = folder(folderID) else { return }
        let now = Date()
        if keepContents {
            // Everything inside moves up one level.
            for index in folders.indices where folders[index].parentID == folderID {
                folders[index].parentID = folder.parentID
            }
            for index in routines.indices where routines[index].folderID == folderID {
                routines[index].folderID = folder.parentID
            }
            folders.removeAll { $0.id == folderID }
        } else {
            // Routines inside go to Recently Deleted; the folders go.
            let ids = subtree(of: folderID)
            let removed = routines.filter { $0.folderID.map(ids.contains) ?? false }
            routines.removeAll { $0.folderID.map(ids.contains) ?? false }
            for var routine in removed {
                routine.deletedAt = now
                deletedRoutines.insert(routine, at: 0)
            }
            folders.removeAll { ids.contains($0.id) }
        }
        let mode: RoutineRepository.FolderDeletion = keepContents ? .keepContents : .deleteContents
        persist("delete the folder") { try $0.routines.deleteFolder(id: folderID, mode: mode, now: now) }
    }

    // MARK: Editor drafts

    /// The routine editor autosaves its draft here so a crash or force-quit
    /// mid-edit never loses a half-built routine.
    func saveDraft(_ routine: Routine?) {
        draft = routine
        database.writeInBackground({ try $0.meta.setJSON(MetaRepository.Key.routineDraft, routine) })
    }

    func loadDraft() -> Routine? {
        draft
    }
}
