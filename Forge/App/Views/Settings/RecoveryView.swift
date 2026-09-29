import SwiftUI
import UniformTypeIdentifiers

/// Looks through every snapshot, set-aside data file and backup file Forge
/// can reach for things that aren't in the app anymore (a workout that
/// vanished, sets that were never saved) and brings back what the athlete
/// picks. Nothing already in Forge changes, except a workout the athlete
/// chooses to replace with a fuller copy.
struct RecoveryView: View {
    @Environment(AppModel.self) private var app
    @State private var selectedWorkouts = Set<UUID>()
    @State private var selectedRoutines = Set<UUID>()
    @State private var selectedCustoms = Set<String>()
    @State private var includeMeasurements = true
    @State private var includePresets = true
    @State private var selectionScan = -1
    @State private var confirmingRestore = false
    @State private var restoredCount: Int?

    var body: some View {
        let data = app.dataSafety
        List {
            if let progress = data.scanProgress {
                scanningSection(progress)
            } else if let report = data.recoveryReport {
                resultSections(report)
            } else if let restoredCount {
                restoredSection(restoredCount)
            } else {
                startSection
            }
        }
        .canvasBackground()
        .navigationTitle("Find Missing Data")
        .stallContext("Find missing data")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button("Scan Again", systemImage: "arrow.clockwise") { scan() }
                    Button("Scan a Backup File…", systemImage: "doc.badge.plus") { scanBackupFile() }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
                .disabled(data.scanProgress != nil || data.isRestoringFound)
            }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if data.scanProgress == nil, let report = data.recoveryReport, !report.isEmpty {
                restoreBar(report)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .confirmationDialog(
            "Restore \(selectedCount) \(selectedCount == 1 ? "item" : "items")?",
            isPresented: $confirmingRestore,
            titleVisibility: .visible
        ) {
            Button("Restore") { restore() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(restoreMessage)
        }
        .onAppear {
            if data.recoveryReport == nil, data.scanProgress == nil, restoredCount == nil {
                scan()
            } else {
                selectDefaults()
            }
        }
        .onChange(of: data.scanCount) { _, _ in selectDefaults() }
        .animation(Motion.smooth, value: data.scanProgress == nil)
        .animation(Motion.smooth, value: data.scanCount)
    }

    // MARK: States

    private var startSection: some View {
        Section {
            VStack(alignment: .leading, spacing: 10) {
                Label("Look for missing data", systemImage: "sparkle.magnifyingglass")
                    .font(.app(.headline))
                Text("Forge checks every snapshot and backup file it can reach for workouts, routines and other items that aren't in the app anymore. Nothing changes until you choose what to bring back.")
                    .font(.app(.subheadline))
                    .foregroundStyle(.secondary)
                Button("Start Scan") { scan() }
                    .buttonStyle(.borderedProminent)
                    .foregroundStyle(Theme.onAccent)
            }
            .padding(.vertical, 6)
        }
    }

    private func scanningSection(_ progress: DataSafetyStore.ScanProgress) -> some View {
        Section {
            VStack(alignment: .leading, spacing: 12) {
                Label("Looking through your backups", systemImage: "sparkle.magnifyingglass")
                    .font(.app(.headline))
                    .symbolEffect(.pulse, options: .repeating)
                ProgressView(value: Double(progress.done), total: Double(max(progress.total, 1)))
                    .tint(Color.accentColor)
                    .animation(Motion.smooth, value: progress.done)
                Text(progress.total == 0 ? "Getting ready…" : "Checked \(progress.done) of \(progress.total)")
                    .font(.num(.subheadline))
                    .foregroundStyle(.secondary)
                    .contentTransition(.numericText())
            }
            .padding(.vertical, 6)
        } footer: {
            Text("Snapshots, set-aside data files, and backup files on this iPhone and in your backup folder.")
        }
    }

    private func restoredSection(_ count: Int) -> some View {
        Section {
            VStack(alignment: .leading, spacing: 10) {
                Label("Restored \(count) \(count == 1 ? "item" : "items")", systemImage: "checkmark.seal.fill")
                    .font(.app(.headline))
                    .foregroundStyle(Theme.success)
                Text("They're back in History, Train and Progress. A snapshot from just before the restore was saved too, in case you want to undo it.")
                    .font(.app(.subheadline))
                    .foregroundStyle(.secondary)
                Button("Scan Again") { scan() }
                    .buttonStyle(.bordered)
            }
            .padding(.vertical, 6)
        }
    }

    @ViewBuilder
    private func resultSections(_ report: RecoveryService.Report) -> some View {
        Section {
            summaryCard(report)
        }
        if !app.history.deleted.isEmpty {
            Section {
                NavigationLink {
                    RecentlyDeletedView()
                } label: {
                    HStack {
                        Label("Recently Deleted", systemImage: "trash")
                        Spacer()
                        Text("\(app.history.deleted.count) \(app.history.deleted.count == 1 ? "workout" : "workouts")")
                            .foregroundStyle(.secondary)
                    }
                }
            } footer: {
                Text("Workouts deleted in the last 30 days are there, not here.")
            }
        }

        let missing = report.workouts.filter { !$0.isReplacement }
        let fuller = report.workouts.filter(\.isReplacement)
        if !missing.isEmpty {
            Section {
                ForEach(missing) { found in
                    selectableRow(isOn: selectedWorkouts.contains(found.id)) {
                        toggle(found.id, in: &selectedWorkouts)
                    } content: {
                        FoundWorkoutLabel(found: found)
                    }
                }
            } header: {
                Text("Missing Workouts")
            }
        }
        if !fuller.isEmpty {
            Section {
                ForEach(fuller) { found in
                    selectableRow(isOn: selectedWorkouts.contains(found.id)) {
                        toggle(found.id, in: &selectedWorkouts)
                    } content: {
                        FoundWorkoutLabel(found: found)
                    }
                }
            } header: {
                Text("Fuller Copies")
            } footer: {
                Text("These workouts are in History with fewer sets than a backup has, often sets that were typed in but never checked off. Choosing one replaces the saved copy's sets and keeps its name, notes and rating.")
            }
        }
        if !report.routines.isEmpty {
            Section("Routines") {
                ForEach(report.routines) { routine in
                    selectableRow(isOn: selectedRoutines.contains(routine.id)) {
                        toggle(routine.id, in: &selectedRoutines)
                    } content: {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(routine.name.isEmpty ? "Untitled routine" : routine.name)
                                .font(.app(.body, .semibold))
                            Text("\(routine.exerciseCount) \(routine.exerciseCount == 1 ? "exercise" : "exercises") · edited \(routine.updatedAt.formatted(date: .abbreviated, time: .omitted))")
                                .font(.app(.caption))
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }
        if !report.customExercises.isEmpty {
            Section {
                ForEach(report.customExercises) { exercise in
                    selectableRow(isOn: selectedCustoms.contains(exercise.id)) {
                        toggle(exercise.id, in: &selectedCustoms)
                    } content: {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(exercise.name)
                                .font(.app(.body, .semibold))
                            Text(exercise.primaryMuscle.displayName)
                                .font(.app(.caption))
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            } header: {
                Text("Custom Exercises")
            } footer: {
                Text("Custom exercises used by the workouts and routines you restore come back with them.")
            }
        }
        if !report.measurements.isEmpty || !report.timerPresets.isEmpty {
            Section("Other") {
                if !report.measurements.isEmpty {
                    Toggle(isOn: $includeMeasurements) {
                        Label("\(report.measurements.count) body \(report.measurements.count == 1 ? "measurement" : "measurements")", systemImage: "figure")
                    }
                }
                if !report.timerPresets.isEmpty {
                    Toggle(isOn: $includePresets) {
                        Label("\(report.timerPresets.count) timer \(report.timerPresets.count == 1 ? "preset" : "presets")", systemImage: "timer")
                    }
                }
            }
        }
        Section {
            Button {
                scanBackupFile()
            } label: {
                Label("Scan a Backup File…", systemImage: "doc.badge.plus")
            }
            .accessibilityIdentifier("scanBackupFile")
        } footer: {
            Text("Have a backup saved somewhere else, like another folder in Files or an email attachment? Forge can check it too.")
        }
    }

    private func summaryCard(_ report: RecoveryService.Report) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            if report.sourcesScanned == 0 {
                Label("No backups to check yet", systemImage: "clock.arrow.circlepath")
                    .font(.app(.headline))
                Text("Forge makes snapshots and backup files as you use it. If you have a backup file saved somewhere else, scan it below.")
                    .font(.app(.subheadline))
                    .foregroundStyle(.secondary)
            } else if report.isEmpty {
                Label("Nothing is missing", systemImage: "checkmark.shield.fill")
                    .font(.app(.headline))
                    .foregroundStyle(Theme.success)
                Text("Forge compared your data with \(backupsText(report.sourcesScanned)). Everything in them is already here.")
                    .font(.app(.subheadline))
                    .foregroundStyle(.secondary)
            } else {
                Label("Found \(report.itemCount) \(report.itemCount == 1 ? "item" : "items") not in Forge", systemImage: "arrow.counterclockwise.circle.fill")
                    .font(.app(.headline))
                    .foregroundStyle(Color.accentColor)
                Text("From \(backupsText(report.sourcesScanned)). Choose what to bring back; nothing already in Forge changes.")
                    .font(.app(.subheadline))
                    .foregroundStyle(.secondary)
            }
            if report.deletedOnPurpose > 0 {
                Text("\(report.deletedOnPurpose) \(report.deletedOnPurpose == 1 ? "item" : "items") you deleted yourself \(report.deletedOnPurpose == 1 ? "isn't" : "aren't") shown.")
                    .font(.app(.caption))
                    .foregroundStyle(.secondary)
            }
            if !report.unreadableSources.isEmpty {
                Text("\(report.unreadableSources.count) \(report.unreadableSources.count == 1 ? "backup" : "backups") couldn't be read.")
                    .font(.app(.caption))
                    .foregroundStyle(Theme.warning)
            }
        }
        .padding(.vertical, 6)
    }

    private func restoreBar(_ report: RecoveryService.Report) -> some View {
        let count = selectedCount
        return Button {
            confirmingRestore = true
        } label: {
            HStack(spacing: 8) {
                if app.dataSafety.isRestoringFound {
                    ProgressView()
                        .tint(Theme.onAccent)
                }
                Text(count == 0 ? "Choose Items to Restore" : "Restore \(count) \(count == 1 ? "Item" : "Items")")
                    .contentTransition(.numericText())
            }
            .font(.app(.body, .semibold))
            .frame(maxWidth: .infinity)
            .padding(.vertical, 6)
        }
        .buttonStyle(.borderedProminent)
        .foregroundStyle(Theme.onAccent)
        .disabled(count == 0 || app.dataSafety.isRestoringFound)
        .accessibilityIdentifier("restoreFoundItems")
        .padding(.horizontal, 16)
        .padding(.top, 10)
        .padding(.bottom, 8)
        .background(.bar)
        .animation(Motion.snappy, value: count)
    }

    private func selectableRow<Content: View>(isOn: Bool, toggle: @escaping () -> Void, @ViewBuilder content: () -> Content) -> some View {
        Button(action: toggle) {
            HStack(spacing: 12) {
                Image(systemName: isOn ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 22, weight: .regular))
                    .foregroundStyle(isOn ? Color.accentColor : Color.secondary)
                    .contentTransition(.symbolEffect(.replace))
                content()
                Spacer(minLength: 0)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .sensoryFeedback(.selection, trigger: isOn)
        .accessibilityAddTraits(isOn ? .isSelected : [])
    }

    // MARK: Selection

    private var selectedCount: Int {
        guard let report = app.dataSafety.recoveryReport else { return 0 }
        return selection(from: report).itemCount
    }

    private func selection(from report: RecoveryService.Report) -> RecoveryService.Report {
        report.selecting(
            workouts: selectedWorkouts,
            routines: selectedRoutines,
            customExercises: selectedCustoms,
            measurements: includeMeasurements ? Set(report.measurements.map(\.id)) : [],
            timerPresets: includePresets ? Set(report.timerPresets.map(\.id)) : []
        )
    }

    /// Everything missing is picked; fuller copies replace what's saved,
    /// so those wait for the athlete to choose them.
    private func selectDefaults() {
        let data = app.dataSafety
        guard let report = data.recoveryReport, selectionScan != data.scanCount else { return }
        selectionScan = data.scanCount
        selectedWorkouts = Set(report.workouts.filter { !$0.isReplacement }.map(\.id))
        selectedRoutines = Set(report.routines.map(\.id))
        selectedCustoms = Set(report.customExercises.map(\.id))
        includeMeasurements = true
        includePresets = true
    }

    private func toggle<ID: Hashable>(_ id: ID, in set: inout Set<ID>) {
        withAnimation(Motion.snappy) {
            if set.contains(id) {
                set.remove(id)
            } else {
                set.insert(id)
            }
        }
    }

    private var restoreMessage: String {
        guard let report = app.dataSafety.recoveryReport else { return "" }
        let chosen = selection(from: report)
        var text = "They're added to Forge alongside what's there now. A snapshot is saved first, so this can be undone."
        let replacing = chosen.workouts.filter(\.isReplacement).count
        if replacing > 0 {
            text += " \(replacing) saved \(replacing == 1 ? "workout gets" : "workouts get") the fuller copy's sets."
        }
        return text
    }

    // MARK: Actions

    /// Looks through a backup file the athlete picks. It's read from a copy,
    /// which works however Forge was installed.
    private func scanBackupFile() {
        DocumentPicker.shared.importCopy(of: [.json, .data]) { url in
            if let url { scan(including: url) }
        }
    }

    private func scan(including file: URL? = nil) {
        restoredCount = nil
        app.dataSafety.scanForMissingData(including: file)
    }

    private func restore() {
        guard let report = app.dataSafety.recoveryReport else { return }
        let chosen = selection(from: report)
        Task {
            if await app.dataSafety.restoreFound(chosen) {
                withAnimation(Motion.smooth) { restoredCount = chosen.itemCount }
            }
        }
    }

    private func backupsText(_ count: Int) -> String {
        count == 1 ? "1 backup" : "\(count) backups"
    }
}

/// A workout found in a backup: what it was, how much is in it, and where
/// it came from.
struct FoundWorkoutLabel: View {
    let found: RecoveryService.FoundWorkout

    var body: some View {
        let workout = found.workout
        VStack(alignment: .leading, spacing: 3) {
            Text(workout.name.isEmpty ? "Workout" : workout.name)
                .font(.app(.body, .semibold))
            Text("\(workout.startedAt.formatted(date: .abbreviated, time: .shortened)) · \(setsText)")
                .font(.app(.caption))
                .foregroundStyle(found.isReplacement ? Color.accentColor : .secondary)
            let names = workout.allExercises.map(\.name)
            if !names.isEmpty {
                Text(names.prefix(3).joined(separator: ", ") + (names.count > 3 ? " +\(names.count - 3)" : ""))
                    .font(.app(.caption))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Text(found.sourceLabel)
                .font(.app(.caption2))
                .foregroundStyle(.tertiary)
                .lineLimit(1)
        }
    }

    private var setsText: String {
        let sets = found.loggedSets == 1 ? "1 set" : "\(found.loggedSets) sets"
        if let current = found.replacesLoggedSets {
            return "\(sets) (History has \(current))"
        }
        return sets
    }
}
