import SwiftUI

/// The full-screen workout: the logger while it runs, then, once it's
/// saved, its summary in the same place (the Finish sheet slides away to
/// reveal it), until Done closes the screen.
struct WorkoutScreen: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        @Bindable var session = app.session
        ZStack {
            if let summary = session.finishedSummary {
                WorkoutSummaryView(summary: summary)
                    .transition(.opacity)
            } else {
                WorkoutView()
                    .transition(.opacity)
            }
        }
        .sheet(isPresented: $session.isFinishing) {
            FinishWorkoutView()
                .environment(app)
        }
    }
}

/// The live workout logger.
///
/// Built so typing stays instant: only `WorkoutContent` observes the whole
/// workout, and every exercise and set below it is an equatable view that
/// redraws only when its own values change.
struct WorkoutView: View {
    @Environment(AppModel.self) private var app
    @State private var picker: WorkoutPicker?
    @State private var confirmDiscard = false
    /// A new timed block's format, waiting for the setup sheet to close
    /// before its movements are picked.
    @State private var pendingTimedConfig: TimerConfig?
    @State private var renaming = false
    @State private var nameText = ""
    @State private var addingTimedBlock: RoutineEditorView.TimedBlockSetup?
    @State private var editingTimer: EditingTimer?
    @State private var loggingResult: UUID?
    @State private var showingPlates = false
    @State private var viewingExercise: ExerciseRoute?
    @FocusState private var focusedField: SetFieldID?
    @State private var focusScrollTarget: SetFieldID?

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
                if app.session.workout != nil || app.session.closingWorkout != nil {
                    WorkoutContent(actions: actions, focus: $focusedField, focusScrollTarget: focusScrollTarget)
                } else {
                    Theme.canvas
                }
            }
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button {
                        app.session.saveNow()
                        app.session.isPresented = false
                    } label: {
                        Image(systemName: "chevron.down")
                            .font(.app(.body, .semibold))
                    }
                    .accessibilityLabel("Minimize workout")
                    .accessibilityIdentifier("minimizeWorkout")
                }
                ToolbarItem(placement: .principal) {
                    WorkoutTitle { name in
                        nameText = name
                        renaming = true
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Finish") {
                        dismissKeyboard()
                        app.session.saveNow()
                        app.session.isFinishing = true
                    }
                    .fontWeight(.semibold)
                    .buttonStyle(.borderedProminent)
                    .foregroundStyle(Theme.onAccent)
                    .accessibilityIdentifier("finishWorkout")
                }
                ToolbarItemGroup(placement: .keyboard) {
                    Button {
                        moveFocus(by: -1)
                    } label: {
                        Image(systemName: "chevron.up")
                    }
                    .accessibilityLabel("Previous field")
                    Button {
                        moveFocus(by: 1)
                    } label: {
                        Image(systemName: "chevron.down")
                    }
                    .accessibilityLabel("Next field")
                    Spacer()
                    Button("Done") {
                        focusedField = nil
                        dismissKeyboard()
                    }
                }
            }
            .navigationBarTitleDisplayMode(.inline)
            .stallContext("Workout")
            .safeAreaInset(edge: .bottom, spacing: 0) {
                RestTimerBar()
            }
            .sheet(item: $picker) { purpose in
                pickerSheet(purpose)
            }
            // Picking the movements follows once the setup sheet is fully
            // gone, so one sheet never tries to open over another.
            .sheet(item: $addingTimedBlock, onDismiss: {
                if let config = pendingTimedConfig {
                    pendingTimedConfig = nil
                    picker = .timedMovements(config)
                }
            }) { setup in
                TimedBlockSetupView(setup: setup) { config in
                    pendingTimedConfig = config
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
                    .themed(app.settings, scheme: .dark)
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
            .onAppear {
                if app.settings.value.keepScreenOn { ScreenAwake.hold("workout") }
            }
            .onDisappear {
                ScreenAwake.release("workout")
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

    /// What the rows can ask the screen to present.
    private var actions: WorkoutActions {
        WorkoutActions(
            addExercises: { picker = .add },
            replaceExercise: { picker = .replace($0) },
            showExercise: { viewingExercise = ExerciseRoute(id: $0) },
            addTimedBlock: { addingTimedBlock = RoutineEditorView.TimedBlockSetup(blockID: nil, config: .standard(.amrap)) },
            editTimer: { blockID, config in editingTimer = EditingTimer(blockID: blockID, config: config) },
            logResult: { loggingResult = $0 },
            showPlates: { showingPlates = true },
            discard: { confirmDiscard = true }
        )
    }

    /// Every set input in on-screen order, for keyboard navigation.
    private var focusOrder: [SetFieldID] {
        guard let workout = app.session.workout else { return [] }
        var order: [SetFieldID] = []
        for block in workout.blocks where !block.isTimed {
            for exercise in block.exercises {
                for set in exercise.sets {
                    for field in exercise.tracking.fields {
                        order.append(SetFieldID(setID: set.id, field: field))
                    }
                }
            }
        }
        return order
    }

    private func moveFocus(by offset: Int) {
        let order = focusOrder
        guard let current = focusedField, let index = order.firstIndex(of: current) else { return }
        let target = index + offset
        guard order.indices.contains(target) else { return }
        let next = order[target]
        focusedField = next
        // Lists only create rows that are on screen: scroll the row in, then
        // focus again once its field exists.
        focusScrollTarget = next
        afterDelay(0.2) {
            if focusedField != next { focusedField = next }
        }
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
                withAnimation(Motion.smooth) {
                    app.session.addTimedBlock(config: config, exercises: exercises)
                }
            }
            .environment(app)
        }
    }
}

struct IdentifiedUUID: Identifiable {
    let id: UUID
}

/// Things rows ask the workout screen to present (pickers, sheets, dialogs).
struct WorkoutActions {
    var addExercises: () -> Void
    var replaceExercise: (UUID) -> Void
    var showExercise: (String) -> Void
    var addTimedBlock: () -> Void
    var editTimer: (UUID, TimerConfig) -> Void
    var logResult: (UUID) -> Void
    var showPlates: () -> Void
    var discard: () -> Void
}

/// Name and running clock in the navigation bar. Observes only the
/// workout's header, so typing in a set never redraws it.
private struct WorkoutTitle: View {
    let rename: (String) -> Void
    @Environment(AppModel.self) private var app

    var body: some View {
        if let header = app.session.displayHeader {
            VStack(spacing: 0) {
                Text(header.name)
                    .font(.app(.subheadline, .semibold))
                    .lineLimit(1)
                Text(header.startedAt, style: .timer)
                    .font(.num(.caption))
                    .foregroundStyle(.secondary)
            }
            .contentShape(Rectangle())
            .onTapGesture { rename(header.name) }
        }
    }
}

/// The rows of the workout: the one view that observes every change.
private struct WorkoutContent: View {
    let actions: WorkoutActions
    var focus: FocusState<SetFieldID?>.Binding
    let focusScrollTarget: SetFieldID?
    @Environment(AppModel.self) private var app

    var body: some View {
        // While the screen goes away after finishing or discarding, the
        // workout stays as it was instead of going blank.
        if let workout = app.session.workout ?? app.session.closingWorkout {
            ScrollViewReader { proxy in
                rows(workout)
                    .onChange(of: focusScrollTarget) { _, target in
                        guard let target else { return }
                        withAnimation(Motion.smooth) { proxy.scrollTo(target.setID, anchor: .center) }
                    }
            }
        }
    }

    private func rows(_ workout: Workout) -> some View {
        let session = app.session
        let setTimer = session.setTimer
        return List {
            WorkoutStatsHeader(workout: workout)
                .listRowInsets(EdgeInsets(top: 4, leading: 16, bottom: 4, trailing: 16))
                .listRowBackground(Color.clear)

            if session.saveFailed {
                Label("Changes aren't saved yet. Forge keeps retrying — don't close the workout.", systemImage: "exclamationmark.triangle.fill")
                    .font(.app(.footnote))
                    .foregroundStyle(Theme.warning)
            }

            ForEach(Array(workout.blocks.enumerated()), id: \.element.id) { index, block in
                if block.isTimed {
                    TimedBlockSection(
                        block: block,
                        index: index,
                        isRunning: session.timedBlockID == block.id,
                        run: { session.runTimedBlock(block.id) },
                        logManually: { actions.logResult(block.id) },
                        editTimer: { actions.editTimer(block.id, block.timer ?? .standard(.amrap)) },
                        remove: {
                            withAnimation(Motion.smooth) {
                                session.mutate(immediate: true) { $0.blocks.removeAll { $0.id == block.id } }
                            }
                        },
                        clearResult: { session.clearResult(for: block.id) }
                    )
                    .equatable()
                } else {
                    ForEach(Array(block.exercises.enumerated()), id: \.element.id) { position, entry in
                        LiveExerciseSection(
                            entry: entry,
                            blockID: block.id,
                            blockIndex: index,
                            blockCount: workout.blocks.count,
                            groupSize: block.exercises.count,
                            position: position,
                            previous: session.previous[entry.exerciseID],
                            setTimer: setTimer.flatMap { timer in entry.sets.contains { $0.id == timer.setID } ? timer : nil },
                            focus: focus,
                            replace: { actions.replaceExercise(entry.id) },
                            showDetails: { actions.showExercise(entry.exerciseID) }
                        )
                        .equatable()
                    }
                }
            }

            Section {
                Button(action: actions.addExercises) {
                    Label("Add Exercises", systemImage: "plus.circle.fill")
                        .font(.app(.body, .semibold))
                }
                .accessibilityIdentifier("workoutAddExercises")
                Button(action: actions.addTimedBlock) {
                    Label("Add Timed Block", systemImage: "timer")
                }
                Button(action: actions.showPlates) {
                    Label("Plate Calculator", systemImage: "circle.grid.2x1")
                }
            }

            Section {
                TextField("Workout notes", text: Binding(
                    get: { workout.notes },
                    set: { value in session.mutate { $0.notes = value } }
                ), axis: .vertical)
                .lineLimit(1...5)
            } header: {
                Text("Notes")
            }

            Section {
                Button("Discard Workout", role: .destructive, action: actions.discard)
                    .frame(maxWidth: .infinity)
            }
        }
        .canvasBackground()
        .listStyle(.insetGrouped)
        .scrollDismissesKeyboard(.interactively)
    }
}

/// Live totals at the top of the workout, with a thin bar for sets done.
struct WorkoutStatsHeader: View {
    let workout: Workout
    @Environment(AppModel.self) private var app

    var body: some View {
        let completed = workout.completedWorkingSets.count
        // A timed block's rows are per-round targets until its result is
        // logged, so they only count once it has one.
        let total = workout.blocks
            .filter { !$0.isTimed || $0.result != nil }
            .flatMap(\.exercises)
            .reduce(0) { $0 + $1.sets.filter { $0.kind.isWorking }.count }
        let volume = workout.volume
        HStack(spacing: 10) {
            miniStat(title: "Time") {
                Text(workout.startedAt, style: .timer)
            }
            miniStat(title: "Sets") {
                Text(total == 0 ? "—" : "\(completed)/\(total)")
                    .contentTransition(.numericText(value: Double(completed)))
            }
            // How much is checked off, tucked into the tile's bottom edge.
            .overlay(alignment: .bottom) {
                if total > 0 {
                    SetsProgressBar(fraction: Double(completed) / Double(total), height: 3)
                        .padding(.horizontal, 12)
                        .padding(.bottom, 5)
                }
            }
            miniStat(title: "Volume") {
                Text(app.settings.units.volume(volume))
                    .contentTransition(.numericText(value: volume))
            }
        }
        .animation(Motion.numeric, value: completed)
        .animation(Motion.numeric, value: volume)
    }

    private func miniStat<Value: View>(title: String, @ViewBuilder value: () -> Value) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .eyebrow()
            value()
                .font(.num(size: 17, .medium))
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.7)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }
}

/// How much of the workout is checked off.
struct SetsProgressBar: View {
    let fraction: Double
    var height: CGFloat = 4

    var body: some View {
        let clamped = CGFloat(max(0, min(1, fraction)))
        let minimum: CGFloat = clamped > 0 ? 6 : 0
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule().fill(Theme.fill)
                Capsule()
                    .fill(clamped >= 1 ? Theme.success : Color.accentColor)
                    .frame(width: max(minimum, proxy.size.width * clamped))
            }
        }
        .frame(height: height)
        .animation(Motion.smooth, value: clamped)
        .accessibilityElement()
        .accessibilityLabel("\(Int((fraction * 100).rounded())) percent of sets done")
    }
}

/// One exercise in the live workout: header, sets, add-set button.
struct LiveExerciseSection: View, Equatable {
    let entry: WorkoutExercise
    let blockID: UUID
    let blockIndex: Int
    let blockCount: Int
    /// Exercises in this block (more than one for a superset or circuit).
    let groupSize: Int
    /// This exercise's place within its block.
    let position: Int
    /// Last time's sets for this exercise, for the "previous" column.
    let previous: [WorkoutSet]?
    /// The timer of one of this exercise's sets, while it has one.
    let setTimer: SetTimerState?
    var focus: FocusState<SetFieldID?>.Binding
    let replace: () -> Void
    let showDetails: () -> Void
    @Environment(AppModel.self) private var app
    @State private var editingNotes = false

    /// Closures and the focus binding don't count: they only ever refer to
    /// the same entry and the same screen.
    nonisolated static func == (lhs: LiveExerciseSection, rhs: LiveExerciseSection) -> Bool {
        lhs.entry == rhs.entry
            && lhs.blockID == rhs.blockID
            && lhs.blockIndex == rhs.blockIndex
            && lhs.blockCount == rhs.blockCount
            && lhs.groupSize == rhs.groupSize
            && lhs.position == rhs.position
            && lhs.previous == rhs.previous
            && lhs.setTimer == rhs.setTimer
    }

    private var isSuperset: Bool { groupSize > 1 }

    var body: some View {
        let session = app.session
        Section {
            header
            if editingNotes || !entry.notes.isEmpty {
                TextField("Notes", text: Binding(
                    get: { entry.notes },
                    set: { value in session.mutate { $0.updateExercise(entry.id) { $0.notes = value } } }
                ), axis: .vertical)
                .font(.app(.subheadline))
                .lineLimit(1...4)
            }
            if !entry.sets.isEmpty {
                SetColumnsHeader(tracking: entry.tracking, showsPrevious: true, showsCheck: true)
            }
            let plans = entry.tracking.isTimed ? entry.plannedDurations(previous: previous) : []
            ForEach(Array(entry.sets.enumerated()), id: \.element.id) { index, set in
                LiveSetRow(
                    set: set,
                    number: entry.sets.workingNumber(at: index),
                    tracking: entry.tracking,
                    previous: previous?[safe: index],
                    planned: plans[safe: index] ?? nil,
                    timer: setTimer?.setID == set.id ? setTimer : nil,
                    focus: focus
                )
                .equatable()
            }
            Button {
                withAnimation(Motion.smooth) {
                    session.addSet(to: entry.id)
                }
            } label: {
                Label("Add Set", systemImage: "plus")
                    .font(.app(.subheadline, .semibold))
                    .frame(maxWidth: .infinity)
            }
            .accessibilityIdentifier("addSet-\(entry.name)")
            .sensoryFeedback(.impact(weight: .light), trigger: entry.sets.count)
        } header: {
            if isSuperset {
                HStack(spacing: 6) {
                    Image(systemName: "link")
                    Text(groupSize > 2 ? "Circuit · \(position + 1) of \(groupSize)" : "Superset · \(position + 1) of \(groupSize)")
                }
                .font(.app(.caption, .semibold))
                .foregroundStyle(Color.accentColor)
            }
        }
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            Button(action: showDetails) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(entry.name)
                        .font(.app(.headline))
                        .foregroundStyle(Color.accentColor)
                        .multilineTextAlignment(.leading)
                    Text(restText)
                        .font(.app(.caption))
                        .foregroundStyle(.secondary)
                }
            }
            .buttonStyle(.plain)
            Spacer()
            Menu {
                exerciseMenu
            } label: {
                Image(systemName: "ellipsis.circle")
                    .font(.app(.title3))
                    .frame(width: 36, height: 32)
                    .contentShape(Rectangle())
            }
            .accessibilityLabel("Exercise options")
        }
    }

    @ViewBuilder
    private var exerciseMenu: some View {
        let session = app.session
        Button(entry.notes.isEmpty ? "Add Note" : "Edit Note", systemImage: "note.text") {
            withAnimation(Motion.smooth) { editingNotes = true }
        }
        if entry.tracking == .weightReps {
            Button("Add Warm-up Sets", systemImage: "flame") {
                withAnimation(Motion.smooth) { session.addWarmups(to: entry.id) }
            }
        }
        if let usual = session.usualTracking(of: entry), !usual.isTimed {
            Toggle(isOn: Binding(get: { entry.tracking.isTimed }, set: { session.setTrackedByTime($0, for: entry.id) })) {
                Label("Track by Time", systemImage: "hourglass")
            }
        }
        Menu("Rest Timer", systemImage: "timer") {
            Button("Default (\(DurationFormat.compact(Double(app.settings.value.defaultRestSeconds))))") { session.setRestSeconds(nil, for: entry.id) }
            Button("Off") { session.setRestSeconds(0, for: entry.id) }
            ForEach(RestOptions.values, id: \.self) { seconds in
                Button(DurationFormat.compact(Double(seconds))) { session.setRestSeconds(seconds, for: entry.id) }
            }
        }
        Button("Replace Exercise", systemImage: "arrow.triangle.2.circlepath", action: replace)
        if blockIndex > 0 {
            Button("Move Up", systemImage: "arrow.up") {
                withAnimation(Motion.smooth) { session.moveBlock(blockID, by: -1) }
            }
        }
        if blockIndex < blockCount - 1 {
            Button("Move Down", systemImage: "arrow.down") {
                withAnimation(Motion.smooth) { session.moveBlock(blockID, by: 1) }
            }
            Button("Superset with Next", systemImage: "link") {
                withAnimation(Motion.smooth) { session.mergeWithNext(blockID) }
            }
        }
        if isSuperset {
            Button("Split Superset", systemImage: "scissors") {
                withAnimation(Motion.smooth) { session.splitBlock(blockID) }
            }
        }
        Divider()
        Button("Remove Exercise", systemImage: "trash", role: .destructive) {
            withAnimation(Motion.smooth) { session.removeExercise(entry.id) }
        }
    }

    private var restText: String {
        let seconds = entry.restSeconds ?? app.library.restSeconds(for: entry.exerciseID) ?? app.settings.value.defaultRestSeconds
        if seconds == 0 { return "Rest timer off" }
        if isSuperset, position < groupSize - 1 { return "Rest after the last exercise in the superset" }
        return "Rest \(DurationFormat.compact(Double(seconds)))"
    }
}

struct LiveSetRow: View, Equatable {
    let set: WorkoutSet
    let number: Int
    let tracking: TrackingType
    let previous: WorkoutSet?
    /// For a timed exercise: the time this set is planned for.
    let planned: Double?
    /// This set's countdown, while it has one.
    let timer: SetTimerState?
    var focus: FocusState<SetFieldID?>.Binding
    @Environment(AppModel.self) private var app

    nonisolated static func == (lhs: LiveSetRow, rhs: LiveSetRow) -> Bool {
        lhs.set == rhs.set
            && lhs.number == rhs.number
            && lhs.tracking == rhs.tracking
            && lhs.previous == rhs.previous
            && lhs.planned == rhs.planned
            && lhs.timer == rhs.timer
    }

    var body: some View {
        let session = app.session
        HStack(spacing: 8) {
            SetKindMenu(kind: set.kind, number: number, completed: set.isCompleted, rpe: set.rpe) { kind in
                session.setKind(kind, for: set.id)
            } onDelete: {
                withAnimation(Motion.smooth) { session.removeSet(set.id) }
            } onRPE: { value in
                session.mutate(immediate: true) { workout in
                    workout.updateSet(set.id) { $0.rpe = value }
                }
            }
            if tracking.isTimed {
                // Timed sets count down right beside their number.
                SetTimerPill(
                    planned: planned,
                    timer: timer,
                    completed: set.isCompleted,
                    logged: set.duration,
                    toggle: {
                        // Clear the screen's focus too, so it's never
                        // handed back to a field later.
                        focus.wrappedValue = nil
                        dismissKeyboard()
                        session.toggleSetTimer(set.id)
                    },
                    reset: { session.resetSetTimer() }
                )
                .equatable()
            } else {
                Button {
                    copyPrevious()
                } label: {
                    Text(previousText)
                        .font(.num(.caption))
                        .foregroundStyle(previous == nil ? Color.secondary.opacity(0.5) : Color.secondary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.6)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .buttonStyle(.plain)
                .disabled(previous == nil)
            }
            TrackingFields(
                tracking: tracking,
                weight: field(\.weight),
                reps: field(\.reps),
                duration: field(\.duration),
                distance: field(\.distance),
                placeholder: placeholder,
                completed: set.isCompleted,
                focus: focus,
                setID: set.id
            )
            // The time can't change under a running countdown.
            .disabled(timer != nil)
            Button {
                dismissKeyboard()
                withAnimation(Motion.snappy) {
                    session.toggleCompletion(of: set.id)
                }
            } label: {
                Image(systemName: set.isCompleted ? "checkmark.circle.fill" : "circle")
                    .font(.app(.title2))
                    .foregroundStyle(set.isCompleted ? Theme.success : Color.secondary.opacity(0.5))
                    .contentTransition(.symbolEffect(.replace))
                    .symbolEffect(.bounce, value: set.isCompleted)
                    .frame(width: SetColumn.check, height: 36)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(set.isCompleted ? "Mark set incomplete" : "Complete set")
            .accessibilityIdentifier("completeSet")
            .sensoryFeedback(.success, trigger: set.isCompleted) { old, new in !old && new }
        }
        .listRowBackground(set.isCompleted ? Theme.success.opacity(0.10) : Theme.surface)
        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
            Button(role: .destructive) {
                withAnimation(Motion.smooth) { session.removeSet(set.id) }
            } label: {
                Label("Delete", systemImage: "trash")
            }
        }
    }

    /// A binding to one of this set's values. It reads the value this row
    /// was drawn with, so the fields never observe the whole workout.
    private func field<Value>(_ keyPath: WritableKeyPath<WorkoutSet, Value>) -> Binding<Value> {
        let session = app.session
        let id = set.id
        let current = set[keyPath: keyPath]
        return Binding(
            get: { current },
            set: { newValue in session.updateSet(id) { $0[keyPath: keyPath] = newValue } }
        )
    }

    /// Routine targets first, then last time's numbers, as greyed hints (a
    /// timed set's time is its planned time).
    private var placeholder: SetTarget? {
        var hint: SetTarget?
        if let target = set.target, !target.isEmpty {
            hint = target
        } else if let previous {
            hint = SetTarget(reps: previous.reps, weight: previous.weight, duration: previous.duration, distance: previous.distance)
        }
        if tracking.isTimed, let planned {
            var timed = hint ?? SetTarget()
            timed.duration = planned
            hint = timed
        }
        return hint
    }

    private var previousText: String {
        guard let previous else { return "—" }
        return app.settings.units.setDescription(previous, tracking: tracking)
    }

    private func copyPrevious() {
        guard let previous else { return }
        let tracking = tracking
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

/// Floating countdown at the bottom of the workout: the timed set in
/// progress, or the rest after a set.
struct RestTimerBar: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        let setTimer = app.session.setTimer
        let rest = app.session.rest
        ZStack {
            if let setTimer {
                SetTimerCard(timer: setTimer, title: app.session.setTimerTitle ?? "Timed set")
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            } else if let rest {
                RestTimerCard(rest: rest)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(Motion.smooth, value: setTimer != nil)
        .animation(Motion.smooth, value: rest != nil)
    }
}

/// The rest countdown itself. The digits change once a second and the bar
/// is the only thing redrawn every frame, so it sweeps at the display's full
/// rate without the rest of the card doing any work.
private struct RestTimerCard: View {
    let rest: RestTimerState
    @Environment(AppModel.self) private var app

    var body: some View {
        let session = app.session
        // Ticks aligned to the end time, so each lands exactly as the
        // displayed second changes.
        let start = rest.endsAt.addingTimeInterval(-(max(0, rest.duration).rounded(.up) + 1))
        TimelineView(.periodic(from: start, by: 1)) { context in
            let remaining = rest.remaining(at: context.date)
            let done = remaining <= 0
            let clock = done ? "Go!" : DurationFormat.countdownClock(remaining)
            VStack(spacing: 10) {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(done ? "Rest complete" : "Rest")
                            .font(.num(.caption2, .medium))
                            .tracking(0.9)
                            .textCase(.uppercase)
                            .foregroundStyle(done ? Theme.success : .secondary)
                        Text(clock)
                            .font(.num(size: 30, .semibold))
                            .monospacedDigit()
                            .foregroundStyle(done ? Theme.success : Color.primary)
                            .contentTransition(.numericText(countsDown: true))
                            .animation(Motion.numeric, value: clock)
                            // "Go!" gives one small pulse when the rest ends.
                            .phaseAnimator([1.0, 1.12, 1.0], trigger: done) { content, scale in
                                content.scaleEffect(scale, anchor: .leading)
                            } animation: { _ in
                                .snappy(duration: 0.22)
                            }
                    }
                    Spacer()
                    HStack(spacing: 8) {
                        Button("−15") { session.adjustRest(by: -15) }
                            .buttonStyle(.bordered)
                        Button("+15") { session.adjustRest(by: 15) }
                            .buttonStyle(.bordered)
                        Button(done ? "Done" : "Skip") {
                            withAnimation(Motion.smooth) { session.skipRest() }
                        }
                        .buttonStyle(.borderedProminent)
                        .foregroundStyle(Theme.onAccent)
                        .accessibilityIdentifier("skipRest")
                    }
                    .font(.app(.subheadline, .semibold))
                    .sensoryFeedback(.selection, trigger: rest.duration)
                }
                RestProgressTrack(rest: rest, done: done)
                if !rest.exerciseName.isEmpty, !done {
                    Text("Next: \(rest.exerciseName)")
                        .font(.app(.caption))
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .animation(Motion.smooth, value: done)
        }
        .padding(14)
        .floatingSurface(cornerRadius: 22)
        .padding(.horizontal, 12)
        .padding(.bottom, 6)
    }
}

/// The rest bar, redrawn every frame (and nothing else is).
private struct RestProgressTrack: View {
    let rest: RestTimerState
    let done: Bool

    var body: some View {
        TimelineView(.animation(minimumInterval: AppEnvironment.isUITest ? 0.5 : nil, paused: done)) { context in
            RestProgressBar(progress: done ? 1 : rest.progress(at: context.date), done: done)
        }
        .frame(height: 5)
    }
}

/// The rest countdown's track.
private struct RestProgressBar: View {
    let progress: Double
    let done: Bool

    var body: some View {
        let fraction = CGFloat(max(0, min(1, progress)))
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.primary.opacity(0.1))
                Capsule()
                    .fill(done ? Theme.success : Color.accentColor)
                    .frame(width: max(6, proxy.size.width * fraction))
            }
        }
        .frame(height: 5)
        .accessibilityHidden(true)
    }
}
