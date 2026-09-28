import SwiftUI

/// Choose one or more exercises. If nothing fits, create a custom exercise
/// right here; it's saved permanently and selected immediately.
struct ExercisePickerView: View {
    let title: String
    let allowsMultiple: Bool
    var offersSuperset = false
    let onDone: ([Exercise], Bool) -> Void

    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    @State private var filter = ExerciseSearchIndex.Filter()
    @State private var scope: LibraryScope = .all
    @State private var selection: [String] = []
    @State private var creating: ExerciseEditorRequest?

    var body: some View {
        NavigationStack {
            let results = exerciseResults
            List {
                if results.isEmpty {
                    Section {
                        VStack(alignment: .leading, spacing: 6) {
                            Text(query.isEmpty ? "Nothing here yet" : "No exercise called “\(query)”")
                                .font(.app(.headline))
                            Text("Create it once and it's saved to your library permanently.")
                                .font(.app(.subheadline))
                                .foregroundStyle(.secondary)
                        }
                        .padding(.vertical, 6)
                    }
                }
                Section {
                    ForEach(results) { exercise in
                        Button {
                            toggle(exercise)
                        } label: {
                            HStack {
                                ExerciseRowLabel(exercise: exercise, isFavorite: app.library.isFavorite(exercise.id))
                                Spacer()
                                selectionIndicator(for: exercise)
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityIdentifier("pick-\(exercise.name)")
                    }
                }
                Section {
                    Button {
                        creating = ExerciseEditorRequest(exercise: nil, prefillName: query)
                    } label: {
                        Label(query.isEmpty ? "Create Custom Exercise" : "Create “\(query)”", systemImage: "plus.circle.fill")
                            .font(.app(.body, .semibold))
                    }
                    .accessibilityIdentifier("createCustomExercise")
                }
            }
            .canvasBackground()
            .listStyle(.plain)
            .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always), prompt: "Search \(app.library.activeCount) exercises")
            .safeAreaInset(edge: .top, spacing: 0) {
                VStack(spacing: 8) {
                    Picker("Scope", selection: $scope) {
                        ForEach(LibraryScope.allCases) { Text($0.rawValue).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .padding(.horizontal, 16)
                    ExerciseFilterBar(filter: $filter)
                }
                .padding(.vertical, 8)
                .background(.bar)
            }
            .safeAreaInset(edge: .bottom, spacing: 0) {
                if allowsMultiple, !selection.isEmpty {
                    addBar
                }
            }
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                if allowsMultiple, !selection.isEmpty {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Add (\(selection.count))") { finish(superset: false) }
                            .fontWeight(.semibold)
                    }
                }
            }
            .sheet(item: $creating) { request in
                ExerciseEditorView(request: request) { saved in
                    if allowsMultiple {
                        if !selection.contains(saved.id) { selection.append(saved.id) }
                        query = ""
                    } else {
                        onDone([saved], false)
                        dismiss()
                    }
                }
                .environment(app)
            }
        }
    }

    private var addBar: some View {
        HStack(spacing: 10) {
            if offersSuperset, selection.count > 1 {
                Button {
                    finish(superset: true)
                } label: {
                    Label("Superset", systemImage: "link")
                }
                .buttonStyle(SecondaryButtonStyle())
            }
            Button {
                finish(superset: false)
            } label: {
                Text(selection.count == 1 ? "Add 1 Exercise" : "Add \(selection.count) Exercises")
            }
            .buttonStyle(PrimaryButtonStyle())
            .accessibilityIdentifier("confirmAddExercises")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(.bar)
    }

    private var exerciseResults: [Exercise] {
        switch scope {
        case .all:
            return app.library.search(query, filter: filter)
        case .favorites:
            return app.library.search(query, filter: filter, favoritesOnly: true)
        case .custom:
            return app.library.search(query, filter: filter, customOnly: true)
        case .recent:
            let matching = Set(app.library.search(query, filter: filter).map(\.id))
            return app.library.recent(limit: 60).filter { matching.contains($0.id) }
        }
    }

    @ViewBuilder
    private func selectionIndicator(for exercise: Exercise) -> some View {
        if let position = selection.firstIndex(of: exercise.id) {
            Text("\(position + 1)")
                .font(.num(.caption, .semibold))
                .foregroundStyle(Theme.onAccent)
                .frame(width: 26, height: 26)
                .background(Circle().fill(Color.accentColor))
        } else if allowsMultiple {
            Circle()
                .strokeBorder(Color.secondary.opacity(0.5), lineWidth: 1.5)
                .frame(width: 26, height: 26)
        }
    }

    private func toggle(_ exercise: Exercise) {
        guard allowsMultiple else {
            onDone([exercise], false)
            dismiss()
            return
        }
        if let index = selection.firstIndex(of: exercise.id) {
            selection.remove(at: index)
        } else {
            selection.append(exercise.id)
        }
    }

    private func finish(superset: Bool) {
        let chosen = selection.compactMap { app.library.exercise($0) }
        onDone(chosen, superset)
        dismiss()
    }
}

struct ExerciseEditorRequest: Identifiable {
    let id = UUID()
    var exercise: Exercise?
    var prefillName: String = ""
}

/// Create or edit a custom exercise.
struct ExerciseEditorView: View {
    let request: ExerciseEditorRequest
    var onSave: (Exercise) -> Void = { _ in }
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    @State private var exercise: Exercise
    @State private var aliasText: String

    init(request: ExerciseEditorRequest, onSave: @escaping (Exercise) -> Void = { _ in }) {
        self.request = request
        self.onSave = onSave
        let initial = request.exercise ?? Exercise(
            id: Exercise.newCustomID(),
            name: request.prefillName.trimmingCharacters(in: .whitespacesAndNewlines),
            primaryMuscle: .chest,
            equipment: .none,
            category: .strength,
            tracking: .weightReps,
            isCustom: true
        )
        _exercise = State(initialValue: initial)
        _aliasText = State(initialValue: initial.aliases.joined(separator: ", "))
    }

    private var isNew: Bool { request.exercise == nil }
    private var trimmedName: String { exercise.name.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var nameTaken: Bool { app.library.isNameTaken(trimmedName, excluding: exercise.id) }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Exercise name", text: $exercise.name)
                        .font(.app(.body, .semibold))
                        .accessibilityIdentifier("customExerciseName")
                    if nameTaken {
                        Label("An exercise with this name already exists.", systemImage: "exclamationmark.triangle.fill")
                            .font(.app(.footnote))
                            .foregroundStyle(Theme.warning)
                    }
                } footer: {
                    Text("Custom exercises are saved permanently in your library and included in every backup.")
                }
                Section("How it's tracked") {
                    Picker("Tracking", selection: $exercise.tracking) {
                        ForEach(TrackingType.allCases) { type in
                            VStack(alignment: .leading) {
                                Text(type.displayName)
                                Text(type.explanation)
                                    .font(.app(.caption))
                                    .foregroundStyle(.secondary)
                            }
                            .tag(type)
                        }
                    }
                    .pickerStyle(.navigationLink)
                    Picker("Equipment", selection: $exercise.equipment) {
                        ForEach(Equipment.allCases) { Text($0.displayName).tag($0) }
                    }
                    Picker("Type", selection: $exercise.category) {
                        ForEach(ExerciseCategory.allCases) { Text($0.displayName).tag($0) }
                    }
                }
                Section("Muscles") {
                    Picker("Primary", selection: $exercise.primaryMuscle) {
                        ForEach(MuscleGroup.allCases) { Text($0.displayName).tag($0) }
                    }
                    NavigationLink {
                        SecondaryMusclePicker(selection: $exercise.secondaryMuscles, primary: exercise.primaryMuscle)
                    } label: {
                        HStack {
                            Text("Secondary")
                            Spacer()
                            Text(exercise.secondaryMuscles.isEmpty ? "None" : exercise.secondaryMuscles.map(\.displayName).joined(separator: ", "))
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                    }
                }
                Section {
                    TextField("Other names (comma separated)", text: $aliasText)
                    TextField("Instructions or cues", text: $exercise.instructions, axis: .vertical)
                        .lineLimit(2...8)
                } header: {
                    Text("Details")
                } footer: {
                    Text("Other names make it easier to find in search.")
                }
            }
            .canvasBackground()
            .navigationTitle(isNew ? "New Exercise" : "Edit Exercise")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { save() }
                        .fontWeight(.semibold)
                        .disabled(trimmedName.isEmpty || nameTaken)
                        .accessibilityIdentifier("saveCustomExercise")
                }
            }
        }
    }

    private func save() {
        var copy = exercise
        copy.secondaryMuscles.removeAll { $0 == copy.primaryMuscle }
        copy.aliases = aliasText.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        if let saved = app.library.saveCustom(copy) {
            onSave(saved)
            dismiss()
        }
    }
}

struct SecondaryMusclePicker: View {
    @Binding var selection: [MuscleGroup]
    let primary: MuscleGroup

    var body: some View {
        List {
            ForEach(MuscleGroup.allCases.filter { $0 != primary }) { muscle in
                Button {
                    if let index = selection.firstIndex(of: muscle) {
                        selection.remove(at: index)
                    } else {
                        selection.append(muscle)
                    }
                } label: {
                    HStack {
                        Text(muscle.displayName)
                            .foregroundStyle(.primary)
                        Spacer()
                        if selection.contains(muscle) {
                            Image(systemName: "checkmark")
                                .foregroundStyle(Color.accentColor)
                        }
                    }
                }
            }
        }
        .canvasBackground()
        .navigationTitle("Secondary Muscles")
    }
}
