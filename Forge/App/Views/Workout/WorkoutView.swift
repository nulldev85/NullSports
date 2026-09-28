import SwiftUI

/// The live workout logger.
struct WorkoutView: View {
    @Environment(AppModel.self) private var app
    @State private var picker: WorkoutPicker?
    @State private var showingFinish = false
    @State private var confirmDiscard = false
    @State private var renaming = false
    @State private var nameText = ""
    @State private var addingTimedBlock: RoutineEditorView.TimedBlockSetup?
    @State private var editingTimer: EditingTimer?
    @State private var loggingResult: UUID?
    @State private var showingPlates = false
    @State private var viewingExercise: ExerciseRoute?

    enum WorkoutPicker: Identifiable {
        case add
        case replace(UUID)
        case timedMovements(TimerConfig)

        var id: String {
            switch self {
            case .add: return "add"
            case .replace(let id): return "replace-\(id)"
            case .timedMovements: return "timed"
            }
        }
    }

    struct EditingTimer: Identifiable {
        let id = UUID()
        let blockID: UUID
        let config: TimerConfig
    }

    var body: some View {
        @Bindable var session = app.session
        NavigationStack {
            Group {
                if let workout = app.session.workout {
                    workoutList(workout)
                } else {
                    Color(.systemGroupedBackground)
                }
            }
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button {
                        app.session.saveNow()
                        app.session.isPresented = false
                    } label: {
                        Image(systemName: "chevron.down")
                            .font(.body.weight(.semibold))
                    }
                    .accessibilityLabel("Minimize workout")
                    .accessibilityIdentifier("minimizeWorkout")
                }
                ToolbarItem(placement: .principal) {
                    if let workout = app.session.workout {
                        VStack(spacing: 0) {
                            Text(workout.name)
                                .font(.subheadline.weight(.semibold))
                                .lineLimit(1)
                            Text(workout.startedAt, style: .timer)
                                .font(.caption.monospacedDigit())
                                .foregroundStyle(.secondary)
                        }
                        .onTapGesture {
                            nameText = workout.name
                            renaming = true
                        }
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Finish") {
                        dismissKeyboard()
                        app.session.saveNow()
                        showingFinish = true
                    }
                    .fontWeight(.semibold)
                    .buttonStyle(.borderedProminent)
                    .accessibilityIdentifier("finishWorkout")
                }
                ToolbarItemGroup(placement: .keyboard) {
                    Spacer()
                    Button("Done") { dismissKeyboard() }
                }
            }
            .navigationBarTitleDisplayMode(.inline)
            .safeAreaInset(edge: .bottom, spacing: 0) {
                RestTimerBar()
            }
            .sheet(item: $picker) { purpose in
                pickerSheet(purpose)
            }
            .sheet(isPresented: $showingFinish) {
                FinishWorkoutView()
                    .environment(app)
            }
            .sheet(item: $addingTimedBlock) { setup in
                TimedBlockSetupView(setup: setup) { config in
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.45) {
                        picker = .timedMovements(config)
                    }
                }
                .environment(app)
            }
            .sheet(item: $editingTimer) { editing in
                TimedBlockSetupView(setup: RoutineEditorView.TimedBlockSetup(blockID: editing.blockID, config: editing.config)) { config in
                    app.session.updateTimer(config, for: editing.blockID)
                }
                .environment(app)
            }
            .sheet(item: Binding(get: { loggingResult.map { IdentifiedUUID(id: $0) } }, set: { loggingResult = $0?.id })) { item in
                LogResultView(blockID: item.id)
                    .environment(app)
            }
            .sheet(isPresented: $showingPlates) {
                NavigationStack { PlateCalculatorView() }
                    .environment(app)
            }
            .sheet(item: $viewingExercise) { route in
                NavigationStack {
                    ExerciseDetailView(exerciseID: route.id)
                        .toolbar {
                            ToolbarItem(placement: .confirmationAction) {
                                Button("Done") { viewingExercise = nil }
                            }
                        }
                }
                .environment(app)
            }
            .fullScreenCover(isPresented: $session.isTimedRunPresented) {
                WorkoutTimerScreen()
                    .environment(app)
                    .tint(app.settings.accentColor)
            }
            .alert("Rename Workout", isPresented: $renaming) {
                TextField("Workout name", text: $nameText)
                Button("Cancel", role: .cancel) {}
                Button("Save") {
                    let name = nameText.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !name.isEmpty {
                        app.session.mutate(immediate: true) { $0.name = name }
                    }
                }
            }
            .confirmationDialog("Discard this workout?", isPresented: $confirmDiscard, titleVisibility: .visible) {
                Button("Discard Workout", role: .destructive) {
                    app.session.discard()
                }
                Button("Keep Logging", role: .cancel) {}
            } message: {
                Text("If you've logged any sets they'll go to Recently Deleted, so you can still get them back.")
            }
        }
    }

    private func workoutList(_ workout: Workout) -> some View {
        List {
            WorkoutStatsHeader(workout: workout)
                .listRowInsets(EdgeInsets(top: 4, leading: 16, bottom: 4, trailing: 16))
                .listRowBackground(Color.clear)

            if app.session.saveFailed {
                Label("Changes aren't saved yet. Forge keeps retrying — don't close the workout.", systemImage: "exclamationmark.triangle.fill")
                    .font(.footnote)
                    .foregroundStyle(.orange)
            }

            ForEach(Array(workout.blocks.enumerated()), id: \.element.id) { index, block in
                if block.isTimed {
                    TimedBlockSection(
                        block: block,
                        index: index,
                        isRunning: app.session.timedBlockID == block.id,
                        run: { app.session.runTimedBlock(block.id) },
                        logManually: { loggingResult = block.id },
                        editTimer: { editingTimer = EditingTimer(blockID: block.id, config: block.timer ?? .standard(.amrap)) },
                        remove: { app.session.mutate(immediate: true) { $0.blocks.removeAll { $0.id == block.id } } },
                        clearResult: { app.session.clearResult(for: block.id) }
                    )
                } else {
                    ForEach(block.exercises) { entry in
                        LiveExerciseSection(
                            entry: entry,
                            block: block,
                            blockIndex: index,
                            blockCount: workout.blocks.count,
                            replace: { picker = .replace(entry.id) },
                            showDetails: { viewingExercise = ExerciseRoute(id: entry.exerciseID) }
                        )
                    }
                }
            }

            Section {
                Button {
                    picker = .add
                } label: {
                    Label("Add Exercises", systemImage: "plus.circle.fill")
                        .font(.body.weight(.semibold))
                }
                .accessibilityIdentifier("workoutAddExercises")
                Button {
                    addingTimedBlock = RoutineEditorView.TimedBlockSetup(blockID: nil, config: .standard(.amrap))
                } label: {
                    Label("Add Timed Block", systemImage: "timer")
                }
                Button {
                    showingPlates = true
                } label: {
                    Label("Plate Calculator", systemImage: "circle.grid.2x1")
                }
            }

            Section {
                TextField("Workout notes", text: Binding(
                    get: { app.session.workout?.notes ?? "" },
                    set: { value in app.session.mutate { $0.notes = value } }
                ), axis: .vertical)
                .lineLimit(1...5)
            } header: {
                Text("Notes")
            }

            Section {
                Button("Discard Workout", role: .destructive) {
                    confirmDiscard = true
                }
                .frame(maxWidth: .infinity)
            }
        }
        .listStyle(.insetGrouped)
        .scrollDismissesKeyboard(.interactively)
    }

    @ViewBuilder
    private func pickerSheet(_ purpose: WorkoutPicker) -> some View {
        switch purpose {
        case .add:
            ExercisePickerView(title: "Add Exercises", allowsMultiple: true, offersSuperset: true) { exercises, superset in
                app.session.addExercises(exercises, asSuperset: superset)
            }
            .environment(app)
        case .replace(let entryID):
            ExercisePickerView(title: "Replace Exercise", allowsMultiple: false) { exercises, _ in
                if let exercise = exercises.first {
                    app.session.replaceExercise(entryID, with: exercise)
                }
            }
            .environment(app)
        case .timedMovements(let config):
            ExercisePickerView(title: "Movements", allowsMultiple: true) { exercises, _ in
                app.session.addTimedBlock(config: config, exercises: exercises)
            }
            .environment(app)
        }
    }
}

struct IdentifiedUUID: Identifiable {
    let id: UUID
}

/// Live totals at the top of the workout.
struct WorkoutStatsHeader: View {
    let workout: Workout
    @Environment(AppModel.self) private var app

    var body: some View {
        let completed = workout.completedWorkingSets.count
        let total = workout.allExercises.reduce(0) { $0 + $1.sets.filter { $0.kind.isWorking }.count }
        HStack(spacing: 10) {
            miniStat(title: "Time") {
                Text(workout.startedAt, style: .timer)
            }
            miniStat(title: "Sets") {
                Text("\(completed)/\(total)")
            }
            miniStat(title: "Volume") {
                Text(app.settings.units.volume(workout.volume))
            }
        }
    }

    private func miniStat<Value: View>(title: String, @ViewBuilder value: () -> Value) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title.uppercased())
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.secondary)
            value()
                .font(.rounded(17, weight: .bold))
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.7)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }
}

/// One exercise in the live workout: header, sets, add-set button.
struct LiveExerciseSection: View {
    let entry: WorkoutExercise
    let block: WorkoutBlock
    let blockIndex: Int
    let blockCount: Int
    let replace: () -> Void
    let showDetails: () -> Void
    @Environment(AppModel.self) private var app
    @State private var editingNotes = false

    private var isSuperset: Bool { block.exercises.count > 1 }
    private var positionInBlock: Int { block.exercises.firstIndex { $0.id == entry.id } ?? 0 }

    var body: some View {
        Section {
            header
            if editingNotes || !entry.notes.isEmpty {
                TextField("Notes", text: Binding(
                    get: { app.session.workout?.exercise(entry.id)?.notes ?? "" },
                    set: { value in app.session.mutate { $0.updateExercise(entry.id) { $0.notes = value } } }
                ), axis: .vertical)
                .font(.subheadline)
                .lineLimit(1...4)
            }
            if !entry.sets.isEmpty {
                SetColumnsHeader(tracking: entry.tracking, showsPrevious: true, showsCheck: true)
            }
            ForEach(Array(entry.sets.enumerated()), id: \.element.id) { index, set in
                LiveSetRow(
                    set: set,
                    number: entry.sets.workingNumber(at: index),
                    tracking: entry.tracking,
                    previous: app.session.previousSet(for: entry, index: index)
                )
            }
            Button {
                app.session.addSet(to: entry.id)
            } label: {
                Label("Add Set", systemImage: "plus")
                    .font(.subheadline.weight(.semibold))
                    .frame(maxWidth: .infinity)
            }
            .accessibilityIdentifier("addSet-\(entry.name)")
        } header: {
            if isSuperset {
                HStack(spacing: 6) {
                    Image(systemName: "link")
                    Text(block.exercises.count > 2 ? "Circuit · \(positionInBlock + 1) of \(block.exercises.count)" : "Superset · \(positionInBlock + 1) of \(block.exercises.count)")
                }
                .font(.caption.weight(.bold))
                .foregroundStyle(Color.accentColor)
            }
        }
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            Button(action: showDetails) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(entry.name)
                        .font(.headline)
                        .foregroundStyle(Color.accentColor)
                        .multilineTextAlignment(.leading)
                    Text(restText)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .buttonStyle(.plain)
            Spacer()
            Menu {
                exerciseMenu
            } label: {
                Image(systemName: "ellipsis.circle")
                    .font(.title3)
                    .frame(width: 36, height: 32)
                    .contentShape(Rectangle())
            }
            .accessibilityLabel("Exercise options")
        }
    }

    @ViewBuilder
    private var exerciseMenu: some View {
        Button(entry.notes.isEmpty ? "Add Note" : "Edit Note", systemImage: "note.text") { editingNotes = true }
        if entry.tracking == .weightReps {
            Button("Add Warm-up Sets", systemImage: "flame") { app.session.addWarmups(to: entry.id) }
        }
        Menu("Rest Timer", systemImage: "timer") {
            Button("Default (\(DurationFormat.compact(Double(app.settings.value.defaultRestSeconds))))") { app.session.setRestSeconds(nil, for: entry.id) }
            Button("Off") { app.session.setRestSeconds(0, for: entry.id) }
            ForEach(RestOptions.values, id: \.self) { seconds in
                Button(DurationFormat.compact(Double(seconds))) { app.session.setRestSeconds(seconds, for: entry.id) }
            }
        }
        Button("Replace Exercise", systemImage: "arrow.triangle.2.circlepath", action: replace)
        if blockIndex > 0 {
            Button("Move Up", systemImage: "arrow.up") { app.session.moveBlock(block.id, by: -1) }
        }
        if blockIndex < blockCount - 1 {
            Button("Move Down", systemImage: "arrow.down") { app.session.moveBlock(block.id, by: 1) }
            Button("Superset with Next", systemImage: "link") { app.session.mergeWithNext(block.id) }
        }
        if isSuperset {
            Button("Split Superset", systemImage: "scissors") { app.session.splitBlock(block.id) }
        }
        Divider()
        Button("Remove Exercise", systemImage: "trash", role: .destructive) {
            app.session.removeExercise(entry.id)
        }
    }

    private var restText: String {
        let seconds = entry.restSeconds ?? app.library.restSeconds(for: entry.exerciseID) ?? app.settings.value.defaultRestSeconds
        if seconds == 0 { return "Rest timer off" }
        if isSuperset, positionInBlock < block.exercises.count - 1 { return "Rest after the last exercise in the superset" }
        return "Rest \(DurationFormat.compact(Double(seconds)))"
    }
}

struct LiveSetRow: View {
    let set: WorkoutSet
    let number: Int
    let tracking: TrackingType
    let previous: WorkoutSet?
    @Environment(AppModel.self) private var app

    var body: some View {
        let binding = app.session.setBinding(set.id, fallback: set)
        HStack(spacing: 8) {
            SetKindMenu(kind: set.kind, number: number, completed: set.isCompleted) { kind in
                app.session.setKind(kind, for: set.id)
            } onDelete: {
                app.session.removeSet(set.id)
            }
            Button {
                copyPrevious()
            } label: {
                Text(previousText)
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(previous == nil ? Color.secondary.opacity(0.5) : Color.secondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .buttonStyle(.plain)
            .disabled(previous == nil)
            TrackingFields(
                tracking: tracking,
                weight: binding.weight,
                reps: binding.reps,
                duration: binding.duration,
                distance: binding.distance,
                placeholder: placeholder,
                completed: set.isCompleted
            )
            Button {
                dismissKeyboard()
                app.session.toggleCompletion(of: set.id)
            } label: {
                Image(systemName: set.isCompleted ? "checkmark.circle.fill" : "circle")
                    .font(.title2)
                    .foregroundStyle(set.isCompleted ? Color.green : Color.secondary.opacity(0.6))
                    .frame(width: SetColumn.check, height: 36)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(set.isCompleted ? "Mark set incomplete" : "Complete set")
            .accessibilityIdentifier("completeSet")
            .sensoryFeedback(.success, trigger: set.isCompleted) { old, new in !old && new }
        }
        .listRowBackground(set.isCompleted ? Color.green.opacity(0.09) : Color(.secondarySystemGroupedBackground))
        .swipeActions(edge: .trailing) {
            Button(role: .destructive) {
                app.session.removeSet(set.id)
            } label: {
                Label("Delete", systemImage: "trash")
            }
        }
    }

    /// Routine targets first, then last time's numbers, as greyed hints.
    private var placeholder: SetTarget? {
        if let target = set.target, !target.isEmpty { return target }
        guard let previous else { return nil }
        return SetTarget(reps: previous.reps, weight: previous.weight, duration: previous.duration, distance: previous.distance)
    }

    private var previousText: String {
        guard let previous else { return "—" }
        return app.settings.units.setDescription(previous, tracking: tracking)
    }

    private func copyPrevious() {
        guard let previous else { return }
        app.session.mutate { workout in
            workout.updateSet(set.id) { current in
                if tracking.usesWeight { current.weight = previous.weight }
                if tracking.usesReps { current.reps = previous.reps }
                if tracking.usesDuration { current.duration = previous.duration }
                if tracking.usesDistance { current.distance = previous.distance }
            }
        }
    }
}

/// Floating rest countdown at the bottom of the workout.
struct RestTimerBar: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        if let rest = app.session.rest {
            let now = app.session.clock
            let remaining = rest.remaining(at: now)
            let done = remaining <= 0
            VStack(spacing: 8) {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(done ? "Rest complete" : "Rest")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(done ? Color.green : .secondary)
                            .textCase(.uppercase)
                        Text(done ? "Go!" : DurationFormat.countdownClock(remaining))
                            .font(.rounded(30, weight: .bold))
                            .monospacedDigit()
                            .contentTransition(.numericText())
                    }
                    Spacer()
                    HStack(spacing: 8) {
                        Button("−15") { app.session.adjustRest(by: -15) }
                            .buttonStyle(.bordered)
                        Button("+15") { app.session.adjustRest(by: 15) }
                            .buttonStyle(.bordered)
                        Button(done ? "Done" : "Skip") { app.session.skipRest() }
                            .buttonStyle(.borderedProminent)
                            .accessibilityIdentifier("skipRest")
                    }
                    .font(.subheadline.weight(.semibold))
                }
                ProgressView(value: rest.progress(at: now))
                    .tint(done ? .green : .accentColor)
                if !rest.exerciseName.isEmpty, !done {
                    Text("Next: \(rest.exerciseName)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .padding(14)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
            .shadow(color: .black.opacity(0.15), radius: 12, y: 4)
            .padding(.horizontal, 12)
            .padding(.bottom, 6)
            .transition(.move(edge: .bottom).combined(with: .opacity))
        }
    }
}
