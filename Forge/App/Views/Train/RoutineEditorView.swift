import SwiftUI

/// The workout builder. Edits a copy of the routine; the copy is autosaved as
/// a draft while editing, so nothing is lost if the app is closed midway.
struct RoutineEditorView: View {
    let request: RoutineEditorRequest
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    @State private var draft: Routine
    @State private var picker: EditorPicker?
    @State private var timedSetup: TimedBlockSetup?
    @State private var confirmDiscard = false
    @State private var draftSaveTask: Task<Void, Never>?
    @FocusState private var nameFocused: Bool

    init(request: RoutineEditorRequest) {
        self.request = request
        _draft = State(initialValue: request.routine)
    }

    enum EditorPicker: Identifiable {
        case addExercises
        case addMovements(UUID)
        case replace(block: UUID, entry: UUID)

        var id: String {
            switch self {
            case .addExercises: return "add"
            case .addMovements(let block): return "movements-\(block)"
            case .replace(let block, let entry): return "replace-\(block)-\(entry)"
            }
        }
    }

    struct TimedBlockSetup: Identifiable {
        let id = UUID()
        var blockID: UUID?
        var config: TimerConfig
    }

    private var hasChanges: Bool { draft != request.routine }

    var body: some View {
        NavigationStack {
            List {
                detailsSection
                ForEach(draft.blocks) { block in
                    EditorBlockSection(
                        block: blockBinding(block.id),
                        index: draft.blocks.firstIndex { $0.id == block.id } ?? 0,
                        blockCount: draft.blocks.count,
                        actions: blockActions(block.id)
                    )
                }
                addSection
            }
            .listStyle(.insetGrouped)
            .navigationTitle(request.isNew ? "New Routine" : "Edit Routine")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        if hasChanges {
                            confirmDiscard = true
                        } else {
                            close()
                        }
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        if app.routines.save(draft) {
                            close()
                        }
                    }
                    .fontWeight(.semibold)
                    .accessibilityIdentifier("saveRoutine")
                }
                ToolbarItemGroup(placement: .keyboard) {
                    Spacer()
                    Button("Done") { dismissKeyboard() }
                }
            }
            .confirmationDialog("Discard your changes?", isPresented: $confirmDiscard, titleVisibility: .visible) {
                Button("Discard Changes", role: .destructive) { close() }
                Button("Keep Editing", role: .cancel) {}
            }
            .sheet(item: $picker) { purpose in
                ExercisePickerView(
                    title: pickerTitle(purpose),
                    allowsMultiple: !isReplace(purpose),
                    offersSuperset: isAddExercises(purpose)
                ) { exercises, superset in
                    handlePicked(exercises, superset: superset, purpose: purpose)
                }
                .environment(app)
            }
            .sheet(item: $timedSetup) { setup in
                TimedBlockSetupView(setup: setup) { config in
                    applyTimedSetup(setup, config: config)
                }
                .environment(app)
            }
            .onChange(of: draft) { _, newValue in
                scheduleDraftSave(newValue)
            }
            .onAppear {
                if request.isNew, draft.name.isEmpty { nameFocused = true }
            }
            .interactiveDismissDisabled(hasChanges)
        }
    }

    // MARK: Sections

    private var detailsSection: some View {
        Section {
            TextField("Routine name", text: $draft.name)
                .font(.title3.weight(.semibold))
                .focused($nameFocused)
                .accessibilityIdentifier("routineNameField")
            TextField("Notes (optional)", text: $draft.notes, axis: .vertical)
                .lineLimit(1...5)
            Picker(selection: $draft.folderID) {
                Text("Top Level").tag(UUID?.none)
                ForEach(folderOptions, id: \.folder.id) { option in
                    Text(String(repeating: "   ", count: option.depth) + option.folder.name)
                        .tag(Optional(option.folder.id))
                }
            } label: {
                Label("Folder", systemImage: "folder")
            }
            ColorTagPicker(selection: $draft.colorTag)
        }
    }

    private var addSection: some View {
        Section {
            Button {
                picker = .addExercises
            } label: {
                Label("Add Exercises", systemImage: "plus.circle.fill")
                    .font(.body.weight(.semibold))
            }
            .accessibilityIdentifier("addExercisesButton")
            Button {
                timedSetup = TimedBlockSetup(blockID: nil, config: .standard(.amrap))
            } label: {
                Label("Add Timed Block (AMRAP, EMOM, Tabata…)", systemImage: "timer")
            }
        } footer: {
            Text("Tip: use a block's menu to link exercises into supersets, set rest times, or reorder.")
        }
    }

    private var folderOptions: [(folder: Folder, depth: Int)] {
        func walk(_ parent: UUID?, _ depth: Int) -> [(folder: Folder, depth: Int)] {
            app.routines.subfolders(of: parent).flatMap { [(folder: $0, depth: depth)] + walk($0.id, depth + 1) }
        }
        return walk(nil, 0)
    }

    // MARK: Bindings & actions

    private func blockBinding(_ id: UUID) -> Binding<RoutineBlock> {
        Binding(
            get: { draft.blocks.first { $0.id == id } ?? RoutineBlock(id: id) },
            set: { newValue in
                if let index = draft.blocks.firstIndex(where: { $0.id == id }) {
                    draft.blocks[index] = newValue
                }
            }
        )
    }

    private func blockActions(_ id: UUID) -> EditorBlockSection.Actions {
        EditorBlockSection.Actions(
            moveUp: { move(id, by: -1) },
            moveDown: { move(id, by: 1) },
            delete: { draft.blocks.removeAll { $0.id == id } },
            mergeWithNext: { merge(id) },
            split: { split(id) },
            addMovements: { picker = .addMovements(id) },
            replace: { entryID in picker = .replace(block: id, entry: entryID) },
            editTimer: {
                if let block = draft.blocks.first(where: { $0.id == id }), let timer = block.timer {
                    timedSetup = TimedBlockSetup(blockID: id, config: timer)
                }
            },
            removeExercise: { entryID in removeExercise(entryID, from: id) }
        )
    }

    private func move(_ id: UUID, by offset: Int) {
        guard let index = draft.blocks.firstIndex(where: { $0.id == id }) else { return }
        let target = index + offset
        guard draft.blocks.indices.contains(target) else { return }
        withAnimation {
            draft.blocks.swapAt(index, target)
        }
    }

    private func merge(_ id: UUID) {
        guard let index = draft.blocks.firstIndex(where: { $0.id == id }), index + 1 < draft.blocks.count,
              !draft.blocks[index].isTimed, !draft.blocks[index + 1].isTimed else { return }
        withAnimation {
            let next = draft.blocks.remove(at: index + 1)
            draft.blocks[index].exercises.append(contentsOf: next.exercises)
        }
    }

    private func split(_ id: UUID) {
        guard let index = draft.blocks.firstIndex(where: { $0.id == id }), draft.blocks[index].exercises.count > 1 else { return }
        withAnimation {
            let block = draft.blocks.remove(at: index)
            let singles = block.exercises.enumerated().map { offset, exercise in
                RoutineBlock(id: offset == 0 ? block.id : UUID(), exercises: [exercise], notes: offset == 0 ? block.notes : "")
            }
            draft.blocks.insert(contentsOf: singles, at: index)
        }
    }

    private func removeExercise(_ entryID: UUID, from blockID: UUID) {
        guard let index = draft.blocks.firstIndex(where: { $0.id == blockID }) else { return }
        withAnimation {
            draft.blocks[index].exercises.removeAll { $0.id == entryID }
            if draft.blocks[index].exercises.isEmpty, !draft.blocks[index].isTimed {
                draft.blocks.remove(at: index)
            }
        }
    }

    private func defaultSets(for exercise: Exercise) -> [RoutineSet] {
        let last = app.history.lastPerformances([exercise.id], excluding: nil)[exercise.id] ?? []
        if !last.isEmpty {
            return last.map { set in
                RoutineSet(kind: set.kind, target: SetTarget(reps: set.reps, weight: set.weight, duration: set.duration, distance: set.distance))
            }
        }
        switch exercise.tracking {
        case .duration, .weightDuration:
            return Array(repeating: RoutineSet(target: SetTarget(duration: 60)), count: 3).map { RoutineSet(kind: $0.kind, target: $0.target) }
        case .distanceDuration, .shortDistance, .weightDistance:
            return [RoutineSet()]
        default:
            return (0..<3).map { _ in RoutineSet(target: SetTarget(reps: 10)) }
        }
    }

    private func handlePicked(_ exercises: [Exercise], superset: Bool, purpose: EditorPicker) {
        guard !exercises.isEmpty else { return }
        switch purpose {
        case .addExercises:
            let entries = exercises.map { RoutineExercise(exerciseID: $0.id, sets: defaultSets(for: $0), restSeconds: app.library.restSeconds(for: $0.id)) }
            withAnimation {
                if superset, entries.count > 1 {
                    draft.blocks.append(RoutineBlock(exercises: entries))
                } else {
                    draft.blocks.append(contentsOf: entries.map { RoutineBlock(exercises: [$0]) })
                }
            }
        case .addMovements(let blockID):
            guard let index = draft.blocks.firstIndex(where: { $0.id == blockID }) else { return }
            let entries = exercises.map { exercise -> RoutineExercise in
                let target: SetTarget
                switch exercise.tracking {
                case .duration, .weightDuration: target = SetTarget(duration: 30)
                case .distanceDuration, .shortDistance, .weightDistance: target = SetTarget(distance: exercise.tracking.usesShortDistance ? 50 : 400)
                default: target = SetTarget(reps: 10)
                }
                return RoutineExercise(exerciseID: exercise.id, sets: [RoutineSet(target: target)])
            }
            draft.blocks[index].exercises.append(contentsOf: entries)
        case .replace(let blockID, let entryID):
            guard let exercise = exercises.first,
                  let blockIndex = draft.blocks.firstIndex(where: { $0.id == blockID }),
                  let entryIndex = draft.blocks[blockIndex].exercises.firstIndex(where: { $0.id == entryID }) else { return }
            draft.blocks[blockIndex].exercises[entryIndex].exerciseID = exercise.id
        }
    }

    private func applyTimedSetup(_ setup: TimedBlockSetup, config: TimerConfig) {
        if let blockID = setup.blockID, let index = draft.blocks.firstIndex(where: { $0.id == blockID }) {
            draft.blocks[index].timer = config
        } else {
            let block = RoutineBlock(exercises: [], timer: config)
            draft.blocks.append(block)
            // Straight on to choosing the movements.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.45) {
                picker = .addMovements(block.id)
            }
        }
    }

    private func pickerTitle(_ purpose: EditorPicker) -> String {
        switch purpose {
        case .addExercises: return "Add Exercises"
        case .addMovements: return "Add Movements"
        case .replace: return "Replace Exercise"
        }
    }

    private func isReplace(_ purpose: EditorPicker) -> Bool {
        if case .replace = purpose { return true }
        return false
    }

    private func isAddExercises(_ purpose: EditorPicker) -> Bool {
        if case .addExercises = purpose { return true }
        return false
    }

    private func scheduleDraftSave(_ routine: Routine) {
        draftSaveTask?.cancel()
        draftSaveTask = Task {
            try? await Task.sleep(nanoseconds: 600_000_000)
            guard !Task.isCancelled else { return }
            app.routines.saveDraft(routine)
        }
    }

    private func close() {
        draftSaveTask?.cancel()
        app.routines.saveDraft(nil)
        dismiss()
    }
}

struct ColorTagPicker: View {
    @Binding var selection: String?

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 10) {
                Button {
                    selection = nil
                } label: {
                    Circle()
                        .strokeBorder(Color.secondary, lineWidth: 1.5)
                        .frame(width: 28, height: 28)
                        .overlay(Image(systemName: "slash.circle").foregroundStyle(.secondary))
                        .overlay(Circle().strokeBorder(Color.primary, lineWidth: selection == nil ? 2 : 0).padding(-4))
                }
                .accessibilityLabel("No color")
                ForEach(Theme.tagColors, id: \.id) { tag in
                    Button {
                        selection = tag.id
                    } label: {
                        Circle()
                            .fill(tag.color)
                            .frame(width: 28, height: 28)
                            .overlay(Circle().strokeBorder(Color.primary, lineWidth: selection == tag.id ? 2 : 0).padding(-4))
                    }
                    .accessibilityLabel(tag.id.capitalized)
                }
            }
            .padding(.vertical, 6)
            .padding(.horizontal, 4)
        }
        .buttonStyle(.plain)
    }
}

/// One block in the editor: straight sets, a superset/circuit, or a timed block.
struct EditorBlockSection: View {
    struct Actions {
        var moveUp: () -> Void
        var moveDown: () -> Void
        var delete: () -> Void
        var mergeWithNext: () -> Void
        var split: () -> Void
        var addMovements: () -> Void
        var replace: (UUID) -> Void
        var editTimer: () -> Void
        var removeExercise: (UUID) -> Void
    }

    @Binding var block: RoutineBlock
    let index: Int
    let blockCount: Int
    let actions: Actions
    @Environment(AppModel.self) private var app

    var body: some View {
        Section {
            if let timer = block.timer {
                TimedBlockEditorHeader(timer: timer, movementCount: block.exercises.count, edit: actions.editTimer, alternate: Binding(
                    get: { block.timer?.alternateMovements ?? false },
                    set: { block.timer?.alternateMovements = $0 }
                ))
            }
            ForEach($block.exercises) { $entry in
                EditorExerciseRows(
                    entry: $entry,
                    isTimed: block.isTimed,
                    isInSuperset: block.exercises.count > 1 && !block.isTimed,
                    replace: { actions.replace(entry.id) },
                    remove: { actions.removeExercise(entry.id) }
                )
            }
            if block.isTimed {
                Button {
                    actions.addMovements()
                } label: {
                    Label(block.exercises.isEmpty ? "Choose Movements" : "Add Movement", systemImage: "plus")
                }
            }
        } header: {
            HStack {
                BlockHeaderLabel(block: block, index: index)
                Spacer()
                blockMenu
            }
        }
    }

    private var blockMenu: some View {
        Menu {
            if block.isTimed {
                Button("Edit Timer", systemImage: "timer", action: actions.editTimer)
            }
            if index > 0 {
                Button("Move Up", systemImage: "arrow.up", action: actions.moveUp)
            }
            if index < blockCount - 1 {
                Button("Move Down", systemImage: "arrow.down", action: actions.moveDown)
            }
            if !block.isTimed {
                if index < blockCount - 1 {
                    Button("Superset with Next", systemImage: "link", action: actions.mergeWithNext)
                }
                if block.exercises.count > 1 {
                    Button("Split Superset", systemImage: "scissors", action: actions.split)
                }
            }
            Divider()
            Button(block.isTimed ? "Delete Block" : "Remove", systemImage: "trash", role: .destructive, action: actions.delete)
        } label: {
            Image(systemName: "ellipsis.circle")
                .font(.body)
        }
        .textCase(nil)
    }
}

struct TimedBlockEditorHeader: View {
    let timer: TimerConfig
    let movementCount: Int
    let edit: () -> Void
    @Binding var alternate: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button(action: edit) {
                HStack {
                    IconBadge(symbol: timer.kind.symbolName)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(timer.summary)
                            .font(.body.weight(.semibold))
                            .foregroundStyle(.primary)
                        Text(totalText)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Text("Edit")
                        .font(.subheadline)
                }
            }
            .buttonStyle(.plain)
            if movementCount > 1, [.emom, .tabata, .intervals, .custom].contains(timer.kind) {
                Toggle("Alternate movements each interval", isOn: $alternate)
                    .font(.subheadline)
            }
        }
    }

    private var totalText: String {
        let program = TimerProgram(config: timer)
        if let work = program.workDuration {
            return "Total \(DurationFormat.clock(work)) · \(timer.kind.tagline)"
        }
        return timer.kind.tagline
    }
}

/// An exercise inside the editor with its set targets.
struct EditorExerciseRows: View {
    @Binding var entry: RoutineExercise
    let isTimed: Bool
    let isInSuperset: Bool
    let replace: () -> Void
    let remove: () -> Void
    @Environment(AppModel.self) private var app
    @State private var showingNotes = false

    var body: some View {
        let exercise = app.library.exercise(entry.exerciseID)
        let tracking = exercise?.tracking ?? .weightReps
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(exercise?.name ?? "Unknown Exercise")
                        .font(.body.weight(.semibold))
                    if !isTimed {
                        Text(restText)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer()
                Menu {
                    if !isTimed {
                        Menu("Rest Timer", systemImage: "timer") {
                            Button("Use Default") { entry.restSeconds = nil }
                            Button("Off") { entry.restSeconds = 0 }
                            ForEach(RestOptions.values, id: \.self) { seconds in
                                Button(DurationFormat.compact(Double(seconds))) { entry.restSeconds = seconds }
                            }
                        }
                    }
                    Button(entry.notes.isEmpty ? "Add Note" : "Edit Note", systemImage: "note.text") { showingNotes = true }
                    Button("Replace Exercise", systemImage: "arrow.triangle.2.circlepath", action: replace)
                    Divider()
                    Button(isInSuperset ? "Remove from Superset" : "Remove Exercise", systemImage: "trash", role: .destructive, action: remove)
                } label: {
                    Image(systemName: "ellipsis")
                        .frame(width: 32, height: 28)
                        .contentShape(Rectangle())
                }
            }
            if showingNotes || !entry.notes.isEmpty {
                TextField("Notes for this exercise", text: $entry.notes, axis: .vertical)
                    .font(.subheadline)
                    .lineLimit(1...4)
            }
            if isTimed {
                timedTarget(tracking)
            } else {
                SetColumnsHeader(tracking: tracking)
                ForEach(Array(entry.sets.indices), id: \.self) { index in
                    if index < entry.sets.count {
                        setRow(index: index, tracking: tracking)
                    }
                }
                Button {
                    addSet()
                } label: {
                    Label("Add Set", systemImage: "plus")
                        .font(.subheadline.weight(.semibold))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 6)
                        .background(Color(.tertiarySystemFill), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.vertical, 6)
    }

    private var restText: String {
        switch entry.restSeconds {
        case .none: return "Rest: default (\(DurationFormat.compact(Double(app.settings.value.defaultRestSeconds))))"
        case .some(0): return "Rest timer off"
        case .some(let seconds): return "Rest \(DurationFormat.compact(Double(seconds)))"
        }
    }

    private func setRow(index: Int, tracking: TrackingType) -> some View {
        let set = entry.sets[index]
        return HStack(spacing: 8) {
            SetKindMenu(kind: set.kind, number: entry.sets.workingNumber(at: index)) { kind in
                if index < entry.sets.count { entry.sets[index].kind = kind }
            } onDelete: {
                if index < entry.sets.count {
                    _ = withAnimation { entry.sets.remove(at: index) }
                }
            }
            Spacer(minLength: 0)
            TrackingFields(
                tracking: tracking,
                weight: targetBinding(index, \.weight),
                reps: targetBinding(index, \.reps),
                duration: targetBinding(index, \.duration),
                distance: targetBinding(index, \.distance),
                repsMax: targetBinding(index, \.repsMax)
            )
        }
    }

    private func timedTarget(_ tracking: TrackingType) -> some View {
        HStack(spacing: 8) {
            Text("Per round")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            Spacer(minLength: 0)
            TrackingFields(
                tracking: tracking,
                weight: targetBinding(0, \.weight),
                reps: targetBinding(0, \.reps),
                duration: targetBinding(0, \.duration),
                distance: targetBinding(0, \.distance)
            )
        }
        .onAppear {
            if entry.sets.isEmpty { entry.sets = [RoutineSet()] }
        }
    }

    private func targetBinding<T>(_ index: Int, _ keyPath: WritableKeyPath<SetTarget, T?>) -> Binding<T?> {
        Binding(
            get: { index < entry.sets.count ? entry.sets[index].target[keyPath: keyPath] : nil },
            set: { newValue in
                if index < entry.sets.count {
                    entry.sets[index].target[keyPath: keyPath] = newValue
                } else if index == 0 {
                    var set = RoutineSet()
                    set.target[keyPath: keyPath] = newValue
                    entry.sets = [set]
                }
            }
        )
    }

    private func addSet() {
        withAnimation {
            if let last = entry.sets.last {
                entry.sets.append(RoutineSet(kind: last.kind == .warmup ? .normal : last.kind, target: last.target))
            } else {
                entry.sets.append(RoutineSet(target: SetTarget(reps: 10)))
            }
        }
    }
}

enum RestOptions {
    static let values = [15, 30, 45, 60, 75, 90, 120, 150, 180, 240, 300]
}

/// Choose and configure a timed block's format.
struct TimedBlockSetupView: View {
    let setup: RoutineEditorView.TimedBlockSetup
    let onDone: (TimerConfig) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var config: TimerConfig

    init(setup: RoutineEditorView.TimedBlockSetup, onDone: @escaping (TimerConfig) -> Void) {
        self.setup = setup
        self.onDone = onDone
        _config = State(initialValue: setup.config)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker("Format", selection: Binding(
                        get: { config.kind },
                        set: { kind in
                            var fresh = TimerConfig.standard(kind)
                            fresh.alternateMovements = config.alternateMovements
                            config = fresh
                        }
                    )) {
                        ForEach(TimerKind.blockKinds) { kind in
                            Label(kind.displayName, systemImage: kind.symbolName).tag(kind)
                        }
                    }
                    .pickerStyle(.navigationLink)
                } footer: {
                    Text(config.kind.tagline)
                }
                TimerConfigForm(config: $config, showsLeadIn: false)
            }
            .navigationTitle(setup.blockID == nil ? "New Timed Block" : "Edit Timer")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(setup.blockID == nil ? "Next" : "Done") {
                        onDone(config.sanitized())
                        dismiss()
                    }
                    .fontWeight(.semibold)
                }
            }
        }
    }
}
