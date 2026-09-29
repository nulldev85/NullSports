import SwiftUI
import UniformTypeIdentifiers

enum TrainRoute: Hashable {
    case folder(UUID)
    case routine(UUID)
}

struct TrainView: View {
    @Environment(AppModel.self) private var app
    @State private var path = NavigationPath()

    var body: some View {
        NavigationStack(path: $path) {
            FolderContentsView(folderID: nil)
                .navigationDestination(for: TrainRoute.self) { route in
                    switch route {
                    case .folder(let id):
                        FolderContentsView(folderID: id)
                    case .routine(let id):
                        RoutineDetailView(routineID: id)
                    }
                }
        }
    }
}

/// What the routine editor sheet is editing.
struct RoutineEditorRequest: Identifiable {
    let id = UUID()
    var routine: Routine
    var isNew: Bool
    /// Reopening an autosaved draft: it counts as unsaved changes until the
    /// athlete saves or discards it.
    var isRestoredDraft = false
}

struct FolderContentsView: View {
    let folderID: UUID?
    @Environment(AppModel.self) private var app
    @State private var editor: RoutineEditorRequest?
    @State private var showingNewFolder = false
    @State private var newFolderName = ""
    @State private var renaming: Folder?
    @State private var renameText = ""
    @State private var movingRoutine: Routine?
    @State private var movingFolder: Folder?
    @State private var deletingFolder: Folder?
    @State private var deletingRoutine: Routine?
    @State private var searchText = ""
    @State private var draftToRestore: Routine?
    @State private var choosingBackupFolder = false

    private var isRoot: Bool { folderID == nil }
    private var folder: Folder? { app.routines.folder(folderID) }

    var body: some View {
        let subfolders = app.routines.subfolders(of: folderID)
        let routines = app.routines.routines(in: folderID)
        List {
            if isRoot, searchText.isEmpty {
                Section {
                    QuickStartCard()
                        .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 8, trailing: 16))
                        .listRowBackground(Color.clear)
                }
                if let draft = draftToRestore {
                    Section {
                        DraftBanner(draft: draft) {
                            editor = RoutineEditorRequest(routine: draft, isNew: app.routines.routine(draft.id) == nil, isRestoredDraft: true)
                            withAnimation(Motion.smooth) { draftToRestore = nil }
                        } discard: {
                            app.routines.saveDraft(nil)
                            withAnimation(Motion.smooth) { draftToRestore = nil }
                        }
                    }
                }
                if app.dataSafety.shouldSuggestExternalFolder, app.history.summaries.count >= 3 {
                    Section {
                        BackupFolderCard {
                            choosingBackupFolder = true
                        } snooze: {
                            withAnimation(Motion.smooth) {
                                app.dataSafety.snoozeFolderSuggestion()
                            }
                        }
                    }
                }
            }

            if !searchText.isEmpty {
                let matches = app.routines.search(searchText)
                Section("Routines") {
                    if matches.isEmpty {
                        Text("No routines match “\(searchText)”.")
                            .foregroundStyle(.secondary)
                    }
                    ForEach(matches) { routine in
                        routineRow(routine, showFolder: true)
                    }
                }
            } else {
                Section {
                    ForEach(subfolders) { item in
                        folderRow(item)
                    }
                    .onMove { source, destination in
                        var ids = subfolders.map(\.id)
                        ids.move(fromOffsets: source, toOffset: destination)
                        app.routines.reorder(ids)
                    }
                    ForEach(routines) { routine in
                        routineRow(routine, showFolder: false)
                    }
                    .onMove { source, destination in
                        var ids = routines.map(\.id)
                        ids.move(fromOffsets: source, toOffset: destination)
                        app.routines.reorder(ids)
                    }
                } header: {
                    HStack {
                        Text(isRoot ? "My Routines" : "In this folder")
                        Spacer()
                        Menu {
                            addMenuItems
                        } label: {
                            Label("Add", systemImage: "plus.circle.fill")
                                .labelStyle(.iconOnly)
                                .font(.app(.title3))
                        }
                        .accessibilityIdentifier("addRoutineMenu")
                    }
                    .textCase(nil)
                } footer: {
                    if subfolders.isEmpty, routines.isEmpty {
                        emptyFolderMessage
                    }
                }
            }
        }
        .canvasBackground()
        .listStyle(.insetGrouped)
        .navigationTitle(isRoot ? "Train" : (folder?.name ?? "Folder"))
        .navigationBarTitleDisplayMode(isRoot ? .large : .inline)
        .searchable(text: $searchText, placement: .navigationBarDrawer(displayMode: .automatic), prompt: "Search routines")
        .toolbar {
            ToolbarItemGroup(placement: .topBarTrailing) {
                if !isRoot, let folder {
                    Menu {
                        Button("Rename Folder", systemImage: "pencil") {
                            renameText = folder.name
                            renaming = folder
                        }
                        Button("Move Folder", systemImage: "folder") { movingFolder = folder }
                        Button("Delete Folder", systemImage: "trash", role: .destructive) { deletingFolder = folder }
                    } label: {
                        Image(systemName: "ellipsis.circle")
                    }
                }
                Menu {
                    addMenuItems
                } label: {
                    Image(systemName: "plus")
                }
                .accessibilityIdentifier("addMenuToolbar")
                if !(subfolders.isEmpty && routines.isEmpty) {
                    EditButton()
                }
            }
        }
        .onAppear {
            if isRoot, draftToRestore == nil, editor == nil {
                draftToRestore = app.routines.loadDraft()
            }
        }
        .fileImporter(isPresented: $choosingBackupFolder, allowedContentTypes: [.folder]) { result in
            switch result {
            case .success(let url): app.dataSafety.setExportFolder(url)
            case .failure(let error): app.feedback.report(error, while: "use that folder")
            }
        }
        .sheet(item: $editor) { request in
            RoutineEditorView(request: request)
                .environment(app)
        }
        .sheet(item: $movingRoutine) { routine in
            FolderPickerView(title: "Move “\(routine.name)”", current: routine.folderID, excluded: []) { destination in
                app.routines.move(routine.id, to: destination)
            }
            .environment(app)
        }
        .sheet(item: $movingFolder) { folder in
            FolderPickerView(title: "Move “\(folder.name)”", current: folder.parentID, excluded: excludedDestinations(for: folder)) { destination in
                app.routines.moveFolder(folder.id, to: destination)
            }
            .environment(app)
        }
        .alert("New Folder", isPresented: $showingNewFolder) {
            TextField("Folder name", text: $newFolderName)
            Button("Cancel", role: .cancel) {}
            Button("Create") {
                app.routines.createFolder(name: newFolderName, parent: folderID)
            }
        } message: {
            Text("Folders keep routines organized. They can contain other folders too.")
        }
        .alert("Rename Folder", isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
            TextField("Folder name", text: $renameText)
            Button("Cancel", role: .cancel) { renaming = nil }
            Button("Save") {
                if var folder = renaming {
                    folder.name = renameText
                    app.routines.updateFolder(folder)
                }
                renaming = nil
            }
        }
        .confirmationDialog(
            deletingFolder.map { "Delete “\($0.name)”?" } ?? "",
            isPresented: Binding(get: { deletingFolder != nil }, set: { if !$0 { deletingFolder = nil } }),
            titleVisibility: .visible
        ) {
            if let folder = deletingFolder {
                Button("Delete Folder, Keep Routines") {
                    app.routines.deleteFolder(folder.id, keepContents: true)
                    deletingFolder = nil
                }
                Button("Delete Folder and Routines", role: .destructive) {
                    app.routines.deleteFolder(folder.id, keepContents: false)
                    deletingFolder = nil
                }
            }
            Button("Cancel", role: .cancel) { deletingFolder = nil }
        } message: {
            Text("Routines deleted with a folder go to Recently Deleted for 30 days.")
        }
        .confirmationDialog(
            deletingRoutine.map { "Delete “\($0.name)”?" } ?? "",
            isPresented: Binding(get: { deletingRoutine != nil }, set: { if !$0 { deletingRoutine = nil } }),
            titleVisibility: .visible
        ) {
            if let routine = deletingRoutine {
                Button("Delete Routine", role: .destructive) {
                    app.routines.delete(routine)
                    deletingRoutine = nil
                }
            }
            Button("Cancel", role: .cancel) { deletingRoutine = nil }
        } message: {
            Text("It moves to Recently Deleted, where you can restore it for 30 days. Your workout history isn't affected.")
        }
    }

    @ViewBuilder
    private var addMenuItems: some View {
        Button("New Routine", systemImage: "square.and.pencil") {
            editor = RoutineEditorRequest(routine: Routine(folderID: folderID, name: ""), isNew: true)
        }
        Button("New Folder", systemImage: "folder.badge.plus") {
            newFolderName = ""
            showingNewFolder = true
        }
    }

    private var emptyFolderMessage: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(isRoot ? "Build your first routine" : "This folder is empty")
                .font(.app(.subheadline, .semibold))
                .foregroundStyle(.primary)
            Text("Tap + to create a routine or a folder. Routines can mix straight sets, supersets, and timed blocks like AMRAPs and EMOMs.")
        }
        .padding(.top, 8)
    }

    private func excludedDestinations(for folder: Folder) -> Set<UUID> {
        let valid = Set(app.routines.validDestinations(forFolder: folder.id).map(\.id))
        return Set(app.routines.folders.map(\.id)).subtracting(valid)
    }

    private func folderRow(_ item: Folder) -> some View {
        NavigationLink(value: TrainRoute.folder(item.id)) {
            HStack(spacing: 12) {
                IconBadge(symbol: "folder.fill", color: Theme.tagColor(item.colorTag) ?? .accentColor)
                VStack(alignment: .leading, spacing: 2) {
                    Text(item.name)
                        .font(.app(.body, .semibold))
                    let count = app.routines.routineCount(inTree: item.id)
                    let subCount = app.routines.subfolders(of: item.id).count
                    Text(folderSubtitle(routines: count, folders: subCount))
                        .font(.app(.caption))
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.vertical, 2)
        }
        .accessibilityIdentifier("folder-\(item.name)")
        .swipeActions(edge: .trailing) {
            Button(role: .destructive) { deletingFolder = item } label: { Label("Delete", systemImage: "trash") }
            Button { movingFolder = item } label: { Label("Move", systemImage: "folder") }
                .tint(Theme.lavender)
        }
        .contextMenu {
            Button("Rename", systemImage: "pencil") {
                renameText = item.name
                renaming = item
            }
            Button("Move", systemImage: "folder") { movingFolder = item }
            Menu("Color", systemImage: "paintpalette") {
                Button("None") { var copy = item; copy.colorTag = nil; app.routines.updateFolder(copy) }
                ForEach(Theme.tagColors, id: \.id) { tag in
                    Button(tag.name) { var copy = item; copy.colorTag = tag.id; app.routines.updateFolder(copy) }
                }
            }
            Button("Delete", systemImage: "trash", role: .destructive) { deletingFolder = item }
        }
    }

    private func folderSubtitle(routines: Int, folders: Int) -> String {
        var parts: [String] = []
        parts.append(routines == 1 ? "1 routine" : "\(routines) routines")
        if folders > 0 { parts.append(folders == 1 ? "1 folder" : "\(folders) folders") }
        return parts.joined(separator: " · ")
    }

    private func routineRow(_ routine: Routine, showFolder: Bool) -> some View {
        NavigationLink(value: TrainRoute.routine(routine.id)) {
            RoutineRow(routine: routine, folderName: showFolder ? app.routines.folder(routine.folderID)?.name : nil)
        }
        .accessibilityIdentifier("routine-\(routine.name)")
        .swipeActions(edge: .leading) {
            Button {
                app.session.start(from: routine)
            } label: {
                Label("Start", systemImage: "play.fill")
            }
            .tint(Theme.sage)
        }
        .swipeActions(edge: .trailing) {
            Button(role: .destructive) { deletingRoutine = routine } label: { Label("Delete", systemImage: "trash") }
            Button { movingRoutine = routine } label: { Label("Move", systemImage: "folder") }
                .tint(Theme.lavender)
            Button { app.routines.duplicate(routine) } label: { Label("Duplicate", systemImage: "plus.square.on.square") }
                .tint(.gray)
        }
        .contextMenu {
            Button("Start Workout", systemImage: "play.fill") { app.session.start(from: routine) }
            Button("Edit", systemImage: "pencil") { editor = RoutineEditorRequest(routine: routine, isNew: false) }
            Button("Duplicate", systemImage: "plus.square.on.square") { app.routines.duplicate(routine) }
            Button("Move to Folder", systemImage: "folder") { movingRoutine = routine }
            Button("Delete", systemImage: "trash", role: .destructive) { deletingRoutine = routine }
        }
    }
}

struct RoutineRow: View {
    let routine: Routine
    var folderName: String?
    @Environment(AppModel.self) private var app

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            RoundedRectangle(cornerRadius: 3, style: .continuous)
                .fill(Theme.tagColor(routine.colorTag) ?? Color.accentColor.opacity(0.35))
                .frame(width: 5)
                .padding(.vertical, 2)
            VStack(alignment: .leading, spacing: 4) {
                Text(routine.name)
                    .font(.app(.body, .semibold))
                    .lineLimit(1)
                Text(exerciseSummary)
                    .font(.app(.subheadline))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                HStack(spacing: 8) {
                    if let folderName {
                        Label(folderName, systemImage: "folder")
                    }
                    Text(detailText)
                    if let last = routine.lastPerformedAt {
                        Text("· \(last.relativeDayText)")
                    }
                }
                .font(.app(.caption))
                .foregroundStyle(.tertiary)
                .lineLimit(1)
            }
        }
        .padding(.vertical, 4)
    }

    private var exerciseSummary: String {
        let names = routine.blocks.flatMap { block in
            block.exercises.map { app.library.exercise($0.exerciseID)?.name ?? "Unknown" }
        }
        if names.isEmpty { return "No exercises yet" }
        let shown = names.prefix(4).joined(separator: ", ")
        return names.count > 4 ? "\(shown) +\(names.count - 4) more" : shown
    }

    private var detailText: String {
        var parts = ["\(routine.exerciseCount) exercises"]
        if routine.setCount > 0 { parts.append("\(routine.setCount) sets") }
        let timed = routine.blocks.compactMap { $0.timer?.kind.displayName }
        if !timed.isEmpty { parts.append(timed.joined(separator: ", ")) }
        return parts.joined(separator: " · ")
    }
}

struct QuickStartCard: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            if let workout = app.session.header {
                HStack {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Workout in progress")
                            .font(.num(.caption2, .medium))
                            .tracking(0.9)
                            .textCase(.uppercase)
                            .foregroundStyle(Color.accentColor)
                        Text(workout.name)
                            .font(.app(.title3, .semibold))
                        Text(workout.startedAt, style: .timer)
                            .font(.num(.subheadline))
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                }
                Button {
                    app.session.isPresented = true
                } label: {
                    Label("Resume Workout", systemImage: "play.fill")
                }
                .buttonStyle(PrimaryButtonStyle())
            } else {
                VStack(alignment: .leading, spacing: 4) {
                    Text(greeting)
                        .font(.app(.title3, .semibold))
                    Text(subtitle)
                        .font(.app(.subheadline))
                        .foregroundStyle(.secondary)
                }
                Button {
                    app.session.start()
                } label: {
                    Label("Start Empty Workout", systemImage: "plus")
                }
                .buttonStyle(PrimaryButtonStyle())
                .accessibilityIdentifier("startEmptyWorkout")
            }
        }
        .padding(18)
        .animation(Motion.smooth, value: app.session.isActive)
        .background(
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .fill(Theme.surface)
                .overlay(
                    RoundedRectangle(cornerRadius: 22, style: .continuous)
                        .fill(LinearGradient(
                            colors: [Color.accentColor.opacity(0.16), Color.accentColor.opacity(0.02)],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        ))
                )
        )
    }

    private var greeting: String {
        let hour = Calendar.current.component(.hour, from: Date())
        switch hour {
        case 5..<12: return "Good morning"
        case 12..<17: return "Good afternoon"
        default: return "Good evening"
        }
    }

    private var subtitle: String {
        let calendar = app.settings.calendar
        let thisWeek = app.history.digest.totals(since: Stats.weekStart(of: Date(), calendar: calendar)).workouts
        let goal = app.settings.value.weeklyGoal
        if thisWeek == 0 {
            return "Pick a routine below or start a blank session."
        }
        if goal > 0, thisWeek >= goal {
            return "\(thisWeek) workouts this week — weekly goal reached."
        }
        return "\(thisWeek) of \(goal) workouts this week."
    }
}

struct DraftBanner: View {
    let draft: Routine
    let restore: () -> Void
    let discard: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("Unsaved routine", systemImage: "doc.badge.clock")
                .font(.app(.subheadline, .semibold))
            Text("“\(draft.name.isEmpty ? "Untitled" : draft.name)” was being edited when Forge closed.")
                .font(.app(.subheadline))
                .foregroundStyle(.secondary)
            HStack {
                Button("Keep Editing", action: restore)
                    .buttonStyle(.borderedProminent)
                    .foregroundStyle(Theme.onAccent)
                Button("Discard", role: .destructive, action: discard)
                    .buttonStyle(.bordered)
            }
        }
        .padding(.vertical, 4)
    }
}

/// Suggests keeping backup files outside the app, which matters most for
/// sideloaded installs that may get deleted and reinstalled.
struct BackupFolderCard: View {
    let choose: () -> Void
    let snooze: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("Keep a copy off this iPhone", systemImage: "icloud.and.arrow.up")
                .font(.app(.subheadline, .semibold))
            Text("Forge backs up on this iPhone every day, but those files go if the app is deleted. Choose an iCloud Drive folder and every backup is copied there too.")
                .font(.app(.subheadline))
                .foregroundStyle(.secondary)
            HStack {
                Button("Choose Folder", action: choose)
                    .buttonStyle(.borderedProminent)
                    .foregroundStyle(Theme.onAccent)
                    .accessibilityIdentifier("chooseBackupFolder")
                Button("Not Now", action: snooze)
                    .buttonStyle(.bordered)
            }
        }
        .padding(.vertical, 4)
    }
}

/// Pick a destination folder (or the top level).
struct FolderPickerView: View {
    let title: String
    let current: UUID?
    let excluded: Set<UUID>
    let onPick: (UUID?) -> Void
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                Button {
                    onPick(nil)
                    dismiss()
                } label: {
                    row(name: "Top Level", depth: 0, isCurrent: current == nil, symbol: "tray.full")
                }
                ForEach(flattened(parent: nil, depth: 1), id: \.folder.id) { entry in
                    Button {
                        onPick(entry.folder.id)
                        dismiss()
                    } label: {
                        row(name: entry.folder.name, depth: entry.depth, isCurrent: current == entry.folder.id, symbol: "folder.fill")
                    }
                }
            }
            .canvasBackground()
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
        .presentationDetents([.medium, .large])
    }

    private func flattened(parent: UUID?, depth: Int) -> [(folder: Folder, depth: Int)] {
        app.routines.subfolders(of: parent)
            .filter { !excluded.contains($0.id) }
            .flatMap { [(folder: $0, depth: depth)] + flattened(parent: $0.id, depth: depth + 1) }
    }

    private func row(name: String, depth: Int, isCurrent: Bool, symbol: String) -> some View {
        HStack {
            Image(systemName: symbol)
                .foregroundStyle(Color.accentColor)
            Text(name)
                .foregroundStyle(.primary)
            Spacer()
            if isCurrent {
                Text("Current")
                    .font(.app(.caption))
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.leading, CGFloat(max(0, depth - 1)) * 18)
    }
}
