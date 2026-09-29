import Charts
import SwiftUI

struct ExerciseRoute: Hashable, Identifiable {
    let id: String
}

struct ExerciseLibraryView: View {
    @Environment(AppModel.self) private var app
    @State private var query = ""
    @State private var filter = ExerciseSearchIndex.Filter()
    @State private var scope: LibraryScope = .all
    @State private var creating: ExerciseEditorRequest?

    var body: some View {
        NavigationStack {
            let results = exerciseResults
            List {
                if results.isEmpty {
                    ContentUnavailableView {
                        Label(query.isEmpty ? "No exercises" : "No results", systemImage: "magnifyingglass")
                    } description: {
                        Text(scope == .favorites ? "Tap the star on any exercise to add it to your favorites." : "Try a different search, or create your own exercise.")
                    } actions: {
                        Button("Create Exercise") {
                            creating = ExerciseEditorRequest(exercise: nil, prefillName: query)
                        }
                        .buttonStyle(.borderedProminent)
                        .foregroundStyle(Theme.onAccent)
                    }
                    .listRowBackground(Color.clear)
                }
                ForEach(results) { exercise in
                    NavigationLink(value: ExerciseRoute(id: exercise.id)) {
                        ExerciseRowLabel(exercise: exercise, isFavorite: app.library.isFavorite(exercise.id), detail: detail(for: exercise))
                    }
                    .accessibilityIdentifier("exercise-\(exercise.name)")
                    .swipeActions(edge: .trailing) {
                        Button {
                            app.library.toggleFavorite(exercise.id)
                        } label: {
                            Label("Favorite", systemImage: app.library.isFavorite(exercise.id) ? "star.slash" : "star")
                        }
                        .tint(Theme.sand)
                    }
                }
            }
            .canvasBackground()
            .listStyle(.plain)
            .navigationTitle("Exercises")
            .stallContext("Exercises")
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
                // Stays below the navigation bar so it never covers the title.
                .background(Theme.canvas, ignoresSafeAreaEdges: [])
            }
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        creating = ExerciseEditorRequest(exercise: nil, prefillName: query)
                    } label: {
                        Image(systemName: "plus")
                    }
                    .accessibilityLabel("Create exercise")
                }
            }
            .navigationDestination(for: ExerciseRoute.self) { route in
                ExerciseDetailView(exerciseID: route.id)
            }
            .sheet(item: $creating) { request in
                ExerciseEditorView(request: request)
                    .environment(app)
            }
        }
    }

    private var exerciseResults: [Exercise] {
        switch scope {
        case .all: return app.library.search(query, filter: filter)
        case .favorites: return app.library.search(query, filter: filter, favoritesOnly: true)
        case .custom: return app.library.search(query, filter: filter, customOnly: true)
        case .recent:
            let matching = Set(app.library.search(query, filter: filter).map(\.id))
            return app.library.recent(limit: 100).filter { matching.contains($0.id) }
        }
    }

    private func detail(for exercise: Exercise) -> String {
        var text = "\(exercise.primaryMuscle.displayName) · \(exercise.equipment.displayName)"
        if let uses = app.library.usageCounts[exercise.id], uses > 0 {
            text += " · \(uses)×"
        }
        return text
    }
}

struct ExerciseDetailView: View {
    let exerciseID: String
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @State private var tab: DetailTab = .summary
    @State private var metric: ExerciseMetric?
    @State private var sessions: [ExerciseSession] = []
    @State private var editing: ExerciseEditorRequest?
    @State private var confirmArchive = false
    @State private var note = ""
    @State private var loaded = false
    @State private var noteSaveTask: Task<Void, Never>?

    enum DetailTab: String, CaseIterable, Identifiable {
        case summary = "Summary"
        case history = "History"
        case records = "Records"
        var id: String { rawValue }
    }

    var body: some View {
        if let exercise = app.library.exercise(exerciseID) {
            content(exercise)
        } else {
            ContentUnavailableView("Exercise not found", systemImage: "questionmark.circle")
        }
    }

    private func content(_ exercise: Exercise) -> some View {
        List {
            Section {
                VStack(alignment: .leading, spacing: 10) {
                    HStack(spacing: 6) {
                        Pill(text: exercise.primaryMuscle.displayName, color: Theme.color(for: exercise.primaryMuscle), filled: true)
                        ForEach(exercise.secondaryMuscles.prefix(3)) { muscle in
                            Pill(text: muscle.displayName, color: Theme.color(for: muscle))
                        }
                    }
                    HStack(spacing: 14) {
                        Label(exercise.equipment.displayName, systemImage: "wrench.and.screwdriver")
                        Label(exercise.category.displayName, systemImage: Theme.symbol(for: exercise.category))
                    }
                    .font(.app(.subheadline))
                    .foregroundStyle(.secondary)
                    Text("Tracked as \(exercise.tracking.displayName.lowercased())")
                        .font(.app(.caption))
                        .foregroundStyle(.tertiary)
                    if !exercise.aliases.isEmpty {
                        Text("Also called: \(exercise.aliases.joined(separator: ", "))")
                            .font(.app(.caption))
                            .foregroundStyle(.tertiary)
                    }
                }
                .padding(.vertical, 4)
                Picker("View", selection: $tab) {
                    ForEach(DetailTab.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .listRowSeparator(.hidden)
            }

            switch tab {
            case .summary:
                summarySection(exercise)
                notesSection(exercise)
            case .history:
                historySection(exercise)
            case .records:
                recordsSection(exercise)
            }

            if exercise.isCustom {
                Section {
                    Button("Edit Exercise", systemImage: "pencil") {
                        editing = ExerciseEditorRequest(exercise: exercise)
                    }
                    Button(exercise.isArchived ? "Restore Exercise" : "Archive Exercise", systemImage: exercise.isArchived ? "tray.and.arrow.up" : "archivebox", role: exercise.isArchived ? nil : .destructive) {
                        if exercise.isArchived {
                            app.library.unarchive(exercise.id)
                        } else {
                            confirmArchive = true
                        }
                    }
                } footer: {
                    Text("Archiving hides a custom exercise from your library but keeps every workout that used it.")
                }
            }
        }
        .canvasBackground()
        .listStyle(.insetGrouped)
        .navigationTitle(exercise.name)
        .stallContext("Exercise detail")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    app.library.toggleFavorite(exercise.id)
                } label: {
                    Image(systemName: app.library.isFavorite(exercise.id) ? "star.fill" : "star")
                        .foregroundStyle(app.library.isFavorite(exercise.id) ? Theme.sand : Color.accentColor)
                }
                .accessibilityLabel("Favorite")
            }
        }
        // Loaded before the first frame, so pushing this screen never shows
        // an empty state that then fills in.
        .onAppear {
            if !loaded { load(exercise) }
        }
        .onChange(of: app.history.revision) { _, _ in
            sessions = app.history.sessions(for: exercise.id)
        }
        .sheet(item: $editing) { request in
            ExerciseEditorView(request: request)
                .environment(app)
        }
        .confirmationDialog("Archive “\(exercise.name)”?", isPresented: $confirmArchive, titleVisibility: .visible) {
            Button("Archive", role: .destructive) {
                app.library.archive(exercise.id)
                dismiss()
            }
        } message: {
            Text("It disappears from the library but all history is kept. You can restore it from Settings › Archived Exercises.")
        }
    }

    private func saveNote(for id: String) {
        noteSaveTask?.cancel()
        guard loaded, note != app.library.note(for: id) else { return }
        app.library.setNote(note, for: id)
    }

    private func load(_ exercise: Exercise) {
        loaded = true
        sessions = app.history.sessions(for: exercise.id)
        if metric == nil { metric = ExerciseMetric.metrics(for: exercise.tracking).first }
        note = app.library.note(for: exercise.id)
    }

    @ViewBuilder
    private func summarySection(_ exercise: Exercise) -> some View {
        let metrics = ExerciseMetric.metrics(for: exercise.tracking)
        let selected = metric ?? metrics.first ?? .maxReps
        let points = Stats.series(sessions, metric: selected)
        Section {
            if sessions.isEmpty {
                Text("Log this exercise in a workout to see progress charts and records here.")
                    .foregroundStyle(.secondary)
                    .padding(.vertical, 8)
            } else {
                Picker("Metric", selection: Binding(get: { selected }, set: { value in
                    withAnimation(Motion.smooth) { metric = value }
                })) {
                    ForEach(metrics) { Text($0.displayName).tag($0) }
                }
                .pickerStyle(.segmented)
                .sensoryFeedback(.selection, trigger: selected)
                if points.count >= 1 {
                    ProgressChart(points: points, metric: selected, tracking: exercise.tracking)
                        .frame(height: 200)
                        .padding(.vertical, 6)
                }
                HStack(spacing: 12) {
                    StatTile(title: "Sessions", value: "\(sessions.count)")
                    StatTile(title: "Last", value: sessions.first.map { $0.date.relativeDayText } ?? "—")
                }
                .listRowInsets(EdgeInsets())
                .listRowBackground(Color.clear)
            }
        } header: {
            Text("Progress")
        }
    }

    private func notesSection(_ exercise: Exercise) -> some View {
        Section {
            TextField("Personal notes, cues, seat height…", text: $note, axis: .vertical)
                .lineLimit(1...6)
                .onSubmit { saveNote(for: exercise.id) }
                .onChange(of: note) { _, _ in
                    // Saved after a pause in typing, not on every keystroke.
                    noteSaveTask?.cancel()
                    noteSaveTask = Task {
                        try? await Task.sleep(nanoseconds: 500_000_000)
                        guard !Task.isCancelled else { return }
                        saveNote(for: exercise.id)
                    }
                }
                .onDisappear { saveNote(for: exercise.id) }
                .onChange(of: scenePhase) { _, phase in
                    if phase != .active { saveNote(for: exercise.id) }
                }
            Picker("Default Rest", selection: Binding(
                get: { app.library.restSeconds(for: exercise.id) ?? -1 },
                set: { app.library.setRestSeconds($0 < 0 ? nil : $0, for: exercise.id) }
            )) {
                Text("App default").tag(-1)
                Text("Off").tag(0)
                ForEach(RestOptions.values, id: \.self) { Text(DurationFormat.compact(Double($0))).tag($0) }
            }
            if !exercise.instructions.isEmpty {
                Text(exercise.instructions)
                    .font(.app(.subheadline))
                    .foregroundStyle(.secondary)
            }
        } header: {
            Text("Notes")
        }
    }

    @ViewBuilder
    private func historySection(_ exercise: Exercise) -> some View {
        if sessions.isEmpty {
            Section {
                Text("No history yet.")
                    .foregroundStyle(.secondary)
            }
        } else {
            ForEach(sessions) { session in
                Section {
                    ForEach(Array(session.sets.enumerated()), id: \.element.id) { index, set in
                        HStack {
                            SetKindBadge(kind: set.kind, number: session.sets.workingNumber(at: index), completed: true)
                            Text(app.settings.units.setDescription(set, tracking: session.tracking))
                                .font(.num(.subheadline))
                            Spacer()
                            if session.tracking == .weightReps, let weight = set.weight, let reps = set.reps, let estimate = OneRepMax.estimate(weight: weight, reps: reps), set.kind.isWorking {
                                Text("1RM \(app.settings.units.weight(estimate))")
                                    .font(.app(.caption))
                                    .foregroundStyle(.tertiary)
                            }
                        }
                    }
                    if !session.notes.isEmpty {
                        Text(session.notes)
                            .font(.app(.caption))
                            .foregroundStyle(.secondary)
                    }
                } header: {
                    NavigationLink {
                        WorkoutDetailView(workoutID: session.workoutID)
                    } label: {
                        HStack {
                            Text(session.date.formatted(date: .abbreviated, time: .omitted))
                            Text("· \(session.workoutName)")
                                .lineLimit(1)
                            Spacer()
                            Image(systemName: "chevron.right")
                        }
                        .font(.app(.caption, .semibold))
                    }
                    .textCase(nil)
                }
            }
        }
    }

    @ViewBuilder
    private func recordsSection(_ exercise: Exercise) -> some View {
        let records = app.history.records.records(for: exercise.id)
        Section {
            if records.isEmpty {
                Text("Records appear once you've logged this exercise.")
                    .foregroundStyle(.secondary)
            }
            ForEach(records) { record in
                RecordRow(record: record, tracking: exercise.tracking, showsExercise: false)
            }
        } header: {
            Text("Personal Records")
        } footer: {
            Text("Warm-up sets never count toward records.")
        }
    }
}

struct RecordRow: View {
    let record: PersonalRecord
    let tracking: TrackingType
    var showsExercise = true
    @Environment(AppModel.self) private var app

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "trophy.fill")
                .foregroundStyle(Theme.record)
                .frame(width: 30)
            VStack(alignment: .leading, spacing: 2) {
                if showsExercise {
                    Text(app.library.exercise(record.exerciseID)?.name ?? "Exercise")
                        .font(.app(.subheadline, .semibold))
                }
                Text(record.kind.displayName)
                    .font(showsExercise ? .app(.caption) : .app(.subheadline, .semibold))
                    .foregroundStyle(showsExercise ? Color.secondary : Color.primary)
                Text(record.date.formatted(date: .abbreviated, time: .omitted))
                    .font(.app(.caption))
                    .foregroundStyle(.tertiary)
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 2) {
                Text(RecordFormatter.value(record, tracking: tracking, units: app.settings.units))
                    .font(.num(.body, .semibold))
                if let context = RecordFormatter.context(record, tracking: tracking, units: app.settings.units) {
                    Text(context)
                        .font(.app(.caption))
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(.vertical, 2)
    }
}

enum RecordFormatter {
    static func value(_ record: PersonalRecord, tracking: TrackingType, units: UnitPreferences) -> String {
        switch record.kind {
        case .heaviestWeight, .bestOneRepMax: return units.weight(record.value)
        case .bestSetVolume, .bestSessionVolume: return units.volume(record.value)
        case .mostReps, .mostSessionReps: return "\(Int(record.value)) reps"
        case .longestDuration: return DurationFormat.precise(record.value)
        case .longestDistance: return units.distance(record.value, short: tracking.usesShortDistance)
        case .bestPace:
            let perUnit = record.value * (units.distance == .miles ? DistanceUnit.metersPerMile / 1000 : 1)
            return "\(DurationFormat.clock(perUnit)) /\(units.distance.longSymbol)"
        }
    }

    static func context(_ record: PersonalRecord, tracking: TrackingType, units: UnitPreferences) -> String? {
        if let previous = record.previousValue {
            var copy = record
            copy.value = previous
            return "was \(value(copy, tracking: tracking, units: units))"
        }
        guard let weight = record.weight, let reps = record.reps, record.kind != .heaviestWeight || reps > 1 else { return nil }
        return "\(units.weight(weight)) × \(reps)"
    }
}

/// Line chart of one metric across sessions.
struct ProgressChart: View {
    let points: [ProgressPoint]
    let metric: ExerciseMetric
    let tracking: TrackingType
    @Environment(AppModel.self) private var app

    var body: some View {
        let units = app.settings.units
        let domain = yDomain(units: units)
        Chart(points) { point in
            LineMark(
                x: .value("Date", point.date),
                y: .value(metric.displayName, displayValue(point.value, units: units))
            )
            .interpolationMethod(.monotone)
            .foregroundStyle(Color.accentColor)
            // Filled down to the bottom of the visible range rather than to
            // zero, so progress isn't flattened.
            AreaMark(
                x: .value("Date", point.date),
                yStart: .value("Base", domain.lowerBound),
                yEnd: .value(metric.displayName, displayValue(point.value, units: units))
            )
            .interpolationMethod(.monotone)
            .foregroundStyle(LinearGradient(colors: [Color.accentColor.opacity(0.25), .clear], startPoint: .top, endPoint: .bottom))
            PointMark(
                x: .value("Date", point.date),
                y: .value(metric.displayName, displayValue(point.value, units: units))
            )
            .foregroundStyle(Color.accentColor)
            .symbolSize(points.count > 30 ? 12 : 30)
        }
        .chartYScale(domain: domain)
        .chartYAxis {
            AxisMarks(position: .leading) { _ in
                AxisGridLine().foregroundStyle(Theme.line)
                AxisValueLabel().font(.num(.caption2, .regular))
            }
        }
        .chartXAxis {
            AxisMarks { _ in
                AxisGridLine().foregroundStyle(Theme.line)
                AxisValueLabel().font(.num(.caption2, .regular))
            }
        }
    }

    private func yDomain(units: UnitPreferences) -> ClosedRange<Double> {
        let values = points.map { displayValue($0.value, units: units) }
        guard let low = values.min(), let high = values.max() else { return 0...1 }
        let padding = Swift.max((high - low) * 0.2, high * 0.05, 1)
        return Swift.max(0, low - padding)...(high + padding)
    }

    private func displayValue(_ value: Double, units: UnitPreferences) -> Double {
        switch metric {
        case .estimatedOneRepMax, .maxWeight, .sessionVolume: return units.weight.fromKilograms(value)
        case .totalDistance: return units.distance.fromMeters(value, short: tracking.usesShortDistance)
        case .totalDuration: return value / 60
        case .pace: return value / 60
        case .maxReps, .totalReps: return value
        }
    }
}
