import SwiftUI

struct RoutineDetailView: View {
    let routineID: UUID
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    @State private var editor: RoutineEditorRequest?
    @State private var moving = false
    @State private var confirmDelete = false
    /// The routine as last shown, so a delete never flashes an empty screen
    /// while this one slides away.
    @State private var lastShown: Routine?

    var body: some View {
        if let routine = app.routines.routine(routineID) ?? lastShown {
            content(routine)
                .onAppear { lastShown = routine }
                .onChange(of: routine) { _, newValue in lastShown = newValue }
        } else {
            ContentUnavailableView("Routine not found", systemImage: "questionmark.folder", description: Text("It may have been deleted or moved to Recently Deleted."))
        }
    }

    private func content(_ routine: Routine) -> some View {
        List {
            Section {
                VStack(alignment: .leading, spacing: 12) {
                    if !routine.notes.isEmpty {
                        Text(routine.notes)
                            .font(.app(.subheadline))
                            .foregroundStyle(.secondary)
                    }
                    HStack(spacing: 10) {
                        Pill(text: "\(routine.exerciseCount) exercises", color: .accentColor)
                        if routine.setCount > 0 {
                            Pill(text: "\(routine.setCount) sets", color: .accentColor)
                        }
                        if let folder = app.routines.folder(routine.folderID) {
                            Pill(text: folder.name, color: .secondary)
                        }
                    }
                    if let last = app.history.lastDone(routine.id) {
                        Label("Last done \(last.relativeDayText)", systemImage: "clock.arrow.circlepath")
                            .font(.app(.caption))
                            .foregroundStyle(.secondary)
                    }
                    Button {
                        app.session.start(from: routine)
                    } label: {
                        Label(app.session.isActive ? "Resume Current Workout" : "Start Workout", systemImage: "play.fill")
                    }
                    .buttonStyle(PrimaryButtonStyle())
                    .accessibilityIdentifier("startRoutineWorkout")
                }
                .padding(.vertical, 6)
            }

            if routine.blocks.isEmpty {
                Section {
                    Text("This routine has no exercises yet. Tap Edit to add some.")
                        .foregroundStyle(.secondary)
                }
            }

            ForEach(Array(routine.blocks.enumerated()), id: \.element.id) { index, block in
                Section {
                    ForEach(block.exercises) { entry in
                        RoutineExerciseSummaryRow(entry: entry, isTimed: block.isTimed)
                    }
                } header: {
                    BlockHeaderLabel(block: block, index: index)
                } footer: {
                    if !block.notes.isEmpty {
                        Text(block.notes)
                    }
                }
            }

            let recent = app.history.summaries.filter { $0.routineID == routine.id }.prefix(5)
            if !recent.isEmpty {
                Section("Recent Sessions") {
                    ForEach(Array(recent)) { summary in
                        NavigationLink {
                            WorkoutDetailView(workoutID: summary.id)
                        } label: {
                            HStack {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(summary.startedAt.formatted(date: .abbreviated, time: .shortened))
                                        .font(.app(.subheadline, .medium))
                                    Text("\(DurationFormat.compact(summary.duration)) · \(summary.setCount) sets")
                                        .font(.app(.caption))
                                        .foregroundStyle(.secondary)
                                }
                                Spacer()
                                if summary.volume > 0 {
                                    Text(app.settings.units.volume(summary.volume))
                                        .font(.num(.caption))
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                }
            }
        }
        .canvasBackground()
        .listStyle(.insetGrouped)
        .navigationTitle(routine.name)
        .stallContext("Routine")
        .navigationBarTitleDisplayMode(.large)
        .toolbar {
            ToolbarItemGroup(placement: .topBarTrailing) {
                Button("Edit") {
                    editor = RoutineEditorRequest(routine: routine, isNew: false)
                }
                .accessibilityIdentifier("editRoutine")
                Menu {
                    Button("Duplicate", systemImage: "plus.square.on.square") { app.routines.duplicate(routine) }
                    Button("Move to Folder", systemImage: "folder") { moving = true }
                    Button("Delete", systemImage: "trash", role: .destructive) { confirmDelete = true }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
            }
        }
        .sheet(item: $editor) { request in
            RoutineEditorView(request: request)
                .environment(app)
        }
        .sheet(isPresented: $moving) {
            FolderPickerView(title: "Move “\(routine.name)”", current: routine.folderID, excluded: []) { destination in
                app.routines.move(routine.id, to: destination)
            }
            .environment(app)
        }
        .confirmationDialog("Delete “\(routine.name)”?", isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("Delete Routine", role: .destructive) {
                dismiss()
                app.routines.delete(routine)
            }
        } message: {
            Text("It moves to Recently Deleted for 30 days. Past workouts aren't affected.")
        }
    }
}

struct BlockHeaderLabel: View {
    let block: RoutineBlockDisplay
    let index: Int

    init(block: RoutineBlock, index: Int) {
        self.block = RoutineBlockDisplay(timer: block.timer, exerciseCount: block.exercises.count)
        self.index = index
    }

    init(block: WorkoutBlock, index: Int) {
        self.block = RoutineBlockDisplay(timer: block.timer, exerciseCount: block.exercises.count)
        self.index = index
    }

    var body: some View {
        HStack(spacing: 6) {
            if let timer = block.timer {
                Image(systemName: timer.kind.symbolName)
                Text(timer.summary)
            } else if block.exerciseCount > 1 {
                Image(systemName: "link")
                Text(block.exerciseCount > 2 ? "Circuit" : "Superset")
            } else {
                Text("Exercise \(index + 1)")
            }
        }
        .font(.num(.caption2, .medium))
        .tracking(0.9)
        .foregroundStyle(block.timer != nil || block.exerciseCount > 1 ? Color.accentColor : .secondary)
        .textCase(.uppercase)
    }
}

struct RoutineBlockDisplay {
    var timer: TimerConfig?
    var exerciseCount: Int
}

struct RoutineExerciseSummaryRow: View {
    let entry: RoutineExercise
    let isTimed: Bool
    @Environment(AppModel.self) private var app

    var body: some View {
        let exercise = app.library.exercise(entry.exerciseID)
        let tracking = entry.tracking(base: exercise?.tracking ?? .weightReps)
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(exercise?.name ?? "Unknown Exercise")
                    .font(.app(.body, .semibold))
                Spacer()
                if let rest = entry.restSeconds, !isTimed {
                    Label(DurationFormat.compact(Double(rest)), systemImage: "timer")
                        .font(.app(.caption))
                        .foregroundStyle(.secondary)
                }
            }
            if isTimed {
                Text(TargetFormatter.describe(entry.sets.first?.target, tracking: tracking, units: app.settings.units))
                    .font(.app(.subheadline))
                    .foregroundStyle(.secondary)
            } else {
                ForEach(Array(entry.sets.enumerated()), id: \.element.id) { index, set in
                    HStack(spacing: 10) {
                        SetKindBadge(kind: set.kind, number: entry.sets.workingNumber(at: index))
                            .scaleEffect(0.85)
                        Text(TargetFormatter.describe(set.target, tracking: tracking, units: app.settings.units))
                            .font(.num(.subheadline))
                            .foregroundStyle(.secondary)
                    }
                }
            }
            if !entry.notes.isEmpty {
                Text(entry.notes)
                    .font(.app(.caption))
                    .foregroundStyle(.secondary)
                    .italic()
            }
        }
        .padding(.vertical, 4)
    }
}
