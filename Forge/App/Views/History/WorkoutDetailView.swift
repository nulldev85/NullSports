import SwiftUI

struct WorkoutDetailView: View {
    let workoutID: UUID
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    @State private var workout: Workout?
    @State private var editing: Workout?
    @State private var confirmDelete = false
    @State private var savingRoutine = false
    @State private var routineName = ""

    var body: some View {
        Group {
            if let workout {
                content(workout)
            } else {
                ProgressView()
            }
        }
        .task(id: app.history.revision) {
            workout = app.history.workout(workoutID)
        }
    }

    private func content(_ workout: Workout) -> some View {
        let units = app.settings.units
        let records = app.history.records.prs(in: workout.id)
        return List {
            Section {
                VStack(alignment: .leading, spacing: 12) {
                    Text(workout.startedAt.formatted(date: .complete, time: .shortened))
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 4)
                    LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 10) {
                        StatTile(title: "Duration", value: DurationFormat.compact(workout.elapsed()), symbol: "clock")
                        StatTile(title: "Volume", value: units.volume(workout.volume), symbol: "scalemass")
                        StatTile(title: "Sets", value: "\(workout.completedWorkingSets.count)", symbol: "checkmark.circle")
                        StatTile(title: "Records", value: "\(records.count)", symbol: "trophy", tint: Theme.record)
                    }
                    if let rating = workout.rating {
                        HStack(spacing: 2) {
                            ForEach(1...5, id: \.self) { value in
                                Image(systemName: value <= rating ? "star.fill" : "star")
                                    .foregroundStyle(value <= rating ? Color.yellow : Color.secondary)
                            }
                        }
                    }
                    if !workout.notes.isEmpty {
                        Text(workout.notes)
                            .font(.body)
                    }
                }
                .listRowBackground(Color.clear)
                .listRowInsets(EdgeInsets(top: 4, leading: 0, bottom: 4, trailing: 0))
            }

            if !records.isEmpty {
                Section("Personal Records") {
                    ForEach(records) { record in
                        RecordRow(record: record, tracking: workout.allExercises.first { $0.exerciseID == record.exerciseID }?.tracking ?? .weightReps)
                    }
                }
            }

            ForEach(Array(workout.blocks.enumerated()), id: \.element.id) { index, block in
                if let timer = block.timer {
                    Section {
                        HStack {
                            Label(timer.summary, systemImage: timer.kind.symbolName)
                                .font(.body.weight(.semibold))
                            Spacer()
                            if let result = block.result {
                                Text(result.summary(for: timer))
                                    .font(.body.weight(.bold).monospacedDigit())
                            }
                        }
                        ForEach(block.exercises) { exercise in
                            ExerciseSetsSummary(exercise: exercise)
                        }
                    } header: {
                        BlockHeaderLabel(block: block, index: index)
                    }
                } else {
                    Section {
                        ForEach(block.exercises) { exercise in
                            ExerciseSetsSummary(exercise: exercise)
                        }
                    } header: {
                        if block.exercises.count > 1 {
                            BlockHeaderLabel(block: block, index: index)
                        }
                    }
                }
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle(workout.name)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button("Edit Workout", systemImage: "pencil") { editing = workout }
                    if workout.kind == .strength {
                        Button("Save as Routine", systemImage: "square.and.arrow.down") {
                            routineName = workout.name
                            savingRoutine = true
                        }
                    }
                    ShareLink(item: shareText(workout)) {
                        Label("Share Summary", systemImage: "square.and.arrow.up")
                    }
                    Divider()
                    Button("Delete Workout", systemImage: "trash", role: .destructive) { confirmDelete = true }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
            }
        }
        .sheet(item: $editing) { original in
            WorkoutEditorView(original: original) { updated in
                app.history.save(updated)
                self.workout = updated
            }
            .environment(app)
        }
        .alert("Save as Routine", isPresented: $savingRoutine) {
            TextField("Routine name", text: $routineName)
            Button("Cancel", role: .cancel) {}
            Button("Save") {
                let routine = WorkoutFactory.routine(from: workout, name: routineName.isEmpty ? workout.name : routineName)
                if app.routines.save(routine) {
                    app.feedback.show("Saved “\(routine.name)” to your routines", style: .success)
                }
            }
        } message: {
            Text("Creates a routine with these exercises, sets and weights as targets.")
        }
        .confirmationDialog("Delete this workout?", isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("Delete Workout", role: .destructive) {
                app.history.delete(workout.id)
                dismiss()
            }
        } message: {
            Text("It moves to Recently Deleted for 30 days.")
        }
    }

    private func shareText(_ workout: Workout) -> String {
        let units = app.settings.units
        var lines = ["\(workout.name) — \(workout.startedAt.formatted(date: .abbreviated, time: .shortened))"]
        lines.append("\(DurationFormat.compact(workout.elapsed())) · \(units.volume(workout.volume)) · \(workout.completedWorkingSets.count) sets")
        for block in workout.blocks {
            if let timer = block.timer {
                let result = block.result.map { " — " + $0.summary(for: timer) } ?? ""
                lines.append("")
                lines.append("\(timer.summary)\(result)")
            }
            for exercise in block.exercises {
                lines.append("")
                lines.append(exercise.name)
                for set in exercise.sets {
                    let prefix = set.kind.shortLabel.map { "\($0) " } ?? "• "
                    lines.append(prefix + units.setDescription(set, tracking: exercise.tracking))
                }
            }
        }
        if !workout.notes.isEmpty {
            lines.append("")
            lines.append(workout.notes)
        }
        lines.append("")
        lines.append("Logged with Forge")
        return lines.joined(separator: "\n")
    }
}

struct ExerciseSetsSummary: View {
    let exercise: WorkoutExercise
    @Environment(AppModel.self) private var app

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(exercise.name)
                .font(.body.weight(.semibold))
            ForEach(Array(exercise.sets.enumerated()), id: \.element.id) { index, set in
                HStack(spacing: 10) {
                    SetKindBadge(kind: set.kind, number: exercise.sets.workingNumber(at: index), completed: true)
                        .scaleEffect(0.85)
                    Text(app.settings.units.setDescription(set, tracking: exercise.tracking))
                        .font(.subheadline.monospacedDigit())
                    if let rpe = set.rpe {
                        Text("RPE \(NumberFormatting.string(rpe, locale: .current, maxFractionDigits: 1, grouping: false))")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                }
            }
            if !exercise.notes.isEmpty {
                Text(exercise.notes)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .italic()
            }
        }
        .padding(.vertical, 4)
    }
}

/// Edit a finished workout: names, times, and every set.
struct WorkoutEditorView: View {
    let original: Workout
    let onSave: (Workout) -> Void
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    @State private var workout: Workout
    @State private var adding = false
    @State private var confirmDiscard = false

    init(original: Workout, onSave: @escaping (Workout) -> Void) {
        self.original = original
        self.onSave = onSave
        _workout = State(initialValue: original)
    }

    var body: some View {
        NavigationStack {
            List {
                Section("Details") {
                    TextField("Name", text: $workout.name)
                    TextField("Notes", text: $workout.notes, axis: .vertical)
                        .lineLimit(1...5)
                    DatePicker("Started", selection: $workout.startedAt)
                    HStack {
                        Text("Duration")
                        Spacer()
                        DurationField(placeholder: "0:00", seconds: Binding(
                            get: { workout.duration ?? workout.elapsed() },
                            set: { workout.duration = $0 }
                        ), alignment: .trailing)
                        .frame(width: 110)
                    }
                    RatingPicker(rating: $workout.rating)
                }
                ForEach($workout.blocks) { $block in
                    ForEach($block.exercises) { $exercise in
                        Section {
                            EditableSetsList(exercise: $exercise)
                        } header: {
                            HStack {
                                Text(exercise.name)
                                Spacer()
                                Button(role: .destructive) {
                                    let id = exercise.id
                                    workout.removeExercise(id)
                                } label: {
                                    Image(systemName: "trash")
                                }
                            }
                        }
                    }
                }
                Section {
                    Button {
                        adding = true
                    } label: {
                        Label("Add Exercise", systemImage: "plus.circle.fill")
                    }
                }
            }
            .navigationTitle("Edit Workout")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        if workout != original { confirmDiscard = true } else { dismiss() }
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        var updated = workout
                        updated.endedAt = updated.startedAt.addingTimeInterval(updated.duration ?? updated.elapsed())
                        onSave(updated)
                        dismiss()
                    }
                    .fontWeight(.semibold)
                }
                ToolbarItemGroup(placement: .keyboard) {
                    Spacer()
                    Button("Done") { dismissKeyboard() }
                }
            }
            .confirmationDialog("Discard your changes?", isPresented: $confirmDiscard, titleVisibility: .visible) {
                Button("Discard Changes", role: .destructive) { dismiss() }
                Button("Keep Editing", role: .cancel) {}
            }
            .sheet(isPresented: $adding) {
                ExercisePickerView(title: "Add Exercise", allowsMultiple: true) { exercises, _ in
                    for exercise in exercises {
                        let entry = WorkoutExercise(
                            exerciseID: exercise.id,
                            name: exercise.name,
                            tracking: exercise.tracking,
                            sets: [WorkoutSet(isCompleted: true, completedAt: workout.startedAt)]
                        )
                        workout.blocks.append(WorkoutBlock(exercises: [entry]))
                    }
                }
                .environment(app)
            }
            .interactiveDismissDisabled(workout != original)
        }
    }
}

/// Set rows for editing a past workout (every set here counts as done).
struct EditableSetsList: View {
    @Binding var exercise: WorkoutExercise

    var body: some View {
        SetColumnsHeader(tracking: exercise.tracking)
        ForEach(Array(exercise.sets.indices), id: \.self) { index in
            if index < exercise.sets.count {
                HStack(spacing: 8) {
                    SetKindMenu(kind: exercise.sets[index].kind, number: exercise.sets.workingNumber(at: index), completed: true, rpe: exercise.sets[index].rpe) { kind in
                        if index < exercise.sets.count { exercise.sets[index].kind = kind }
                    } onDelete: {
                        if index < exercise.sets.count { exercise.sets.remove(at: index) }
                    } onRPE: { value in
                        if index < exercise.sets.count { exercise.sets[index].rpe = value }
                    }
                    Spacer(minLength: 0)
                    TrackingFields(
                        tracking: exercise.tracking,
                        weight: setBinding(index, \.weight),
                        reps: setBinding(index, \.reps),
                        duration: setBinding(index, \.duration),
                        distance: setBinding(index, \.distance)
                    )
                }
            }
        }
        Button {
            var set = exercise.sets.last ?? WorkoutSet()
            set.id = UUID()
            set.isCompleted = true
            if set.kind == .warmup { set.kind = .normal }
            exercise.sets.append(set)
        } label: {
            Label("Add Set", systemImage: "plus")
                .font(.subheadline.weight(.semibold))
        }
    }

    private func setBinding<T>(_ index: Int, _ keyPath: WritableKeyPath<WorkoutSet, T?>) -> Binding<T?> {
        Binding(
            get: { index < exercise.sets.count ? exercise.sets[index][keyPath: keyPath] : nil },
            set: { newValue in
                if index < exercise.sets.count {
                    exercise.sets[index][keyPath: keyPath] = newValue
                    exercise.sets[index].isCompleted = true
                }
            }
        )
    }
}
